# Baseline algorithm audit — route-constrained indoor positioning

## TL;DR

- The implemented baseline is a **1-D route-position Bayes filter plus an explicit `OFF` state**, not free-form indoor GPS. It assumes the user starts at the first anchor and walks the profile direction; output is checkpoint/zone confidence, not x/y position (`README.md:17-25`, `docs/architecture.md:87-98`).
- The model is “optimizing” **posterior likelihood under a hand-written HMM**: step prediction supplies a forward-motion prior, magnetic stride-lag first-difference likelihoods reweight bins, turn events act as sparse landmarks/off-route evidence, and checkpoint firing is a threshold/gate on posterior tail mass. It is **not trained to directly minimize AR meter error or maximize checkpoint F1** (`analysis/grid-filter.js:295-490`, `analysis/grid-filter.js:818-829`).
- Profile building is empirical: 240 bins per anchor-to-anchor segment, magnetic mean/stddev arrays, median detected steps for stride, majority-vote turn signatures, and per-profile calibration of magnetic-difference noise and OFF likelihood (`analysis/build-profile.js:17-24`, `analysis/build-profile.js:470-523`, `analysis/build-profile.js:604-699`).
- The largest implementation mismatch I found: `transition` / `useForMatching=false` segments are marked by the profile builder, and the old `match-route.js` skips them, but the current JS and Swift grid filters still include their magnetic means in the global map and do not skip them during observation (`analysis/build-profile.js:489-508`, `analysis/grid-filter.js:220-228`, `analysis/grid-filter.js:440-458`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:96-104`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:372-405`, `analysis/match-route.js:495-507`).
- The core JS↔Swift filter math has parity tests, but important live behavior is outside those tests: live step detection, live turn detection, magnetometer-accuracy gating, terminal freeze, checkpoint ordering/debounce, confinement fire gate, off-route UI timing, and trace scoring (`survey-recorder/Tests/FilterParityTests.swift:3-8`, `analysis/make-parity-fixture.js:54-83`, `survey-recorder/project.yml:29-34`).
- Eval coverage is useful but still mostly manual/per-trace. The repo reports repeatability, checkpoint timing, P(OFF), turn logs, and AR mean/P50/P75 when ARKit is present; it does not yet provide a CI-style matrix against the documented commercial gate of ≥90% correct triggers within ±5 m across ≥3 venues / 3+ iPhones / hand+pocket (`analysis/grid-filter.js:845-907`, `docs/STATUS.md:102-104`).

## Data flow

