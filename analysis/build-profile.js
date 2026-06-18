#!/usr/bin/env node
/**
 * Build a reusable magnetic route fingerprint profile from repeated survey sessions.
 *
 * Usage:
 *   node analysis/build-profile.js session1.jsonl session2.jsonl [...] --out profiles/name.json
 */

'use strict';

const fs = require('fs');
const path = require('path');
const turnEvents = require('./turn-events');
const { buildArcLength } = require('./ground-truth');
const { spliceSession } = require('./splice-pauses');

const RESAMPLE_POINTS = 240;
const TURN_CLUSTER_GAP_BINS = 80;
const TURN_MIN_SIGMA_BINS = 12;
const DTW_BAND_FRACTION = 0.1;
const TRANSITION_MAX_MEDIAN_DURATION_SEC = 4.0;
const TRANSITION_MAX_MEDIAN_STEPS = 5;
const MIN_STEP_INTERVAL_S = 0.34;

function usage(exitCode = 1) {
  const msg = [
    'Usage: node analysis/build-profile.js <session.jsonl...> --out profiles/<name>.json [--splice-pauses]',
    '',
    'Builds a route fingerprint profile from repeated survey sessions.',
    '--splice-pauses: remove standing pauses first (pocket survey protocol).',
  ].join('\n');
  if (exitCode === 0) console.log(msg);
  else console.error(msg);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const files = [];
  let out = null;
  let splicePauses = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') usage(0);
    else if (arg === '--out') {
      if (i + 1 >= argv.length) throw new Error('--out requires a path');
      out = argv[++i];
    } else if (arg === '--splice-pauses') {
      splicePauses = true;
    } else if (arg.startsWith('--')) {
      throw new Error(`Unknown option: ${arg}`);
    } else {
      files.push(arg);
    }
  }

  return { files, out, splicePauses };
}

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function magnitude3(v) {
  if (!v || !isFiniteNumber(v.x) || !isFiniteNumber(v.y) || !isFiniteNumber(v.z)) return null;
  return Math.hypot(v.x, v.y, v.z);
}

function removeMostRecentAnchor(anchors, index) {
  for (let i = anchors.length - 1; i >= 0; i--) {
    if (anchors[i].index === index) {
      anchors.splice(i, 1);
      return;
    }
  }
}

function parseSession(filePath, providedLines) {
  const lines = providedLines ?? fs.readFileSync(filePath, 'utf8').split('\n');
  let meta = null;
  const dmMag = [];
  const dmUa = [];
  const rawMag = [];
  const anchors = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      // Tolerate a truncated/corrupt final line from a crashed recording.
      continue;
    }

    switch (obj.type) {
      case 'meta':
        meta = obj;
        break;
      case 'dm': {
        if (!isFiniteNumber(obj.t)) break;
        const mag = magnitude3(obj.mag);
        if (mag !== null) dmMag.push({ t: obj.t, v: mag });
        const ua = magnitude3(obj.ua);
        if (ua !== null) dmUa.push({ t: obj.t, uaMag: ua });
        break;
      }
      case 'mag': {
        if (!isFiniteNumber(obj.t)) break;
        if (isFiniteNumber(obj.x) && isFiniteNumber(obj.y) && isFiniteNumber(obj.z)) {
          rawMag.push({ t: obj.t, v: Math.hypot(obj.x, obj.y, obj.z) });
        }
        break;
      }
      case 'anchor': {
        if (!isFiniteNumber(obj.t)) break;
        const index = Number(obj.index);
        if (!Number.isInteger(index)) break;
        anchors.push({
          t: obj.t,
          index,
          name: String(obj.name ?? `Anchor ${index}`),
        });
        break;
      }
      case 'anchor_undo': {
        const index = Number(obj.index);
        if (Number.isInteger(index)) removeMostRecentAnchor(anchors, index);
        break;
      }
    }
  }

  if (!meta) throw new Error(`${filePath}: no meta line found`);
  anchors.sort((a, b) => a.t - b.t);
  dmMag.sort((a, b) => a.t - b.t);
  dmUa.sort((a, b) => a.t - b.t);
  rawMag.sort((a, b) => a.t - b.t);

  // Prefer calibrated CoreMotion device-motion magnetic field; fall back only if absent.
  const magneticTrace = dmMag.length > 0 ? dmMag : rawMag;

  return {
    file: path.basename(filePath),
    inputPath: filePath,
    meta,
    anchors,
    magneticTrace,
    calibratedMagnetic: dmMag.length > 0,
    uaTrace: dmUa,
  };
}

