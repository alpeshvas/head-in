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

1. **Validate turn anchors live** (clean walk: −159° turn should show "matched" in diagnostics, 3/3 checkpoints; pacing: no false fire). Turn params (`turnUTurnOffLeak` 0.5 etc.) are hand-chosen, not fitted — sweep when more negative traces exist. Missing-turn evidence (walked past bin 350 without turning) not implemented.
2. **JS↔Swift parity test** (shared fixture; THIRD hand-sync just happened (observeTurn + reversal leak) — biggest correctness risk).
3. ~~Commit the working tree~~ ✅ Done 2026-06-11 (four logical commits: recorder upgrades, analysis tooling, live positioning tab, recordings+docs). Note: `recordings/` and `recordings-new/` hold near-duplicate session sets — consolidate sometime.
4. Cosmetics: live-trace scorer label; freeze segment label when off-route; HTML meters in match-route. (Fixed 2026-06-11: segment card/rings now floored at last reached checkpoint via `displayBin`, so they can no longer contradict the ratcheted timeline.)
5. More negative recordings (off-route walk in a different room, standing pass) + pocket-carry passes; re-fit params as traces accumulate.

## Key constraints (unchanged)

End-user runtime is strictly camera-free (ARKit is surveyor-only). Floor detection out of scope v1 (barometer recorded only). Product promise = checkpoint/zone confidence with manual fallback, never a blue dot. Commercial gate: ≥90% correct triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand+pocket.
