#!/usr/bin/env node
/**
 * Magnetic repeatability analysis for survey sessions (feasibility spike).
 *
 * Compares the magnetic magnitude traces of repeated walks of the same route
 * and reports, per anchor-to-anchor segment, how well the passes agree
 * (Pearson correlation + DTW mean deviation). High agreement across passes is
 * the go signal for magnetic fingerprinting in that venue.
 *
 * Usage:
 *   node analysis/analyze-repeatability.js session1.jsonl session2.jsonl [...] [--out report.html]
 *
 * Sessions should be repeated walks of the same route in the same direction.
 * Input files come from the SurveyRecorder iOS app (one JSON object per line).
 */

'use strict';

const fs = require('fs');
const path = require('path');

const RESAMPLE_POINTS = 200;
const DTW_BAND_FRACTION = 0.1;

function parseArgs(argv) {
  const files = [];
  let out = 'analysis/report.html';
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out') {
      out = argv[++i];
    } else {
      files.push(argv[i]);
    }
  }
  return { files, out };
}

function parseSession(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  let meta = null;
  const dm = [];
  const rawMag = [];
  const anchors = [];

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue; // tolerate a truncated final line from a crashed session
    }
    switch (obj.type) {
      case 'meta':
        meta = obj;
        break;
      case 'dm':
        if (obj.mag) {
          dm.push({
            t: obj.t,
            v: Math.hypot(obj.mag.x, obj.mag.y, obj.mag.z),
            acc: obj.mag.acc,
          });
        }
        break;
      case 'mag':
        rawMag.push({ t: obj.t, v: Math.hypot(obj.x, obj.y, obj.z) });
        break;
      case 'anchor':
        anchors.push({ t: obj.t, index: obj.index, name: obj.name });
        break;
      case 'anchor_undo': {
        // Remove the most recent anchor with the undone index.
        for (let i = anchors.length - 1; i >= 0; i--) {
          if (anchors[i].index === obj.index) {
            anchors.splice(i, 1);
            break;
          }
        }
        break;
      }
    }
  }

  if (!meta) throw new Error(`${filePath}: no meta line found`);
  anchors.sort((a, b) => a.t - b.t);

  // Prefer calibrated device-motion magnitude; fall back to raw magnetometer.
  const trace = dm.length > 0 ? dm : rawMag;
  const calibrated = dm.length > 0;

  return {
    file: path.basename(filePath),
    meta,
    trace,
    anchors,
    calibrated,
  };
}

/** Linear-interpolation resample of {t, v} samples onto n uniform points in [t0, t1]. */
function resample(samples, t0, t1, n) {
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
  if (cost[n][m] === INF) return NaN;
  return cost[n][m] / steps[n][m];
}

function verdict(meanR) {
  if (meanR >= 0.8) return 'STRONG';
  if (meanR >= 0.6) return 'MODERATE';
  return 'WEAK';
}

function buildSegments(session) {
  const segments = new Map(); // segment index -> resampled trace
  const anchorsByIndex = new Map(session.anchors.map((a) => [a.index, a]));
  for (const a of session.anchors) {
    const next = anchorsByIndex.get(a.index + 1);
    if (!next || next.t <= a.t) continue;
    const trace = resample(session.trace, a.t, next.t, RESAMPLE_POINTS);
    if (trace) {
      segments.set(a.index, { trace, from: a.name, to: next.name, duration: next.t - a.t });
    }
  }
  return segments;
}

function svgOverlay(traces, labels, width = 640, height = 180) {
  const all = traces.flat();
  const min = Math.min(...all);
  const max = Math.max(...all);
  const range = max - min || 1;
  const colors = ['#2563eb', '#dc2626', '#16a34a', '#9333ea', '#ea580c', '#0891b2', '#be185d'];
  const pad = 6;

  const polylines = traces
    .map((trace, k) => {
      const points = trace
        .map((v, i) => {
          const x = pad + ((width - 2 * pad) * i) / (trace.length - 1);
          const y = height - pad - ((height - 2 * pad) * (v - min)) / range;
          return `${x.toFixed(1)},${y.toFixed(1)}`;
        })
        .join(' ');
      return `<polyline fill="none" stroke="${colors[k % colors.length]}" stroke-width="1.5" points="${points}"/>`;
    })
    .join('\n');

  const legend = labels
    .map(
      (label, k) =>
        `<span style="color:${colors[k % colors.length]};margin-right:12px;font-size:12px">&#9644; ${label}</span>`
    )
    .join('');

  return `
    <div>${legend}</div>
    <svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" style="background:#fafafa;border:1px solid #e5e7eb">
      ${polylines}
    </svg>
    <div style="font-size:11px;color:#6b7280">y: ${min.toFixed(1)}&ndash;${max.toFixed(1)} µT &middot; x: normalized segment progress</div>`;
}