1. **Recorder / live trace generation.**
   - Sensors are sampled at 100 Hz through Core Motion; `CMDeviceMotion` is requested in `.xMagneticNorthZVertical`, and raw magnetometer, pedometer, and barometer streams are also started (`survey-recorder/SurveyRecorder/SensorRecorder.swift:7`, `survey-recorder/SurveyRecorder/SensorRecorder.swift:26-59`).
   - Survey recording writes `dm` lines with quaternion, rotation, user acceleration, gravity, and calibrated magnetic field; raw `mag`, pedometer `step`, `baro`, optional `arpose`, and `anchor` lines are also written (`survey-recorder/SurveyRecorder/RecordingController.swift:51-84`, `survey-recorder/SurveyRecorder/RecordingController.swift:100-133`, `survey-recorder/SurveyRecorder/RecordingController.swift:136-167`, `survey-recorder/SurveyRecorder/RecordingController.swift:192-199`).
   - Session metadata includes route id, direction, device pose, pass type, checkpoints, device model, and, for live runs, `profileResource` (`survey-recorder/SurveyRecorder/SessionWriter.swift:38-56`).
   - Live runs additionally write `filter`, `turn`, `cp_fired`, and `end` lines from `LivePositioningController` (`survey-recorder/SurveyRecorder/LivePositioningController.swift:150-163`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:212-242`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:390-401`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:418-419`).

2. **Profile builder.**
   - `analysis/build-profile.js` parses JSONL, applies `anchor_undo`, and prefers calibrated `dm.mag` magnitude over raw magnetometer fallback (`analysis/build-profile.js:78-151`).
   - It splits sessions by consecutive anchors, resamples each segment to 240 fixed bins, counts user-acceleration peak steps, and stores per-segment magnetic mean/stddev, duration/steps stats, pairwise Pearson/DTW quality, and transition labels (`analysis/build-profile.js:227-244`, `analysis/build-profile.js:274-293`, `analysis/build-profile.js:443-463`, `analysis/build-profile.js:470-523`).
   - Short spans are labeled `transition` when median duration ≤4 s or median detected steps ≤5 (`analysis/build-profile.js:21-22`, `analysis/build-profile.js:489-502`).
   - Optional pocket preprocessing removes standing pauses and closes time gaps before profile building (`analysis/splice-pauses.js:1-10`, `analysis/splice-pauses.js:14-72`, `analysis/build-profile.js:753-764`).
   - Turn signatures come from gyro yaw rate projected onto gravity, clustered by direction/bin and retained only if seen in a majority of passes; ARKit arc length is preferred for turn localization when present (`analysis/turn-events.js:73-107`, `analysis/build-profile.js:527-602`).
   - Calibration is automatically fitted per profile: `diffSigmaUT` from MAD residuals at truth, `offLogLikPerPoint` from wrong-position log-likelihoods, with ARKit truth when available and anchor-interpolated truth otherwise (`analysis/build-profile.js:604-699`).

3. **Profile consumption.**
   - Swift decodes optional `turns` and `calibration` and lists bundled profiles/resources (`survey-recorder/SurveyRecorder/RouteProfile.swift:3-14`, `survey-recorder/SurveyRecorder/RouteProfile.swift:22-31`).
   - `GlobalRouteProfile` concatenates all segment arrays into one global bin axis, computes `binsPerStep = segmentBinCount / medianSteps`, creates one checkpoint decision bin per segment end, and computes a typical profile magnetic-window range for the pacing gate (`survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:52-80`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:81-140`).
   - The JS reference does the equivalent global profile construction and reads profile-carried calibration with fallback constants (`analysis/grid-filter.js:201-245`).

4. **Offline JS replay.**
   - `analysis/grid-filter.js` parses `dm` magnitude/user acceleration/yaw-rate, anchors, and AR poses; detects steps offline; builds events from steps, 1 s idle ticks, and detected turns; then replays predict/observe/decision logic (`analysis/grid-filter.js:122-162`, `analysis/grid-filter.js:174-196`, `analysis/grid-filter.js:714-839`).
   - It is also the current reporting/scoring path: checkpoint table, P(OFF), turn log, and AR meter error when possible (`analysis/grid-filter.js:845-907`).

5. **Swift live runtime.**
   - `LivePositioningController` receives live device motion, buffers magnetic magnitudes, detects turns and steps incrementally, runs `RouteBeliefFilter`, gates checkpoint firing, writes traces, and updates UI state (`survey-recorder/SurveyRecorder/LivePositioningController.swift:197-329`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:331-381`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:385-452`).

## Algorithm components

### State and prediction

