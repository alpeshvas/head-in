#!/usr/bin/env node
/**
 * Route-constrained grid Bayes filter (Phase 2 estimator from docs/research/SYNTHESIS.md).
 *
 * Replaces the heuristic threshold matcher with the design recommended by
 * docs/research/route-constrained-fusion.md:
 *
 *   - State: discrete grid over global route position (all profile segments
 *     concatenated, ~240 bins/segment) plus one explicit OFF-route state.
 *   - Transition: step-driven. Each detected step advances belief by the
 *     per-segment calibrated stride (bins/step) with ~35% noise and a small
 *     backward/stay tail; standing applies only tiny diffusion. Every step
 *     leaks a little probability into OFF; OFF re-enters near the current mode.
 *   - Emission: mean-removed pointwise Gaussian of the last N steps of magnetic
 *     magnitude (resampled PER STEP to bin units, Magicol-style) against the
 *     profile mean/stddev (heteroscedastic noise). Flat windows (< minimum µT
 *     range) are skipped entirely. OFF emits against a structureless profile.
 *   - Decisions: checkpoint k fires when P(position >= anchor_k) > tau on two
 *     consecutive updates with P(OFF) < 0.5. Off-route fires when P(OFF) > 0.5
 *     sustained. No ratchet anywhere: the posterior may retreat.
 *
 * Scoring uses recorded anchors (true checkpoint times) and, when present,
 * ARKit ground truth (true meters) via analysis/ground-truth.js.
 *
 * Usage:
 *   node analysis/grid-filter.js <profile.json> <session.jsonl> [--out report.html]
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { buildArcLength } = require('./ground-truth');
const { detectTurns } = require('./turn-events');

// sensorSigmaUT and offLogLikPerPoint were fitted with --calibrate against the
// held-out Plumeria clean pass (hand pose). Re-fit per venue/pose as data grows.
const PARAMS = {
  sensorSigmaUT: 1.5,        // extra magnetic noise on top of survey stddev (µT); fitted
  minWindowRangeUT: 3.0,     // flat-window gate: skip emission below this live range
  windowSteps: 4,            // emission window length in detected steps
  stepNoiseFrac: 0.35,       // stddev of stride noise as a fraction of bins/step
  kernelFloor: 1e-4,         // uniform floor inside the step kernel support (backtrack)
  obsIndependenceBins: 8,    // temper: ~1 independent magnetic observation per this many bins
  offLeakPerStep: 0.02,      // P(enter OFF) per step
  unobservedOffLeak: 0.04,   // EXTRA leak when a step had no magnetic corroboration
  observationRecencySteps: 2, // checkpoint decisions need an observation this recent
  offStay: 0.95,             // P(stay OFF) per step
  idleDiffusionSigma: 0.6,   // bins/sec of diffusion while standing
  checkpointTau: 0.8,        // P(position >= checkpoint) needed to fire
  offRouteTau: 0.5,          // P(OFF) needed to flag off-route
  offRouteSustainSec: 3.0,   // how long P(OFF) must stay above tau
  minStepIntervalS: 0.34,
  // Fitted from replays via --calibrate (Newson-Krumm recipe): the typical
  // per-point log-likelihood of a live window evaluated at a WRONG position.
  // null -> fall back to the structureless-field OFF model.
  offLogLikPerPoint: -4.86, // must be re-fitted whenever sensorSigmaUT changes
  // Turn-anchor observation (Phase 3). A detected turn that matches a profile
  // signature turn (same direction, magnitude within tolerance) concentrates
  // belief around the signature bin; a large turn matching nothing favors OFF.
  turnMatchToleranceDeg: 55, // |live delta - signature delta| to count as a match
  turnLikFloor: 0.05,        // on-route likelihood far from any matching turn
  turnOffLik: 0.3,           // OFF-state likelihood for a matched turn event
  turnNegativeMinDeg: 100,   // unmatched turns below this are ignored, not OFF evidence
  // An unmatched U-turn is a TRANSITION, not an emission: the walker reversed
  // where the route has no turn, so on-route mass moves into OFF directly
  // (a likelihood reweight cannot create OFF mass when P(OFF) is ~0), and the
  // following steps keep leaking because the step kernel still pushes belief
  // forward while the walker is actually heading back.
  turnUTurnOffLeak: 0.5,     // on-route mass moved to OFF at the reversal itself
  turnReversalLeakPerStep: 0.12, // extra per-step leak after an unexplained reversal
  turnReversalSteps: 8,      // how many steps the reversal leak lasts
};

// ---------------------------------------------------------------------------
// Session parsing (magnetic + user-acceleration + anchors + AR poses)

function parseSession(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  let meta = null;
  const dm = [];
  const anchors = [];
  const arPoses = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj.type === 'meta') meta = obj;
    else if (obj.type === 'dm' && obj.mag) {
      const t = Number(obj.t);
      const mag = Math.hypot(Number(obj.mag.x), Number(obj.mag.y), Number(obj.mag.z));
      const ua = obj.ua ? Math.hypot(Number(obj.ua.x), Number(obj.ua.y), Number(obj.ua.z)) : NaN;
      let yawRate = NaN;
      if (obj.rot && obj.g) {
        const gm = Math.hypot(obj.g.x, obj.g.y, obj.g.z) || 1;
        yawRate = -(obj.rot.x * obj.g.x + obj.rot.y * obj.g.y + obj.rot.z * obj.g.z) / gm;
      }
      if (Number.isFinite(t) && Number.isFinite(mag)) dm.push({ t, mag, ua, yawRate });
    } else if (obj.type === 'anchor' && Number.isFinite(Number(obj.t))) {
      anchors.push({ t: Number(obj.t), index: obj.index, name: String(obj.name ?? '') });
    } else if (obj.type === 'anchor_undo') {
      for (let i = anchors.length - 1; i >= 0; i--) {
        if (anchors[i].index === obj.index) { anchors.splice(i, 1); break; }
      }
    } else if (obj.type === 'arpose' && obj.p) {
      const t = Number(obj.t);
      const x = Number(obj.p.x), y = Number(obj.p.y), z = Number(obj.p.z);
      if ([t, x, y, z].every(Number.isFinite)) arPoses.push({ t, x, y, z, tracking: String(obj.track || '') });
    }
  }
  if (!meta) throw new Error(`${filePath}: no meta line`);
  if (dm.length === 0) throw new Error(`${filePath}: no dm samples`);
  dm.sort((a, b) => a.t - b.t);
  anchors.sort((a, b) => a.t - b.t);
  arPoses.sort((a, b) => a.t - b.t);
  return { file: path.basename(filePath), meta, dm, anchors, arPoses };
}

// ---------------------------------------------------------------------------
// Step detection (same recipe as match-route.js / the on-device detector)

function median(values) {
  if (!values.length) return 0;
  const s = values.slice().sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function detectSteps(dm) {
  const usable = dm.filter((s) => Number.isFinite(s.ua));
  if (usable.length < 3) return [];
  const radius = 3;
  const signal = usable.map((_, i) => {
    let sum = 0, n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(usable.length - 1, i + radius); j++) { sum += usable[j].ua; n++; }
    return sum / n;
  });
  const med = median(signal);
  const mad = median(signal.map((v) => Math.abs(v - med))) || 0.03;
  const threshold = med + Math.max(0.045, 1.6 * mad);
  const steps = [];
  let last = -Infinity;
  for (let i = 1; i < signal.length - 1; i++) {
    if (signal[i] > signal[i - 1] && signal[i] >= signal[i + 1] && signal[i] > threshold
        && usable[i].t - last >= PARAMS.minStepIntervalS) {
      steps.push(usable[i].t);
      last = usable[i].t;
    }
  }
  return steps;
}

// ---------------------------------------------------------------------------
// Global route profile: concatenate all segments into one bin axis

function buildGlobalProfile(profile) {
  const mean = [];
  const std = [];
  const segments = [];
  const anchorBins = new Map(); // anchor name -> bin where it sits

  for (const seg of profile.segments) {
    const m = seg.magneticMagnitude && seg.magneticMagnitude.mean;
    const s = (seg.magneticMagnitude && seg.magneticMagnitude.stddev) || [];
    if (!Array.isArray(m) || m.length < 2) {
      throw new Error(`segment ${seg.index} has no magnetic mean array; cannot build global grid`);
    }
    const startBin = mean.length;
    if (!anchorBins.has(seg.from)) anchorBins.set(seg.from, startBin);
    for (let i = 0; i < m.length; i++) {
      mean.push(m[i]);
      std.push(Number.isFinite(s[i]) ? Math.max(s[i], 0.2) : 1.0);
    }
    const medianSteps = Math.max(seg.detectedSteps && seg.detectedSteps.median || 0, 1);
    segments.push({
      index: seg.index,
      from: seg.from,
      to: seg.to,
      isTransition: seg.kind === 'transition' || seg.useForMatching === false,
      startBin,
      count: m.length,
      binsPerStep: m.length / medianSteps,
    });
    anchorBins.set(seg.to, mean.length - 1);
  }

  const globalMean = mean.reduce((a, b) => a + b, 0) / mean.length;
  const globalVar = mean.reduce((a, b) => a + (b - globalMean) ** 2, 0) / mean.length;

  const turns = Array.isArray(profile.turns) ? profile.turns : [];
  return { mean, std, segments, anchorBins, bins: mean.length, globalMean, globalVar, turns };
}

function segmentOfBin(gp, bin) {
  for (const seg of gp.segments) {
    if (bin < seg.startBin + seg.count) return seg;
  }
  return gp.segments[gp.segments.length - 1];
}

/**
 * Mean-removed Gaussian log-likelihood of a live window whose newest sample sits
 * at global bin `endBin`. Mean removal cancels device hard-iron bias and iOS
 * recalibration offsets (Magicol recipe). Returns per-point stats or null when
 * the window does not fit.
 */
