#!/usr/bin/env node
// Exploratory Phase-3 tool: extract turn events from recorded sessions.
//
// Heading source: rotation rate projected onto the gravity axis (yaw rate about
// vertical), integrated. Pure gyro — immune to the magnetic yaw corrections
// CoreMotion applies indoors, and drift is irrelevant at the 1–3 s scale of a
// turn. The quaternion-derived yaw is computed alongside as a cross-check.
//
// Usage: node analysis/turn-events.js <session.jsonl> [...more sessions]

const fs = require('fs');
const path = require('path');
const { buildArcLength } = require('./ground-truth');

const PARAMS = {
  smoothRadiusS: 0.15,     // box smoothing applied to yaw-rate before detection
  turnRateThresh: 0.35,    // rad/s of vertical-axis rotation that counts as "turning"
  minTurnDeg: 35,          // sustained heading change to qualify as a turn event
  mergeGapS: 0.5,          // contiguous turning regions closer than this merge
};

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
    else if (obj.type === 'dm' && obj.rot && obj.g) {
      const t = Number(obj.t);
      const g = obj.g;
      const gm = Math.hypot(g.x, g.y, g.z) || 1;
      // Signed rotation rate about the vertical axis (gravity points down, so
      // negate to make counter-clockwise-from-above positive).
      const yawRate = -(obj.rot.x * g.x + obj.rot.y * g.y + obj.rot.z * g.z) / gm;
      const q = obj.q;
      const qYaw = q ? Math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z)) : NaN;
      if (Number.isFinite(t) && Number.isFinite(yawRate)) dm.push({ t, yawRate, qYaw });
    } else if (obj.type === 'anchor' && Number.isFinite(Number(obj.t))) {
      anchors.push({ t: Number(obj.t), index: obj.index, name: String(obj.name ?? '') });
    } else if (obj.type === 'anchor_undo') {
      for (let i = anchors.length - 1; i >= 0; i--) {
        if (anchors[i].index === obj.index) { anchors.splice(i, 1); break; }
      }
    } else if (obj.type === 'arpose' && obj.p) {
      const t = Number(obj.t);
      const { x, y, z } = obj.p;
      if ([t, x, y, z].every(Number.isFinite)) arPoses.push({ t, x, y, z, tracking: String(obj.track || '') });
    }
  }
  if (!meta) throw new Error(`${filePath}: no meta line`);
  dm.sort((a, b) => a.t - b.t);
  anchors.sort((a, b) => a.t - b.t);
  arPoses.sort((a, b) => a.t - b.t);
  return { file: path.basename(filePath), meta, dm, anchors, arPoses };
}

function smoothRate(dm, radiusS) {
  const out = new Array(dm.length);
  let lo = 0, hi = 0, sum = 0;
  for (let i = 0; i < dm.length; i++) {
    while (hi < dm.length && dm[hi].t <= dm[i].t + radiusS) { sum += dm[hi].yawRate; hi++; }
    while (dm[lo].t < dm[i].t - radiusS) { sum -= dm[lo].yawRate; lo++; }
    out[i] = sum / (hi - lo);
  }
  return out;
}

/** Contiguous |yawRate| > threshold regions, merged across short gaps, with the
 *  signed heading delta integrated over each region. `t` is the time at which
 *  half of the total rotation had accumulated — slow turning regions can span
 *  seconds, and the half-rotation point localizes the physical corner far
 *  better than the region midpoint. */
function detectTurns(dm) {
  const rate = smoothRate(dm, PARAMS.smoothRadiusS);
  const regions = [];
  let cur = null;
  for (let i = 0; i < dm.length; i++) {
    if (Math.abs(rate[i]) > PARAMS.turnRateThresh) {
      if (cur && dm[i].t - cur.endT > PARAMS.mergeGapS) { regions.push(cur); cur = null; }
      if (!cur) cur = { startT: dm[i].t, endT: dm[i].t, deltaRad: 0, increments: [] };
      const dt = i > 0 ? dm[i].t - dm[i - 1].t : 0;
      cur.deltaRad += rate[i] * dt;
      cur.increments.push({ t: dm[i].t, d: rate[i] * dt });
      cur.endT = dm[i].t;
    } else if (cur && dm[i].t - cur.endT > PARAMS.mergeGapS) {
      regions.push(cur);
      cur = null;
    }
  }
  if (cur) regions.push(cur);
  return regions
    .map((r) => {
      let tHalf = (r.startT + r.endT) / 2;
      let cum = 0;
      for (const inc of r.increments) {
        cum += inc.d;
        if (Math.abs(cum) >= Math.abs(r.deltaRad) / 2) { tHalf = inc.t; break; }
      }
      return { t: tHalf, startT: r.startT, endT: r.endT, deltaDeg: (r.deltaRad * 180) / Math.PI };
    })
    .filter((r) => Math.abs(r.deltaDeg) >= PARAMS.minTurnDeg);
}

function describe(session) {
  const { meta, dm, anchors, arPoses } = session;
  const turns = detectTurns(dm);
  const t0 = anchors.length ? anchors[0].t : dm[0].t;

  let arc = null;
  let arcStart = 0;
  const tracked = arPoses.filter((p) => p.tracking === 'normal');
  if (tracked.length > 50) {
    try {
      arc = buildArcLength(arPoses);
      arcStart = arc.lengthAt(t0);
    } catch { arc = null; }
  }

  console.log(`\n=== ${session.file} (${meta.passType ?? 'unknown'}${arc ? ', ARKit truth' : ''}) ===`);
  if (anchors.length) {
    console.log(`anchors: ${anchors.map((a) => `${a.name}@${(a.t - t0).toFixed(1)}s`).join('  ')}`);
  }
  if (!turns.length) {
    console.log('no turn events');
    return turns;
  }
  for (const turn of turns) {
    // Locate within the anchor intervals (segment + time fraction).
    let where = 'outside anchors';
    for (let i = 0; i + 1 < anchors.length; i++) {
      if (turn.t >= anchors[i].t && turn.t < anchors[i + 1].t) {
        const f = (turn.t - anchors[i].t) / (anchors[i + 1].t - anchors[i].t);
        where = `${anchors[i].name}->${anchors[i + 1].name} @ ${(f * 100).toFixed(0)}%`;
        break;
      }
    }
    if (anchors.length && turn.t < anchors[0].t) where = 'before Start';
    if (anchors.length && turn.t >= anchors[anchors.length - 1].t) where = 'after last anchor';
    const meters = arc ? ` ${(arc.lengthAt(turn.t) - arcStart).toFixed(2)}m` : '';
    console.log(
      `  t+${(turn.t - t0).toFixed(1)}s  ${turn.deltaDeg > 0 ? '+' : ''}${turn.deltaDeg.toFixed(0)}°` +
      ` (${(turn.endT - turn.startT).toFixed(1)}s)  ${where}${meters}`
    );
  }
  return turns;
}

if (require.main === module) {
  const files = process.argv.slice(2);
  if (!files.length) {
    console.error('usage: node analysis/turn-events.js <session.jsonl> [...]');
    process.exit(1);
  }
  for (const f of files) describe(parseSession(f));
}

module.exports = { parseSession, detectTurns, PARAMS };