- State is exact probability over every global route bin plus `pOff` (`analysis/grid-filter.js:295-308`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:150-167`).
- Initialization is a small exponential spread over the first 8 bins; there is no global localization or mid-route initialization (`analysis/grid-filter.js:298-307`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:160-167`).
- A step advances belief forward by the segment’s learned stride (`binsPerStep`) with `stepNoiseFrac=0.35`, a `kernelFloor` tail, support from one stride backward to three strides forward, and `offLeakPerStep=0.02`; route start and end are barriers (`analysis/grid-filter.js:325-400`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:189-266`).
- OFF re-entry is local: `pOff * (1-offStay)` re-enters near the **last confident mode**, not a global relocalization (`analysis/grid-filter.js:362-386`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:229-252`).
- Idle only diffuses on-route belief slightly; it is not a full standing/off-route classifier (`analysis/grid-filter.js:415-434`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:344-367`).

### Magnetic observation

- Each step uses the last `windowSteps=6` step intervals, resampled per step to the candidate segment’s bin rate (`analysis/grid-filter.js:581-614`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:331-352`).
- The live window is skipped if its magnetic magnitude range is <3 µT; Swift also skips observation when iOS reports the magnetometer `uncalibrated` (`analysis/grid-filter.js:609-611`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:298-317`).
- The likelihood is a Gaussian on **stride-lag first differences** of magnetic magnitude, not raw magnitude. It uses one homoscedastic `diffSigmaUT`; the per-bin profile stddev is stored but explicitly not used in the likelihood (`analysis/grid-filter.js:254-290`, `analysis/grid-filter.js:436-490`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:378-405`).
- Observation log-likelihoods are tempered by `obsIndependenceBins=8`; OFF likelihood is profile-calibrated `offLogLikPerPoint * 8` or fallback (`analysis/grid-filter.js:454-464`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:403-415`).
- At the terminal region, JS replay and Swift live stop applying magnetic emissions once posterior mass is essentially at the route end, to avoid post-route samples blowing up `pOff` (`analysis/grid-filter.js:779-803`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:284-297`).

### Turn observations

