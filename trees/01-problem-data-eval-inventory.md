# TL;DR

This repo is a phone-only, route-constrained indoor checkpoint trigger prototype, not a free-form indoor GPS/blue-dot system. The core data asset is repeated iPhone JSONL route walks in `recordings-new/`, converted into `profiles/*.json` magnetic route profiles and replayed by the JS reference grid filter (`analysis/grid-filter.js`) plus a Swift port in the survey app. Current strongest path: known ordered route, single floor, prepared profile, checkpoint/zone confidence with manual fallback. Current weakest path: reverse/mid-route/out-of-order walking and arbitrary movement; crude magnetic-only or compass guards were tried/rejected, and a proper gait-heading guard is research work.

# Confirmed problem statement

- Goal: no-installed-hardware indoor positioning on phones, first focused on iPhone, with route-constrained confidence rather than full indoor GPS (`docs/research-notes.md:3-21`).
- Product target: detect whether user is near a checkpoint, estimate progress along a known route, identify low confidence, and fall back to manual confirmation (`docs/research-notes.md:7-13`).
- Current product direction: survey known routes, anchor survey sessions at checkpoints, build route-segment magnetic profiles, run a route-constrained grid Bayes filter over route-position bins plus explicit `OFF`, and emit conservative checkpoint/progress/off-route/fallback events (`README.md:15-25`).
- Product promise must remain checkpoint/route/zone confidence, not arbitrary indoor blue dot (`README.md:25`, `README.md:93-100`, `docs/architecture.md:205-216`).
- Survey/runtime constraints: no venue-installed hardware by default, no camera dependency for end-user runtime, single-floor routes, ARKit only for surveyor/offline ground truth (`README.md:93-100`, `docs/architecture.md:11-16`).

# Dataset inventory and stratification

## Data model / file conventions

- Schema 2 live/survey JSONL files are named with `venue_route_direction_pose_passType_timestamp.jsonl` and write a line-1 `meta` object containing `venueId`, `routeId`, `direction`, `devicePose`, `passType`, `groundTruth`, checkpoint names, device model, and optional `profileResource` (`survey-recorder/SurveyRecorder/SessionWriter.swift:30-57`).
- Supported pass types are `normal`, `pacing`, `offRoute`, `standing`, and `live`; only `normal`, `pacing`, and `live` were found in `recordings-new/` (`survey-recorder/SurveyRecorder/Models.swift:18-45`).
- Poses represented in current data: `hand` and `pocket`; `bag` is supported in code but not represented in `recordings-new/` (`survey-recorder/SurveyRecorder/Models.swift:10-15`).
- `recordings/` is an older 17-file subset; `recordings-new/` is the main current pulled-session set. `recordings/` and `recordings-new/` are near-duplicate for older sessions and should eventually be consolidated (`docs/STATUS.md:73-83`).

## `recordings-new/` inventory

I inspected 57 JSONL files under `recordings-new/`. Metadata below comes from each file's line-1 `meta` object; representative examples: `recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl:1`, `recordings-new/Plumeria_L478_forward_pocket_normal_20260611-133605_anchors-fixed.jsonl:1`, `recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030752.jsonl:1`, `recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095345.jsonl:1`.