function perPointLogLik(gp, live, endBin) {
  const L = live.length;
  if (endBin - L + 1 < 0 || endBin >= gp.bins) return null;

  let liveMean = 0, profMean = 0;
  for (let k = 0; k < L; k++) { liveMean += live[k]; profMean += gp.mean[endBin - L + 1 + k]; }
  liveMean /= L; profMean /= L;

  let ll = 0;
  const residuals = [];
  for (let k = 0; k < L; k++) {
    const idx = endBin - L + 1 + k;
    const resid = (live[k] - liveMean) - (gp.mean[idx] - profMean);
    const v = gp.std[idx] ** 2 + PARAMS.sensorSigmaUT ** 2;
    ll += -0.5 * (resid * resid / v + Math.log(2 * Math.PI * v));
    residuals.push(resid);
  }
  return { perPoint: ll / L, residuals };
}

// ---------------------------------------------------------------------------
// The filter

class RouteGridFilter {
  constructor(globalProfile) {
    this.gp = globalProfile;
    this.belief = new Float64Array(globalProfile.bins).fill(0);
    // Initialize at route start with a little spread.
    for (let i = 0; i < Math.min(8, globalProfile.bins); i++) this.belief[i] = Math.exp(-i / 3);
    this.pOff = 0.0;
    this.reversalStepsLeft = 0;
    this.normalize();
  }