- Turn detector input is signed gyro rotation projected onto gravity; offline detection smooths yaw rate, groups threshold-crossing regions, and localizes a turn at half accumulated rotation (`analysis/turn-events.js:4-7`, `analysis/turn-events.js:73-107`). Swift live has a separate incremental detector intended to mirror it (`survey-recorder/SurveyRecorder/LivePositioningController.swift:563-633`).
- A live turn matches a profile turn only with same sign, angle within 55°, posterior mean within 3× turn sigma, and ≥10% on-route posterior support within 3× sigma (`analysis/grid-filter.js:500-528`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:278-303`).
- Matched turns apply a Gaussian landmark bump plus floor and multiply OFF by 0.3; unmatched turns ≥100° move 50% of on-route mass to OFF and start 8 reversal-suppression steps (`analysis/grid-filter.js:529-558`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:304-328`).
- Turn evidence is hand-pose only in JS replay (`session.meta.devicePose === 'hand'`) and user-selected hand only in live Swift (`analysis/grid-filter.js:727-735`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:250-269`).

### Checkpoint / off-route decisions

- Checkpoint decision is a posterior gate, not the posterior itself: recent observation (`stepsSinceObservation <= 2`), not reversal-active, confinement ratio ≥0.8, posterior tail mass beyond `anchor - 0.5 stride` >0.8, `pOff < 0.5`, and two consecutive updates (`analysis/grid-filter.js:739-750`, `analysis/grid-filter.js:818-829`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:403-425`).
- The confinement/pacing gate is a **decision-only** guard: live magnetic range over 8 s divided by the profile median 6-step-window range; it blocks checkpoint fires but does not change belief (`analysis/grid-filter.js:87-98`, `analysis/grid-filter.js:101-117`, `analysis/grid-filter.js:761-777`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:42-49`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:368-381`).
- JS replay computes an off-route event only when `pOff > 0.5` sustains for 3 s; Swift UI currently displays “Off route?” immediately when `pOff > 0.5`, so the live UI is not identical to JS off-route scoring (`analysis/grid-filter.js:830-835`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:440-442`).
- Swift live only considers the **next** checkpoint; JS replay keeps independent state for every checkpoint and can mark multiple checkpoint states on the same event if posterior mass jumps far enough (`survey-recorder/SurveyRecorder/LivePositioningController.swift:403-425`, `analysis/grid-filter.js:818-829`).
- UI progress is deliberately ratcheted/floored after fired checkpoints, even though the posterior itself may retreat (`survey-recorder/SurveyRecorder/LivePositioningController.swift:428-438`).

## Parameter / calibration assumptions

- **Route axis:** 240 bins per segment, independent of physical segment length (`analysis/build-profile.js:17`, `analysis/build-profile.js:375-394`). Meters only enter evaluation when ARKit ground truth exists; runtime state is bins (`analysis/grid-filter.js:619-657`).
- **Stride:** per-segment median detected survey steps; no per-user stride learning at runtime (`analysis/grid-filter.js:219-228`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:96-104`).
- **Magnetic feature:** magnitude-only first differences. This mitigates hard-iron/device bias and recalibration, but still loses vector/heading information (`analysis/grid-filter.js:254-260`).
- **Profile stddev:** stored for readability/diagnostics, but not used by the live likelihood; one fitted sigma per venue/profile is used instead (`analysis/build-profile.js:375-394`, `analysis/grid-filter.js:274-279`).
- **Calibration coupling:** `diffSigmaUT`, `offLogLikPerPoint`, and `windowSteps` are coupled; changing any without re-fitting makes OFF likelihood poorly calibrated (`analysis/grid-filter.js:38-61`, `analysis/build-profile.js:604-699`).
- **Current profile calibration snapshot:**
  - `profiles/plumeria-test-forward.json`: σ=2.556, offLL=-4.863, LOO ARKit, 3 passes (`profiles/plumeria-test-forward.json:1570-1575`).
  - `profiles/plumeria-l478-forward.json`: σ=2.84, offLL=-3.946, LOO ARKit, 3 passes (`profiles/plumeria-l478-forward.json:3132-3137`).
  - `profiles/plumeria-l478-pocket.json`: σ=2.684, offLL=-5.052, LOO anchor-interpolated, 3 passes (`profiles/plumeria-l478-pocket.json:3120-3125`).
  - `profiles/office-right-wing-forward.json`: σ=1.218, offLL=-3.418, LOO ARKit, 2 passes (`profiles/office-right-wing-forward.json:2072-2077`).
  - `profiles/office-near-lis-forward.json`: σ=2.172, offLL=-3.623, LOO ARKit, 2 passes (`profiles/office-near-lis-forward.json:3624-3629`).
  - `profiles/ravi-place-home-forward.json`: σ=3.573, offLL=-3.174, LOO ARKit, 2 passes (`profiles/ravi-place-home-forward.json:2079-2084`).
  - `profiles/meadows-test-forward.json` has no `calibration` block, so filters fall back to `FilterParams` defaults (`survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:11-14`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:137-139`).
- **Pose:** hand vs pocket is handled by separate profile metadata and user-selected live pose. Runtime does not auto-detect pocketing (`survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `survey-recorder/SurveyRecorder/SessionWriter.swift:44-47`).
- **Scope assumptions:** single-floor, no camera in end-user runtime, no arbitrary indoor blue dot, no global relocalization (`README.md:93-100`, `docs/architecture.md:171-177`, `docs/architecture.md:211-216`).

## JS ↔ Swift parity risks

What parity **does cover**:

- `FilterParityTests` drives Swift `RouteBeliefFilter` through op fixtures generated from JS (`predictStep`, `observe`, `applyUnobservedLeak`, `observeTurn`, `predictIdle`) and asserts `meanBin`, `pOff`, `probBeyond`, and periodic full belief snapshots (`survey-recorder/Tests/FilterParityTests.swift:3-8`, `survey-recorder/Tests/FilterParityTests.swift:69-101`).
- Five fixture tests currently cover Plumeria clean/pacing, L478 pacing, Ravi forward, and Ravi pacing (`survey-recorder/Tests/FilterParityTests.swift:38-57`).
- The macOS test target includes only `RouteBeliefFilter.swift`, `RouteProfile.swift`, tests, and fixtures — not `LivePositioningController.swift` (`survey-recorder/project.yml:21-34`).

What parity **does not cover / can drift**:

