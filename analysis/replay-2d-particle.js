#!/usr/bin/env node
/**
 * Offline scaffold for 2D particle-filter replay against sample2d survey sessions.
 *
 * This uses held-out mapPoint samples as truth to derive pseudo-step events. It is
 * not a production runtime simulator yet; it exists to validate map geometry,
 * heatmap usefulness, and confidence/error reporting before live-device tuning.
 *
 * Usage:
 *   node analysis/replay-2d-particle.js venue-map-with-heatmap.json heldout-2d-survey.jsonl
 */

'use strict';

const fs = require('fs');

const PARAMS = {
  particles: 1200,
  initialRadiusM: 1.8,
  stepLengthM: 0.74,
  stepSigmaM: 0.22,
  headingSigmaRad: 12 * Math.PI / 180,
  magneticSigmaUT: 3.0,
  outsidePenalty: 0.0001,
  wallPenalty: 0.001,
  resampleNeffFraction: 0.5,
  pseudoStepMeters: 0.70,
};

function usage() {
  console.error('Usage: node analysis/replay-2d-particle.js <venue-map-with-heatmap.json> <2d-survey.jsonl>');
  process.exit(1);
}

function readPackage(file) {
  const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (pkg.schema !== 1 || !pkg.map || !Array.isArray(pkg.heatmapCells)) throw new Error(`${file}: expected schema-1 map package with heatmapCells`);
  return pkg;
}

function readSamples(file) {
  return fs.readFileSync(file, 'utf8').split('\n').flatMap((line) => {
    if (!line.trim()) return [];
    let obj;
    try { obj = JSON.parse(line); } catch { return []; }
    if (obj.type !== 'sample2d' || !obj.map || !obj.mag) return [];
    const sample = {
      t: Number(obj.t), x: Number(obj.map.x), y: Number(obj.map.y),
      mag: Number(obj.mag.magnitudeUT), bv: Number(obj.mag.verticalUT), roomId: obj.roomId || null,
    };
    return [sample].filter((s) => [s.t, s.x, s.y, s.mag, s.bv].every(Number.isFinite));
  }).sort((a, b) => a.t - b.t);
}