  normalize() {
    let sum = this.pOff;
    for (const v of this.belief) sum += v;
    if (sum <= 0) { this.belief.fill(1 / this.belief.length); this.pOff = 0; return; }
    for (let i = 0; i < this.belief.length; i++) this.belief[i] /= sum;
    this.pOff /= sum;
  }

  /** One detected step: advance by per-segment stride with noise + OFF leak. */
  predictStep() {
    const gp = this.gp;
    const next = new Float64Array(gp.bins).fill(0);
    let leaked = 0;

    for (let i = 0; i < gp.bins; i++) {
      const p = this.belief[i];
      if (p <= 0) continue;
      const m = segmentOfBin(gp, i).binsPerStep;
      const sigma = Math.max(0.8, PARAMS.stepNoiseFrac * m);
      const lo = Math.floor(i - m);          // allow a backward step
      const hi = Math.ceil(i + 3 * m);       // up to 3 strides forward
      let kernelSum = 0;
      for (let j = lo; j <= hi; j++) {
        kernelSum += Math.exp(-0.5 * ((j - i - m) / sigma) ** 2) + PARAMS.kernelFloor;
      }
      const stay = p * (1 - PARAMS.offLeakPerStep);
      for (let j = lo; j <= hi; j++) {
        const k = Math.exp(-0.5 * ((j - i - m) / sigma) ** 2) + PARAMS.kernelFloor;
        const share = stay * (k / kernelSum);
        if (j < 0) {
          next[0] += share;                  // route start is a barrier
        } else if (j >= gp.bins) {
          leaked += share;                   // stepping past the route end = off-route evidence
        } else {
          next[j] += share;
        }
      }
      leaked += p * PARAMS.offLeakPerStep;
    }

    // OFF dynamics: stay or re-enter proportional to current on-route shape.
    const reenter = this.pOff * (1 - PARAMS.offStay);
    let beliefSum = 0;
    for (const v of next) beliefSum += v;
    if (beliefSum > 0 && reenter > 0) {
      for (let i = 0; i < next.length; i++) next[i] += reenter * (next[i] / beliefSum);
    }
    this.belief = next;
    this.pOff = this.pOff * PARAMS.offStay + leaked;
    // Steps taken while the heading is unexplained (after an unmatched U-turn)
    // are not credible route progress.
    if (this.reversalStepsLeft > 0) {
      this.reversalStepsLeft--;
      let mass = 0;
      for (let i = 0; i < this.belief.length; i++) {
        const leak = this.belief[i] * PARAMS.turnReversalLeakPerStep;
        this.belief[i] -= leak;
        mass += leak;
      }
      this.pOff += mass;
    }
    this.normalize();
  }

  /** A step happened but magnetic evidence could not corroborate it (flat window,
   *  uncalibrated sensor): motion without verification raises route uncertainty. */
  applyUnobservedLeak() {
    let mass = 0;
    for (let i = 0; i < this.belief.length; i++) {
      const leak = this.belief[i] * PARAMS.unobservedOffLeak;
      this.belief[i] -= leak;
      mass += leak;
    }
    this.pOff += mass;
    this.normalize();
  }