1. **Step detection.** JS offline step detection computes threshold over the full replay signal; Swift live uses an incremental recent-window detector (`analysis/grid-filter.js:174-195`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:635-678`). This can change event timing/count and therefore checkpoint decisions. Example trace evidence: the live Plumeria trace recorded 25 live steps, 20 magnetic updates, and a final `Bedroom exit` `cp_fired` line (`recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl:1822-1824`); JS replay recomputes its own step sequence and does not read those `cp_fired` lines.
2. **Turn detection.** Fixture generation inserts exact JS-detected turn ops; it does not feed raw gyro into Swift `LiveTurnDetector` (`analysis/make-parity-fixture.js:31-37`, `analysis/make-parity-fixture.js:71-73`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:563-633`).
3. **Controller-only gates.** Terminal freeze, magnetic uncalibrated skip, confinement fire gate, and checkpoint debounce/order are in replay/controller logic, not the core filter ops tested by parity (`analysis/grid-filter.js:779-829`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:284-317`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:403-425`).
4. **Off-route semantics.** JS has sustained off-route scoring; Swift status is immediate (`analysis/grid-filter.js:830-835`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:440-442`).
5. **Transition semantics.** `isTransition` is carried into both global profiles but not used by either filter’s observation loop; only the old segment matcher skips transitions (`analysis/grid-filter.js:220-228`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:96-104`, `analysis/match-route.js:495-507`).
6. **Live trace scorer staleness.** Old live traces contain actual `cp_fired` events from whatever app build produced them, but `analysis/grid-filter.js` ignores those and replays raw sensors with current JS code. This is useful for current-code simulation but not a faithful scorer of historical live behavior (`analysis/grid-filter.js:122-162`, `analysis/grid-filter.js:845-907`, `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl:757`, `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl:1035`, `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl:1823`).

## Scoring / eval coverage

### What the repo evaluates today

- **Repeatability / profile feasibility:** `analysis/analyze-repeatability.js` reports Pearson correlation and DTW mean deviation across repeated anchored passes (`analysis/analyze-repeatability.js:1-14`, `analysis/analyze-repeatability.js:176-180`). Profile building stores similar per-segment quality stats (`analysis/build-profile.js:397-420`, `analysis/build-profile.js:496-508`).
- **Old segment matcher:** `analysis/match-route.js` uses recorded anchors only for offline validation segmentation, matches windows by Pearson near a PDR prior, blends magnetic/PDR estimates, and reports segment MAE and optional AR meters (`analysis/match-route.js:1-12`, `analysis/match-route.js:380-429`, `analysis/match-route.js:531-607`). This is not the current live model.
- **Grid filter replay:** `analysis/grid-filter.js` reports per-checkpoint true tap / detected / delay / verdict, P(OFF), turn matches, and AR mean/P50/P75 meter error if AR poses and anchors exist (`analysis/grid-filter.js:845-907`).
- **AR ground truth:** `analysis/ground-truth.js` turns ARKit poses into horizontal arc length and segment progress (`analysis/ground-truth.js:60-120`).
- **Parity:** macOS XCTest validates core filter math against JS-generated fixtures (`survey-recorder/Tests/FilterParityTests.swift:58-103`).
- **Manual status matrix:** `docs/STATUS.md` records hand-run results across Plumeria, L478, Office, Ravi, pocket mode, pacing, reverse/out-of-order failures, and known limitations (`docs/STATUS.md:15-64`, `docs/STATUS.md:87-100`).
- **Fresh supplemental live trace:** while auditing, a new untracked Ravi live trace appeared in `recordings-new/`; its own live trace ended with `reachedCheckpoints:0` after 96 steps, which is useful evidence for the current pacing gate but is not yet reflected in `docs/STATUS.md` (`recordings-new/Ravi-place_Home_forward_hand_live_20260619-115128.jsonl:7629`, `recordings-new/Ravi-place_Home_forward_hand_live_20260619-115128.jsonl:7665`).

### What eval currently does **not** cover well