function mulberry32(seed) {
  let a = seed >>> 0;
  return function rand() {
    a += 0x6D2B79F5;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function normal(rand, mean, sigma) {
  const u1 = Math.max(rand(), 1e-12), u2 = rand();
  return mean + sigma * Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

function pointInPolygon(p, poly) {
  if (!poly || poly.length < 3) return false;
  let inside = false, j = poly.length - 1;
  for (let i = 0; i < poly.length; i++) {
    const pi = poly[i], pj = poly[j];
    if (((pi.y > p.y) !== (pj.y > p.y)) && p.x < ((pj.x - pi.x) * (p.y - pi.y)) / Math.max(pj.y - pi.y, 1e-9) + pi.x) inside = !inside;
    j = i;
  }
  return inside;
}

function isWalkable(map, p) {
  if (!map.walkablePolygons || map.walkablePolygons.length === 0) return p.x >= 0 && p.y >= 0 && p.x <= map.widthMeters && p.y <= map.heightMeters;
  return map.walkablePolygons.some((poly) => pointInPolygon(p, poly));
}

function orient(a, b, c) { return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); }
function segmentsIntersect(a, b, c, d) { return orient(a, b, c) * orient(a, b, d) < 0 && orient(c, d, a) * orient(c, d, b) < 0; }
function crossesWall(map, a, b) {
  for (const wall of map.walls || []) {
    for (let i = 1; i < wall.points.length; i++) if (segmentsIntersect(a, b, wall.points[i - 1], wall.points[i])) return true;
  }
  return false;
}

function nearestCell(cells, p) {
  let best = null, bestD = Infinity;
  for (const cell of cells) {
    const dx = cell.center.x - p.x, dy = cell.center.y - p.y, d = dx * dx + dy * dy;
    if (d < bestD) { best = cell; bestD = d; }
  }
  return best;
}

class Filter {
  constructor(map, cells, start) {
    this.map = map; this.cells = cells; this.rand = mulberry32(0x5eed); this.particles = [];
    for (let i = 0; i < PARAMS.particles; i++) {
      const r = PARAMS.initialRadiusM * Math.sqrt(this.rand()), th = 2 * Math.PI * this.rand();
      this.particles.push({ x: start.x + r * Math.cos(th), y: start.y + r * Math.sin(th), h: 2 * Math.PI * this.rand(), w: 1 / PARAMS.particles });
    }
    this.normalize();
  }
  predict(headingDelta) {
    for (const p of this.particles) {
      const old = { x: p.x, y: p.y };
      p.h += headingDelta + normal(this.rand, 0, PARAMS.headingSigmaRad);
      const step = Math.max(0.2, normal(this.rand, PARAMS.stepLengthM, PARAMS.stepSigmaM));
      p.x += step * Math.cos(p.h); p.y += step * Math.sin(p.h);
      if (!isWalkable(this.map, p)) p.w *= PARAMS.outsidePenalty;
      if (crossesWall(this.map, old, p)) p.w *= PARAMS.wallPenalty;
    }
    this.normalize(); if (this.neff() < this.particles.length * PARAMS.resampleNeffFraction) this.resample();
  }
  observe(change) {
    const v = PARAMS.magneticSigmaUT ** 2;
    for (const p of this.particles) {
      const expected = nearestCell(this.cells, p)?.magneticChangeUT || 0;
      const r = change - expected;
      p.w *= Math.exp(-0.5 * r * r / v);
    }
    this.normalize(); if (this.neff() < this.particles.length * PARAMS.resampleNeffFraction) this.resample();
  }
  normalize() {
    const s = this.particles.reduce((a, p) => a + p.w, 0);
    if (!(s > 0)) { for (const p of this.particles) p.w = 1 / this.particles.length; return; }
    for (const p of this.particles) p.w /= s;
  }
  neff() { const ss = this.particles.reduce((a, p) => a + p.w * p.w, 0); return ss > 0 ? 1 / ss : 0; }
  resample() {
    const c = []; let acc = 0; for (const p of this.particles) { acc += p.w; c.push(acc); }
    const next = []; const step = 1 / this.particles.length; let u = this.rand() * step; let j = 0;
    for (let i = 0; i < this.particles.length; i++, u += step) { while (j < c.length - 1 && c[j] < u) j++; next.push({ ...this.particles[j], w: step }); }
    this.particles = next;
  }
  estimate() {
    let x = 0, y = 0; for (const p of this.particles) { x += p.x * p.w; y += p.y * p.w; }
    let v = 0; for (const p of this.particles) v += p.w * ((p.x - x) ** 2 + (p.y - y) ** 2);
    return { x, y, radius: Math.sqrt(v), neff: this.neff() };
  }
}

function percentile(values, p) {
  if (!values.length) return NaN;
  const s = values.slice().sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.max(0, Math.round((s.length - 1) * p)))];
}

function main() {
  const [mapFile, sessionFile] = process.argv.slice(2);
  if (!mapFile || !sessionFile) usage();
  const pkg = readPackage(mapFile), samples = readSamples(sessionFile);
  if (samples.length < 2) throw new Error('Need at least 2 sample2d samples');
  if (!pkg.heatmapCells.length) throw new Error('Map package has no heatmapCells; run build-2d-heatmap first');
  const filter = new Filter(pkg.map, pkg.heatmapCells, { x: samples[0].x, y: samples[0].y });
  const errors = [];
  let lastStep = samples[0], lastHeading = 0, lastFeature = samples[0];
  for (const s of samples.slice(1)) {
    const dx = s.x - lastStep.x, dy = s.y - lastStep.y;
    if (Math.hypot(dx, dy) < PARAMS.pseudoStepMeters) continue;
    const heading = Math.atan2(dy, dx);
    let dh = heading - lastHeading;
    while (dh > Math.PI) dh -= 2 * Math.PI;
    while (dh < -Math.PI) dh += 2 * Math.PI;
    filter.predict(dh);
    const change = Math.hypot(s.mag - lastFeature.mag, s.bv - lastFeature.bv);
    filter.observe(change);
    const e = filter.estimate();
    errors.push(Math.hypot(e.x - s.x, e.y - s.y));
    lastStep = s; lastHeading = heading; lastFeature = s;
  }
  console.log(`Replay steps: ${errors.length}`);
  console.log(`P50 ${percentile(errors, 0.5).toFixed(2)} m · P75 ${percentile(errors, 0.75).toFixed(2)} m · P90 ${percentile(errors, 0.9).toFixed(2)} m`);
}

if (require.main === module) {
  try { main(); } catch (error) { console.error(error.message); process.exit(1); }
}