  /** Standing/idle: tiny diffusion, no stride. */
  predictIdle(dtSec) {
    const sigma = PARAMS.idleDiffusionSigma * Math.max(dtSec, 0);
    if (sigma < 0.05) return;
    const radius = Math.ceil(3 * sigma);
    const kernel = [];
    let ks = 0;
    for (let d = -radius; d <= radius; d++) { const k = Math.exp(-0.5 * (d / sigma) ** 2); kernel.push(k); ks += k; }
    const next = new Float64Array(this.gp.bins).fill(0);
    for (let i = 0; i < this.gp.bins; i++) {
      const p = this.belief[i];
      if (p <= 0) continue;
      for (let d = -radius; d <= radius; d++) {
        const j = Math.min(this.gp.bins - 1, Math.max(0, i + d));
        next[j] += p * (kernel[d + radius] / ks);
      }
    }
    this.belief = next;
    this.normalize();
  }

  /**
   * Emission update. `liveWindowForSegment(seg)` returns the live magnitude window
   * resampled to that segment's bin rate (per-step), newest sample last, or null.
   */
  observe(liveWindowForSegment) {
    const gp = this.gp;
    const logLik = new Float64Array(gp.bins).fill(NaN);
    const windowCache = new Map();
    let anyWindow = false;

    for (let s = 0; s < gp.bins; s++) {
      const seg = segmentOfBin(gp, s);
      if (!windowCache.has(seg.index)) windowCache.set(seg.index, liveWindowForSegment(seg));
      const live = windowCache.get(seg.index);
      if (!live) continue;
      const L = live.length;
      if (s - L + 1 < 0) continue; // window must fit inside the route start

      const stats = perPointLogLik(gp, live, s);
      if (!stats) continue;
      logLik[s] = stats.perPoint * PARAMS.obsIndependenceBins; // temper autocorrelation
      anyWindow = true;
    }
    if (!anyWindow) return false;

    // OFF model: calibrated mismatch level when fitted, else a structureless field.
    let offLL = NaN;
    if (PARAMS.offLogLikPerPoint !== null) {
      offLL = PARAMS.offLogLikPerPoint * PARAMS.obsIndependenceBins;
    } else {
      for (const live of windowCache.values()) {
        if (!live) continue;
        const L = live.length;
        let liveMean = 0;
        for (const v of live) liveMean += v;
        liveMean /= L;
        const v = this.gp.globalVar + PARAMS.sensorSigmaUT ** 2;
        let ll = 0;
        for (const x of live) ll += -0.5 * (((x - liveMean) ** 2) / v + Math.log(2 * Math.PI * v));
        offLL = (ll / L) * PARAMS.obsIndependenceBins;
        break; // all segments share the same underlying samples
      }
    }

    // Log-space update against the max for numeric stability.
    let maxLL = Number.isFinite(offLL) ? offLL : -Infinity;
    for (const ll of logLik) if (Number.isFinite(ll) && ll > maxLL) maxLL = ll;
    for (let s = 0; s < gp.bins; s++) {
      if (Number.isFinite(logLik[s])) this.belief[s] *= Math.exp(logLik[s] - maxLL);
      // bins with no window (too close to route start) keep prior weight unchanged
    }
    if (Number.isFinite(offLL)) this.pOff *= Math.exp(offLL - maxLL);
    this.normalize();
    return true;
  }

  /**
   * Turn-anchor observation (Phase 3, UnLoc-style landmark reset). The
   * likelihood over bins is a floor plus a Gaussian bump at every signature
   * turn whose direction matches and whose magnitude is within tolerance;
   * OFF gets a constant (people turn off-route at some rate). A matched turn
   * therefore snaps belief to the turn's bin; a large turn that matches no
   * signature turn pushes mass into OFF.
   */
  observeTurn(deltaDeg) {
    const matches = this.gp.turns.filter(
      (turn) => Math.sign(turn.deltaDeg) === Math.sign(deltaDeg) &&
        Math.abs(deltaDeg - turn.deltaDeg) <= PARAMS.turnMatchToleranceDeg
    );
    if (!matches.length) {
      // A modest unmatched turn (doorway wiggle, hand adjustment) is
      // uninformative; an unmatched U-turn-scale rotation is a transition
      // into OFF plus a sustained leak while the heading stays unexplained.
      if (Math.abs(deltaDeg) < PARAMS.turnNegativeMinDeg) return false;
      let moved = 0;
      for (let i = 0; i < this.belief.length; i++) {
        const leak = this.belief[i] * PARAMS.turnUTurnOffLeak;
        this.belief[i] -= leak;
        moved += leak;
      }
      this.pOff += moved;
      this.reversalStepsLeft = PARAMS.turnReversalSteps;
      this.normalize();
      return false;
    }
    // Matched turn: emission update. The Gaussian bump only re-concentrates
    // belief that already has support near the signature bin — a match cannot
    // teleport belief from elsewhere on the route.
    for (let i = 0; i < this.belief.length; i++) {
      let lik = PARAMS.turnLikFloor;
      for (const turn of matches) {
        lik += Math.exp(-0.5 * ((i - turn.bin) / turn.sigmaBins) ** 2);
      }
      this.belief[i] *= lik;
    }
    this.pOff *= PARAMS.turnOffLik;
    this.reversalStepsLeft = 0; // heading is explained again
    this.normalize();
    return true;
  }