| Venue / route | Direction | Poses | Pass-type/files in `recordings-new/` | Checkpoints / anchors | Notes |
|---|---:|---|---|---|---|
| `Test / Test` | forward | hand | 5 schema-1 files with no `passType`: `Test_Test_forward_hand_20260610-193139.jsonl`, `...193441`, `...194428`, `...194457`, `...194527` | Start → End | Earliest two-anchor baseline data; representative meta at `recordings-new/Test_Test_forward_hand_20260610-193139.jsonl:1`. |
| `Meadows / Test` | forward | hand | 5 schema-1 files (`Meadows_Test_forward_hand_20260610-200257`..`200514`) + 1 schema-2 `normal` GT file (`...233734`) | 4 checkpoint names in schema-1 profile | Profile is old/no calibration; representative meta at `recordings-new/Meadows_Test_forward_hand_20260610-200257.jsonl:1`. |
| `Plumeria / Test` | forward | hand | 5 `normal` GT files, 1 `pacing`, 3 `live` | Start → Room exit → Bedroom entry → Bedroom exit | Main ~12 m home route. Clean morning trio is `Plumeria_Test_forward_hand_normal_20260611-104309/104347/104421`; exclude `...20260610-233908` because it has no anchor taps (`docs/STATUS.md:73-77`). Pacing negative meta: `recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl:1`. |
| `Plumeria / L478` | forward | hand | 3 `normal` GT, 4 `live` | 7 anchors / 6 segments | 43 m apartment loop with U-turn and repeated hallway (`docs/STATUS.md:47-53`); normal source meta example `recordings-new/Plumeria_L478_forward_hand_normal_20260611-123833.jsonl:1`. |
| `Plumeria / L478` | forward | pocket | 3 original `normal`, 3 `_anchors-fixed` normal variants, 3 `live` | 7 anchors / 6 segments | Pocket surveys rely on pause-derived anchors because phone cannot be tapped in pocket; use `_anchors-fixed` variants and `--splice-pauses` (`docs/STATUS.md:54-64`, `analysis/splice-pauses.js:1-10`). Live pocket trace records selected `profileResource` (`recordings-new/Plumeria_L478_forward_pocket_live_20260612-135652.jsonl:1`). |
| `Office / Right wing garden` | forward | pocket-tagged survey, hand live | 2 `normal` GT survey files tagged `pocket`; 2 hand `live` files | Work room → Room 1 → Room 2 → Room 3 → Game room | 12.5 m, third venue / first non-home; status notes survey was tagged pocket but phone was visibly held (`docs/STATUS.md:39-45`). Representative survey meta: `recordings-new/Office_Right-wing-garden_forward_pocket_normal_20260619-013707.jsonl:1`. |
| `Office Near / LIS` | forward | hand | 5 `normal` GT, 4 `live` | 8 checkpoints | Includes first/failed and re-surveyed LIS route data. Survey practice docs note original long open-office leg failed; evenly spaced checkpoints fixed live completion (`docs/SURVEY-PRACTICE.md:14-22`). Representative survey meta: `recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030752.jsonl:1`. |
| `Ravi place / Home` | forward | hand | 3 `normal` GT, 5 `live` | Checkpoint 1 → Balcony → Kitvhen → Room 1 → Master bedroom | Profile uses two faster reuse passes, not the slow ad-hoc bootstrap pass (`docs/SURVEY-PRACTICE.md:51-57`); representative survey meta: `recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095345.jsonl:1`. |

Counts from inspection: 57 total files; 19 with `groundTruth: true`; 21 `live` traces; 1 explicit `pacing` negative trace; no current `offRoute` or `standing` traces despite schema support. `docs/STATUS.md` also lists more negative recordings as pending (`docs/STATUS.md:79-85`).

## Profile inventory

Profiles are the route maps: `route`, ordered `anchors`, `segments`, optional `turns`, and optional fitted `calibration` (`docs/architecture.md:45-55`). `build-profile` emits schema 1 with 240 resample bins/segment, quality stats, turn signatures, and calibration (`analysis/build-profile.js:470-524`, `analysis/build-profile.js:527-610`, `analysis/build-profile.js:760-793`). Bundled app resources are listed in `RouteProfile.bundledProfiles` (`survey-recorder/SurveyRecorder/RouteProfile.swift:22-31`).

