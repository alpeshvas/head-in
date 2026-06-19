#!/usr/bin/env node
/**
 * Bidirectional ("to-and-fro") replay PROTOTYPE — research validation only.
 *
 * Tests the hypotheses in docs/research/bidirectional-route-tracking.md on a
 * real out-and-back recording, WITHOUT touching the shipped grid-filter.js /
 * RouteBeliefFilter.swift logic. It reuses grid-filter.js's exported building
 * blocks (profile, emission, step detection, window provider) and adds:
 *
 *   1. A REVERSE-direction emission read (profile first-difference taken the
 *      other way), to test the load-bearing claim in §2: on a retraced path the
 *      differenced emission, read in the reverse direction, scores the true
 *      (decreasing-bin) position highest. Output: a likelihood-ridge dump for
 *      the forward and return legs.
 *   2. A binary direction LATCH (§3) toggled by the gyro U-turn from
 *      turn-events.js, with a direction-aware step kernel (mean +stride forward,
 *      -stride backward). Output: latch-flip times vs the true turnaround.
 *   3. Scoring against ARKit ground truth, where TRUE route position on the
 *      return leg is obtained by PROJECTING each ARKit pose onto the OUTBOUND
 *      path polyline (nearest-point arc position) — drift-tolerant and
 *      direction-agnostic, unlike folding cumulative arc length.
 *
 * Usage:
 *   node analysis/bidir-replay.js <profile.json> <roundtrip-session.jsonl> [--ridge]
 *
 * This is a research harness. It is intentionally separate from the production
 * filter and is NOT wired into parity fixtures.
 */

'use strict';

const fs = require('fs');
const {
  buildGlobalProfile, parseSession, detectSteps, makeWindowProvider,
  segmentOfBin, perPointLogLik, PARAMS, replay, metersMapper,
} = require('./grid-filter.js');
const { detectTurns } = require('./turn-events.js');
const { buildArcLength } = require('./ground-truth.js');

const UTURN_MIN_DEG = 140;   // a reversal is near-180; route corners here are <=90 (measured)

// --------------------------------------------------------------------------
// Ground truth: true route position (in profile bins) at any time, for BOTH
// legs of a single out-and-back.

/**
 * Build a mapper from time -> true route position for a SINGLE out-and-back.
 *
 * A square route makes displacement-from-start useless (it dips/rises as you
 * round corners), so the turnaround is found from the GYRO U-TURN (the only
 * >=UTURN_MIN_DEG rotation), which is unambiguous and is the leg split point.
 *
 * GROUND TRUTH SCALE (bidirectional-route-tracking.md §15): the bin<->meters
 * mapping is PER-SEGMENT (metersMapper, from the actual anchor taps), NOT a single
 * average bins-per-metre over the whole leg. A single-scale fold inflated the error
 * ~2x (forward leg measured 3.43 m under the single scale vs 0.71 m under the
 * per-segment scale, the latter matching the independent leave-one-out) — and that
 * artifact contaminated every §8-§14 return number. With all anchors tapped
 * (an out-and-back taps them on the way out), metersMapper is available; fall back
 * to the old single-scale fold only when anchors are missing.
 *
 *  - forward leg: true route metres = cumulative ARKit arc from the start.
 *  - return leg: a retrace, so route metres = outboundMetres - (distance retraced).
 * `trueMetersAt`/`binToMeters` are the per-segment-accurate primitives; score in
 * METRES (|binToMeters(meanBin) - trueMetersAt(t)|), not bins x average scale.
 *
 * Requires exactly one U-turn; warns and returns null otherwise.
 */
