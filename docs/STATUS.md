# Project Status — Indoor Positioning Prototype

Updated: 2026-06-11 (end of grid-filter validation session)

## Phase plan (from docs/research/SYNTHESIS.md) and status

| Phase | Status |
|---|---|
| **0 — Survey recorder upgrades** | ✅ Done. Schema 2: pass types (normal/pacing/offRoute/standing/live), opt-in ARKit 6-DoF ground truth (surveyor-only camera; runtime stays camera-free), raw vectors/gravity/gyro already in `dm` lines. |
| **1 — Replay harness + metrics** | ✅ Mostly. `analysis/ground-truth.js` (ARKit arc-length truth), `analysis/match-route.js` reports true meters, `analysis/grid-filter.js` replay + `--calibrate` (Newson-Krumm fitting). Gaps: leave-one-out rotation, live-trace scorer prints "FALSE ADVANCE" for ungraded live fires (cosmetic). |
| **2 — Grid Bayes filter + OFF state** | ✅ Done & validated offline + live. JS reference `analysis/grid-filter.js`, Swift port `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` (must be kept in sync BY HAND — parity test still missing). |
| **3 — Anchors** | 🔄 IN PROGRESS. **Turn anchors implemented + validated offline** (2026-06-11): `analysis/turn-events.js` (gyro gravity-axis yaw turn detection, half-rotation localization), turn signature in profiles (`build-profile.js`, majority-vote clustering, ARKit arc-length localization), turn observation in both filters (matched turn = positional emission bump; unmatched U-turn = OFF-mass injection + 8-step reversal leak). Pacing false fire eliminated (was −10.5 s mid-pacing → now −4.2 s during the real walk-out); clean passes unchanged (3/3, P50 0.22 m). Turn anchors fully validated live on both routes incl. pacing hardening (support gate + reversal suppression). Remaining anchors: audio-playback prior (needs tour-app integration), accuracy-gated GPS + entrance anchoring (needs a semi-outdoor venue). **Stair events dropped — multi-floor is out of scope (Alpesh, 2026-06-11), consistent with the v1 floor-detection constraint.** |
| **4 — Scale** | Later: distinctiveness maps, crowdsourced fingerprints, neural odometry (RoNIN; needs own training data for commercial). |

## Validated results (Plumeria home route, 3 segments, ~12 m)

- Magnetic repeatability across 3 fresh clean passes: overall r=0.85 STRONG (seg0 0.73 moderate, seg1 0.93, seg2 0.90).
- Leave-one-out vs ARKit truth: heuristic matcher ~0.23 m mean; **grid filter P50 0.22 m, P75 0.71 m, 3/3 checkpoints (delays 1.2/0.3/0.3 s)**.
- **Live clean walk** (trace `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl`): 3/3 fires (7.1/9.8/17.6 s), P(OFF) max 0.24, 20/25 steps corroborated. JS parity replay agrees structurally.
- **Live pacing test**: no checkpoints fired, "Off route?" flagged, grey "last agreed" ring — all three hardening fixes verified (corroboration gate: no observation in last 2 steps ⇒ no fire; unobserved-step OFF leak 0.04; kernel overflow past route end ⇒ OFF).
- Calibrated params (fitted, hand pose, Plumeria): sensorSigmaUT=1.5, offLogLikPerPoint=-4.86. THE PAIR IS COUPLED — re-fit OFF whenever sigma changes (`--calibrate`).
- **Turn signature (Plumeria)**: one majority turn, −159°@bin350±18 (all 3 passes, ARKit-localized 5.2–5.7 m). Offline: pacing U-turns (+172°, −129°) inject P(OFF)=0.5 and kill the early fire; clean passes match the signature and are otherwise unchanged. Profiles rebuilt with `turns[]`; bundled Plumeria resource updated (Meadows profile has no turns — decodes as optional).

## Differenced emission upgrade (2026-06-11, closes the Phase-2 research deviation)

- Emission rewritten to **stride-lag first-differences** (SYNTHESIS convergence pt. 1, FollowMe/MaLoc): per-step-resampled window, differenced at one stride of lag, single fitted homoscedastic noise (Magicol one-sigma; per-bin survey std NOT used — adjacent-bin map errors are common-mode and cancel; bin-scale differencing is noise-dominated, both verified failed). Fitted: `diffSigmaUT=2.42`, `offLogLikPerPoint=-4.99`, `windowSteps=6` (COUPLED TRIPLE — re-run `--calibrate` if any changes).
- Two end-of-route consequences of the sharper posterior, both fixed: route end is now an absorbing barrier (overflow→OFF blocked the final fire), and emission **freezes in the 2-stride terminal region** (post-route field in the window blew P(OFF) to 1.0; arrival counts as observed for the recency gate).
- Replay matrix: **L478 clean P75 7.2→0.72 m, all delays sub-second (hallway wrong-mode stretch eliminated)**; Test clean 3/3 P50 0.31 (P75 0.71→1.48, within promise); Test pacing strictly better (fires only at the genuine walk-out); both live traces full fires.
- **L478 circling-pacing unchanged (3 false fires ~18.5 s)**: by then 50% of on-route mass had genuinely marched to the U-turn region, so the support gate can't help. Research-anchored next fix: **missing-turn evidence** ("expected-but-missing turn is an off-route flag", pdr-neural-odometry.md §turn-detection) — penalize mass crossing a signature turn bin without a recent matching turn observation. NOT yet implemented.