| Profile | Route / pose | Source passes | Anchors / segments | Turns / calibration | Citations |
|---|---|---:|---:|---|---|
| `profiles/meadows-test-forward.json` | Meadows / Test / hand | 5 schema-1 | 4 anchors / 3 segments | no turn/calibration block observed | `profiles/meadows-test-forward.json:4-18`, `profiles/meadows-test-forward.json:18-41` |
| `profiles/plumeria-test-forward.json` | Plumeria / Test / hand | 3 clean GT | 4 / 3 | 1 turn; `diffSigmaUT=2.556`, `offLogLik=-4.863`, ARKit LOO | `profiles/plumeria-test-forward.json:4-39`, `profiles/plumeria-test-forward.json:1562-1577` |
| `profiles/plumeria-loo.json` | Plumeria / Test / hand | 2 clean GT | 4 / 3 | LOO eval profile | `profiles/plumeria-loo.json:4-39`, `profiles/plumeria-loo.json:1561-1576` |
| `profiles/plumeria-l478-forward.json` | Plumeria / L478 / hand | 3 clean GT | 7 / 6 | 6 turns; `diffSigmaUT=2.84`, `offLogLik=-3.946`, ARKit LOO | `profiles/plumeria-l478-forward.json:4-50`, `profiles/plumeria-l478-forward.json:3094-3139` |
| `profiles/plumeria-l478-loo.json` | Plumeria / L478 / hand | 2 clean GT | 7 / 6 | LOO eval profile | `profiles/plumeria-l478-loo.json:4-49`, `profiles/plumeria-l478-loo.json:3093-3132` |
| `profiles/plumeria-l478-pocket.json` | Plumeria / L478 / pocket | 3 `_anchors-fixed` | 7 / 6 | 4 pocket turns in profile; turn evidence disabled at runtime for pocket; `diffSigmaUT=2.684`, `offLogLik=-5.052`, anchor-interpolated LOO | `profiles/plumeria-l478-pocket.json:4-50`, `profiles/plumeria-l478-pocket.json:3094-3127`, `docs/STATUS.md:57-64` |
| `profiles/office-right-wing-forward.json` | Office / Right wing garden / pocket-tagged | 2 GT | 5 / 4 | no turns; `diffSigmaUT=1.218`, `offLogLik=-3.418` | `profiles/office-right-wing-forward.json:4-41`, `profiles/office-right-wing-forward.json:2071-2079` |
| `profiles/office-near-lis-forward.json` | Office Near / LIS / hand | 2 GT | 8 / 7 | 3 turns; `diffSigmaUT=2.172`, `offLogLik=-3.623` | `profiles/office-near-lis-forward.json:4-53`, `profiles/office-near-lis-forward.json:3604-3631` |
| `profiles/ravi-place-home-forward.json` | Ravi place / Home / hand | 2 GT reuse passes | 5 / 4 | 1 turn; `diffSigmaUT=3.573`, `offLogLik=-3.174` | `profiles/ravi-place-home-forward.json:4-41`, `profiles/ravi-place-home-forward.json:2071-2086` |

# Evaluation criteria and commands

## Criteria

- Initial pilot success metric: detect checkpoint arrival within about 2–5 m at least 80–90% of the time while entering low confidence rather than making false claims when ambiguous (`docs/research-notes.md:365-373`).
- Research/commercial target: 1–3 m P50 along-track in hand, 90–95% checkpoint triggers within ±5 m, degrading to 3–6 m in pocket; do not promise blue dot (`docs/research/SYNTHESIS.md:6-8`).
- Commercial gate before going past Phase 3: ≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand and pocket carry, with low false-advance rate and permanent one-tap fallback (`docs/research/SYNTHESIS.md:38-40`, `docs/STATUS.md:102-104`).
- Offline metric standard: P75 positioning error, checkpoint detection rate within labeled truth, false-advance rate/session, median detection delay, off-route detection delay/false-alarm rate on deliberate negative recordings (`docs/research/route-constrained-fusion.md:39-42`).
- Current `grid-filter` scorer prints checkpoint truth/detected/delay/verdict; `ok` is `abs(delay) <= 6s`, otherwise early/late/missed/false-advance (`analysis/grid-filter.js:845-866`). It also prints max P(OFF), off-route flag, turn matches, and ARKit true-meter mean/P50/P75 when ground truth exists (`analysis/grid-filter.js:876-903`).
- Survey-quality gate: aim for per-segment repeatability `r >= ~0.85`; record ≥3 clean passes for honest leave-one-out validation; 2 passes are minimum but not enough for honest LOO (`docs/SURVEY-PRACTICE.md:24-34`, `docs/SURVEY-PRACTICE.md:42-47`, `docs/SURVEY-PRACTICE.md:80-86`).