function buildTrueBinMapper(session, gp) {
  const t0 = session.anchors.length ? session.anchors[0].t : session.dm[0].t;
  const ap = session.arPoses.filter((p) => p.tracking === 'normal' && p.t >= t0);
  if (ap.length < 20) return null;

  const uturns = detectTurns(session.dm).filter((tr) => Math.abs(tr.deltaDeg) >= UTURN_MIN_DEG && tr.t >= t0);
  if (uturns.length !== 1) {
    console.log(`\n!! buildTrueBinMapper: expected exactly ONE U-turn (>=${UTURN_MIN_DEG}°), found ${uturns.length}.`);
    console.log(`   This harness handles a single out-and-back only. Re-record one clean lap, or extend for multi-lap.`);
    return null;
  }
  const turnT = uturns[0].t;

  const arc = buildArcLength(session.arPoses);
  const arcStart = arc.lengthAt(t0);
  const arcAtTurn = arc.lengthAt(turnT) - arcStart;    // outbound path length
  const tEnd = session.dm[session.dm.length - 1].t;
  const arcEnd = arc.lengthAt(tEnd) - arcStart;         // total path length (out + back)
  const returnArc = arcEnd - arcAtTurn;                 // return path length

  // Per-segment scale (the fix). metersMapper measures route METRES from the
  // start via cumulative ARKit arc, and maps metres<->bin per segment.
  const mm = metersMapper(session, gp);
  const singleMetresPerBin = arcAtTurn / Math.max(gp.bins - 1, 1); // fallback only
  const outboundMetres = mm ? mm.truthMetersAt(turnT) : arcAtTurn;

  function trueMetersAt(t) {
    if (mm) {
      if (t <= turnT) return mm.truthMetersAt(t);
      const back = mm.truthMetersAt(t) - outboundMetres;   // distance retraced
      return Math.max(0, outboundMetres - back);
    }
    // fallback: single-scale (old behavior) expressed in metres
    const a = arc.lengthAt(t) - arcStart;
    return t <= turnT ? a : Math.max(0, arcAtTurn - (a - arcAtTurn));
  }

  return {
    turnT,
    outboundArc: arcAtTurn,
    returnArc,
    mm,
    trueMetersAt,
    binToMeters: mm ? mm.binToMeters : (bin) => bin * singleMetresPerBin,
    trueBinAt(t) {
      const metres = trueMetersAt(t);
      return mm ? mm.metersToBin(metres) : Math.min(gp.bins - 1, Math.max(0, metres / Math.max(singleMetresPerBin, 1e-9)));
    },
    isReturn(t) { return t > turnT; },
  };
}

// --------------------------------------------------------------------------
// Reverse emission: per-point logLik of a live window whose newest sample sits
// at bin `endBin`, but read as if walking the path in DECREASING-bin direction.
// Forward (grid-filter.js perPointLogLik): resid = (live[k+lag]-live[k]) -
//   (mean[idx+lag]-mean[idx]),  idx = endBin-L+1+k  (window maps low->high bins).
// Reverse: the newest live sample is at endBin and the window extends UPWARD in
//   bin (you came from higher bins), and the profile difference is taken the
//   other way. Equivalent: map window oldest->newest to high->low bins and
//   negate the profile lag difference.

function perPointLogLikReverse(gp, live, endBin) {
  const L = live.length;
  // Window occupies bins [endBin .. endBin+L-1] (came from higher bins, now at endBin).
  if (endBin + L - 1 >= gp.bins || endBin < 0) return null;
  const lag = Math.max(2, Math.round(segmentOfBin(gp, endBin).binsPerStep));
  if (L <= lag) return null;
  const v = gp.diffSigmaUT * gp.diffSigmaUT;
  let ll = 0; let n = 0;
  for (let k = 0; k + lag < L; k++) {
    // live newest (k=0) at endBin; live[k] sits at bin endBin+k.
    const idx = endBin + k;
    // profile difference walked in the REVERSE direction: mean[idx]-mean[idx+lag]
    const liveDiff = live[k + lag] - live[k];
    const profDiff = gp.mean[idx] - gp.mean[idx + lag];
    const resid = liveDiff - profDiff;
    ll += -0.5 * (resid * resid / v + Math.log(2 * Math.PI * v));
    n++;
  }
  return n ? ll / n : null;
}

// --------------------------------------------------------------------------
// Ridge dump: at each step, the best-matching bin under forward read and under
// reverse read, vs the true bin. Confirms (or refutes) §2.

