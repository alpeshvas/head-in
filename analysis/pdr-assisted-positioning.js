#!/usr/bin/env node
/**
 * Route-constrained PDR + magnetic fingerprint replay prototype.
 *
 * This is intentionally offline and simple: it uses recorded survey sessions to
 * build a magnetic fingerprint from repeated walks, then leave-one-session-out
 * replays each walk as if it were live. PDR provides a monotonic route-progress
 * prior from accelerometer step peaks; magnetic matching searches near that PDR
 * prior and nudges the estimate toward the best-matching fingerprint window.
 *
 * Usage:
 *   node analysis/pdr-assisted-positioning.js session1.jsonl session2.jsonl [...] [--out report.html]
 */

'use strict';

const fs = require('fs');
const path = require('path');

const FINGERPRINT_POINTS = 240;
const WINDOW_POINTS = 28;
const SEARCH_RADIUS = 0.18; // route fraction around PDR prior
const MAGNETIC_BLEND = 0.45; // final = pdr*(1-blend) + magnetic*blend when confident
const MIN_STEP_INTERVAL_S = 0.34;

function parseArgs(argv) {
  const files = [];
  let out = 'analysis/pdr-report.html';
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out') out = argv[++i];
    else files.push(argv[i]);
  }
  return { files, out };
}

function parseSession(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  let meta = null;
  const dm = [];
  const anchors = [];
  const pedometer = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    switch (obj.type) {
      case 'meta':
        meta = obj;
        break;
      case 'dm':
        if (obj.mag && obj.ua) {
          dm.push({
            t: obj.t,
            mag: Math.hypot(obj.mag.x, obj.mag.y, obj.mag.z),
            uaMag: Math.hypot(obj.ua.x, obj.ua.y, obj.ua.z),
            uaZ: obj.ua.z,
          });
        }
        break;
      case 'step':
        pedometer.push({ t: obj.t, steps: obj.steps, distance: obj.distance });
        break;
      case 'anchor':
        anchors.push({ t: obj.t, index: obj.index, name: obj.name });
        break;
      case 'anchor_undo':
        for (let i = anchors.length - 1; i >= 0; i--) {
          if (anchors[i].index === obj.index) { anchors.splice(i, 1); break; }
        }
        break;
    }
  }

  if (!meta) throw new Error(`${filePath}: no meta line found`);
  anchors.sort((a, b) => a.t - b.t);
  return { file: path.basename(filePath), meta, dm, anchors, pedometer };
}

function segmentFor(session, index = 0) {
  const byIndex = new Map(session.anchors.map((a) => [a.index, a]));
  const start = byIndex.get(index);
  const end = byIndex.get(index + 1);
  if (!start || !end || end.t <= start.t) return null;
  const samples = session.dm.filter((s) => s.t >= start.t && s.t <= end.t);
  if (samples.length < WINDOW_POINTS * 2) return null;
  return { index, start, end, samples, duration: end.t - start.t };
}