## Commands

From `package.json` and README (`package.json:6-13`, `README.md:57-90`):

```sh
# Repeatability / survey quality
npm run analyze -- recordings-new/<session1>.jsonl recordings-new/<session2>.jsonl --out analysis/report.html

# Build a profile
npm run build-profile -- recordings-new/Plumeria_Test_forward_hand_normal_20260611-104*.jsonl --out profiles/plumeria-test-forward.json

# Build a pocket profile with pause splicing
npm run build-profile -- recordings-new/Plumeria_L478_forward_pocket_normal_*_anchors-fixed.jsonl --splice-pauses --out profiles/plumeria-l478-pocket.json

# Inspect ARKit ground truth / route lengths
npm run ground-truth -- recordings-new/<gt-session>.jsonl --out analysis/ground-truth.html

# Replay current reference filter
node analysis/grid-filter.js profiles/<profile>.json recordings-new/<session>.jsonl --out analysis/filter-report.html

# Fit emission/OFF calibration from a GT session
node analysis/grid-filter.js profiles/<profile>.json recordings-new/<gt-session>.jsonl --calibrate

# Older heuristic matcher
npm run match -- profiles/<profile>.json recordings-new/<session>.jsonl --out analysis/match-report.html

# JS↔Swift parity tests
npm test
```

Relevant command implementation citations: `analysis/analyze-repeatability.js:1-15`, `analysis/build-profile.js:1-30`, `analysis/ground-truth.js:1-18`, `analysis/grid-filter.js:27-28`, `analysis/grid-filter.js:960-985`, `analysis/match-route.js:1-12`, `analysis/splice-pauses.js:1-10`. Parity status and fixture workflow are documented in `docs/STATUS.md:79-85`.

Spot-checks run during this scout with current JS (no output files written):

- `node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl` now reports 0 fired checkpoints under current JS, matching the documented in-place pacing gate fix; historical live trace still contains old `cp_fired` lines at `recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl:2375` and `:2478`.
- `node analysis/grid-filter.js profiles/office-near-lis-forward.json recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl` still false-advances Checkpoint 2–6 under current JS, matching the documented reverse-walk limitation; trace has `cp_fired` lines at `recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl:1268`, `:2046`, `:2698`, `:2886`, `:3096`.
- `node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095845.jsonl` reports 3/4 (misses `Master bedroom`) under current JS; treat this as a follow-up data/profile check because it is not called out explicitly in `docs/STATUS.md`.

# Baseline/current algorithm

## Baseline / older scripts

- `analysis/pdr-assisted-positioning.js` is the early offline prototype: leave-one-session-out magnetic fingerprint replay with monotonic PDR route-progress prior; magnetic matching searches near the PDR prior and nudges the estimate (`analysis/pdr-assisted-positioning.js:1-13`).
- `analysis/match-route.js` is the older offline matcher: replays one session against one profile, uses recorded anchors only to split/score validation segments, and emits `near_checkpoint` when truth progress/fused progress thresholds are crossed (`analysis/match-route.js:1-12`, `analysis/match-route.js:441-455`).
- `analysis/analyze-repeatability.js` remains the survey-quality baseline: Pearson correlation + DTW deviation per anchor-to-anchor segment (`analysis/analyze-repeatability.js:1-15`).

