#!/usr/bin/env node
/**
 * Extract a 2D floor-plane path aligned to a profile's BIN GRID, for the
 * dev/debug map view. The runtime estimate is 1-D arc-length (a bin index), so
 * the map shows a marker constrained to this surveyed path: path[bin] is the
 * (x,z) for that bin. NOT a free 2D position — there is no lateral estimate.
 *
 * For each profile segment we slice the survey's ARKit poses between the
 * segment's from/to anchors, take the floor-plane (x,z) polyline, and resample
 * it by arc-length to exactly `binCount` points so path[globalBin] lines up with
 * RouteBeliefFilter / grid-filter bins. Concatenated over segments -> path[bins].
 *
 * Usage: node analysis/extract-path.js <profile.json> <survey.jsonl> <out-path.json>
 */
'use strict';
const fs = require('fs');

function resampleByArcLength(pts, n) {
  // pts: [{x,z}], returns n points evenly spaced along the polyline arc-length.
  if (pts.length === 0) return [];
  if (pts.length === 1) return Array.from({ length: n }, () => [pts[0].x, pts[0].z]);
  const cum = [0];
  for (let i = 1; i < pts.length; i++) {
    cum.push(cum[i - 1] + Math.hypot(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z));
  }
  const total = cum[cum.length - 1] || 1;
  const out = [];
  let j = 0;
  for (let k = 0; k < n; k++) {
    const target = (total * k) / Math.max(n - 1, 1);
    while (j < cum.length - 2 && cum[j + 1] < target) j++;
    const span = cum[j + 1] - cum[j];
    const f = span > 1e-9 ? (target - cum[j]) / span : 0;
    out.push([
      pts[j].x + (pts[j + 1].x - pts[j].x) * f,
      pts[j].z + (pts[j + 1].z - pts[j].z) * f,
    ]);
  }
  return out;
}

function main() {
  const [profPath, sessPath, outPath] = process.argv.slice(2);
  if (!profPath || !sessPath || !outPath) {
    console.error('usage: node analysis/extract-path.js <profile.json> <survey.jsonl> <out-path.json>');
    process.exit(1);
  }
  const profile = JSON.parse(fs.readFileSync(profPath, 'utf8'));
  const lines = fs.readFileSync(sessPath, 'utf8').trim().split('\n')
    .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);

  const anchorTime = new Map(); // name -> t (first occurrence)
  for (const o of lines) if (o.type === 'anchor' && !anchorTime.has(o.name)) anchorTime.set(o.name, Number(o.t));
  const poses = lines.filter((o) => o.type === 'arpose' && o.p && o.track === 'normal')
    .map((o) => ({ t: Number(o.t), x: Number(o.p.x), z: Number(o.p.z) }))
    .sort((a, b) => a.t - b.t);
  if (poses.length < 2) throw new Error('no usable ARKit poses (need ground-truth survey)');

  const path = [];
  const checkpoints = [];
  for (const seg of profile.segments) {
    const n = seg.magneticMagnitude && seg.magneticMagnitude.mean ? seg.magneticMagnitude.mean.length : 0;
    if (!n) throw new Error(`segment ${seg.index} has no magnetic mean`);
    const tFrom = anchorTime.get(seg.from);
    const tTo = anchorTime.get(seg.to);
    if (tFrom === undefined || tTo === undefined) throw new Error(`anchors ${seg.from}/${seg.to} not in survey`);
    const segPoses = poses.filter((p) => p.t >= tFrom && p.t <= tTo);
    const startBin = path.length;
    const resampled = resampleByArcLength(segPoses.length >= 2 ? segPoses : poses, n);
    for (const xz of resampled) path.push(xz);
    checkpoints.push({ name: seg.to, bin: path.length - 1, x: path[path.length - 1][0], z: path[path.length - 1][1] });
  }
  // start checkpoint (bin 0)
  checkpoints.unshift({ name: profile.segments[0].from, bin: 0, x: path[0][0], z: path[0][1] });

  const xs = path.map((p) => p[0]);
  const zs = path.map((p) => p[1]);
  const out = {
    generated: 'analysis/extract-path.js',
    profileFile: profPath.split('/').pop(),
    sessionFile: sessPath.split('/').pop(),
    bins: path.length,
    bounds: { minX: Math.min(...xs), maxX: Math.max(...xs), minZ: Math.min(...zs), maxZ: Math.max(...zs) },
    path: path.map(([x, z]) => [Math.round(x * 1000) / 1000, Math.round(z * 1000) / 1000]),
    checkpoints,
  };
  fs.writeFileSync(outPath, JSON.stringify(out));
  const w = (out.bounds.maxX - out.bounds.minX).toFixed(1);
  const h = (out.bounds.maxZ - out.bounds.minZ).toFixed(1);
  console.log(`${outPath}: ${out.bins} bins, ${w}x${h}m, ${checkpoints.length} checkpoints (${checkpoints.map((c) => c.name).join(' -> ')})`);
}
main();