function ridgeReport(profile, session) {
  const gp = buildGlobalProfile(profile);
  const steps = detectSteps(session.dm);
  const provider = makeWindowProvider(session.dm, steps);
  const gt = buildTrueBinMapper(session, gp);
  if (!gt) { console.log('No ARKit ground truth — cannot build ridge report.'); return; }
  const t0 = session.anchors.length ? session.anchors[0].t : session.dm[0].t;

  console.log(`\n=== Reverse-emission ridge report ===`);
  console.log(`bins=${gp.bins}  turnaround t+${(gt.turnT - t0).toFixed(1)}s  outboundArc=${gt.outboundArc.toFixed(1)}m`);
  console.log('leg     t(s)  trueBin  fwdArgmax fwdLL   revArgmax revLL   winnerAtTrue');
  console.log('-'.repeat(82));

  let fwdGoodFwdLeg = 0, fwdLegN = 0, revGoodRetLeg = 0, retLegN = 0;

  for (const t of steps) {
    const liveFor = provider(t);
    const trueBin = Math.round(gt.trueBinAt(t));
    if (trueBin < 0 || trueBin >= gp.bins) continue;
    const seg = segmentOfBin(gp, Math.min(trueBin, gp.bins - 1));
    const live = liveFor(seg);
    if (!live) continue;

    // scan all bins for fwd and rev argmax
    let fwdBest = { bin: -1, ll: -Infinity }, revBest = { bin: -1, ll: -Infinity };
    for (let s = 0; s < gp.bins; s++) {
      const f = perPointLogLik(gp, live, s);
      if (f && f.perPoint > fwdBest.ll) fwdBest = { bin: s, ll: f.perPoint };
      const r = perPointLogLikReverse(gp, live, s);
      if (r !== null && r > revBest.ll) revBest = { bin: s, ll: r };
    }
    // which read wins AT THE TRUE bin
    const fAtTrue = perPointLogLik(gp, live, trueBin);
    const rAtTrue = perPointLogLikReverse(gp, live, trueBin);
    const fv = fAtTrue ? fAtTrue.perPoint : -Infinity;
    const rv = rAtTrue !== null ? rAtTrue : -Infinity;
    const winner = fv >= rv ? 'FWD' : 'REV';

    const ret = gt.isReturn(t);
    // "good" = argmax within 1.5 strides of true
    const stride = seg.binsPerStep;
    if (!ret) { fwdLegN++; if (Math.abs(fwdBest.bin - trueBin) <= 1.5 * stride) fwdGoodFwdLeg++; }
    else { retLegN++; if (Math.abs(revBest.bin - trueBin) <= 1.5 * stride) revGoodRetLeg++; }

    console.log(
      (ret ? 'RETURN' : 'fwd   ').padEnd(8) +
      ((t - t0).toFixed(1)).padStart(5) +
      String(trueBin).padStart(8) +
      String(fwdBest.bin).padStart(10) + fwdBest.ll.toFixed(2).padStart(8) +
      String(revBest.bin).padStart(10) + revBest.ll.toFixed(2).padStart(8) +
      ('  ' + winner).padStart(8)
    );
  }
  console.log('-'.repeat(82));
  console.log(`Forward leg: forward-read argmax within 1.5 strides of true: ${fwdGoodFwdLeg}/${fwdLegN}`);
  console.log(`Return  leg: REVERSE-read argmax within 1.5 strides of true: ${revGoodRetLeg}/${retLegN}`);
  console.log(`\n§2 PASS if the return leg's reverse-read argmax tracks the true (decreasing) bin`);
  console.log(`comparably to the forward leg's forward-read argmax. If reverse-read does NOT`);
  console.log(`ridge on the return, the differenced reverse claim is refuted.`);
}

// --------------------------------------------------------------------------
// Turn / latch report: does the gyro see a clean U-turn at the true turnaround,
// and how do route corners compare?

function latchReport(profile, session) {
  const gp = buildGlobalProfile(profile);
  const gt = buildTrueBinMapper(session, gp);
  const t0 = session.anchors.length ? session.anchors[0].t : session.dm[0].t;
  const turns = detectTurns(session.dm);
  console.log(`\n=== Latch-toggle report ===`);
  if (gt) console.log(`true turnaround at t+${(gt.turnT - t0).toFixed(1)}s`);
  console.log(`UTURN_MIN_DEG=${UTURN_MIN_DEG} (route corners measured <=90, turnaround ~180)`);
  console.log('t(s)    delta   |delta|  classified');
  console.log('-'.repeat(50));
  let latch = 'forward';
  const flips = [];
  for (const tr of turns) {
    const cls = Math.abs(tr.deltaDeg) >= UTURN_MIN_DEG ? 'U-TURN -> FLIP LATCH' : 'corner (ignore)';
    if (Math.abs(tr.deltaDeg) >= UTURN_MIN_DEG) {
      latch = latch === 'forward' ? 'backward' : 'forward';
      flips.push({ t: tr.t, to: latch });
    }
    console.log(
      ((tr.t - t0).toFixed(1)).padStart(5) +
      ((tr.deltaDeg > 0 ? '+' : '') + tr.deltaDeg.toFixed(0) + '°').padStart(8) +
      (Math.abs(tr.deltaDeg).toFixed(0)).padStart(8) +
      '  ' + cls
    );
  }
  console.log('-'.repeat(50));
  if (gt && flips.length) {
    const f = flips[0];
    console.log(`first latch flip: t+${(f.t - t0).toFixed(1)}s -> ${f.to}; true turnaround t+${(gt.turnT - t0).toFixed(1)}s; delay ${(f.t - gt.turnT).toFixed(1)}s`);
  } else if (!flips.length) {
    console.log('NO U-turn detected >= threshold — latch never flips (return leg would not track).');
  }
}