## Current reference algorithm

- Reference implementation: `analysis/grid-filter.js`; live Swift port: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` + `survey-recorder/SurveyRecorder/LivePositioningController.swift` (`README.md:27-35`, `README.md:74-82`).
- State: discrete grid over concatenated route-position bins (~240 bins/segment) plus explicit `OFF` state (`analysis/grid-filter.js:1-29`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:1-10`).
- Transition: detected steps advance belief by per-segment stride with noise/backward tail; standing applies small diffusion; step motion leaks some mass to OFF; local OFF re-entry is around last confident on-route mode (`analysis/grid-filter.js:8-13`, `docs/architecture.md:108-137`, `docs/architecture.md:171-177`).
- Emission: stride-lag first-difference Gaussian on last 6 step intervals of magnetic magnitude, per-step resampled, with flat-window gate and terminal-region freeze (`analysis/grid-filter.js:14-19`, `analysis/grid-filter.js:38-61`, `docs/STATUS.md:24-29`).
- Anchors: turn signatures are extracted offline by majority clustering; live hand-carry turn observations snap/support route turns or inject OFF/reversal suppression for unmatched U-turn-scale turns (`analysis/build-profile.js:527-601`, `analysis/grid-filter.js:62-86`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:268-340`).
- Checkpoint fire rule: recent magnetic observation, no active reversal, confinement ratio above threshold, posterior mass past decision bin >0.8, `pOff < 0.5`, two consecutive updates (`analysis/grid-filter.js:818-829`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:403-419`, `docs/architecture.md:179-191`).
- In-place pacing gate: live field range over 8 s normalized by profile typical range; below 0.8 blocks checkpoint fires while leaving belief/tracking untouched (`analysis/grid-filter.js:87-99`, `analysis/grid-filter.js:761-777`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:367-380`).
- Pocket mode: turn evidence is disabled/conditioned by user-selected live pose because leg-swing distorts turn magnitudes; live pose is a manual selector, not detected automatically (`survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `docs/STATUS.md:57-58`).

# Known blockers / current failures

