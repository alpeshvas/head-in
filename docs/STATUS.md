# Project Status — Indoor Positioning Prototype

Updated: 2026-06-11 (end of grid-filter validation session)

## Phase plan (from docs/research/SYNTHESIS.md) and status

| Phase | Status |
|---|---|
| **0 — Survey recorder upgrades** | ✅ Done. Schema 2: pass types (normal/pacing/offRoute/standing/live), opt-in ARKit 6-DoF ground truth (surveyor-only camera; runtime stays camera-free), raw vectors/gravity/gyro already in `dm` lines. |
| **1 — Replay harness + metrics** | ✅ Mostly. `analysis/ground-truth.js` (ARKit arc-length truth), `analysis/match-route.js` reports true meters, `analysis/grid-filter.js` replay + `--calibrate` (Newson-Krumm fitting). Gaps: leave-one-out rotation, live-trace scorer prints "FALSE ADVANCE" for ungraded live fires (cosmetic). |
| **2 — Grid Bayes filter + OFF state** | ✅ Done & validated offline + live. JS reference `analysis/grid-filter.js`, Swift port `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` (must be kept in sync BY HAND — parity test still missing). |
| **3 — Anchors** | 🔄 IN PROGRESS. **Turn anchors implemented + validated offline** (2026-06-11): `analysis/turn-events.js` (gyro gravity-axis yaw turn detection, half-rotation localization), turn signature in profiles (`build-profile.js`, majority-vote clustering, ARKit arc-length localization), turn observation in both filters (matched turn = positional emission bump; unmatched U-turn = OFF-mass injection + 8-step reversal leak). Pacing false fire eliminated (was −10.5 s mid-pacing → now −4.2 s during the real walk-out); clean passes unchanged (3/3, P50 0.22 m). **Live walk validation pending.** Next anchors: audio-playback prior, accuracy-gated GPS, entrance anchoring. |
| **4 — Scale** | Later: distinctiveness maps, crowdsourced fingerprints, neural odometry (RoNIN; needs own training data for commercial). |

## Validated results (Plumeria home route, 3 segments, ~12 m)

- Magnetic repeatability across 3 fresh clean passes: overall r=0.85 STRONG (seg0 0.73 moderate, seg1 0.93, seg2 0.90).
- Leave-one-out vs ARKit truth: heuristic matcher ~0.23 m mean; **grid filter P50 0.22 m, P75 0.71 m, 3/3 checkpoints (delays 1.2/0.3/0.3 s)**.
- **Live clean walk** (trace `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl`): 3/3 fires (7.1/9.8/17.6 s), P(OFF) max 0.24, 20/25 steps corroborated. JS parity replay agrees structurally.
- **Live pacing test**: no checkpoints fired, "Off route?" flagged, grey "last agreed" ring — all three hardening fixes verified (corroboration gate: no observation in last 2 steps ⇒ no fire; unobserved-step OFF leak 0.04; kernel overflow past route end ⇒ OFF).
- Calibrated params (fitted, hand pose, Plumeria): sensorSigmaUT=1.5, offLogLikPerPoint=-4.86. THE PAIR IS COUPLED — re-fit OFF whenever sigma changes (`--calibrate`).
- **Turn signature (Plumeria)**: one majority turn, −159°@bin350±18 (all 3 passes, ARKit-localized 5.2–5.7 m). Offline: pacing U-turns (+172°, −129°) inject P(OFF)=0.5 and kill the early fire; clean passes match the signature and are otherwise unchanged. Profiles rebuilt with `turns[]`; bundled Plumeria resource updated (Meadows profile has no turns — decodes as optional).

## Filter architecture (both implementations)

720-bin grid over concatenated segment profiles + OFF state. Step-driven: predictStep (per-segment stride, σ=0.35·stride, backward tail, OFF leak 0.02, end-overflow→OFF), predictIdle when standing. Emission per step: last 4 step-intervals resampled per-step to bin units, mean-removed Gaussian vs profile mean/stddev (+σ²), tempered (indep bins=8), flat gate 3 µT, frozen when magnetometer uncalibrated. Checkpoint: P(s≥anchor−stride/2)>0.8 twice consecutively + observation within last 2 steps + P(OFF)<0.5. Off-route: P(OFF)>0.5 sustained. No ratchets except the UI timeline (fire-once-forward, deliberate).

## L478 apartment loop route (added 2026-06-11, second test route)

