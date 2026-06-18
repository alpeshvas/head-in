#!/usr/bin/env node
/**
 * Offline route matcher for SurveyRecorder JSONL sessions.
 *
 * Usage:
 *   node analysis/match-route.js <profile.json> <session.jsonl> [--out report.html]
 *
 * The matcher replays a recorded session against a pre-built route fingerprint
 * profile. Recorded anchors are used to split and score the offline replay into
 * anchor-to-anchor validation segments; they are not treated as live runtime
 * inputs to the magnetic matcher.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { buildArcLength, segmentGroundTruth } = require('./ground-truth');

// Minimum tracking quality for AR ground truth to be trusted as the error reference.
const MIN_AR_TRACKING_QUALITY = 0.6;

const DEFAULT_WINDOW_POINTS = 28;
const SEARCH_RADIUS = 0.18; // segment-progress fraction around the PDR prior
const MAGNETIC_BLEND = 0.45;
const MIN_STEP_INTERVAL_S = 0.34;
const MIN_MATCH_WINDOW_POINTS = 8;

function parseArgs(argv) {
  const positional = [];
  let out = null;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--out') {
      if (i + 1 >= argv.length) throw new Error('--out requires a file path');
      out = argv[++i];
    } else if (arg === '--help' || arg === '-h') {
      return { help: true };
    } else if (arg.startsWith('--')) {
      throw new Error(`Unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }

  if (positional.length !== 2) {
    return { help: true, invalid: positional.length !== 0 };
  }

  return { profilePath: positional[0], sessionPath: positional[1], out };
}

function usage() {
  return [
    'Usage:',
    '  node analysis/match-route.js <profile.json> <session.jsonl> [--out report.html]',
    '',
    'Replays one recorded SurveyRecorder session against one route fingerprint profile.',
  ].join('\n');
}

function readProfile(filePath) {
  const profile = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (profile.schema !== 1) throw new Error(`${filePath}: expected profile schema 1`);
  if (!profile.route || typeof profile.route !== 'object') throw new Error(`${filePath}: missing route object`);
  if (!Array.isArray(profile.anchors)) throw new Error(`${filePath}: missing anchors array`);
  if (!Array.isArray(profile.segments)) throw new Error(`${filePath}: missing segments array`);

  for (const [i, segment] of profile.segments.entries()) {
    if (typeof segment.index !== 'number') throw new Error(`${filePath}: segment ${i} missing numeric index`);
    if (typeof segment.from !== 'string' || typeof segment.to !== 'string') {
      throw new Error(`${filePath}: segment ${segment.index} missing from/to anchor names`);
    }
    const isTransition = segment.kind === 'transition' || segment.useForMatching === false;
    if (!isTransition) {
      const mean = segment.magneticMagnitude && segment.magneticMagnitude.mean;
      if (!Array.isArray(mean) || mean.length < MIN_MATCH_WINDOW_POINTS || mean.some((v) => !Number.isFinite(v))) {
        throw new Error(`${filePath}: fingerprint segment ${segment.index} requires magneticMagnitude.mean with at least ${MIN_MATCH_WINDOW_POINTS} finite values`);
      }
    }
  }

  return profile;
}

function parseSession(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  let meta = null;
  const dm = [];
  const rawMag = [];
  const anchors = [];
  const arPoses = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      // Recorder exports can have a truncated final line after a crash; ignore it.
      continue;
    }

    switch (obj.type) {
      case 'meta':
        meta = obj;
        break;
      case 'dm': {
        if (obj.mag && isFiniteVector(obj.mag)) {
          const sample = {
            t: Number(obj.t),
            mag: magnitude(obj.mag),
            magAccuracy: obj.mag.acc,
            source: 'dm.mag',
          };
          if (obj.ua && isFiniteVector(obj.ua)) {
            sample.uaMag = magnitude(obj.ua);
            sample.uaZ = Number(obj.ua.z);
          }
          if (Number.isFinite(sample.t) && Number.isFinite(sample.mag)) dm.push(sample);
        }
        break;
      }
      case 'mag':
        // Fallback only. Matching prefers calibrated device-motion magnetic field.
        if (isFiniteVector(obj)) {
          const sample = { t: Number(obj.t), mag: magnitude(obj), source: 'mag' };
          if (Number.isFinite(sample.t) && Number.isFinite(sample.mag)) rawMag.push(sample);
        }
        break;
      case 'anchor':
        if (Number.isFinite(Number(obj.t))) {
          anchors.push({ t: Number(obj.t), index: obj.index, name: String(obj.name ?? obj.index ?? '') });
        }
        break;
      case 'anchor_undo':
        undoAnchor(anchors, obj);
        break;
      case 'arpose':
        if (obj.p) {
          const t = Number(obj.t);
          const x = Number(obj.p.x);
          const y = Number(obj.p.y);
          const z = Number(obj.p.z);
          if ([t, x, y, z].every(Number.isFinite)) {
            arPoses.push({ t, x, y, z, tracking: String(obj.track || '') });
          }
        }
        break;
      default:
        break;
    }
  }

  if (!meta) throw new Error(`${filePath}: no meta line found`);
  anchors.sort((a, b) => a.t - b.t);
  dm.sort((a, b) => a.t - b.t);
  rawMag.sort((a, b) => a.t - b.t);
  arPoses.sort((a, b) => a.t - b.t);

  const trace = dm.length > 0 ? dm : rawMag;
  if (trace.length === 0) throw new Error(`${filePath}: no dm.mag or raw magnetometer samples found`);

  return {
    file: path.basename(filePath),
    path: filePath,
    meta,
    trace,
    dm,
    anchors,
    arPoses,
    arc: arPoses.length >= 2 ? buildArcLength(arPoses) : null,
    calibrated: dm.length > 0,
  };
}

function isFiniteVector(v) {
  return Number.isFinite(Number(v.x)) && Number.isFinite(Number(v.y)) && Number.isFinite(Number(v.z));
}

function magnitude(v) {
  return Math.hypot(Number(v.x), Number(v.y), Number(v.z));
}

function undoAnchor(anchors, undo) {
  for (let i = anchors.length - 1; i >= 0; i--) {
    const sameIndex = undo.index !== undefined && anchors[i].index === undo.index;
    const sameName = undo.name !== undefined && anchors[i].name === undo.name;
    if (sameIndex || sameName) {
      anchors.splice(i, 1);
      return;
    }
  }
}

function anchorLabel(anchor) {
  return anchor && anchor.name ? anchor.name : String(anchor && anchor.index !== undefined ? anchor.index : 'unknown');
}

function buildAnchorResolver(profile, session) {
  const profileByName = new Map(profile.anchors.map((a) => [a.name, a]));
  const sessionByIndex = new Map();
  const sessionByName = new Map();

  for (const anchor of session.anchors) {
    if (anchor.index !== undefined && !sessionByIndex.has(anchor.index)) sessionByIndex.set(anchor.index, anchor);
    if (anchor.name && !sessionByName.has(anchor.name)) sessionByName.set(anchor.name, anchor);
  }

  return function resolve(name) {
    const profileAnchor = profileByName.get(name);
    if (profileAnchor && sessionByIndex.has(profileAnchor.index)) return sessionByIndex.get(profileAnchor.index);
    if (sessionByName.has(name)) return sessionByName.get(name);
    return null;
  };
}

function samplesBetween(samples, startT, endT) {
  return samples.filter((s) => s.t >= startT && s.t <= endT);
}

function buildValidationSegment(session, profile, profileSegment, resolveAnchor) {
  const start = resolveAnchor(profileSegment.from);
  const end = resolveAnchor(profileSegment.to);
  if (!start || !end) {
    return {
      ok: false,
      reason: `missing recorded anchor${!start && !end ? 's' : ''}: ${!start ? profileSegment.from : ''}${!start && !end ? ', ' : ''}${!end ? profileSegment.to : ''}`,
    };
  }
  if (end.t <= start.t) {
    return { ok: false, reason: `anchor order is not increasing (${anchorLabel(start)} >= ${anchorLabel(end)})` };
  }

  const traceSamples = samplesBetween(session.trace, start.t, end.t);
  const stepSamples = samplesBetween(session.dm, start.t, end.t).filter((s) => Number.isFinite(s.uaMag));
  if (traceSamples.length < 2) return { ok: false, reason: 'not enough magnetic samples between anchors' };

  return {
    ok: true,
    start,
    end,
    duration: end.t - start.t,
    traceSamples,
    stepSamples,
  };
}

function median(values) {
  if (values.length === 0) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function smooth(values, radius = 3) {
  return values.map((_, i) => {
    let sum = 0;
    let n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(values.length - 1, i + radius); j++) {
      sum += values[j];
      n++;
    }
    return n ? sum / n : values[i];
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

function clamp01(x) {
  return Math.min(1, Math.max(0, x));
}

function pdrProgressAt(t, startT, endT, steps) {
  const timeProgress = clamp01((t - startT) / Math.max(endT - startT, 0.001));
  if (steps.length < 2) return timeProgress;

  const first = steps[0].t;
  const last = steps[steps.length - 1].t;
  if (t <= first) {
    return clamp01(0.5 * (t - startT) / Math.max(first - startT, 0.001) / steps.length);
  }
  if (t >= last) {
    return clamp01((steps.length - 1) / steps.length + (t - last) / Math.max(endT - last, 0.001) / steps.length);
  }

  let count = 0;
  while (count < steps.length && steps[count].t <= t) count++;
  const prev = steps[count - 1];
  const next = steps[count];
  const within = next ? (t - prev.t) / Math.max(next.t - prev.t, 0.001) : 0;
  return clamp01((count - 1 + within) / Math.max(steps.length - 1, 1));
}

function pearson(a, b) {
  const n = Math.min(a.length, b.length);
  if (n === 0) return 0;
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
  return va === 0 || vb === 0 ? 0 : cov / Math.sqrt(va * vb);
}

function chooseWindowSize(trackLength, profileLength) {
  let size = Math.min(DEFAULT_WINDOW_POINTS, trackLength, profileLength);
  if (size % 2 === 1) size -= 1;
  return size >= MIN_MATCH_WINDOW_POINTS ? size : 0;
}

function matchWindow(track, i, profileMean, windowSize) {
  const half = Math.floor(windowSize / 2);
  if (i < half || i >= track.length - half) return null;

  const live = track.slice(i - half, i + half).map((p) => p.mag);
  const pdr = track[i].pdr;
  const maxIndex = profileMean.length - 1;
  const centerLo = Math.max(half, Math.floor((pdr - SEARCH_RADIUS) * maxIndex));
  const centerHi = Math.min(profileMean.length - half - 1, Math.ceil((pdr + SEARCH_RADIUS) * maxIndex));
  if (centerLo > centerHi) return null;

  let best = { progress: pdr, r: -Infinity };
  for (let c = centerLo; c <= centerHi; c++) {
    const fp = profileMean.slice(c - half, c + half);
    const r = pearson(live, fp);
    if (r > best.r) best = { progress: c / maxIndex, r };
  }

  return best.r === -Infinity ? null : best;
}

function buildTrack(validationSegment, steps, groundTruth) {
  const startT = validationSegment.start.t;
  const endT = validationSegment.end.t;
  const useAR = groundTruth && groundTruth.trackingQuality >= MIN_AR_TRACKING_QUALITY;
  return validationSegment.traceSamples.map((s) => ({
    t: s.t,
    mag: s.mag,
    // True progress: real distance travelled (ARKit) when available and well-tracked,
    // else the time-linear assumption (constant walking speed).
    truth: useAR ? groundTruth.progressAt(s.t) : clamp01((s.t - startT) / Math.max(endT - startT, 0.001)),
    pdr: pdrProgressAt(s.t, startT, endT, steps),
  }));
}

function replayFingerprintSegment(profileSegment, validationSegment, groundTruth) {
  const profileMean = profileSegment.magneticMagnitude.mean;
  const steps = detectSteps(validationSegment.stepSamples);
  const track = buildTrack(validationSegment, steps, groundTruth);
  const windowSize = chooseWindowSize(track.length, profileMean.length);
  const estimates = [];

  for (let i = 0; i < track.length; i++) {
    const p = track[i];
    const match = windowSize ? matchWindow(track, i, profileMean, windowSize) : null;
    const correlation = match ? match.r : 0;
    const confidence = match ? clamp01((correlation - 0.25) / 0.55) : 0;
    const blend = MAGNETIC_BLEND * confidence;
    const magnetic = match ? match.progress : p.pdr;
    const fused = clamp01(p.pdr * (1 - blend) + magnetic * blend);
    estimates.push({ ...p, magnetic, fused, correlation, confidence });
  }

  const pdrMae = mae(estimates, 'pdr');
  const fusedMae = mae(estimates, 'fused');
  const matched = estimates.filter((r) => r.confidence > 0 || r.correlation !== 0);
  const avgConfidence = average(estimates, 'confidence');
  const avgCorrelation = matched.length ? matched.reduce((sum, r) => sum + r.correlation, 0) / matched.length : 0;
  const event = nearCheckpointEvent(estimates, profileSegment.to);

  // True error in meters when ARKit ground truth backs the truth signal.
  const useAR = groundTruth && groundTruth.trackingQuality >= MIN_AR_TRACKING_QUALITY;
  const lengthMeters = useAR ? groundTruth.lengthMeters : null;

  return {
    kind: 'fingerprint',
    status: windowSize ? 'matched' : 'no_window',
    samples: track.length,
    steps: steps.length,
    pdrMae,
    fusedMae,
    truthSource: useAR ? 'arkit' : 'time',
    lengthMeters,
    arTrackingQuality: groundTruth ? groundTruth.trackingQuality : null,
    pdrMaeMeters: lengthMeters != null ? pdrMae * lengthMeters : null,
    fusedMaeMeters: lengthMeters != null ? fusedMae * lengthMeters : null,
    avgConfidence,
    avgCorrelation,
    finalPdr: estimates.length ? estimates[estimates.length - 1].pdr : 0,
    finalFused: estimates.length ? estimates[estimates.length - 1].fused : 0,
    event,
    estimates,
    windowSize,
  };
}

function mae(rows, key) {
  if (rows.length === 0) return 0;
  return rows.reduce((sum, row) => sum + Math.abs(row[key] - row.truth), 0) / rows.length;
}

function average(rows, key) {
  if (rows.length === 0) return 0;
  return rows.reduce((sum, row) => sum + row[key], 0) / rows.length;
}

function nearCheckpointEvent(estimates, checkpointName) {
  for (const row of estimates) {
    if (row.truth >= 0.75 && row.fused >= 0.9) {
      return {
        type: 'near_checkpoint',
        checkpoint: checkpointName,
        truthProgress: row.truth,
        fusedProgress: row.fused,
        confidence: row.confidence,
      };
    }
  }
  return null;
}

function transitionResult(profileSegment, validationSegment) {
  const steps = validationSegment && validationSegment.ok ? detectSteps(validationSegment.stepSamples) : [];
  return {
    kind: 'transition',
    status: 'transition_skipped',
    samples: validationSegment && validationSegment.ok ? validationSegment.traceSamples.length : 0,
    steps: steps.length,
    pdrMae: null,
    fusedMae: null,
    avgConfidence: null,
    avgCorrelation: null,
    finalPdr: null,
    finalFused: null,
    event: null,
    estimates: [],
    windowSize: 0,
    note: `${profileSegment.kind === 'transition' ? 'transition' : 'useForMatching=false'}; magnetic matching skipped`,
  };
}

function skippedResult(reason) {
  return {
    kind: 'skipped',
    status: 'skipped',
    samples: 0,
    steps: 0,
    pdrMae: null,
    fusedMae: null,
    avgConfidence: null,
    avgCorrelation: null,
    finalPdr: null,
    finalFused: null,
    event: null,
    estimates: [],
    windowSize: 0,
    note: reason,
  };
}

function analyze(profile, session) {
  const resolveAnchor = buildAnchorResolver(profile, session);
  return profile.segments.map((profileSegment) => {
    const validationSegment = buildValidationSegment(session, profile, profileSegment, resolveAnchor);
    const isTransition = profileSegment.kind === 'transition' || profileSegment.useForMatching === false;
    const groundTruth = validationSegment.ok && session.arc
      ? segmentGroundTruth(session.arc, validationSegment.start.t, validationSegment.end.t)
      : null;
    const result = !validationSegment.ok
      ? skippedResult(validationSegment.reason)
      : isTransition
        ? transitionResult(profileSegment, validationSegment)
        : replayFingerprintSegment(profileSegment, validationSegment, groundTruth);

    return {
      profileSegment,
      validationSegment,
      result,
      label: `${profileSegment.index}: ${profileSegment.from} -> ${profileSegment.to}`,
    };
  });
}

function formatNumber(value, digits = 3) {
  return value === null || value === undefined || !Number.isFinite(value) ? '--' : value.toFixed(digits);
}

function formatPercent(value, digits = 1) {
  return value === null || value === undefined || !Number.isFinite(value) ? '--' : `${(value * 100).toFixed(digits)}%`;
}

function eventText(event) {
  if (!event) return '--';
  return `${event.type}:${event.checkpoint}@${formatPercent(event.truthProgress, 0)} conf=${formatNumber(event.confidence, 2)}`;
}

function printReport(profile, session, rows) {
  const route = profile.route;
  console.log(`Profile: ${route.venueId || 'unknown'} / ${route.routeId || 'unknown'} / ${route.direction || 'unknown'} / ${route.devicePose || 'unknown'}`);
  console.log(`Session: ${session.file} (${session.calibrated ? 'calibrated dm.mag' : 'raw magnetometer fallback'})`);
  console.log('NOTE: recorded anchors are used only for offline validation segmentation/scoring, not as live runtime matcher inputs.');
  console.log('');

  const headers = [
    ['Segment', 31],
    ['Kind', 13],
    ['Samples', 8],
    ['Steps', 7],
    ['PDR MAE', 9],
    ['Fused MAE', 10],
    ['Corr', 7],
    ['Conf', 7],
    ['Final', 8],
    ['Event/Status', 0],
  ];
  console.log(headers.map(([h, w]) => (w ? h.padEnd(w) : h)).join(''));
  console.log('-'.repeat(118));

  for (const row of rows) {
    const r = row.result;
    const status = r.event ? eventText(r.event) : (r.note || r.status || '--');
    console.log(
      row.label.slice(0, 29).padEnd(31) +
      String(r.kind).padEnd(13) +
      String(r.samples).padEnd(8) +
      String(r.steps).padEnd(7) +
      formatNumber(r.pdrMae).padEnd(9) +
      formatNumber(r.fusedMae).padEnd(10) +
      formatNumber(r.avgCorrelation, 2).padEnd(7) +
      formatNumber(r.avgConfidence, 2).padEnd(7) +
      formatPercent(r.finalFused, 0).padEnd(8) +
      status
    );
  }

  const matchedRows = rows.filter((row) => row.result.kind === 'fingerprint' && row.result.samples > 0);
  if (matchedRows.length) {
    const avgPdrMae = matchedRows.reduce((sum, row) => sum + row.result.pdrMae, 0) / matchedRows.length;
    const avgFusedMae = matchedRows.reduce((sum, row) => sum + row.result.fusedMae, 0) / matchedRows.length;
    const avgConf = matchedRows.reduce((sum, row) => sum + row.result.avgConfidence, 0) / matchedRows.length;
    console.log('-'.repeat(118));
    console.log(`Fingerprint averages: PDR MAE ${formatPercent(avgPdrMae)} segment, fused MAE ${formatPercent(avgFusedMae)} segment, confidence ${formatNumber(avgConf, 2)}`);

    const arRows = matchedRows.filter((row) => row.result.truthSource === 'arkit');
    if (arRows.length) {
      console.log('');
      console.log('TRUE error vs ARKit ground truth (meters):');
      console.log('Segment'.padEnd(34) + 'Length m'.padEnd(10) + 'PDR m'.padEnd(9) + 'Fused m'.padEnd(9) + 'AR track');
      console.log('-'.repeat(72));
      let sumPdrM = 0;
      let sumFusedM = 0;
      let sumLen = 0;
      for (const row of arRows) {
        const r = row.result;
        console.log(
          row.label.slice(0, 32).padEnd(34) +
          r.lengthMeters.toFixed(2).padEnd(10) +
          r.pdrMaeMeters.toFixed(2).padEnd(9) +
          r.fusedMaeMeters.toFixed(2).padEnd(9) +
          `${(r.arTrackingQuality * 100).toFixed(0)}%`
        );
        sumPdrM += r.pdrMaeMeters;
        sumFusedM += r.fusedMaeMeters;
        sumLen += r.lengthMeters;
      }
      console.log('-'.repeat(72));
      console.log(`Mean true error: PDR ${(sumPdrM / arRows.length).toFixed(2)} m, fused ${(sumFusedM / arRows.length).toFixed(2)} m  (over ${sumLen.toFixed(1)} m of matched route)`);
    } else if (session.arPoses && session.arPoses.length >= 2) {
      console.log('AR poses present but tracking quality below threshold; reported MAE is vs time-linear truth, not meters.');
    } else {
      console.log('No ARKit ground truth in this session; MAE is vs time-linear truth (assumes constant walking speed).');
    }
  }
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function svgReplay(estimates, width = 720, height = 190) {
  if (!estimates || estimates.length < 2) return '<p>No replay estimates available.</p>';
  const pad = 12;
  const colors = { truth: '#111827', pdr: '#2563eb', magnetic: '#059669', fused: '#dc2626' };
  const line = (key) => estimates.map((row, i) => {
    const x = pad + ((width - 2 * pad) * i) / (estimates.length - 1);
    const y = height - pad - ((height - 2 * pad) * clamp01(row[key]) );
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');

  return `<div class="legend">
    <span style="color:${colors.truth}">truth(time)</span>
    <span style="color:${colors.pdr}">PDR</span>
    <span style="color:${colors.magnetic}">magnetic</span>
    <span style="color:${colors.fused}">fused</span>
  </div>
  <svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" role="img" aria-label="segment progress replay">
    <polyline fill="none" stroke="${colors.truth}" stroke-width="1.2" points="${line('truth')}"/>
    <polyline fill="none" stroke="${colors.pdr}" stroke-width="1.2" points="${line('pdr')}"/>
    <polyline fill="none" stroke="${colors.magnetic}" stroke-width="1.2" points="${line('magnetic')}"/>
    <polyline fill="none" stroke="${colors.fused}" stroke-width="1.8" points="${line('fused')}"/>
  </svg>`;
}

function writeHtml(outPath, profile, session, rows) {
  const route = profile.route;
  const bodyRows = rows.map((row) => {
    const r = row.result;
    return `<tr>
      <td>${escapeHtml(row.label)}</td>
      <td>${escapeHtml(r.kind)}</td>
      <td>${r.samples}</td>
      <td>${r.steps}</td>
      <td>${escapeHtml(formatPercent(r.pdrMae))}</td>
      <td>${escapeHtml(formatPercent(r.fusedMae))}</td>
      <td>${escapeHtml(formatNumber(r.avgCorrelation, 2))}</td>
      <td>${escapeHtml(formatNumber(r.avgConfidence, 2))}</td>
      <td>${escapeHtml(formatPercent(r.finalFused, 0))}</td>
      <td>${escapeHtml(r.event ? eventText(r.event) : (r.note || r.status || '--'))}</td>
    </tr>`;
  }).join('\n');

  const sections = rows.map((row) => {
    const r = row.result;
    const validation = row.validationSegment && row.validationSegment.ok
      ? `${r.samples} samples &middot; ${(row.validationSegment.duration).toFixed(2)}s validation segment from recorded anchors`
      : escapeHtml(r.note || 'not replayed');
    const details = r.kind === 'fingerprint'
      ? `${svgReplay(r.estimates)}<p>Window ${r.windowSize || '--'} points &middot; PDR MAE ${formatPercent(r.pdrMae)} &middot; fused MAE ${formatPercent(r.fusedMae)} &middot; average confidence ${formatNumber(r.avgConfidence, 2)} &middot; event ${escapeHtml(r.event ? eventText(r.event) : 'none')}</p>`
      : `<p>${escapeHtml(r.note || r.status)}.</p>`;
    return `<section>
      <h2>${escapeHtml(row.label)}</h2>
      <p>${validation}</p>
      ${details}
    </section>`;
  }).join('\n');

  const html = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Route matcher replay report</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:900px;margin:24px auto;padding:0 16px;color:#111827;line-height:1.45}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border:1px solid #e5e7eb;padding:6px 8px;text-align:left}th{background:#f9fafb}section{margin-top:28px;padding-top:8px;border-top:1px solid #e5e7eb}svg{max-width:100%;height:auto;background:#fafafa;border:1px solid #e5e7eb}.legend{font-size:12px;margin-bottom:4px}.legend span{margin-right:14px;font-weight:600}.note{background:#fffbeb;border:1px solid #fde68a;padding:10px 12px;border-radius:6px}
</style></head><body>
<h1>Route matcher replay report</h1>
<p><strong>Profile:</strong> ${escapeHtml(route.venueId || 'unknown')} / ${escapeHtml(route.routeId || 'unknown')} / ${escapeHtml(route.direction || 'unknown')} / ${escapeHtml(route.devicePose || 'unknown')}</p>
<p><strong>Session:</strong> ${escapeHtml(session.file)} (${session.calibrated ? 'calibrated dm.mag' : 'raw magnetometer fallback'})</p>
<p class="note"><strong>Offline validation note:</strong> recorded anchors split and score this replay into anchor-to-anchor segments. They are not live runtime inputs to the magnetic matcher.</p>
<table><thead><tr><th>Segment</th><th>Kind</th><th>Samples</th><th>Steps</th><th>PDR MAE</th><th>Fused MAE</th><th>Corr</th><th>Conf</th><th>Final</th><th>Event/Status</th></tr></thead><tbody>
${bodyRows}
</tbody></table>
${sections}
</body></html>`;

  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, html);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    process.exit(args.invalid ? 1 : 0);
  }

  const profile = readProfile(args.profilePath);
  const session = parseSession(args.sessionPath);
  const rows = analyze(profile, session);
  printReport(profile, session, rows);

  if (args.out) {
    writeHtml(args.out, profile, session, rows);
    console.log(`\nHTML report: ${args.out}`);
  }
}

try {
  main();
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(1);
}