// --------------------------------------------------------------------------
// Direction-aware FULL FILTER replay (the real §2 test).
//
// The bare-emission-argmax probe (ridgeReport) does not ridge on this weak
// field even FORWARD — pointwise magnitude is too weakly discriminative here
// (the documented LIS finding). What makes grid-filter.js work is the STEP
// PRIOR accumulating evidence over time. So the apples-to-apples test is to
// run the full filter — direction-aware — and score the POSTERIOR MEAN vs the
// true bin, on both legs.
//
// DirectionalFilter extends the shipped RouteGridFilter and overrides only:
//   - predictStep: kernel mean +m (forward) or -m (backward)
//   - observe:     forward emission read (forward) or reverse read (backward)
// Everything else (OFF dynamics, normalize, meanBin) is the shipped logic.

const { RouteGridFilter } = require('./grid-filter.js');

class DirectionalFilter extends RouteGridFilter {
  constructor(gp) { super(gp); this.direction = 'forward'; }

  /** Step kernel mean follows the latch: +m forward, -m backward. */
  predictStep() {
    if (this.direction === 'forward') return super.predictStep();
    // backward: mirror the shipped kernel about the current bin.
    const gp = this.gp;
    const next = new Float64Array(gp.bins).fill(0);
    let leaked = 0;
    for (let i = 0; i < gp.bins; i++) {
      const p = this.belief[i];
      if (p <= 0) continue;
      const m = segmentOfBin(gp, i).binsPerStep;
      const sigma = Math.max(0.8, PARAMS.stepNoiseFrac * m);
      const lo = Math.floor(i - 3 * m);   // up to 3 strides BACKWARD
      const hi = Math.ceil(i + m);        // small forward tail
      let kernelSum = 0;
      for (let j = lo; j <= hi; j++) kernelSum += Math.exp(-0.5 * ((j - i + m) / sigma) ** 2) + PARAMS.kernelFloor;
      const stay = p * (1 - PARAMS.offLeakPerStep);
      for (let j = lo; j <= hi; j++) {
        const k = Math.exp(-0.5 * ((j - i + m) / sigma) ** 2) + PARAMS.kernelFloor;
        const share = stay * (k / kernelSum);
        if (j < 0) next[0] += share;            // start barrier (return destination)
        else if (j >= gp.bins) next[gp.bins - 1] += share;
        else next[j] += share;
      }
      leaked += p * PARAMS.offLeakPerStep;
    }
    // OFF re-entry around last confident mode (same as shipped).
    const reenter = this.pOff * (1 - PARAMS.offStay);
    if (reenter > 0) {
      const center = this.lastConfidentMode;
      const sigma = PARAMS.reentrySigmaStrides * segmentOfBin(gp, center).binsPerStep;
      const lo = Math.max(0, Math.floor(center - 3 * sigma));
      const hi = Math.min(gp.bins - 1, Math.ceil(center + 3 * sigma));
      let ks = 0;
      for (let i = lo; i <= hi; i++) ks += (next[i] + 1e-12) * Math.exp(-0.5 * ((i - center) / sigma) ** 2);
      if (ks > 0) for (let i = lo; i <= hi; i++) next[i] += reenter * ((next[i] + 1e-12) * Math.exp(-0.5 * ((i - center) / sigma) ** 2)) / ks;
    }
    this.belief = next;
    this.pOff = this.pOff * PARAMS.offStay + leaked;
    this.normalize();
  }