- No automated “full matrix” over all current `profiles/*.json` and `recordings-new/*.jsonl`; results in `docs/STATUS.md` are evidence, but not a CI assertion (`docs/STATUS.md:73-85`).
- No direct product-gate metric: the documented commercial gate is ≥90% correct triggers within ±5 m across ≥3 venues / 3+ iPhone models / hand+pocket, but `grid-filter.js` checkpoint verdict is ±6 seconds against anchor taps and AR meter error is reported separately over step updates, not per trigger (`analysis/grid-filter.js:858-866`, `analysis/grid-filter.js:891-903`, `docs/STATUS.md:102-104`).
- Live traces with no survey anchors are labeled as `FALSE ADVANCE` for recomputed detections because recorded `cp_fired` events are not treated as truth (`analysis/grid-filter.js:858-866`). This is already called out as a cosmetic/gap in status (`docs/STATUS.md:7-12`).
- Negative pass scoring is implicit: “no checkpoint fires” is visible in the table, but there is no separate confusion matrix for pacing/offRoute/standing, no sustained off-route precision/recall, and no cost model for false advance vs late/missed.
- Controller-level live behavior is not tested by parity: step/turn detector differences, motion-mode gating, confinement gate, terminal freeze, magnetometer accuracy gating, checkpoint order, UI ratchet, and immediate off-route UI.
- `transition` labels are not actually excluded by the grid-filter observation model, so eval statements that “transition segments are not matched” only apply to `match-route.js`, not the current baseline.
- Calibration quality is only as good as available passes/truth. Some profiles use only two passes; pocket L478 calibration is anchor-interpolated; Meadows falls back to global defaults (`profiles/office-right-wing-forward.json:2072-2077`, `profiles/plumeria-l478-pocket.json:3120-3125`, `profiles/meadows-test-forward.json`).
- Known limitations remain accepted/documented: pacing on weak/U-turn routes was mitigated by confinement gating, but live re-test status is pending in docs; reverse/mid-route/out-of-order use still false-advances because the model assumes one forward route in order (`docs/STATUS.md:89-100`).

## Concrete experiment ideas using existing scripts/data

Use `/tmp` outputs to preserve the research-only constraint.

1. **Build a current automated replay matrix.**
   - Forward/live examples:
     ```sh
     node analysis/grid-filter.js profiles/plumeria-test-forward.json recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl
     node analysis/grid-filter.js profiles/plumeria-l478-forward.json recordings-new/Plumeria_L478_forward_hand_live_20260611-125057.jsonl
     node analysis/grid-filter.js profiles/office-right-wing-forward.json recordings-new/Office_Right-wing-garden_forward_hand_live_20260619-014811.jsonl
     ```
   - Negative/limitation examples:
     ```sh
     node analysis/grid-filter.js profiles/plumeria-l478-forward.json recordings-new/Plumeria_L478_forward_hand_live_20260611-125529.jsonl
     node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl
     node analysis/grid-filter.js profiles/office-near-lis-forward.json recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
     ```
   - Record fired count, false advances, max P(OFF), off-route flag, and AR P50/P75 when present. This turns `docs/STATUS.md` into reproducible current-code evidence.

2. **Compare JS replay vs historical live trace events.**
   - Parse `filter.steps`, `filter.magUpdates`, and `cp_fired` from live JSONL, then run `analysis/grid-filter.js` on the same raw `dm` trace. This isolates offline-step-detector/current-code drift from actual recorded live behavior. The Plumeria trace cited above is a good first check (`recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl:1822-1824`).

3. **Transition ablation without source edits.**
   - Because current grid filters do not skip `transition` bins, create a temporary `/tmp/profile-transition-flattened.json` that leaves segment counts/steps intact but replaces transition magnetic means with a neutral/flat profile, then replay Office RW and Plumeria. If results change, transition magnetic evidence is materially influencing the baseline despite `useForMatching=false`.