  meanBin() {
    let m = 0, w = 0;
    for (let i = 0; i < this.belief.length; i++) { m += i * this.belief[i]; w += this.belief[i]; }
    return w > 0 ? m / w : 0;
  }

  probBeyond(bin) {
    let p = 0;
    for (let i = bin; i < this.belief.length; i++) p += this.belief[i];
    return p; // OFF mass intentionally excluded
  }
}

// ---------------------------------------------------------------------------
// Live window: resample the last `windowSteps` step intervals to bin units

function makeWindowProvider(dm, stepTimes) {
  // dm sorted by t. Returns provider(nowT) -> (segment) -> Float64Array|null
  function magAt(t) {
    // binary search + linear interpolation
    let lo = 0, hi = dm.length - 1;
    if (t <= dm[0].t) return dm[0].mag;
    if (t >= dm[hi].t) return dm[hi].mag;
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (dm[mid].t <= t) lo = mid; else hi = mid; }
    const span = dm[hi].t - dm[lo].t;
    const f = span > 0 ? (t - dm[lo].t) / span : 0;
    return dm[lo].mag + (dm[hi].mag - dm[lo].mag) * f;
  }

  return function providerAt(nowT) {
    const past = stepTimes.filter((t) => t <= nowT);
    if (past.length < 2) return () => null;
    const used = past.slice(-(PARAMS.windowSteps + 1)); // boundaries of last N intervals
    return function liveWindowForSegment(seg) {
      const perStep = Math.max(2, Math.round(seg.binsPerStep));
      const out = [];
      for (let k = 0; k < used.length - 1; k++) {
        const a = used[k], b = used[k + 1];
        for (let i = 0; i < perStep; i++) {
          out.push(magAt(a + ((b - a) * (i + 1)) / perStep));
        }
      }
      const lo = Math.min(...out), hi = Math.max(...out);
      if (hi - lo < PARAMS.minWindowRangeUT) return null; // flat-window gate
      return out;
    };
  };
}

// ---------------------------------------------------------------------------
// Replay + scoring

function metersMapper(session, gp) {
  // Map bin -> meters using AR segment lengths when available (else null).
  if (session.arPoses.length < 2 || session.anchors.length < 2) return null;
  const arc = buildArcLength(session.arPoses);
  const anchorByName = new Map(session.anchors.map((a) => [a.name, a]));
  const lens = [];
  for (const seg of gp.segments) {
    const a = anchorByName.get(seg.from);
    const b = anchorByName.get(seg.to);
    if (!a || !b || b.t <= a.t) return null;
    lens.push(arc.lengthAt(b.t) - arc.lengthAt(a.t));
  }
  const startT = anchorByName.get(gp.segments[0].from).t;
  function binToMeters(bin) {
    let acc = 0;
    for (let i = 0; i < gp.segments.length; i++) {
      const seg = gp.segments[i];
      if (bin < seg.startBin + seg.count || i === gp.segments.length - 1) {
        return acc + lens[i] * Math.min(1, Math.max(0, (bin - seg.startBin) / Math.max(seg.count - 1, 1)));
      }
      acc += lens[i];
    }
    return acc;
  }
  function truthMetersAt(t) { return arc.lengthAt(t) - arc.lengthAt(startT); }
  function metersToBin(m) {
    let acc = 0;
    for (let i = 0; i < gp.segments.length; i++) {
      const seg = gp.segments[i];
      if (m <= acc + lens[i] || i === gp.segments.length - 1) {
        const frac = lens[i] > 0 ? Math.min(1, Math.max(0, (m - acc) / lens[i])) : 0;
        return seg.startBin + frac * Math.max(seg.count - 1, 1);
      }
      acc += lens[i];
    }
    return gp.bins - 1;
  }
  return { binToMeters, truthMetersAt, metersToBin, lens, total: lens.reduce((a, b) => a + b, 0) };
}

/**
 * Newson-Krumm-style parameter fitting from a clean replay with ARKit truth:
 *   - sensorSigmaUT from the MAD of mean-removed residuals at the TRUE position
 *   - offLogLikPerPoint as the median per-point log-likelihood at WRONG positions
 *     (>= 2 strides away from truth) — the calibrated OFF/mismatch level
 */
