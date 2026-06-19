#!/usr/bin/env node
/**
 * Build 2D heatmap cells from AR-aligned 2D survey sessions.
 *
 * Usage:
 *   node analysis/build-2d-heatmap.js venue-map.json session1.jsonl [...] --out venue-map-with-heatmap.json
 */

'use strict';

const fs = require('fs');
const path = require('path');

const DEFAULT_CELL_SIZE_M = 0.5;
const DEFAULT_PASS_SEPARATION_S = 8;

function usage(exitCode = 1) {
  const msg = [
    'Usage: node analysis/build-2d-heatmap.js <venue-map.json> <2d-survey.jsonl...> --out <venue-map-with-heatmap.json> [--cell-size 0.5]',
    '',
    'Reads schema-1 venue-map JSON and sample2d JSONL sessions, then writes the same map package with heatmapCells.',
  ].join('\n');
  if (exitCode === 0) console.log(msg);
  else console.error(msg);
  process.exit(exitCode);
}

function parseArgs(argv) {
  let out = null;
  let cellSize = DEFAULT_CELL_SIZE_M;
  const files = [];
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--help' || arg === '-h') usage(0);
    else if (arg === '--out') {
      if (i + 1 >= argv.length) throw new Error('--out requires a path');
      out = argv[++i];
    } else if (arg === '--cell-size') {
      if (i + 1 >= argv.length) throw new Error('--cell-size requires a number');
      cellSize = Number(argv[++i]);
      if (!Number.isFinite(cellSize) || cellSize <= 0) throw new Error('--cell-size must be positive');
    } else if (arg.startsWith('--')) {
      throw new Error(`Unknown option: ${arg}`);
    } else {
      files.push(arg);
    }
  }
  if (files.length < 2 || !out) usage(1);
  return { mapPath: files[0], sessionPaths: files.slice(1), out, cellSize };
}

function readMapPackage(filePath) {
  const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  if (parsed.schema !== 1 || !parsed.map) throw new Error(`${filePath}: expected schema-1 venue map package`);
  return parsed;
}

function readSamples(filePath) {
  const lines = fs.readFileSync(filePath, 'utf8').split('\n');
  const samples = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj.type !== 'sample2d' || !obj.map || !obj.mag) continue;
    const sample = {
      source: path.basename(filePath),
      t: Number(obj.t),
      x: Number(obj.map.x),
      y: Number(obj.map.y),
      magnitudeUT: Number(obj.mag.magnitudeUT),
      verticalUT: Number(obj.mag.verticalUT),
      roomId: obj.roomId ? String(obj.roomId) : null,
    };
    if ([sample.t, sample.x, sample.y, sample.magnitudeUT, sample.verticalUT].every(Number.isFinite)) {
      samples.push(sample);
    }
  }
  return samples;
}

function pointInPolygon(point, polygon) {
  if (!Array.isArray(polygon) || polygon.length < 3) return false;
  let inside = false;
  let j = polygon.length - 1;
  for (let i = 0; i < polygon.length; i++) {
    const pi = polygon[i];
    const pj = polygon[j];
    const dy = pj.y - pi.y;
    if (Math.abs(dy) > 1e-9 &&
        ((pi.y > point.y) !== (pj.y > point.y)) &&
        (point.x < ((pj.x - pi.x) * (point.y - pi.y)) / dy + pi.x)) {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}

function isWalkable(map, sample) {
  if (Array.isArray(map.rooms) && map.rooms.some((room) => pointInPolygon(sample, room.polygon))) {
    return true;
  }
  if (!Array.isArray(map.walkablePolygons) || map.walkablePolygons.length === 0) {
    return sample.x >= 0 && sample.y >= 0 && sample.x <= map.widthMeters && sample.y <= map.heightMeters;
  }
  return map.walkablePolygons.some((polygon) => pointInPolygon({ x: sample.x, y: sample.y }, polygon));
}

function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = values.slice().sort((a, b) => a - b);
  const idx = Math.min(sorted.length - 1, Math.max(0, Math.round((sorted.length - 1) * p)));
  return sorted[idx];
}

function mean(values) {
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function stddev(values) {
  if (values.length < 2) return 0;
  const m = mean(values);
  const variance = values.reduce((sum, value) => sum + (value - m) ** 2, 0) / (values.length - 1);
  return Math.sqrt(Math.max(0, variance));
}

function round(value, digits = 4) {
  if (!Number.isFinite(value)) return 0;
  const m = 10 ** digits;
  return Math.round(value * m) / m;
}

function buildCells(map, samples, cellSize) {
  const buckets = new Map();
  for (const sample of samples) {
    if (!isWalkable(map, sample)) continue;
    const ix = Math.floor(sample.x / cellSize);
    const iy = Math.floor(sample.y / cellSize);
    const key = `${ix},${iy}`;
    if (!buckets.has(key)) buckets.set(key, { ix, iy, samples: [] });
    buckets.get(key).samples.push(sample);
  }

  const cells = [];
  for (const bucket of buckets.values()) {
    const sorted = bucket.samples.slice().sort((a, b) => a.t - b.t);
    const sources = new Set(sorted.map((s) => s.source));
    const deltas = [];
    for (let i = 1; i < sorted.length; i++) {
      if (sorted[i].source !== sorted[i - 1].source) continue;
      const dm = sorted[i].magnitudeUT - sorted[i - 1].magnitudeUT;
      const dv = sorted[i].verticalUT - sorted[i - 1].verticalUT;
      deltas.push(Math.hypot(dm, dv));
    }
    const magnitudes = sorted.map((s) => s.magnitudeUT);
    const verticals = sorted.map((s) => s.verticalUT);
    cells.push({
      center: {
        x: round((bucket.ix + 0.5) * cellSize, 3),
        y: round((bucket.iy + 0.5) * cellSize, 3),
      },
      cellSizeMeters: cellSize,
      sampleCount: sorted.length,
      passCount: sources.size,
      magneticChangeUT: round(percentile(deltas, 0.75), 4),
      meanMagnitudeUT: round(mean(magnitudes), 4),
      stddevMagnitudeUT: round(stddev(magnitudes), 4),
      meanVerticalUT: round(mean(verticals), 4),
      stddevVerticalUT: round(stddev(verticals), 4),
    });
  }
  cells.sort((a, b) => a.center.y === b.center.y ? a.center.x - b.center.x : a.center.y - b.center.y);
  return cells;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const pkg = readMapPackage(args.mapPath);
  const samples = args.sessionPaths.flatMap(readSamples);
  if (!samples.length) throw new Error('No sample2d lines found in input sessions');
  pkg.heatmapCells = buildCells(pkg.map, samples, args.cellSize);
  fs.mkdirSync(path.dirname(args.out), { recursive: true });
  fs.writeFileSync(args.out, `${JSON.stringify(pkg, null, 2)}\n`);
  console.log(`${args.out}: ${pkg.heatmapCells.length} cells from ${samples.length} samples`);
}

if (require.main === module) {
  try { main(); } catch (error) { console.error(error.message); process.exit(1); }
}
