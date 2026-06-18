#!/usr/bin/env node
/**
 * ARKit ground-truth extraction for SurveyRecorder JSONL sessions.
 *
 * When a session was recorded with the surveyor "ground truth" toggle on, it
 * contains `arpose` lines: 6-DoF camera poses from ARKit world tracking (metric,
 * gravity-aligned). This module turns that trajectory into TRUE position-along-route:
 *
 *   - cumulative horizontal arc length over the AR path (meters)
 *   - per-segment true length (meters) between recorded anchors
 *   - true fractional progress at any timestamp (replaces the time-linear assumption)
 *
 * ARFrame.timestamp, CMDeviceMotion.timestamp and ProcessInfo.systemUptime all share
 * the system-uptime clock, so AR poses align with the sensor/anchor streams directly.
 *
 * Used as a library by match-route.js, and runnable standalone to inspect AR quality:
 *   node analysis/ground-truth.js <session.jsonl> [--out report.html]
 */

'use strict';

const fs = require('fs');
const path = require('path');

/** Parse arpose (and meta/anchor) lines from a session file. */
function parseARPoses(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  const poses = [];
  const anchors = [];
  let meta = null;

  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      continue;
    }
    if (obj.type === 'meta') {
      meta = obj;
    } else if (obj.type === 'arpose' && obj.p) {
      const t = Number(obj.t);
      const x = Number(obj.p.x);
      const y = Number(obj.p.y);
      const z = Number(obj.p.z);
      if ([t, x, y, z].every(Number.isFinite)) {
        poses.push({ t, x, y, z, tracking: String(obj.track || '') });
      }
    } else if (obj.type === 'anchor' && Number.isFinite(Number(obj.t))) {
      anchors.push({ t: Number(obj.t), index: obj.index, name: String(obj.name ?? obj.index ?? '') });
    }
  }

  poses.sort((a, b) => a.t - b.t);
  anchors.sort((a, b) => a.t - b.t);
  return { meta, poses, anchors };
}

/**
 * Cumulative arc length over the AR trajectory. Horizontal (x,z) by default since
 * routes are single-floor and vertical handheld bob is noise; pass use3d for full 3D.
 */
function buildArcLength(poses, { use3d = false } = {}) {
  const cum = new Array(poses.length).fill(0);
  for (let i = 1; i < poses.length; i++) {
    const dx = poses[i].x - poses[i - 1].x;
    const dy = poses[i].y - poses[i - 1].y;
    const dz = poses[i].z - poses[i - 1].z;
    cum[i] = cum[i - 1] + (use3d ? Math.hypot(dx, dy, dz) : Math.hypot(dx, dz));
  }
  const normalCount = poses.filter((p) => p.tracking === 'normal').length;

  function lengthAt(t) {
    if (poses.length === 0) return 0;
    if (t <= poses[0].t) return cum[0];
    if (t >= poses[poses.length - 1].t) return cum[cum.length - 1];
    let lo = 0;
    let hi = poses.length - 1;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (poses[mid].t <= t) lo = mid;
      else hi = mid;
    }
    const span = poses[hi].t - poses[lo].t;
    const frac = span > 0 ? (t - poses[lo].t) / span : 0;
    return cum[lo] + (cum[hi] - cum[lo]) * frac;
  }

  return {
    poses,
    cum,
    lengthAt,
    totalMeters: cum.length ? cum[cum.length - 1] : 0,
    trackingQuality: poses.length ? normalCount / poses.length : 0,
  };
}

/**
 * Ground truth for one [startT, endT] segment: true length in meters and a
 * progressAt(t) ∈ [0,1] based on real distance travelled, not elapsed time.
 * Returns null when there is no usable AR coverage for the segment.
 */
function segmentGroundTruth(arc, startT, endT) {
  if (!arc || arc.poses.length < 2) return null;
  const startLen = arc.lengthAt(startT);
  const endLen = arc.lengthAt(endT);
  const lengthMeters = endLen - startLen;
  const within = arc.poses.filter((p) => p.t >= startT && p.t <= endT);
  const normal = within.filter((p) => p.tracking === 'normal').length;
  if (lengthMeters <= 0 || within.length < 2) return null;

  return {
    lengthMeters,
    poseCount: within.length,
    trackingQuality: within.length ? normal / within.length : 0,
    progressAt(t) {
      return Math.min(1, Math.max(0, (arc.lengthAt(t) - startLen) / lengthMeters));
    },
  };
}

// ---- Standalone CLI: inspect AR quality for one session --------------------

function trackingColor(tracking) {
  if (tracking === 'normal') return '#16a34a';
  if (tracking.startsWith('limited')) return '#d97706';
  return '#dc2626';
}