function calibrate(profile, session) {
  const gp = buildGlobalProfile(profile);
  const mm = metersMapper(session, gp);
  if (!mm) throw new Error('calibration needs a session with ARKit ground truth and all anchors');

  const steps = detectSteps(session.dm);
  const provider = makeWindowProvider(session.dm, steps);
  const matchedResiduals = [];
  const matchedPerPoint = [];
  const mismatchPerPoint = [];

  for (const t of steps) {
    const liveFor = provider(t);
    const trueBin = Math.round(mm.metersToBin(mm.truthMetersAt(t)));
    const seg = segmentOfBin(gp, Math.min(trueBin, gp.bins - 1));
    const live = liveFor(seg);
    if (!live) continue;

    const atTruth = perPointLogLik(gp, live, Math.min(trueBin, gp.bins - 1));
    if (atTruth) {
      matchedResiduals.push(...atTruth.residuals);
      matchedPerPoint.push(atTruth.perPoint);
    }
    const stride = seg.binsPerStep;
    for (let s = live.length - 1; s < gp.bins; s += 17) {
      if (Math.abs(s - trueBin) < 2 * stride) continue;
      const wrongSeg = segmentOfBin(gp, s);
      const wrongLive = liveFor(wrongSeg);
      if (!wrongLive) continue;
      const stats = perPointLogLik(gp, wrongLive, s);
      if (stats) mismatchPerPoint.push(stats.perPoint);
    }
  }

  const absResiduals = matchedResiduals.map(Math.abs);
  const sigmaTotal = 1.4826 * median(absResiduals);
  const meanMapVar = gp.std.reduce((a, b) => a + b * b, 0) / gp.std.length;
  const sensorSigma = Math.sqrt(Math.max(0.25, sigmaTotal ** 2 - meanMapVar));

  return {
    samples: { matched: matchedPerPoint.length, mismatched: mismatchPerPoint.length, residuals: matchedResiduals.length },
    sigmaTotal,
    sensorSigmaUT: sensorSigma,
    matchedPerPointMedian: median(matchedPerPoint),
    mismatchPerPointMedian: median(mismatchPerPoint),
  };
}

function replay(profile, session) {
  const gp = buildGlobalProfile(profile);
  const filter = new RouteGridFilter(gp);
  const steps = detectSteps(session.dm);
  const provider = makeWindowProvider(session.dm, steps);
  const mm = metersMapper(session, gp);

  // Events: step times plus 1s idle ticks between them.
  const t0 = session.dm[0].t;
  const tEnd = session.dm[session.dm.length - 1].t;
  const events = [];
  for (const t of steps) events.push({ t, kind: 'step' });
  for (let t = t0; t <= tEnd; t += 1.0) events.push({ t, kind: 'tick' });
  // Turn events fire when the turning region ends — the earliest a live
  // detector could emit them.
  const turns = session.dm.some((s) => Number.isFinite(s.yawRate)) ? detectTurns(session.dm) : [];
  for (const turn of turns) events.push({ t: turn.endT, kind: 'turn', deltaDeg: turn.deltaDeg });
  events.sort((a, b) => a.t - b.t);

  const checkpointStates = profile.anchors.slice(1).map((a) => {
    const bin = gp.anchorBins.get(a.name) ?? gp.bins - 1;
    // Fire on P(s >= anchor - half a stride): without the margin, an end-of-route
    // checkpoint is a single boundary bin and can never accumulate tau mass.
    const stride = segmentOfBin(gp, Math.max(0, bin - 1)).binsPerStep;
    return {
      name: a.name,
      bin,
      decisionBin: Math.max(0, Math.round(bin - 0.5 * stride)),
      consecutive: 0,
      firedAt: null,
    };
  });

  const timeline = [];
  const turnLog = [];
  let lastT = t0;
  let offSince = null;
  let offRouteAt = null;
  let observed = 0;
  let stepsSinceObservation = Infinity;

  for (const ev of events) {
    if (ev.kind === 'step') {
      filter.predictStep();
      if (filter.observe(provider(ev.t))) {
        observed++;
        stepsSinceObservation = 0;
      } else {
        stepsSinceObservation++;
        filter.applyUnobservedLeak();
      }
    } else if (ev.kind === 'turn') {
      // Live stops at route completion; mirror that so the surveyor's
      // end-of-recording turn-around is not scored as evidence.
      if (checkpointStates.every((cp) => cp.firedAt !== null)) continue;
      const matched = filter.observeTurn(ev.deltaDeg);
      turnLog.push({ t: ev.t, deltaDeg: ev.deltaDeg, matched, pOffAfter: filter.pOff });
    } else {
      const sinceStep = steps.length ? Math.min(...steps.map((s) => Math.abs(s - ev.t))) : Infinity;
      if (sinceStep > 1.5) filter.predictIdle(ev.t - lastT);
    }
    lastT = ev.t;

    const meanBin = filter.meanBin();
    const pOff = filter.pOff;
    for (const cp of checkpointStates) {
      if (cp.firedAt !== null) continue;
      // No corroboration, no checkpoint: dead-reckoning alone must not fire events.
      const ok = stepsSinceObservation <= PARAMS.observationRecencySteps
        && filter.probBeyond(cp.decisionBin) / Math.max(1 - pOff, 1e-9) > PARAMS.checkpointTau
        && pOff < 0.5;
      cp.consecutive = ok ? cp.consecutive + 1 : 0;
      if (cp.consecutive >= 2) cp.firedAt = ev.t;
    }
    if (pOff > PARAMS.offRouteTau) {
      if (offSince === null) offSince = ev.t;
      if (offRouteAt === null && ev.t - offSince >= PARAMS.offRouteSustainSec) offRouteAt = ev.t;
    } else {
      offSince = null;
    }
    timeline.push({ t: ev.t, meanBin, pOff, kind: ev.kind });
  }

  return { gp, filter, steps, timeline, checkpointStates, offRouteAt, mm, observed, turnLog };
}

