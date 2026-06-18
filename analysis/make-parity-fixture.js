#!/usr/bin/env node
// Generates the JS<->Swift parity fixture: drives the reference RouteGridFilter
// through the same op sequence a replay produces (predictStep / observe with the
// exact per-segment windows / applyUnobservedLeak / observeTurn / predictIdle)
// and records the posterior after every op. The Swift test (FilterParityTests)
// applies the identical ops to RouteBeliefFilter and asserts the posterior
// matches. Regenerate whenever filter math or params change in either
// implementation:
//
//   node analysis/make-parity-fixture.js profiles/plumeria-test-forward.json \
//     recordings-new/<session>.jsonl survey-recorder/Tests/Fixtures/parity-fixture.json

const fs = require('fs');
const path = require('path');
const gf = require('./grid-filter');
const { detectTurns } = require('./turn-events');

function main() {
  const [profilePath, sessionPath, outPath] = process.argv.slice(2);
  if (!outPath) {
    console.error('usage: node analysis/make-parity-fixture.js <profile.json> <session.jsonl> <out.json>');
    process.exit(1);
  }
  const profile = JSON.parse(fs.readFileSync(profilePath, 'utf8'));
  const session = gf.parseSession(sessionPath);
  const gp = gf.buildGlobalProfile(profile);
  const filter = new gf.RouteGridFilter(gp);
  const steps = gf.detectSteps(session.dm);
  const provider = gf.makeWindowProvider(session.dm, steps);

  const t0 = session.dm[0].t;
  const tEnd = session.dm[session.dm.length - 1].t;
  const events = [];
  for (const t of steps) events.push({ t, kind: 'step' });
  for (let t = t0; t <= tEnd; t += 1.0) events.push({ t, kind: 'tick' });
  for (const turn of detectTurns(session.dm)) events.push({ t: turn.endT, kind: 'turn', deltaDeg: turn.deltaDeg });
  events.sort((a, b) => a.t - b.t);

  const probeBins = gp.segments.map((s) => s.startBin + Math.floor(s.count / 2));
  const ops = [];
  const expect = () => ({
    meanBin: filter.meanBin(),
    pOff: filter.pOff,
    probBeyond: probeBins.map((b) => filter.probBeyond(b)),
  });
  const push = (op) => {
    op.expect = expect();
    // Periodic full-belief snapshots catch compensating errors that the
    // scalar summaries would miss.
    if (ops.length % 25 === 0) op.expect.belief = Array.from(filter.belief);
    ops.push(op);
  };

  let lastT = t0;
  for (const ev of events) {
    if (ev.kind === 'step') {
      filter.predictStep();
      push({ op: 'predictStep' });
      const w = provider(ev.t);
      const windows = {};
      for (const seg of gp.segments) {
        const win = w(seg);
        windows[seg.index] = win ? Array.from(win) : null;
      }
      const observed = filter.observe((seg) => windows[seg.index]);
      push({ op: 'observe', windows });
      if (!observed) {
        filter.applyUnobservedLeak();
        push({ op: 'applyUnobservedLeak' });
      }
    } else if (ev.kind === 'turn') {
      filter.observeTurn(ev.deltaDeg);
      push({ op: 'observeTurn', deltaDeg: ev.deltaDeg });
    } else {
      const sinceStep = steps.length ? Math.min(...steps.map((s) => Math.abs(s - ev.t))) : Infinity;
      if (sinceStep > 1.5) {
        const dt = ev.t - lastT;
        filter.predictIdle(dt);
        push({ op: 'predictIdle', dt });
      }
    }
    lastT = ev.t;
  }

  const fixture = {
    generated: 'analysis/make-parity-fixture.js',
    profileFile: path.basename(profilePath),
    sessionFile: path.basename(sessionPath),
    params: gf.PARAMS,
    probeBins,
    ops,
  };
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(fixture) + '\n');
  console.log(`${outPath}: ${ops.length} ops (${ops.filter((o) => o.op === 'observe').length} observe, ${ops.filter((o) => o.op === 'observeTurn').length} turn, ${ops.filter((o) => o.op === 'predictIdle').length} idle)`);
}

main();