function median(values) {
  const sorted = values.slice().sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function smooth(values, radius = 3) {
  return values.map((_, i) => {
    let sum = 0, n = 0;
    for (let j = Math.max(0, i - radius); j <= Math.min(values.length - 1, i + radius); j++) {
      sum += values[j]; n++;
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

function pdrProgressAt(t, startT, endT, steps) {
  if (steps.length < 2) return clamp01((t - startT) / (endT - startT));
  const first = steps[0].t;
  const last = steps[steps.length - 1].t;
  // Before first detected step, ramp gently from anchor start to first step.
  if (t <= first) return clamp01(0.5 * (t - startT) / Math.max(first - startT, 0.001) / steps.length);
  if (t >= last) return clamp01((steps.length - 1) / steps.length + (t - last) / Math.max(endT - last, 0.001) / steps.length);
  let count = 0;
  while (count < steps.length && steps[count].t <= t) count++;
  const prev = steps[count - 1];
  const next = steps[count];
  const within = next ? (t - prev.t) / Math.max(next.t - prev.t, 0.001) : 0;
  return clamp01((count - 1 + within) / Math.max(steps.length - 1, 1));
}

function clamp01(x) { return Math.min(1, Math.max(0, x)); }

function interpolateSeries(points, xKey, yKey, n) {
  const sorted = points.slice().sort((a, b) => a[xKey] - b[xKey]);
  const out = new Array(n);
  let j = 0;
  for (let i = 0; i < n; i++) {
    const x = i / (n - 1);
    while (j < sorted.length - 2 && sorted[j + 1][xKey] < x) j++;
    const a = sorted[j], b = sorted[Math.min(j + 1, sorted.length - 1)];
    const frac = b[xKey] === a[xKey] ? 0 : (x - a[xKey]) / (b[xKey] - a[xKey]);
    out[i] = a[yKey] + (b[yKey] - a[yKey]) * Math.min(1, Math.max(0, frac));
  }
  return out;
}

function pearson(a, b) {
  const n = a.length;
  let sa = 0, sb = 0;
  for (let i = 0; i < n; i++) { sa += a[i]; sb += b[i]; }
  const ma = sa / n, mb = sb / n;
  let cov = 0, va = 0, vb = 0;
  for (let i = 0; i < n; i++) {
    const da = a[i] - ma, db = b[i] - mb;
    cov += da * db; va += da * da; vb += db * db;
  }
  return va === 0 || vb === 0 ? 0 : cov / Math.sqrt(va * vb);
}

function buildTrack(session, segmentIndex) {
  const seg = segmentFor(session, segmentIndex);
  if (!seg) return null;
  const steps = detectSteps(seg.samples);
  const track = seg.samples.map((s, i) => ({
    t: s.t,
    mag: s.mag,
    pdr: pdrProgressAt(s.t, seg.start.t, seg.end.t, steps),
    // Only for offline scoring. Runtime would not know this between anchors.
    truth: i / (seg.samples.length - 1),
  }));
  return { session, seg, steps, track };
}

function buildFingerprint(tracks) {
  const resampled = tracks.map((tr) => interpolateSeries(tr.track, 'pdr', 'mag', FINGERPRINT_POINTS));
  return Array.from({ length: FINGERPRINT_POINTS }, (_, i) => {
    const vals = resampled.map((r) => r[i]);
    return vals.reduce((a, b) => a + b, 0) / vals.length;
  });
}

function matchWindow(track, i, fingerprint) {
  const half = Math.floor(WINDOW_POINTS / 2);
  if (i < half || i >= track.length - half) return null;
  const live = track.slice(i - half, i + half).map((p) => p.mag);
  const pdr = track[i].pdr;
  const centerLo = Math.max(half, Math.floor((pdr - SEARCH_RADIUS) * (FINGERPRINT_POINTS - 1)));
  const centerHi = Math.min(FINGERPRINT_POINTS - half - 1, Math.ceil((pdr + SEARCH_RADIUS) * (FINGERPRINT_POINTS - 1)));
  let best = { progress: pdr, score: -Infinity, r: 0 };
  for (let c = centerLo; c <= centerHi; c++) {
    const fp = fingerprint.slice(c - half, c + half);
    const r = pearson(live, fp);
    if (r > best.score) best = { progress: c / (FINGERPRINT_POINTS - 1), score: r, r };
  }
  return best;
}

function replay(trackObj, fingerprint) {
  const estimates = [];
  for (let i = 0; i < trackObj.track.length; i++) {
    const p = trackObj.track[i];
    const match = matchWindow(trackObj.track, i, fingerprint);
    const confidence = match ? clamp01((match.r - 0.25) / 0.55) : 0;
    const blend = MAGNETIC_BLEND * confidence;
    const fused = match ? clamp01(p.pdr * (1 - blend) + match.progress * blend) : p.pdr;
    estimates.push({ ...p, magnetic: match?.progress ?? p.pdr, fused, confidence, r: match?.r ?? 0 });
  }
  return estimates;
}

function mae(rows, key) {
  return rows.reduce((sum, r) => sum + Math.abs(r[key] - r.truth), 0) / rows.length;
}

function svgReplay(rows, width = 680, height = 180) {
  const pad = 10;
  const colors = { truth: '#111827', pdr: '#2563eb', fused: '#dc2626' };
  const line = (key) => rows.map((r, i) => {
    const x = pad + ((width - 2 * pad) * i) / (rows.length - 1);
    const y = height - pad - ((height - 2 * pad) * r[key]);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  return `<div style="font-size:12px;margin-bottom:4px">
    <span style="color:${colors.truth};margin-right:12px">&#9644; anchor-normalized truth</span>
    <span style="color:${colors.pdr};margin-right:12px">&#9644; PDR prior</span>
    <span style="color:${colors.fused}">&#9644; PDR + magnetic</span>
  </div>
  <svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" style="background:#fafafa;border:1px solid #e5e7eb">
    <polyline fill="none" stroke="${colors.truth}" stroke-width="1.2" points="${line('truth')}"/>
    <polyline fill="none" stroke="${colors.pdr}" stroke-width="1.2" points="${line('pdr')}"/>
    <polyline fill="none" stroke="${colors.fused}" stroke-width="1.7" points="${line('fused')}"/>
  </svg>
  <div style="font-size:11px;color:#6b7280">y: route progress Start=0 to End=1 &middot; x: replay time</div>`;
}

function main() {
  const { files, out } = parseArgs(process.argv.slice(2));
  if (files.length < 3) {
    console.error('Need at least 3 sessions so each replay can train on the other passes.');
    process.exit(1);
  }

  const sessions = files.map(parseSession);
  const segmentIndexes = [...new Set(sessions.flatMap((s) => s.anchors.map((a) => a.index)))]
    .filter((i) => sessions.some((s) => segmentFor(s, i)))
    .sort((a, b) => a - b);

  console.log('Segment'.padEnd(30) + 'Session'.padEnd(46) + 'Samples'.padEnd(9) + 'Steps'.padEnd(7) + 'PDR MAE'.padEnd(10) + 'Fused MAE'.padEnd(11) + 'Avg conf');
  console.log('-'.repeat(124));

  const rows = [];
  const sections = [];
  for (const segmentIndex of segmentIndexes) {
    const tracks = sessions.map((s) => buildTrack(s, segmentIndex)).filter(Boolean);
    if (tracks.length < 3) continue;
    const { from, to } = { from: tracks[0].seg.start.name, to: tracks[0].seg.end.name };
    const segmentLabel = `${segmentIndex}: ${from} -> ${to}`;
    const segmentSections = [];

    for (let i = 0; i < tracks.length; i++) {
      const train = tracks.filter((_, j) => j !== i);
      const fingerprint = buildFingerprint(train);
      const estimates = replay(tracks[i], fingerprint);
      const pdrMae = mae(estimates, 'pdr');
      const fusedMae = mae(estimates, 'fused');
      const avgConf = estimates.reduce((sum, r) => sum + r.confidence, 0) / estimates.length;
      rows.push({ segmentLabel, file: tracks[i].session.file, samples: estimates.length, steps: tracks[i].steps.length, pdrMae, fusedMae, avgConf });
      console.log(
        segmentLabel.slice(0, 28).padEnd(30) +
        tracks[i].session.file.padEnd(46) +
        String(estimates.length).padEnd(9) +
        String(tracks[i].steps.length).padEnd(7) +
        pdrMae.toFixed(3).padEnd(10) +
        fusedMae.toFixed(3).padEnd(11) +
        avgConf.toFixed(2)
      );
      segmentSections.push(`<h4>${tracks[i].session.file}</h4><p>PDR MAE ${(pdrMae * 100).toFixed(1)}% segment &middot; fused MAE ${(fusedMae * 100).toFixed(1)}% segment &middot; detected steps ${tracks[i].steps.length}</p>${svgReplay(estimates)}`);
    }

    sections.push(`<h2>Segment ${segmentLabel}</h2>${segmentSections.join('\n')}`);
  }

  if (rows.length === 0) throw new Error('Need at least 3 sessions with matching anchor-to-anchor segments plus device-motion samples.');

  const avg = (key) => rows.reduce((sum, r) => sum + r[key], 0) / rows.length;
  console.log('-'.repeat(124));
  console.log(`Average PDR MAE: ${(avg('pdrMae') * 100).toFixed(1)}% of segment`);
  console.log(`Average fused MAE: ${(avg('fusedMae') * 100).toFixed(1)}% of segment`);
  console.log('Note: scoring is per anchor-to-anchor segment. Anchors validate segment boundaries; within-segment error uses normalized replay time as a proxy.');

  const html = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>PDR + magnetic replay report</title>
<style>body{font-family:-apple-system,sans-serif;max-width:760px;margin:24px auto;padding:0 16px}h2{margin-top:32px}h4{margin-top:22px}code{background:#f3f4f6;padding:2px 4px;border-radius:4px}</style>
</head><body>
<h1>PDR + magnetic replay report</h1>
<p>${sessions.length} sessions &middot; ${segmentIndexes.length} candidate segments &middot; leave-one-session-out fingerprint matching.</p>
<p><strong>Important:</strong> scoring is per anchor-to-anchor segment. Anchors validate segment boundaries; within-segment error uses normalized replay time as a proxy.</p>
${sections.join('\n')}
</body></html>`;
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, html);
  console.log(`\nHTML report: ${out}`);
}

main();