// ---------------------------------------------------------------------------
// Reporting

function scoreAndPrint(profile, session, r) {
  const { gp, timeline, checkpointStates, offRouteAt, mm } = r;
  const anchorByName = new Map(session.anchors.map((a) => [a.name, a]));

  console.log(`Profile: ${profile.route.venueId} / ${profile.route.routeId} / ${profile.route.direction}`);
  console.log(`Session: ${session.file} (passType=${session.meta.passType || 'normal/unknown'})`);
  console.log(`Grid: ${gp.bins} bins over ${gp.segments.length} segments · ${r.steps.length} detected steps · ${r.observed} magnetic updates`);
  console.log('');

  // Checkpoint table
  console.log('Checkpoint'.padEnd(22) + 'True tap'.padEnd(10) + 'Detected'.padEnd(10) + 'Delay s'.padEnd(9) + 'Verdict');
  console.log('-'.repeat(72));
  let falseAdvances = 0;
  for (const cp of checkpointStates) {
    const truth = anchorByName.get(cp.name);
    const trueT = truth ? truth.t : null;
    const det = cp.firedAt;
    let verdict;
    if (det === null && trueT === null) verdict = 'correctly not fired';
    else if (det === null) verdict = 'MISSED';
    else if (trueT === null) { verdict = 'FALSE ADVANCE'; falseAdvances++; }
    else verdict = Math.abs(det - trueT) <= 6 ? 'ok' : (det < trueT - 6 ? 'EARLY (false-ish)' : 'late');
    console.log(
      cp.name.slice(0, 20).padEnd(22) +
      (trueT !== null ? rel(trueT, timeline) : '--').padEnd(10) +
      (det !== null ? rel(det, timeline) : '--').padEnd(10) +
      (det !== null && trueT !== null ? (det - trueT).toFixed(1) : '--').padEnd(9) +
      verdict
    );
  }

  // Off-route
  console.log('');
  const maxOff = Math.max(...timeline.map((p) => p.pOff));
  console.log(`P(OFF): max ${maxOff.toFixed(2)} · off-route flagged: ${offRouteAt !== null ? `yes @ ${rel(offRouteAt, timeline)}` : 'no'}`);

  // Turn anchors
  const signature = r.gp.turns.map((t) => `${t.deltaDeg > 0 ? '+' : ''}${t.deltaDeg}°@bin${t.bin}`).join(' ') || 'none';
  console.log(`Turn signature: ${signature}`);
  for (const turn of r.turnLog) {
    console.log(`  turn ${rel(turn.t, timeline)} ${turn.deltaDeg > 0 ? '+' : ''}${turn.deltaDeg.toFixed(0)}° -> ${turn.matched ? 'MATCH (snap)' : 'unmatched'} · P(OFF) ${turn.pOffAfter.toFixed(2)}`);
  }

  // True meters error (clean passes with AR)
  if (mm) {
    const start = anchorByName.get(gp.segments[0].from);
    const end = anchorByName.get(gp.segments[gp.segments.length - 1].to);
    if (start && end) {
      const scored = timeline.filter((p) => p.t >= start.t && p.t <= end.t && p.kind === 'step');
      const errors = scored.map((p) => Math.abs(mm.binToMeters(p.meanBin) - mm.truthMetersAt(p.t)));
      errors.sort((a, b) => a - b);
      const mean = errors.reduce((a, b) => a + b, 0) / Math.max(errors.length, 1);
      const p50 = errors[Math.floor(errors.length * 0.5)] || 0;
      const p75 = errors[Math.floor(errors.length * 0.75)] || 0;
      console.log('');
      console.log(`TRUE error vs ARKit (over ${mm.total.toFixed(1)} m route, ${errors.length} step updates):`);
      console.log(`  mean ${mean.toFixed(2)} m · P50 ${p50.toFixed(2)} m · P75 ${p75.toFixed(2)} m`);
    }
  } else {
    console.log('(no ARKit ground truth in this session — behavioral scoring only)');
  }

  return { falseAdvances };
}

function rel(t, timeline) {
  return `${(t - timeline[0].t).toFixed(1)}s`;
}