  /** Emission read in the latch direction. */
  observe(liveWindowForSegment) {
    if (this.direction === 'forward') return super.observe(liveWindowForSegment);
    const gp = this.gp;
    const logLik = new Float64Array(gp.bins).fill(NaN);
    const windowCache = new Map();
    let anyWindow = false;
    for (let s = 0; s < gp.bins; s++) {
      const seg = segmentOfBin(gp, s);
      if (!windowCache.has(seg.index)) windowCache.set(seg.index, liveWindowForSegment(seg));
      const live = windowCache.get(seg.index);
      if (!live) continue;
      const r = perPointLogLikReverse(gp, live, s);
      if (r === null) continue;
      logLik[s] = r * PARAMS.obsIndependenceBins;
      anyWindow = true;
    }
    if (!anyWindow) return false;
    const offLL = gp.offLogLikPerPoint * PARAMS.obsIndependenceBins;
    let maxLL = offLL;
    for (const ll of logLik) if (Number.isFinite(ll) && ll > maxLL) maxLL = ll;
    for (let s = 0; s < gp.bins; s++) if (Number.isFinite(logLik[s])) this.belief[s] *= Math.exp(logLik[s] - maxLL);
    this.pOff *= Math.exp(offLL - maxLL);
    this.normalize();
    return true;
  }

  /** Reversed turn-sequence RECAPTURE (bidirectional-route-tracking.md §3.5):
   *  on the return leg, a detected turn that matches the profile's signature
   *  read with flipped sign re-pins belief to that turn's bin (UnLoc-style
   *  landmark reset). This re-localizes on a weak field where the magnetic
   *  emission alone cannot hold position between corners. `signature` is the
   *  profile turns; we match on sign-flipped magnitude. Returns the matched bin
   *  or null. */
  recaptureReverse(deltaDeg, signature, tolDeg = 55) {
    if (this.direction !== 'backward') return null;
    // Enforce REVERSE ORDER: on the return leg corners are re-crossed in the
    // reverse of the survey order, so consume the signature from the end. The
    // next expected corner is signature[reverseCursor]; matching by order (not
    // nearest magnitude) is essential when corner magnitudes are close
    // (76° vs 92° here). reverseCursor starts at the last signature index when
    // the latch flips to backward.
    if (this._revCursor === undefined) this._revCursor = signature.length - 1;
    if (this._revCursor < 0) return null;
    const turn = signature[this._revCursor];
    const expected = -turn.deltaDeg; // opposite sign on the return
    if (Math.sign(expected) !== Math.sign(deltaDeg) || Math.abs(deltaDeg - expected) > tolDeg) {
      return null; // not the next expected corner; ignore (don't consume)
    }
    this._revCursor -= 1;
    // Landmark RESET (UnLoc-style): on a weak field the magnetic emission is
    // unreliable, so a matched corner should DOMINATE, not gently reweight.
    // Replace belief with a Gaussian at the corner bin (coarse sigma) rather
    // than multiply the (wrong, confident) prior.
    const bin = turn.bin;
    const sigma = Math.max(turn.sigmaBins, 8) * 2;
    for (let i = 0; i < this.belief.length; i++) {
      this.belief[i] = Math.exp(-0.5 * ((i - bin) / sigma) ** 2);
    }
    this.pOff = 0.05;
    this.normalize();
    return bin;
  }
}