- 43 m, 6 segments, 7 anchors, contains a route U-turn (+181°) and a twice-traversed hallway. 3 clean passes w/ GT (`Plumeria_L478_*_normal_*-123833/-124255/-124358`; exclude `-123733`, mistapped). Profiles: `plumeria-l478-forward.json` (3-pass, bundled in app) + `plumeria-l478-loo.json`.
- LOO replay: **6/6 checkpoints within ±4.8 s, P50 0.76 m, but P75 7.2 m** — ~9 s wrong-mode stretch where the posterior jumps to the mirrored outbound hallway; the route U-turn match recaptures it. UI ratchet (displayBin) masks the stretch live. First hard evidence the 4-step window is too short for corridor disambiguation (research floor: 4–8 s) — try windowSteps 6–8 (requires re-running `--calibrate`: sigma/OFF pair is coupled to window stats).
- Live walk ✅ 2026-06-11 (`..._live_20260611-125057.jsonl`): 6/6 fires, route complete, all 6 turns matched, P(OFF) max 0.27.
- **Live pacing on L478 exposed the U-turn-match hole** (`..._live_20260611-125529.jsonl`): pacing U-turns matched the route's own +181°/+215° signature → 3 false fires. Fixed same day with (a) **posterior-support gate** (`turnMatchMinSupport` 0.1: a match needs ≥10% of on-route mass within 3σ of a matched bin, else treated as unmatched) and (b) **reversal fire-suppression** (checkpoints cannot fire while `reversalActive`, i.e. within `turnReversalSteps` of an unmatched U-turn). Replay matrix after fix: all clean passes unchanged (L478 6/6 P50 0.77 m; Test 3/3 P50 0.22 m); Test pacing now MISSED instead of −4.2 s early (conservative direction — false advance costs more than late); L478 pacing false fires delayed 13 s→27 s but **not eliminated**.
- **Known residual hole: sustained circling/arc pacing** — the turn detector only emits when rotation stops for 0.5 s, so pacing in slow circles (L478 trace, t 18–36 s) produces no turn events → no OFF injections → magnetic march can still fire early checkpoints. Real fix is heading-parity state (track walking direction relative to route, match windows against reversed profile when retracing) — Phase 4-ish. Parity fixtures regenerated (3rd fixture covers the support gate).
- Pending: off-route + standing negative passes, pocket-carry passes.

## App state (installed on iPhone 13 "iPhone", UDID B41E2C49-EB3F-5963-9D2A-751DDFD82757)

- Live tab runs the grid filter; profile picker (toolbar map icon): Plumeria (default) / Meadows, bundled in Resources/.
- Every Live run writes a trace (`*_live_*.jsonl`, full dm stream + `filter` state lines + `cp_fired` events) to the Sessions tab.
- Survey tab: pass-type picker (live excluded), ARKit ground-truth toggle.
- Deploy: `cd survey-recorder && xcodegen generate && xcodebuild -project SurveyRecorder.xcodeproj -scheme SurveyRecorder -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build` then `xcrun devicectl device install app --device B41E2C49-... build/Build/Products/Debug-iphoneos/SurveyRecorder.app`. Pull sessions: `xcrun devicectl device copy from --device B41E2C49-... --domain-type appDataContainer --domain-identifier com.headout.indoorpositioning.SurveyRecorder --source Documents/sessions --destination <dir>` (mkdir dest first; device must be plugged in + unlocked; "available (paired)" in `devicectl list devices`).

## Data inventory

- `recordings/` + `recordings-new/`: pulled sessions. Morning trio `Plumeria_*_normal_202606 11-104*` = clean passes w/ ARKit GT (profile + held-out). `*_pacing_20260610-234034` = negative. **Exclude `Plumeria_*_normal_20260610-233908`** (route walk with no anchor taps — user's early live test, not a survey).
- `profiles/plumeria-test-forward.json` (3-pass) and `plumeria-loo.json` (2-pass, for held-out eval).
- Commands: `npm run analyze|build-profile|match|ground-truth` and `node analysis/grid-filter.js <profile> <session> [--out html] [--calibrate]`.

## Outstanding (in priority order)

1. ~~Validate turn anchors live~~ ✅ DONE 2026-06-11. Clean walk (`..._live_20260611-121903.jsonl`): 3/3 fires, −166.5° matched corroborating Bedroom entry. Pacing (`..._live_20260611-122245.jsonl`): 8 U-turns over 36 s all unmatched, P(OFF) peak 0.56, no fire until the genuine walk-out at 40.6 s. Remaining sub-items: turn params hand-chosen, not fitted (sweep when more negative traces exist); missing-turn evidence not implemented.
2. ~~JS↔Swift parity test~~ ✅ DONE 2026-06-11. `npm test` → macOS XCTest target `FilterParityTests` replays op fixtures (generated by `npm run parity-fixture` = `analysis/make-parity-fixture.js`) through `RouteBeliefFilter` and asserts meanBin/pOff/probBeyond after every op + periodic full-belief snapshots (1e-6). Two fixtures (pacing + clean walk) cover all filter ops. Mutation-checked: a 0.01 param change fails at the first affected op. **REGENERATE FIXTURES whenever filter math/params change on either side.**
3. ~~Commit the working tree~~ ✅ Done 2026-06-11 (four logical commits: recorder upgrades, analysis tooling, live positioning tab, recordings+docs). Note: `recordings/` and `recordings-new/` hold near-duplicate session sets — consolidate sometime.
4. Cosmetics: live-trace scorer label; freeze segment label when off-route; HTML meters in match-route. (Fixed 2026-06-11: segment card/rings now floored at last reached checkpoint via `displayBin`, so they can no longer contradict the ratcheted timeline.)
5. More negative recordings (off-route walk in a different room, standing pass) + pocket-carry passes; re-fit params as traces accumulate.

## Key constraints (unchanged)

End-user runtime is strictly camera-free (ARKit is surveyor-only). Floor detection out of scope v1 (barometer recorded only). Product promise = checkpoint/zone confidence with manual fallback, never a blue dot. Commercial gate: ≥90% correct triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand+pocket.