function writeHtml(outPath, profile, session, r) {
  const { timeline, gp, mm, checkpointStates, offRouteAt } = r;
  const width = 760, height = 240, pad = 28;
  const tMin = timeline[0].t, tMax = timeline[timeline.length - 1].t;
  const px = (t) => pad + ((width - 2 * pad) * (t - tMin)) / Math.max(tMax - tMin, 1e-9);

  const lineBin = timeline.map((p) => `${px(p.t).toFixed(1)},${(height - pad - (height - 2 * pad) * (p.meanBin / (gp.bins - 1))).toFixed(1)}`).join(' ');
  const lineOff = timeline.map((p) => `${px(p.t).toFixed(1)},${(height - pad - (height - 2 * pad) * p.pOff).toFixed(1)}`).join(' ');
  let truthLine = '';
  if (mm) {
    const pts = timeline.filter((p) => p.kind === 'step').map((p) => {
      const frac = Math.min(1, Math.max(0, mm.truthMetersAt(p.t) / Math.max(mm.total, 1e-9)));
      return `${px(p.t).toFixed(1)},${(height - pad - (height - 2 * pad) * frac).toFixed(1)}`;
    }).join(' ');
    truthLine = `<polyline fill="none" stroke="#111827" stroke-width="1.4" points="${pts}"/>`;
  }
  const anchorMarks = session.anchors.map((a) =>
    `<line x1="${px(a.t).toFixed(1)}" y1="${pad}" x2="${px(a.t).toFixed(1)}" y2="${height - pad}" stroke="#9ca3af" stroke-dasharray="3,3"/>`
  ).join('');

  const cpRows = checkpointStates.map((cp) =>
    `<tr><td>${cp.name}</td><td>${cp.firedAt !== null ? rel(cp.firedAt, timeline) : '--'}</td></tr>`).join('');

  const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>Grid filter replay</title>
<style>body{font-family:-apple-system,sans-serif;max-width:860px;margin:24px auto;padding:0 16px}td,th{border:1px solid #e5e7eb;padding:5px 9px;font-size:13px}table{border-collapse:collapse}</style>
</head><body>
<h1>Grid filter replay</h1>
<p>${session.file} vs ${profile.route.venueId}/${profile.route.routeId} · off-route: ${offRouteAt !== null ? 'FLAGGED' : 'no'}</p>
<div style="font-size:12px"><span style="color:#dc2626;font-weight:600">posterior mean (route fraction)</span> ·
<span style="color:#7c3aed;font-weight:600">P(OFF)</span> ·
<span style="color:#111827;font-weight:600">ARKit truth</span> · dashed = anchor taps</div>
<svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" style="background:#fafafa;border:1px solid #e5e7eb">
${anchorMarks}
${truthLine}
<polyline fill="none" stroke="#dc2626" stroke-width="1.6" points="${lineBin}"/>
<polyline fill="none" stroke="#7c3aed" stroke-width="1.4" points="${lineOff}"/>
</svg>
<h2>Checkpoint detections</h2>
<table><thead><tr><th>Checkpoint</th><th>Fired</th></tr></thead><tbody>${cpRows}</tbody></table>
</body></html>`;
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, html);
}

// ---------------------------------------------------------------------------

function main() {
  const argv = process.argv.slice(2);
  const positional = [];
  let out = null;
  let calibrateMode = false;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out') out = argv[++i];
    else if (argv[i] === '--calibrate') calibrateMode = true;
    else positional.push(argv[i]);
  }
  if (positional.length !== 2) {
    console.error('Usage: node analysis/grid-filter.js <profile.json> <session.jsonl> [--out report.html] [--calibrate]');
    process.exit(1);
  }
  const profile = JSON.parse(fs.readFileSync(positional[0], 'utf8'));
  const session = parseSession(positional[1]);

  if (calibrateMode) {
    const c = calibrate(profile, session);
    console.log(`Calibration from ${session.file}:`);
    console.log(`  residual samples: ${c.samples.residuals} (matched windows ${c.samples.matched}, mismatched ${c.samples.mismatched})`);
    console.log(`  total residual sigma (MAD-based): ${c.sigmaTotal.toFixed(2)} µT`);
    console.log(`  -> fitted sensorSigmaUT: ${c.sensorSigmaUT.toFixed(2)}  (current PARAMS: ${PARAMS.sensorSigmaUT})`);
    console.log(`  per-point logLik at TRUE position (median): ${c.matchedPerPointMedian.toFixed(3)}`);
    console.log(`  per-point logLik at WRONG positions (median): ${c.mismatchPerPointMedian.toFixed(3)}`);
    console.log(`  -> fitted offLogLikPerPoint: ${c.mismatchPerPointMedian.toFixed(3)}  (current PARAMS: ${PARAMS.offLogLikPerPoint})`);
    return;
  }

  const r = replay(profile, session);
  scoreAndPrint(profile, session, r);
  if (out) {
    writeHtml(out, profile, session, r);
    console.log(`\nHTML report: ${out}`);
  }
}

module.exports = { buildGlobalProfile, RouteGridFilter, replay, calibrate, PARAMS, parseSession, detectSteps, makeWindowProvider, segmentOfBin };

if (require.main === module) {
  main();
}