function main() {
  const { files, out } = parseArgs(process.argv.slice(2));
  if (files.length < 2) {
    console.error('Need at least 2 session files of the same route/direction.');
    console.error('Usage: node analysis/analyze-repeatability.js a.jsonl b.jsonl [...] [--out report.html]');
    process.exit(1);
  }

  const sessions = files.map(parseSession);

  const routeKey = (s) => `${s.meta.venueId}/${s.meta.routeId}/${s.meta.direction}`;
  const keys = new Set(sessions.map(routeKey));
  if (keys.size > 1) {
    console.warn(`WARNING: sessions span multiple route/direction combos: ${[...keys].join(', ')}`);
    console.warn('Comparisons only make sense within one combo; results may be meaningless.\n');
  }

  for (const s of sessions) {
    const calNote = s.calibrated ? 'calibrated dm' : 'RAW magnetometer only (no device-motion samples)';
    console.log(`${s.file}: ${s.trace.length} samples, ${s.anchors.length} anchors, ${calNote}`);
  }
  console.log('');

  const perSession = sessions.map((s) => ({ session: s, segments: buildSegments(s) }));
  const allSegmentIndexes = [...new Set(perSession.flatMap((p) => [...p.segments.keys()]))].sort((x, y) => x - y);

  const rows = [];
  const htmlSections = [];

  for (const segIndex of allSegmentIndexes) {
    const present = perSession.filter((p) => p.segments.has(segIndex));
    if (present.length < 2) {
      rows.push({ segIndex, label: '(only in 1 session)', n: present.length, meanR: NaN, meanDtw: NaN });
      continue;
    }

    const traces = present.map((p) => p.segments.get(segIndex).trace);
    const labels = present.map((p) => p.session.file);
    const { from, to } = present[0].segments.get(segIndex);

    let sumR = 0;
    let sumDtw = 0;
    let pairs = 0;
    for (let i = 0; i < traces.length; i++) {
      for (let j = i + 1; j < traces.length; j++) {
        sumR += pearson(traces[i], traces[j]);
        sumDtw += dtwMeanDeviation(traces[i], traces[j]);
        pairs++;
      }
    }
    const meanR = sumR / pairs;
    const meanDtw = sumDtw / pairs;
    rows.push({ segIndex, label: `${from} -> ${to}`, n: present.length, meanR, meanDtw });

    htmlSections.push(`
      <h3>Segment ${segIndex}: ${from} &rarr; ${to}
        <small>(${present.length} passes, r=${meanR.toFixed(3)}, DTW=${meanDtw.toFixed(2)} µT, ${verdict(meanR)})</small>
      </h3>
      ${svgOverlay(traces, labels)}`);
  }

  console.log('Segment'.padEnd(8) + 'Route'.padEnd(36) + 'Passes'.padEnd(8) + 'Mean r'.padEnd(9) + 'DTW µT'.padEnd(9) + 'Verdict');
  console.log('-'.repeat(80));
  for (const r of rows) {
    const rStr = Number.isNaN(r.meanR) ? '-' : r.meanR.toFixed(3);
    const dtwStr = Number.isNaN(r.meanDtw) ? '-' : r.meanDtw.toFixed(2);
    const v = Number.isNaN(r.meanR) ? '-' : verdict(r.meanR);
    console.log(
      String(r.segIndex).padEnd(8) + r.label.slice(0, 34).padEnd(36) + String(r.n).padEnd(8) + rStr.padEnd(9) + dtwStr.padEnd(9) + v
    );
  }

  const comparable = rows.filter((r) => !Number.isNaN(r.meanR));
  if (comparable.length > 0) {
    const overall = comparable.reduce((acc, r) => acc + r.meanR, 0) / comparable.length;
    console.log('-'.repeat(80));
    console.log(`Overall mean r: ${overall.toFixed(3)} (${verdict(overall)})`);
    console.log('Rule of thumb: STRONG (r>=0.8) means magnetic fingerprinting is viable on this route;');
    console.log('MODERATE means viable with PDR+map support; WEAK means this venue/route is hostile.');
  }

  const html = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Magnetic repeatability report</title>
<style>body{font-family:-apple-system,sans-serif;max-width:720px;margin:24px auto;padding:0 16px}h3 small{color:#6b7280;font-weight:normal}</style>
</head>
<body>
<h1>Magnetic repeatability report</h1>
<p>${sessions.length} sessions &middot; route ${[...keys].join(', ')}</p>
${htmlSections.join('\n')}
</body>
</html>`;

  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, html);
  console.log(`\nHTML report: ${out}`);
}

main();