function routeFromMeta(meta) {
  const route = {
    venueId: String(meta.venueId ?? ''),
    routeId: String(meta.routeId ?? ''),
    direction: String(meta.direction ?? ''),
    devicePose: String(meta.devicePose ?? ''),
  };
  if (meta.floorId !== undefined && meta.floorId !== null && String(meta.floorId) !== '') {
    route.floorId = String(meta.floorId);
  }
  return route;
}

function routeKey(route) {
  return JSON.stringify({
    venueId: route.venueId,
    routeId: route.routeId,
    direction: route.direction,
    devicePose: route.devicePose,
    floorId: route.floorId ?? '',
  });
}

function sameCheckpointList(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return a === b;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (String(a[i]) !== String(b[i])) return false;
  }
  return true;
}

function warnOnMixedRouteMetadata(sessions) {
  if (sessions.length < 2) return;
  const routeKeys = new Set(sessions.map((s) => routeKey(routeFromMeta(s.meta))));
  const firstCheckpoints = sessions[0].meta.checkpoints;
  const checkpointsMixed = sessions.some((s) => !sameCheckpointList(firstCheckpoints, s.meta.checkpoints));

  if (routeKeys.size > 1 || checkpointsMixed) {
    const labels = sessions.map((s) => `${s.file}:${routeKey(routeFromMeta(s.meta))}`).join(', ');
    console.warn(`WARNING: source sessions have mixed route metadata: ${labels}`);
    if (checkpointsMixed) console.warn('WARNING: source sessions have mixed checkpoint names/order.');
    console.warn('Profile will use the first session route metadata; verify the output before reuse.\n');
  }
}

function buildAnchorList(sessions) {
  const byIndex = new Map();
  const firstCheckpoints = sessions[0]?.meta?.checkpoints;

  if (Array.isArray(firstCheckpoints)) {
    firstCheckpoints.forEach((name, index) => {
      byIndex.set(index, { index, name: String(name) });
    });
  }

  for (const session of sessions) {
    for (const anchor of session.anchors) {
      if (!byIndex.has(anchor.index)) {
        byIndex.set(anchor.index, { index: anchor.index, name: anchor.name });
      }
    }
  }

  return [...byIndex.values()].sort((a, b) => a.index - b.index);
}

function anchorMapForSession(session) {
  const byIndex = new Map();
  for (const anchor of session.anchors) byIndex.set(anchor.index, anchor);
  return byIndex;
}

/** Linear-interpolation resample of {t, v} samples onto n uniform points in [t0, t1]. */
function resample(samples, t0, t1, n) {
  if (t1 <= t0) return null;
  const within = samples.filter((s) => s.t >= t0 && s.t <= t1);
  if (within.length < 2) return null;

  const out = new Array(n);
  let j = 0;
  for (let i = 0; i < n; i++) {
    const t = t0 + ((t1 - t0) * i) / (n - 1);
    while (j < within.length - 2 && within[j + 1].t < t) j++;
    const a = within[j];
    const b = within[j + 1];
    const frac = b.t === a.t ? 0 : (t - a.t) / (b.t - a.t);
    out[i] = a.v + (b.v - a.v) * Math.min(1, Math.max(0, frac));
  }
  return out;
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function minMedianMax(values) {
  if (values.length === 0) return { min: null, median: null, max: null };
  return {
    min: Math.min(...values),
    median: median(values),
    max: Math.max(...values),
  };
}

function smooth(values, radius = 3) {
  return values.map((_, i) => {
    let sum = 0;
    let n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(values.length - 1, i + radius); j++) {
      sum += values[j];
      n++;
    }
    return sum / n;
  });
}