function topDownSvg(poses, anchors, width = 520, height = 420) {
  if (poses.length < 2) return '<p>No AR poses.</p>';
  const xs = poses.map((p) => p.x);
  const zs = poses.map((p) => p.z);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minZ = Math.min(...zs);
  const maxZ = Math.max(...zs);
  const pad = 24;
  const spanX = maxX - minX || 1;
  const spanZ = maxZ - minZ || 1;
  const scale = Math.min((width - 2 * pad) / spanX, (height - 2 * pad) / spanZ);
  const px = (x) => pad + (x - minX) * scale;
  const py = (z) => height - pad - (z - minZ) * scale;

  const dots = poses
    .map((p) => `<circle cx="${px(p.x).toFixed(1)}" cy="${py(p.z).toFixed(1)}" r="1.3" fill="${trackingColor(p.tracking)}"/>`)
    .join('');

  const anchorMarks = anchors
    .map((a) => {
      // nearest pose in time to place the anchor marker
      let best = poses[0];
      let bestDt = Infinity;
      for (const p of poses) {
        const dt = Math.abs(p.t - a.t);
        if (dt < bestDt) {
          bestDt = dt;
          best = p;
        }
      }
      return `<g>
        <circle cx="${px(best.x).toFixed(1)}" cy="${py(best.z).toFixed(1)}" r="5" fill="none" stroke="#111827" stroke-width="2"/>
        <text x="${(px(best.x) + 7).toFixed(1)}" y="${(py(best.z) + 3).toFixed(1)}" font-size="11">${escapeHtml(a.name)}</text>
      </g>`;
    })
    .join('');

  return `<svg viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" style="background:#fafafa;border:1px solid #e5e7eb">
    ${dots}${anchorMarks}
  </svg>
  <div style="font-size:11px;color:#6b7280">Top-down AR path (x horizontal, z depth, meters). Green=normal · amber=limited · red=notAvailable tracking. Circles = checkpoint anchors.</div>`;
}

function escapeHtml(v) {
  return String(v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function runCli(argv) {
  let out = null;
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--out') out = argv[++i];
    else if (argv[i] === '--3d') positional.use3d = true;
    else positional.push(argv[i]);
  }
  if (positional.length !== 1) {
    console.error('Usage: node analysis/ground-truth.js <session.jsonl> [--out report.html]');
    process.exit(1);
  }

  const { meta, poses, anchors } = parseARPoses(positional[0]);
  if (poses.length === 0) {
    console.error(`${path.basename(positional[0])}: no arpose lines — recorded without ground truth?`);
    process.exit(2);
  }
  const arc = buildArcLength(poses);

  console.log(`Session: ${path.basename(positional[0])}`);
  console.log(`AR poses: ${poses.length} · total path ${arc.totalMeters.toFixed(2)} m · tracking-normal ${(arc.trackingQuality * 100).toFixed(0)}%`);
  console.log('');
  console.log('Segment'.padEnd(34) + 'Length m'.padEnd(10) + 'Poses'.padEnd(7) + 'Tracking');
  console.log('-'.repeat(70));

  for (let i = 0; i < anchors.length - 1; i++) {
    const a = anchors[i];
    const b = anchors[i + 1];
    const gt = segmentGroundTruth(arc, a.t, b.t);
    const label = `${a.name} -> ${b.name}`.slice(0, 32);
    if (!gt) {
      console.log(label.padEnd(34) + '--'.padEnd(10) + '--'.padEnd(7) + 'no AR coverage');
    } else {
      console.log(
        label.padEnd(34) +
        gt.lengthMeters.toFixed(2).padEnd(10) +
        String(gt.poseCount).padEnd(7) +
        `${(gt.trackingQuality * 100).toFixed(0)}% normal`
      );
    }
  }

  if (out) {
    const segRows = [];
    for (let i = 0; i < anchors.length - 1; i++) {
      const gt = segmentGroundTruth(arc, anchors[i].t, anchors[i + 1].t);
      segRows.push(`<tr><td>${escapeHtml(anchors[i].name)} &rarr; ${escapeHtml(anchors[i + 1].name)}</td>
        <td>${gt ? gt.lengthMeters.toFixed(2) : '--'}</td>
        <td>${gt ? gt.poseCount : '--'}</td>
        <td>${gt ? (gt.trackingQuality * 100).toFixed(0) + '%' : 'no coverage'}</td></tr>`);
    }
    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><title>AR ground truth</title>
<style>body{font-family:-apple-system,sans-serif;max-width:720px;margin:24px auto;padding:0 16px}table{border-collapse:collapse}td,th{border:1px solid #e5e7eb;padding:6px 10px;font-size:13px}</style>
</head><body>
<h1>AR ground truth: ${escapeHtml(meta ? `${meta.venueId} / ${meta.routeId}` : path.basename(positional[0]))}</h1>
<p>${poses.length} AR poses · total path ${arc.totalMeters.toFixed(2)} m · ${(arc.trackingQuality * 100).toFixed(0)}% normal tracking</p>
${topDownSvg(poses, anchors)}
<h2>Segments</h2>
<table><thead><tr><th>Segment</th><th>Length (m)</th><th>Poses</th><th>Tracking</th></tr></thead><tbody>
${segRows.join('\n')}
</tbody></table>
</body></html>`;
    fs.mkdirSync(path.dirname(out), { recursive: true });
    fs.writeFileSync(out, html);
    console.log(`\nHTML report: ${out}`);
  }
}

module.exports = { parseARPoses, buildArcLength, segmentGroundTruth };

if (require.main === module) {
  runCli(process.argv.slice(2));
}