## Filter architecture (both implementations)

240-bins-per-segment grid over concatenated segment profiles + OFF state. Step-driven: predictStep (per-segment stride, σ=0.35·stride, backward tail, OFF leak 0.02, start AND end bins are absorbing barriers), predictIdle when standing. Emission per step: last 6 step-intervals resampled per-step to bin units, **stride-lag first-difference Gaussian** with single fitted noise (diffSigmaUT 2.42), tempered (indep bins=8), flat gate 3 µT, frozen when magnetometer uncalibrated and in the 2-stride terminal region. Turn anchors: matched (sign+magnitude tolerance 55° AND ≥10% posterior support within 3σ) → positional bump ×OFF 0.3; unmatched ≥100° → 0.5 OFF injection + 8-step reversal leak. Checkpoint: P(s≥anchor−stride/2)>0.8 twice consecutively + observation within last 2 steps + NOT reversal-active + P(OFF)<0.5. Off-route: P(OFF)>0.5 sustained 3 s. No ratchets except the UI (timeline fire-once-forward + displayBin floor, deliberate).

## L478 apartment loop route (added 2026-06-11, second test route)

- 43 m, 6 segments, 7 anchors, contains a route U-turn (+181°) and a twice-traversed hallway. 3 clean passes w/ GT (`Plumeria_L478_*_normal_*-123833/-124255/-124358`; exclude `-123733`, mistapped). Profiles: `plumeria-l478-forward.json` (3-pass, bundled in app) + `plumeria-l478-loo.json`.
- LOO replay: **6/6 checkpoints within ±4.8 s, P50 0.76 m, but P75 7.2 m** — ~9 s wrong-mode stretch where the posterior jumps to the mirrored outbound hallway; the route U-turn match recaptures it. UI ratchet (displayBin) masks the stretch live. First hard evidence the 4-step window is too short for corridor disambiguation (research floor: 4–8 s). RESOLVED same day by the differenced-emission upgrade (see section above): wrong-mode stretch eliminated, P75 0.72 m.
- Live walk ✅ 2026-06-11 (`..._live_20260611-125057.jsonl`): 6/6 fires, route complete, all 6 turns matched, P(OFF) max 0.27.
- **Live pacing on L478 exposed the U-turn-match hole** (`..._live_20260611-125529.jsonl`): pacing U-turns matched the route's own +181°/+215° signature → 3 false fires. Fixed same day with (a) **posterior-support gate** (`turnMatchMinSupport` 0.1: a match needs ≥10% of on-route mass within 3σ of a matched bin, else treated as unmatched) and (b) **reversal fire-suppression** (checkpoints cannot fire while `reversalActive`, i.e. within `turnReversalSteps` of an unmatched U-turn). Replay matrix after fix: all clean passes unchanged (L478 6/6 P50 0.77 m; Test 3/3 P50 0.22 m); Test pacing now MISSED instead of −4.2 s early (conservative direction — false advance costs more than late); L478 pacing false fires delayed 13 s→27 s but **not eliminated**.
- **Known residual hole: sustained circling/arc pacing** — the turn detector only emits when rotation stops for 0.5 s, so pacing in slow circles (L478 trace, t 18–36 s) produces no turn events → no OFF injections → magnetic march can still fire early checkpoints. **Research-anchored fix (SYNTHESIS convergence pt. 1): differenced 4–8 s windows** — magnitude is direction-symmetric, first-differences are not (reversed walk = reversed-negated diff sequence; also device-invariant and immune to mid-walk iOS recalibration, magnetic-fingerprinting.md §gradients). The "heading-parity state" idea is NOT from the research — extrapolation, only revisit if differencing proves insufficient. Parity fixtures regenerated (3rd fixture covers the support gate).
- **First pocket pass** ✅ 2026-06-11 (`..._pocket_normal_20260611-133605.jsonl`; `*_anchors-fixed` variant has checkpoint times recovered from 3-s standing pauses — the surveyor can't tap with the phone pocketed, so taps were an end-burst; future surveys: pause ≥3 s at each checkpoint). Pass 1: 6/6 fires in order, delays −1.7…+10.8 s. **Passes 2–3 (134156/134318): only 4/6 — both die in the back half (Kitchen→Bedroom), P(OFF)=1.0, final two checkpoints never fire — and still die with turn evidence disabled, so the blocker is the EMISSION: pocket windows mismatch the hand-surveyed profile where gradients are strong (leg-swing oscillation through gradients).** Zero pocket turn matches in any pass (leg-swing compresses turn magnitudes) and turn injections add false OFF — turn evidence should be disabled/down-weighted for pocket pose regardless. Pocket verdict: 1/3 passes meet the checkpoint promise → research fork is live. Options ladder: (1) per-pose profiles — survey in pocket, match pocket-vs-pocket (cheap test; needs pocket surveys with pauses at ALL checkpoints incl. Hall so pause-derived anchors cover every segment), (2) RoNIN-class odometry (Phase 4, weeks). Decision pending the per-pose-profile experiment.
- Survey UX gap: no way to end a recording without tapping through remaining anchors (caused the end-burst).
- Pending: off-route + standing negative passes, 1–2 more pocket passes.

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