function directionalReplay(profile, session, { latchMode = 'gyro', recapture = false } = {}) {
  const gp = buildGlobalProfile(profile);
  const gt = buildTrueBinMapper(session, gp);
  if (!gt) { console.log('No usable single-lap ground truth — aborting directional replay.'); return; }
  const t0 = session.anchors.length ? session.anchors[0].t : session.dm[0].t;
  const steps = detectSteps(session.dm);
  const provider = makeWindowProvider(session.dm, steps);
  const filter = new DirectionalFilter(gp);
  const signature = gp.turns || [];

  const allTurns = detectTurns(session.dm).filter((tr) => tr.t >= t0);
  // Latch flips: from the gyro U-turn (real-world), or — for an upper-bound
  // ("does reverse tracking even work if the latch were perfect?") — from the
  // ARKit turnaround time itself.
  const flipTimes = latchMode === 'oracle'
    ? [gt.turnT]
    : allTurns.filter((tr) => Math.abs(tr.deltaDeg) >= UTURN_MIN_DEG).map((tr) => tr.t);

  const events = [];
  for (const t of steps) events.push({ t, kind: 'step' });
  for (const ft of flipTimes) events.push({ t: ft, kind: 'flip' });
  // Recapture turns: the non-U-turn corners (the U-turn drives the flip, not a
  // corner match). Only fed when recapture is on.
  if (recapture) {
    for (const tr of allTurns) {
      if (Math.abs(tr.deltaDeg) >= UTURN_MIN_DEG) continue; // that's the flip
      events.push({ t: tr.endT, kind: 'recapture', deltaDeg: tr.deltaDeg });
    }
  }
  events.sort((a, b) => a.t - b.t);

  const rows = [];
  const recaptures = [];
  let fwdErr = [], retErr = [];
  for (const ev of events) {
    if (ev.kind === 'flip') {
      filter.direction = filter.direction === 'forward' ? 'backward' : 'forward';
      continue;
    }
    if (ev.kind === 'recapture') {
      const bin = filter.recaptureReverse(ev.deltaDeg, signature);
      if (bin !== null) recaptures.push({ t: ev.t - t0, deltaDeg: ev.deltaDeg, bin });
      continue;
    }
    filter.predictStep();
    filter.observe(provider(ev.t));
    const mean = filter.meanBin();
    const trueBin = gt.trueBinAt(ev.t);
    const errBins = mean - trueBin;
    const errM = (errBins / Math.max(gp.bins - 1, 1)) * gt.outboundArc;
    const ret = gt.isReturn(ev.t);
    (ret ? retErr : fwdErr).push(Math.abs(errM));
    rows.push({ t: ev.t - t0, ret, dir: filter.direction, mean: Math.round(mean), trueBin: Math.round(trueBin), errM, pOff: filter.pOff });
  }

  const pct = (arr, p) => { if (!arr.length) return NaN; const s = arr.slice().sort((a, b) => a - b); return s[Math.floor(s.length * p)]; };
  console.log(`\n=== Direction-aware FULL FILTER replay (latch=${latchMode}) ===`);
  console.log(`leg    t(s)  dir       meanBin  trueBin  err(m)  pOff`);
  console.log('-'.repeat(60));
  for (const r of rows.filter((_, i) => i % 3 === 0)) {
    console.log(
      (r.ret ? 'RET ' : 'fwd ') + (r.t.toFixed(1)).padStart(6) + '  ' + r.dir.padEnd(9) +
      String(r.mean).padStart(7) + String(r.trueBin).padStart(9) + (r.errM.toFixed(2)).padStart(8) + (r.pOff.toFixed(2)).padStart(6)
    );
  }
  console.log('-'.repeat(60));
  console.log(`Forward leg (n=${fwdErr.length}): P50 ${pct(fwdErr, 0.5)?.toFixed(2)} m · P75 ${pct(fwdErr, 0.75)?.toFixed(2)} m`);
  console.log(`Return  leg (n=${retErr.length}): P50 ${pct(retErr, 0.5)?.toFixed(2)} m · P75 ${pct(retErr, 0.75)?.toFixed(2)} m`);
  if (recapture) {
    console.log(`Recaptures (reversed-signature corner re-pins on the return leg):`);
    for (const r of recaptures) console.log(`  t+${r.t.toFixed(1)}s  ${r.deltaDeg > 0 ? '+' : ''}${r.deltaDeg.toFixed(0)}° -> re-pinned to bin ${r.bin}`);
    if (!recaptures.length) console.log('  (none matched)');
  }
  console.log(`\n§2 PASS if the RETURN-leg P50 is in the same 1–3 m band as the forward leg.`);
  console.log(`(latch=oracle isolates "does reverse tracking work with a perfect flip?";`);
  console.log(` latch=gyro is the realistic end-to-end with the real ~${(flipTimes[0] - gt.turnT || 0).toFixed(1)}s-late flip.)`);
}