function detectSteps(samples) {
  if (samples.length < 3) return [];
  const signal = smooth(samples.map((s) => s.uaMag), 3);
  const med = median(signal);
  const deviations = signal.map((v) => Math.abs(v - med));
  const mad = median(deviations) || 0.03;
  const threshold = med + Math.max(0.045, 1.6 * mad);
  const steps = [];
  let lastStepT = -Infinity;

  for (let i = 1; i < signal.length - 1; i++) {
    const isPeak = signal[i] > signal[i - 1] && signal[i] >= signal[i + 1] && signal[i] > threshold;
    const farEnough = samples[i].t - lastStepT >= MIN_STEP_INTERVAL_S;
    if (isPeak && farEnough) {
      steps.push({ t: samples[i].t, strength: signal[i] });
      lastStepT = samples[i].t;
    }
  }
  return steps;
}

function pearson(a, b) {
  const n = a.length;
  let sa = 0;
  let sb = 0;
  for (let i = 0; i < n; i++) {
    sa += a[i];
    sb += b[i];
  }
  const ma = sa / n;
  const mb = sb / n;
  let cov = 0;
  let va = 0;
  let vb = 0;
  for (let i = 0; i < n; i++) {
    const da = a[i] - ma;
    const db = b[i] - mb;
    cov += da * db;
    va += da * da;
    vb += db * db;
  }
  if (va === 0 || vb === 0) return 0;
  return cov / Math.sqrt(va * vb);
}

/** DTW with a Sakoe-Chiba band; returns mean |a-b| (µT) along the optimal warp path. */
function dtwMeanDeviation(a, b) {
  const n = a.length;
  const m = b.length;
  const band = Math.max(1, Math.round(Math.max(n, m) * DTW_BAND_FRACTION));
  const INF = Infinity;
  const cost = Array.from({ length: n + 1 }, () => new Float64Array(m + 1).fill(INF));
  const steps = Array.from({ length: n + 1 }, () => new Float64Array(m + 1).fill(0));
  cost[0][0] = 0;

  for (let i = 1; i <= n; i++) {
    const jLo = Math.max(1, i - band);
    const jHi = Math.min(m, i + band);
    for (let j = jLo; j <= jHi; j++) {
      const d = Math.abs(a[i - 1] - b[j - 1]);
      let best = cost[i - 1][j - 1];
      let bestSteps = steps[i - 1][j - 1];
      if (cost[i - 1][j] < best) {
        best = cost[i - 1][j];
        bestSteps = steps[i - 1][j];
      }
      if (cost[i][j - 1] < best) {
        best = cost[i][j - 1];
        bestSteps = steps[i][j - 1];
      }
      if (best === INF) continue;
      cost[i][j] = best + d;
      steps[i][j] = bestSteps + 1;
    }
  }

  if (cost[n][m] === INF || steps[n][m] === 0) return NaN;
  return cost[n][m] / steps[n][m];
}

function qualityForCorrelation(meanCorrelation) {
  if (meanCorrelation !== null && meanCorrelation >= 0.8) return 'strong';
  if (meanCorrelation !== null && meanCorrelation >= 0.6) return 'moderate';
  return 'weak';
}