4. **Calibration sensitivity sweep.**
   - Use the exported mutable `PARAMS` from a one-off Node script to vary `confinementFireMin`, `diffSigmaUT`, or `offLogLikPerPoint` around profile values and call `gf.replay(profile, session)`. Count checkpoint fires on forward vs pacing traces. This tests how much current behavior depends on hand-picked gates vs profile-carried calibration (`analysis/grid-filter.js:38-99`, `analysis/grid-filter.js:999`).

5. **Leave-one-out profile rebuilds to `/tmp`.**
   - Example:
     ```sh
     node analysis/build-profile.js \
       recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl \
       recordings-new/Plumeria_Test_forward_hand_normal_20260611-104347.jsonl \
       --out /tmp/plumeria-test-loo.json
     node analysis/grid-filter.js /tmp/plumeria-test-loo.json recordings-new/Plumeria_Test_forward_hand_normal_20260611-104421.jsonl
     ```
   - Repeat per route to separate in-sample/multi-pass profile quality from true held-out generalization.

6. **Run parity after any math change, but do not treat it as live parity.**
   - Existing command: `npm test` (runs XcodeGen + macOS XCTest; see `package.json:12`). For research-only inspection without rewriting fixtures, use the already-generated project if present:
     ```sh
     cd survey-recorder && xcodebuild test -project SurveyRecorder.xcodeproj -scheme FilterParityTests -destination platform=macOS -derivedDataPath build -quiet
     ```
   - If fixtures are regenerated for inspection, write to `/tmp` first:
     ```sh
     node analysis/make-parity-fixture.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-102451.jsonl /tmp/parity-ravi-pacing.json
     ```

7. **Reverse/start-guard experiments.**
   - Re-run the LIS reverse trace against the forward profile, then run the existing gait-heading exploratory script against LIS forward/reverse data:
     ```sh
     node analysis/grid-filter.js profiles/office-near-lis-forward.json recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
     node analysis/gait-heading-direction.js <fwd1.jsonl> <fwd2.jsonl> recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
     ```
   - This targets the documented “no start/direction guard” failure without changing the current filter (`docs/STATUS.md:95-100`, `analysis/gait-heading-direction.js:52-64`).

## Exact core citation index

- Product contract / scope: `README.md:17-25`, `README.md:93-100`, `docs/architecture.md:1-3`, `docs/architecture.md:205-216`.
- Recorder/session schema: `survey-recorder/SurveyRecorder/SensorRecorder.swift:7-59`, `survey-recorder/SurveyRecorder/RecordingController.swift:51-84`, `survey-recorder/SurveyRecorder/RecordingController.swift:192-234`, `survey-recorder/SurveyRecorder/SessionWriter.swift:38-56`.
- Profile builder: `analysis/build-profile.js:17-24`, `analysis/build-profile.js:78-151`, `analysis/build-profile.js:470-523`, `analysis/build-profile.js:527-602`, `analysis/build-profile.js:604-699`, `analysis/build-profile.js:742-793`.
- Turn extraction: `analysis/turn-events.js:15-20`, `analysis/turn-events.js:73-107`.
- JS filter core: `analysis/grid-filter.js:38-99`, `analysis/grid-filter.js:201-245`, `analysis/grid-filter.js:254-290`, `analysis/grid-filter.js:295-578`, `analysis/grid-filter.js:581-614`, `analysis/grid-filter.js:714-839`, `analysis/grid-filter.js:845-907`.
- Swift filter/controller: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:11-50`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:52-140`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:150-448`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:197-452`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:563-678`.
- Parity: `analysis/make-parity-fixture.js:1-12`, `analysis/make-parity-fixture.js:54-95`, `survey-recorder/Tests/FilterParityTests.swift:3-103`, `survey-recorder/project.yml:21-34`.
- Eval/ground truth: `analysis/analyze-repeatability.js:1-14`, `analysis/match-route.js:1-12`, `analysis/match-route.js:380-429`, `analysis/match-route.js:531-607`, `analysis/ground-truth.js:60-120`, `docs/STATUS.md:35-37`, `docs/STATUS.md:87-104`.