// --------------------------------------------------------------------------
// SHIPPED-path round-trip report (bidirectional-route-tracking.md §13).
//
// Drives the REAL grid-filter.js replay() — the same RouteGridFilter +
// stabilizers (mode-anchored OFF re-entry, terminal freeze, unobserved leak,
// confinement gate) and the latch + −stride + reverse emission + reversed-turn
// recapture that ship in the filter — and scores forward/return legs vs ARKit.
//
// This SUPERSEDES the DirectionalFilter `--filter/--recapture/--oracle` path
// above: that runs a stale parallel loop with the known-buggy
// perPointLogLikReverse (§10) and no stabilizers. Scores in METRES via the
// per-segment ground truth (§15) — the single-average-scale fold inflated these
// ~2x in §13/§14.
function shippedReport(profile, session) {
  const gp = buildGlobalProfile(profile);
  const gt = buildTrueBinMapper(session, gp);
  if (!gt) { console.log('No ARKit ground truth / not a single out-and-back — cannot score.'); return; }
  const t0 = session.anchors.length ? session.anchors[0].t : session.dm[0].t;
  const r = replay(profile, session);

  // Latch + recapture trace (turnLog carries every observed turn; while
  // returning, a matched turn IS a reversed-signature corner recapture).
  console.log(`\n=== SHIPPED replay() round-trip (the Live-path filter) ===`);
  console.log(`turnaround t+${(gt.turnT - t0).toFixed(1)}s  outboundArc ${gt.outboundArc.toFixed(1)}m  returnArc ${gt.returnArc.toFixed(1)}m  GT=${gt.mm ? 'per-segment' : 'single-scale(fallback)'}`);
  const fired = r.checkpointStates.filter((c) => c.firedAt !== null).length;
  console.log(`forward checkpoints fired: ${fired}/${r.checkpointStates.length}` +
    (fired < r.checkpointStates.length ? '  (last unfired — see §13 lifecycle note)' : ''));
  console.log(`final returning=${r.filter.returning}`);
  for (const tl of r.turnLog) {
    console.log(`  turn t+${(tl.t - t0).toFixed(1)}s  ${tl.deltaDeg > 0 ? '+' : ''}${tl.deltaDeg.toFixed(0)}° -> ${tl.matched ? 'MATCH' : 'unmatched'}  pOff ${tl.pOffAfter.toFixed(2)}`);
  }

  // Score in METRES with the per-segment scale (§15): |binToMeters(meanBin) - trueMetresAt|.
  const fwd = [], ret = [];
  for (const row of r.timeline) {
    if (row.kind !== 'step') continue;
    const err = Math.abs(gt.binToMeters(row.meanBin) - gt.trueMetersAt(row.t));
    (gt.isReturn(row.t) ? ret : fwd).push(err);
  }
  const pct = (a, p) => { if (!a.length) return NaN; const s = a.slice().sort((x, y) => x - y); return s[Math.floor(p * (s.length - 1))]; };
  console.log('-'.repeat(60));
  console.log(`Forward leg (n=${fwd.length}): P50 ${pct(fwd, 0.5)?.toFixed(2)} m · P75 ${pct(fwd, 0.75)?.toFixed(2)} m`);
  console.log(`Return  leg (n=${ret.length}): P50 ${pct(ret, 0.5)?.toFixed(2)} m · P75 ${pct(ret, 0.75)?.toFixed(2)} m`);
}

// --------------------------------------------------------------------------

function main() {
  const argv = process.argv.slice(2);
  const ridge = argv.includes('--ridge');
  const filterMode = argv.includes('--filter');
  const oracle = argv.includes('--oracle');
  const recapture = argv.includes('--recapture');
  const shipped = argv.includes('--shipped');
  const pos = argv.filter((a) => !a.startsWith('--'));
  if (pos.length !== 2) {
    console.error('Usage: node analysis/bidir-replay.js <profile.json> <roundtrip-session.jsonl> [--shipped] [--ridge] [--filter] [--oracle] [--recapture]');
    process.exit(1);
  }
  const profile = JSON.parse(fs.readFileSync(pos[0], 'utf8'));
  const session = parseSession(pos[1]);
  console.log(`Profile: ${profile.route.venueId}/${profile.route.routeId}  Session: ${session.file}`);
  latchReport(profile, session);
  if (ridge) ridgeReport(profile, session);
  if (shipped) shippedReport(profile, session);
  if (filterMode || oracle || recapture) {
    console.log('\n!! --filter/--oracle/--recapture run the STALE DirectionalFilter parallel loop');
    console.log('   (buggy perPointLogLikReverse §10, no replay() stabilizers). Use --shipped for');
    console.log('   the honest Live-path number (bidirectional-route-tracking.md §13).');
    directionalReplay(profile, session, { latchMode: oracle ? 'oracle' : 'gyro', recapture });
  }
  if (!ridge && !filterMode && !oracle && !recapture && !shipped) {
    console.log('\n(flags: --shipped REAL replay() round-trip score [recommended] · --ridge raw-emission argmax dump ·');
    console.log(' --filter/--oracle/--recapture SUPERSEDED stale parallel loop, see §13)');
  }
}

if (require.main === module) main();

module.exports = { perPointLogLikReverse, buildTrueBinMapper, DirectionalFilter, directionalReplay, UTURN_MIN_DEG };