1. **Route-order / reverse / mid-route entry is the main unresolved design limitation.** The filter is a 1-D ordered forward-route tracker, so out-of-order or shortcut walks fire route order rather than physical order (`docs/STATUS.md:95`). Reverse walking a forward profile can silently false-advance because the filter initializes at bin 0 and step prediction moves forward while magnetic magnitude is direction-symmetric (`docs/STATUS.md:96`). The LIS reverse trace is in-repo and contains checkpoint fires (`recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl:1`, `recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl:1268`, `:2046`, `:2698`, `:2886`, `:3096`).
2. **Magnetic-only start/entrance arming was tried and reverted.** It suppressed the LIS reverse walk but did not generalize to short Test / office-right-wing routes, causing 0-checkpoint regressions; pointwise magnetic magnitude is too weak for robust start confirmation (`docs/STATUS.md:96-100`).
3. **Compass/device heading was tested and rejected for travel direction.** It reflects phone hold angle, not travel direction (`docs/STATUS.md:98`). Research says gait/PCA travel heading is promising, but the crude implementation was a no-go for shipping: forward passes disagreed by ~100–170° in some LIS segments; do not ship a reverse guard without proper per-step gait-cycle sign resolution (`docs/research/direction-and-entrance-anchoring.md:9-30`, `docs/research/direction-and-entrance-anchoring.md:68-109`, `docs/research/direction-and-entrance-anchoring.md:111-135`).
4. **Pacing false-advances were historically severe but are currently offline-mitigated, with live re-test caveat.** Ravi-place longer pacing and L478 circling-pacing exposed that step count can march the route estimate through weak fields; current in-place pacing gate reports all pacing → 0 fires offline, but status marks live re-test pending and notes the gate is controller-level, not in filter parity fixtures (`docs/STATUS.md:87-94`).
5. **Pocket carry still has edge cases and no automatic pose detection.** Pocket-specific profile is viable and live-validated in status, but final checkpoint can miss at recording edge due to pull-out/end-turn transient; live runtime relies on a user-selected Hand/Pocket carry picker (`docs/STATUS.md:54-64`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`). Current JS replay of pocket live `...135652` does not reproduce the historical final `cp_fired` even though the trace contains it (`recordings-new/Plumeria_L478_forward_pocket_live_20260612-135652.jsonl:878`, `:1042`, `:1495`, `:3009`, `:4083`, `:5050`); follow up if pocket final-fire parity matters.
6. **Survey quality is a product/data blocker, not just code.** Long open-office legs with weak/non-repeatable magnetic field caused LIS live failure; re-surveying with more evenly spaced checkpoints fixed completion (`docs/SURVEY-PRACTICE.md:8-22`). Build profiles should target ≥3 clean passes and `r >= ~0.85`; 2-pass profiles exist but are thin for honest validation (`docs/SURVEY-PRACTICE.md:24-34`, `docs/SURVEY-PRACTICE.md:42-57`).
7. **Coverage is below commercial gate.** Dataset spans multiple venues and two iPhone model identifiers, but not ≥3 iPhone models with repeated hand+pocket validation per route. Several current profiles are 2-pass only (`profiles/office-right-wing-forward.json:10-13`, `profiles/office-near-lis-forward.json:10-13`, `profiles/ravi-place-home-forward.json:10-13`). Off-route and standing negative passes are absent and explicitly pending (`docs/STATUS.md:79-85`).
8. **Live-trace scorer cosmetic gotcha.** `grid-filter` prints `FALSE ADVANCE` for live traces that have no recorded truth anchors; STATUS calls this cosmetic (`docs/STATUS.md:9-12`). Do not treat every live replay `FALSE ADVANCE` as a true failure unless the trace is a deliberate negative/reverse/out-of-order test or has truth anchors.
9. **No global relocalization / free roam.** OFF re-entry is local near last confident mode; arbitrary distant re-entry or free-room positioning needs a different architecture (2-D/global/per-zone) (`docs/architecture.md:171-177`, `docs/architecture.md:211-216`).

# Best files to read next

1. `docs/STATUS.md:87-104` — current known limitations and product constraints; read before changing algorithm behavior.
2. `analysis/grid-filter.js:1-99`, `analysis/grid-filter.js:735-839`, `analysis/grid-filter.js:845-903` — JS reference filter, fire gate, scoring, metrics.
3. `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:1-70`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:367-420` — Swift port and live checkpoint decision.
4. `docs/SURVEY-PRACTICE.md:1-90` — how to collect route data that actually tracks; explains LIS/Ravi survey failures.
5. `profiles/*.json` — route/profile truth; start with `profiles/plumeria-l478-forward.json:4-50` and `profiles/plumeria-l478-forward.json:3094-3139` for a rich hand route, plus `profiles/plumeria-l478-pocket.json:4-50` and `profiles/plumeria-l478-pocket.json:3094-3127` for pocket.
6. `recordings-new/` — current session corpus. Start with clean GT replays (`Plumeria_Test_forward_hand_normal_20260611-104309/104347/104421`, `Plumeria_L478_forward_hand_normal_20260611-123833/124255/124358`) and known negatives/edge cases (`Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl`, `Office-Near_LIS_forward_hand_live_20260619-031803.jsonl`, `Ravi-place_Home_forward_hand_live_20260619-100523.jsonl`, `Ravi-place_Home_forward_hand_live_20260619-105724.jsonl`).
7. `docs/research/direction-and-entrance-anchoring.md:68-135` — reverse/wrong-way research and why no guard is currently shipped.
8. `docs/research/SYNTHESIS.md:6-40` and `docs/research/route-constrained-fusion.md:39-56` — success metrics and why the grid filter architecture exists.