function round(value, digits = 6) {
  if (value === null) return null;
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function roundedStats(stats, digits = 3) {
  return {
    min: round(stats.min, digits),
    median: round(stats.median, digits),
    max: round(stats.max, digits),
  };
}

function meanStddev(traces) {
  const mean = new Array(RESAMPLE_POINTS).fill(0);
  for (const trace of traces) {
    for (let i = 0; i < RESAMPLE_POINTS; i++) mean[i] += trace[i];
  }
  for (let i = 0; i < RESAMPLE_POINTS; i++) mean[i] /= traces.length;

  const stddev = new Array(RESAMPLE_POINTS).fill(0);
  for (const trace of traces) {
    for (let i = 0; i < RESAMPLE_POINTS; i++) {
      const d = trace[i] - mean[i];
      stddev[i] += d * d;
    }
  }
  for (let i = 0; i < RESAMPLE_POINTS; i++) stddev[i] = Math.sqrt(stddev[i] / traces.length);

  return {
    mean: mean.map((v) => round(v, 6)),
    stddev: stddev.map((v) => round(v, 6)),
  };
}

function pairwiseMetrics(traces) {
  if (traces.length < 2) return { meanCorrelation: null, meanDtwMicrotesla: null };
  let sumR = 0;
  let sumDtw = 0;
  let pairs = 0;
  let dtwPairs = 0;

  for (let i = 0; i < traces.length; i++) {
    for (let j = i + 1; j < traces.length; j++) {
      sumR += pearson(traces[i], traces[j]);
      const dtw = dtwMeanDeviation(traces[i], traces[j]);
      if (Number.isFinite(dtw)) {
        sumDtw += dtw;
        dtwPairs++;
      }
      pairs++;
    }
  }

  return {
    meanCorrelation: pairs > 0 ? sumR / pairs : null,
    meanDtwMicrotesla: dtwPairs > 0 ? sumDtw / dtwPairs : null,
  };
}

function segmentIndexesFromAnchors(anchors, sessions) {
  const indexes = new Set();
  const anchorIndexes = new Set(anchors.map((a) => a.index));
  for (const anchor of anchors) {
    if (anchorIndexes.has(anchor.index + 1)) indexes.add(anchor.index);
  }

  for (const session of sessions) {
    const byIndex = anchorMapForSession(session);
    for (const index of byIndex.keys()) {
      if (byIndex.has(index + 1)) indexes.add(index);
    }
  }

  return [...indexes].sort((a, b) => a - b);
}

function samplesBetween(samples, t0, t1) {
  return samples.filter((s) => s.t >= t0 && s.t <= t1);
}

function buildSegmentInstance(session, index) {
  const anchors = anchorMapForSession(session);
  const start = anchors.get(index);
  const end = anchors.get(index + 1);
  if (!start || !end || end.t <= start.t) return null;

  const trace = resample(session.magneticTrace, start.t, end.t, RESAMPLE_POINTS);
  if (!trace) return null;

  const uaSamples = samplesBetween(session.uaTrace, start.t, end.t);
  const steps = detectSteps(uaSamples).length;

  return {
    file: session.file,
    index,
    from: start.name,
    to: end.name,
    trace,
    duration: end.t - start.t,
    detectedSteps: steps,
  };
}

function formatNumber(value, digits = 3) {
  return value === null || !Number.isFinite(value) ? '-' : value.toFixed(digits);
}

function buildProfile(sessions) {
  const route = routeFromMeta(sessions[0].meta);
  const anchors = buildAnchorList(sessions);
  const anchorByIndex = new Map(anchors.map((a) => [a.index, a]));
  const segmentIndexes = segmentIndexesFromAnchors(anchors, sessions);
  const segments = [];

  for (const index of segmentIndexes) {
    const instances = sessions.map((session) => buildSegmentInstance(session, index)).filter(Boolean);
    if (instances.length === 0) {
      console.warn(`WARNING: segment ${index} has no usable magnetic samples; skipping.`);
      continue;
    }

    const traces = instances.map((instance) => instance.trace);
    const magneticMagnitude = meanStddev(traces);
    const pairwise = pairwiseMetrics(traces);
    const duration = minMedianMax(instances.map((instance) => instance.duration));
    const detectedSteps = minMedianMax(instances.map((instance) => instance.detectedSteps));
    const isTransition =
      duration.median !== null && detectedSteps.median !== null &&
      (duration.median <= TRANSITION_MAX_MEDIAN_DURATION_SEC || detectedSteps.median <= TRANSITION_MAX_MEDIAN_STEPS);

    const fallbackFrom = anchorByIndex.get(index)?.name ?? instances[0].from;
    const fallbackTo = anchorByIndex.get(index + 1)?.name ?? instances[0].to;

    segments.push({
      index,
      from: instances[0].from || fallbackFrom,
      to: instances[0].to || fallbackTo,
      kind: isTransition ? 'transition' : 'fingerprint',
      useForMatching: !isTransition,
      quality: isTransition ? 'transition' : qualityForCorrelation(pairwise.meanCorrelation),
      passes: instances.length,
      meanCorrelation: round(pairwise.meanCorrelation, 6),
      meanDtwMicrotesla: round(pairwise.meanDtwMicrotesla, 6),
      duration: roundedStats(duration, 3),
      detectedSteps: roundedStats(detectedSteps, 3),
      magneticMagnitude,
    });
  }

  return {
    schema: 1,
    createdAtUnix: Math.floor(Date.now() / 1000),
    route,
    sourceFiles: sessions.map((s) => s.file),
    anchors,
    settings: {
      resamplePoints: RESAMPLE_POINTS,
      transitionMaxMedianDurationSec: TRANSITION_MAX_MEDIAN_DURATION_SEC,
      transitionMaxMedianSteps: TRANSITION_MAX_MEDIAN_STEPS,
    },
    segments,
  };
}

/**
 * Phase-3 turn signature: gyro turn events from every survey pass, located on
 * the profile's global bin axis, clustered across passes. Only turns seen in a
 * majority of passes survive — one-off wiggles and the surveyor's end-of-route
 * turn-around drop out. Position within a segment comes from ARKit arc length
 * when the pass recorded ground truth (time fraction is a poor localizer:
 * walking slows mid-turn), falling back to time fraction otherwise.
 */
function buildTurnSignature(filePaths, profile, splicedLines = new Map()) {
  const startBins = new Map();
  let acc = 0;
  for (const seg of profile.segments) {
    startBins.set(seg.index, acc);
    acc += seg.magneticMagnitude.mean.length;
  }

  const perPass = [];
  for (const filePath of filePaths) {
    const session = turnEvents.parseSession(filePath, splicedLines.get(filePath));
    const anchors = session.anchors;
    let arc = null;
    if (session.arPoses.filter((p) => p.tracking === 'normal').length > 50) {
      try { arc = buildArcLength(session.arPoses); } catch { arc = null; }
    }
    const located = [];
    for (const turn of turnEvents.detectTurns(session.dm)) {
      for (let i = 0; i + 1 < anchors.length; i++) {
        if (turn.t < anchors[i].t || turn.t >= anchors[i + 1].t) continue;
        const startBin = startBins.get(anchors[i].index);
        if (startBin === undefined) break;
        const count = profile.segments.find((s) => s.index === anchors[i].index).magneticMagnitude.mean.length;
        let f;
        if (arc) {
          const m0 = arc.lengthAt(anchors[i].t);
          const m1 = arc.lengthAt(anchors[i + 1].t);
          f = m1 > m0 ? (arc.lengthAt(turn.t) - m0) / (m1 - m0) : 0;
        } else {
          f = (turn.t - anchors[i].t) / (anchors[i + 1].t - anchors[i].t);
        }
        located.push({ bin: startBin + Math.min(Math.max(f, 0), 1) * (count - 1), deltaDeg: turn.deltaDeg });
        break;
      }
    }
    perPass.push(located);
  }

  // Cluster across passes: same turn direction, nearby bins.
  const all = perPass.flatMap((turns, pass) => turns.map((t) => ({ ...t, pass }))).sort((a, b) => a.bin - b.bin);
  const clusters = [];
  for (const turn of all) {
    const cluster = clusters.find(
      (c) => Math.sign(c.turns[0].deltaDeg) === Math.sign(turn.deltaDeg) &&
        Math.abs(c.turns[c.turns.length - 1].bin - turn.bin) <= TURN_CLUSTER_GAP_BINS
    );
    if (cluster) cluster.turns.push(turn);
    else clusters.push({ turns: [turn] });
  }

  const minPasses = Math.ceil((filePaths.length + 1) / 2);
  const signature = [];
  for (const cluster of clusters) {
    const passes = new Set(cluster.turns.map((t) => t.pass)).size;
    if (passes < minPasses) continue;
    const bins = cluster.turns.map((t) => t.bin);
    const deltas = cluster.turns.map((t) => t.deltaDeg);
    const binMean = bins.reduce((a, b) => a + b, 0) / bins.length;
    const binStd = Math.sqrt(bins.reduce((a, b) => a + (b - binMean) ** 2, 0) / bins.length);
    signature.push({
      bin: Math.round(binMean),
      deltaDeg: Math.round(deltas.reduce((a, b) => a + b, 0) / deltas.length),
      sigmaBins: Math.round(Math.max(TURN_MIN_SIGMA_BINS, 1.5 * binStd)),
      passes,
    });
  }
  return signature.sort((a, b) => a.bin - b.bin);
}

function printSessionSummary(sessions) {
  for (const session of sessions) {
    const magNote = session.calibratedMagnetic ? 'calibrated dm.mag' : 'RAW mag fallback';
    console.log(`${session.file}: ${session.magneticTrace.length} magnetic samples, ${session.uaTrace.length} ua samples, ${session.anchors.length} anchors, ${magNote}`);
  }
  console.log('');
}

function printSegmentTable(segments) {
  console.log(
    'Segment'.padEnd(8) +
      'Route'.padEnd(34) +
      'Kind'.padEnd(13) +
      'Use'.padEnd(6) +
      'Passes'.padEnd(8) +
      'Med sec'.padEnd(9) +
      'Med steps'.padEnd(11) +
      'Mean r'.padEnd(9) +
      'DTW µT'.padEnd(9) +
      'Quality'
  );
  console.log('-'.repeat(116));

  for (const segment of segments) {
    const route = `${segment.from} -> ${segment.to}`;
    console.log(
      String(segment.index).padEnd(8) +
        route.slice(0, 32).padEnd(34) +
        segment.kind.padEnd(13) +
        String(segment.useForMatching).padEnd(6) +
        String(segment.passes).padEnd(8) +
        formatNumber(segment.duration.median, 2).padEnd(9) +
        formatNumber(segment.detectedSteps.median, 1).padEnd(11) +
        formatNumber(segment.meanCorrelation, 3).padEnd(9) +
        formatNumber(segment.meanDtwMicrotesla, 2).padEnd(9) +
        segment.quality
    );
  }
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    console.error(err.message);
    usage(1);
  }

  if (args.files.length === 0 || !args.out) usage(1);

  // Pocket surveys pause at checkpoints instead of tapping; pauses become
  // flat-field bin stretches in time-resampled profiles (attractors under the
  // differenced emission), so splice them out before building.
  const splicedLines = new Map();
  if (args.splicePauses) {
    for (const file of args.files) {
      const result = spliceSession(file);
      splicedLines.set(file, result.lines);
      console.log(`${path.basename(file)}: spliced out ${result.pauses.length} pauses (${result.removedSeconds.toFixed(1)}s)`);
    }
    console.log('');
  }
  const sessions = args.files.map((f) => parseSession(f, splicedLines.get(f)));
  warnOnMixedRouteMetadata(sessions);
  printSessionSummary(sessions);

  const profile = buildProfile(sessions);
  if (profile.segments.length === 0) {
    throw new Error('No usable anchor-to-anchor segments found. Check anchors and magnetic samples.');
  }

  printSegmentTable(profile.segments);

  profile.turns = buildTurnSignature(args.files, profile, splicedLines);
  console.log(
    profile.turns.length
      ? `\nTurn signature: ${profile.turns.map((t) => `${t.deltaDeg > 0 ? '+' : ''}${t.deltaDeg}°@bin${t.bin}±${t.sigmaBins} (${t.passes}p)`).join('  ')}`
      : '\nTurn signature: no majority turns detected'
  );

  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, JSON.stringify(profile, null, 2) + '\n');
  console.log(`\nProfile JSON: ${args.out}`);
}

if (require.main === module) {
  try {
    main();
  } catch (err) {
    console.error(`ERROR: ${err.message}`);
    process.exit(1);
  }
}
