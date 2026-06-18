#!/usr/bin/env node
// Pocket-survey preprocessing: remove standing pauses from a recorded session
// and close the time gaps, so build-profile's wall-time resampling sees a
// continuous walk. Why: checkpoint pauses (the pocket surveying protocol —
// the surveyor cannot tap with the phone pocketed) become flat-field bin
// stretches in time-resampled profiles, and under the differenced emission
// flat profile regions match any weakly-varying live window (attractors).
// Anchors inside a removed interval snap to the splice point.
//
// Usage: node analysis/splice-pauses.js <session.jsonl> <out.jsonl> [--th 0.08]

const fs = require('fs');

function main() {
  const [src, dst] = process.argv.slice(2);
  if (!dst) {
    console.error('usage: node analysis/splice-pauses.js <session.jsonl> <out.jsonl> [--th 0.08]');
    process.exit(1);
  }
  const thArg = process.argv.indexOf('--th');
  const TH = thArg > 0 ? parseFloat(process.argv[thArg + 1]) : 0.08;
  const MIN_PAUSE_S = 0.7;

  const lines = fs.readFileSync(src, 'utf8').trim().split('\n');
  const parsed = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } });
  const dm = parsed.filter((o) => o && o.type === 'dm' && o.ua)
    .map((o) => ({ t: o.t, ua: Math.hypot(o.ua.x, o.ua.y, o.ua.z) }));
  if (dm.length < 100) throw new Error('not enough dm samples');

  // 0.5 s centered box smoothing, then sustained sub-threshold intervals.
  let lo = 0;
  const sm = dm.map((s) => {
    while (dm[lo].t < s.t - 0.25) lo++;
    let sum = 0, n = 0;
    for (let j = lo; j < dm.length && dm[j].t <= s.t + 0.25; j++) { sum += dm[j].ua; n++; }
    return { t: s.t, v: sum / n };
  });
  const pauses = [];
  let cur = null;
  for (const s of sm) {
    if (s.v < TH) {
      if (!cur) cur = { a: s.t, b: s.t };
      cur.b = s.t;
    } else if (cur) {
      if (cur.b - cur.a >= MIN_PAUSE_S) pauses.push(cur);
      cur = null;
    }
  }
  if (cur && cur.b - cur.a >= MIN_PAUSE_S) pauses.push(cur);

  // Spliced time: t' = t - (removed time before t); inside a pause -> splice point.
  function splice(t) {
    let removed = 0;
    for (const p of pauses) {
      if (t >= p.b) removed += p.b - p.a;
      else if (t > p.a) return p.a - removed; // inside: collapse to start
      else break;
    }
    return t - removed;
  }
  function insidePause(t) {
    return pauses.some((p) => t > p.a && t < p.b);
  }

  const out = [];
  let dropped = 0;
  for (const [i, o] of parsed.entries()) {
    if (!o) continue;
    if (o.type === 'meta' || !('t' in o)) { out.push(lines[i]); continue; }
    if (o.type === 'anchor') {
      out.push(JSON.stringify({ ...o, t: splice(o.t), spliced: true }));
      continue;
    }
    if (insidePause(o.t)) { dropped++; continue; }
    out.push(JSON.stringify({ ...o, t: splice(o.t) }));
  }
  fs.writeFileSync(dst, out.join('\n') + '\n');
  const removedTotal = pauses.reduce((a, p) => a + (p.b - p.a), 0);
  console.log(`${dst}: removed ${pauses.length} pauses (${removedTotal.toFixed(1)}s, ${dropped} samples)`);
}

main();
