# Adversarial weakness audit — problem / eval / baseline

Scope note: the requested root `plan.md` and `progress.md` were not present in `/Users/alpesh/codebase/indoor-positioning` during this audit, so I audited the repo code, docs, profiles, and `recordings-new/` directly. I did not modify project/source files; this markdown file is the requested output artifact.

## TL;DR

The current prototype is honest about being a **known-start, ordered-route checkpoint trigger**, but the current eval can still give false confidence because it mostly tests that exact happy path. The sharpest adversarial finding is a **current JS replay vs Swift live mismatch**: JS replay now freezes belief during confinement/pacing, while Swift live still advances the filter and only freezes display/blocks fires. That means the replay matrix can say pacing is closed while a real app run may accumulate hidden progress and fire after the confinement window clears.

Other high-risk gaps: reverse/out-of-order/mid-route use still false-advances; explicit negative data is nearly absent; several profiles are evaluated with only 2 clean passes or with fixed profiles containing the evaluated source pass; pocket/hand carry is manually selected and confounded in the Office data; OFF re-entry only supports local recovery; and parity tests cover only the core filter ops, not the live controller, detectors, gating, or checkpoint decision behavior.

## Ranked weaknesses

### 1. Critical — Current JS replay can pass pacing evals while Swift live still has hidden-progress behavior

**Why this can pass current evals but fail real use**

The replay path now treats low-confinement pacing steps as idle and does not advance belief (`analysis/grid-filter.js:793-803`). The Swift live path still calls `filter.predictStep()` on every walking step before magnetic observation (`survey-recorder/SurveyRecorder/LivePositioningController.swift:280-317`), and later only blocks checkpoint fires/freezes display when `confined` is true (`LivePositioningController.swift:385-390`, `LivePositioningController.swift:407-416`, `LivePositioningController.swift:439-445`). The code comment in Swift explicitly says “the belief still marches on step count” (`LivePositioningController.swift:387-389`).

This is not covered by the parity tests: the macOS test target includes `RouteBeliefFilter.swift`, `RouteProfile.swift`, fixtures, and tests only, not `LivePositioningController.swift` (`survey-recorder/project.yml:25-34`). The fixture generator drives raw `predictStep`/`observe` ops and has no confinement decision logic (`analysis/make-parity-fixture.js:54-70`).

**Evidence**

- JS replay freezes low-confinement steps with `predictIdle`: `analysis/grid-filter.js:793-803`.
- Swift live always calls `filter.predictStep()` for detected walking steps, then observes/leaks: `survey-recorder/SurveyRecorder/LivePositioningController.swift:280-317`.
- Swift confinement only gates firing/display: `survey-recorder/SurveyRecorder/LivePositioningController.swift:385-390`, `:407-416`, `:439-445`.
- Parity scope excludes controller/gates: `survey-recorder/project.yml:25-34`, `survey-recorder/Tests/FilterParityTests.swift:3-8`.
- Historical live pacing traces did fire under an earlier build: `recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl:2375`, `:2478`, end reached 2 checkpoints at `:5453`. Current JS replay of that same trace now reports 0 fires, so historical live output and current replay already diverge as artifacts.

**Suggested tests to expose it**

1. Add a Swift controller-level replay/simulation test that feeds `dm` samples into `LivePositioningController` logic, not just `RouteBeliefFilter` ops. Assert the same checkpoint fires as `analysis/grid-filter.js` for all pacing/resume traces.
2. Specific adversarial live test: pace in place for 20–40 s, then walk forward after the confinement window clears. Expected: no stored-progress checkpoint burst. Current Swift code is suspicious because the hidden belief can march while display/firing are gated.
3. Regenerate parity fixtures only after deciding whether the product behavior should be “freeze belief” or “only gate fires,” then make JS and Swift implement the same policy.

**Likely false confidence in current metrics**

Very high. Any “all pacing → 0 fires” claim from `analysis/grid-filter.js` may not describe the installed app until this controller-level mismatch is closed.

---

### 2. Critical — Route-order / known-start assumption lets reverse, out-of-order, and mid-route users false-advance

**Why this can pass current evals but fail real use**

The filter initializes at the first route bins (`analysis/grid-filter.js:295-307`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:160-166`) and step prediction has a forward-stride prior (`analysis/grid-filter.js:325-340`, `RouteBeliefFilter.swift:189-224`). The architecture explicitly says checkpoints fire in route order (`docs/architecture.md:130-137`). That matches a guided route started at the entrance, but fails if a user enters mid-route, walks backward, visits rooms out of order, or takes shortcuts.

**Evidence**

- Code starts at route start: `analysis/grid-filter.js:299-306`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:160-166`.
- Code advances steps by positive stride: `analysis/grid-filter.js:325-340`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:189-224`.
- Docs state checkpoints fire in route order and the state is 1D route-only: `docs/architecture.md:124-137`.
- STATUS documents the exact limitation and failed magnetic/compass guard attempts: `docs/STATUS.md:95-100`.
- Verified replay: `node analysis/grid-filter.js profiles/office-near-lis-forward.json recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl` fired Checkpoint 2–6 on a reverse/misuse trace, with max `P(OFF)=0.37` and no off-route flag. The trace metadata is live/forward-profile at `recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl:1`; historical live fires are at `:1268`, `:2046`, `:2698`, `:2886`, `:3096`.
- Verified replay: `node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-100523.jsonl` fired Balcony and Kitvhen on an out-of-order trace; metadata at `recordings-new/Ravi-place_Home_forward_hand_live_20260619-100523.jsonl:1`, historical live fires at `:2020`, `:2327`.

**Suggested tests to expose it**

1. Add a negative suite with expected **zero fires** for reverse route, mid-route start, and out-of-order room visits for every bundled profile.
2. Add “start not armed” scenarios: begin at each non-start checkpoint and walk forward; no checkpoint should fire until an explicit entrance/absolute cue or manual start confirmation occurs.
3. Add a route-direction acceptance metric separate from route-completion: false route-order fires are worse than late/manual fallback.

**Likely false confidence in current metrics**

High. Clean forward walks can show excellent P50/P75 and 100% checkpoint completion while the system still silently advances the tour in the wrong physical order.

---

### 3. High — Negative examples are too sparse and under-labeled to validate false-advance behavior

**Why this can pass current evals but fail real use**

The schema supports deliberate negatives (`pacing`, `offRoute`, `standing`) and says the matcher should fail them on purpose (`survey-recorder/SurveyRecorder/Models.swift:18-25`). In the current `recordings-new/` inventory I found only one explicit `passType="pacing"` file and no explicit `offRoute` or `standing` pass types. STATUS also lists off-route and standing passes as pending (`docs/STATUS.md:64`, `docs/STATUS.md:85`). Several negative scenarios are hidden inside `passType=live` traces and docs, which makes them easy to omit or mis-score.

**Evidence**

- Negative schema exists: `survey-recorder/SurveyRecorder/Models.swift:18-25`.
- Only explicit pacing negative found: `recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl:1`.
- STATUS says off-route/standing negatives are still pending: `docs/STATUS.md:64`, `docs/STATUS.md:85`.
- The replay scorer uses recorded anchors as truth; live traces without anchors are not ground-truth negatives unless a manifest says so (`analysis/grid-filter.js:856-877`).

**Suggested tests to expose it**

1. Record at least one `offRoute` and one `standing` session per major route/profile, with ARKit or manual notes for where the user is relative to route.
2. Move known negative live traces (`Ravi ...100523`, `...102451`, `...105724`, LIS reverse `...031803`, L478 pacing `...125529`) into an eval manifest with explicit expected outcome: zero checkpoint fires until genuine re-entry.
3. Add confusion-matrix metrics: false fires/session, time to first false fire, sustained `P(OFF)` detection delay, false off-route during clean walks.

**Likely false confidence in current metrics**

High. A small pacing gate can pass all available explicit negatives while failing true off-route, standing-with-phone-motion, wrong-start, wrong-profile, or re-entry behavior.

---

### 4. High — Fixed-profile evaluation risks profile/source leakage and 2-pass overconfidence

**Why this can pass current evals but fail real use**

Checked-in profiles store the source sessions used to build the magnetic mean arrays (`analysis/build-profile.js:512-523`). If a replay uses the same checked-in profile against one of its `sourceFiles`, the magnetic fingerprint and calibration have seen that pass. The docs also say the replay harness gap includes leave-one-out rotation (`docs/STATUS.md:9-10`). Survey practice warns that 2-pass profiles cannot provide honest LOO because each fold leaves only a 1-pass profile (`docs/SURVEY-PRACTICE.md:42-47`).

Several current production-like profiles are only 2-pass: Office right wing (`profiles/office-right-wing-forward.json:10-13`, calibration `:2072-2077`), Office Near LIS (`profiles/office-near-lis-forward.json:10-13`, `:3624-3629`), and Ravi Home (`profiles/ravi-place-home-forward.json:10-13`, `:2079-2084`).

**Evidence**

- Profile builder embeds `sourceFiles`: `analysis/build-profile.js:512-523`.
- Calibration is fitted from the same input files via internal leave-one-out, but the final checked-in profile still includes all input passes: `analysis/build-profile.js:604-699`, `:776-783`.
- `profiles/plumeria-test-forward.json` includes the 3 clean source files at `:11-15`; calibration says 3-pass ARKit LOO at `:1570-1575`.
- Office/Ravi/LIS profile source lists show only 2 passes: `profiles/office-right-wing-forward.json:10-13`, `profiles/office-near-lis-forward.json:10-13`, `profiles/ravi-place-home-forward.json:10-13`.
- Survey guidance: 3 clean passes are required for honest validation; 2-pass LOO is degenerate (`docs/SURVEY-PRACTICE.md:42-47`).

**Suggested tests to expose it**

1. Eval harness must assert `session.basename ∉ profile.sourceFiles` for any claim labeled held-out.
2. For every route with ≥3 clean passes, rebuild `/tmp` LOO profiles per fold and replay only the held-out pass.
3. For 2-pass routes, report “smoke only / not acceptance-grade,” and require a third reuse pass before accepting commercial metrics.
4. Include cross-day/cross-device holdout once data exists; source-file exclusion alone does not prevent same-day/same-surveyor coupling.

**Likely false confidence in current metrics**

Medium-high. In-sample/fixed-profile replays can make magnetic matching, calibration, turn signatures, and checkpoint timing look more stable than they will be on a new user/device/day.

---

### 5. High — Live traces lack independent truth; `cp_fired` is app output, not correctness

**Why this can pass current evals but fail real use**

Most live traces have `groundTruth:false` and no anchor taps. The replay scorer labels any detected live checkpoint without a truth anchor as `FALSE ADVANCE` (`analysis/grid-filter.js:868-877`), while STATUS calls that cosmetic for ungraded live runs (`docs/STATUS.md:9-10`). Conversely, counting historical `cp_fired` lines as success is also unsafe because those are app outputs from whatever build produced the trace.

**Evidence**

- Session metadata records `groundTruth` and `profileResource`, but live runs normally write `groundTruth:false`: `survey-recorder/SurveyRecorder/SessionWriter.swift:38-56`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:153-163`.
- Scorer treats missing truth anchor as `FALSE ADVANCE`: `analysis/grid-filter.js:868-877`.
- STATUS notes live-trace false-advance labels are cosmetic/ungraded: `docs/STATUS.md:9-10`.
- Example: Office right-wing live replay prints four `FALSE ADVANCE` rows even STATUS says the live hand walk was validated 4/4 (`docs/STATUS.md:41-45`); metadata for that live trace is `recordings-new/Office_Right-wing-garden_forward_hand_live_20260619-014811.jsonl:1` and historical `cp_fired` outputs are `:594`, `:1395`, `:1839`, `:2189`.

**Suggested tests to expose it**

1. Eval manifest must distinguish `live_positive_ungraded`, `live_negative`, `survey_gt`, and `historical_app_output`.
2. For live positives, collect independent truth: manual observer tap, ARKit surveyor mode when feasible, or a post-run annotation file.
3. Report historical `cp_fired` and current JS replay results side-by-side, but never treat either as truth by itself.

**Likely false confidence in current metrics**

Medium-high. The same trace can be called a success in STATUS, a `FALSE ADVANCE` in replay, or a regression depending on whether app output or independent truth is used.

---

### 6. High — Hand/pocket carry confounds are not controlled; runtime pose is manual and profile pose can mismatch actual carry

**Why this can pass current evals but fail real use**

Pocket handling is explicitly pose-specific. Turn evidence is disabled for pocket in JS based on session metadata (`analysis/grid-filter.js:727-735`) and in Swift based on a user-selected `livePose` (`survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `:250-269`). The UI says runtime cannot detect pocketing and exposes a manual Hand/Pocket picker that is disabled during a run (`survey-recorder/SurveyRecorder/Views/LivePositioningView.swift:221-234`).

The profile picker is independent of the carry picker (`LivePositioningView.swift:4-64`), so a user can select a hand profile with Pocket carry or a pocket profile with Hand carry. Office right wing is especially confounded: the profile metadata is `devicePose:"pocket"` (`profiles/office-right-wing-forward.json:4-13`), but STATUS says the phone was visibly held and live validation was hand (`docs/STATUS.md:41-45`); the survey meta says pocket (`recordings-new/Office_Right-wing-garden_forward_pocket_normal_20260619-013707.jsonl:1`) while live meta says hand (`recordings-new/Office_Right-wing-garden_forward_hand_live_20260619-014811.jsonl:1`).

**Evidence**

- Runtime cannot auto-detect pocketing: `survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `survey-recorder/SurveyRecorder/Views/LivePositioningView.swift:221-234`.
- JS turn evidence key is session pose, not profile pose: `analysis/grid-filter.js:727-735`.
- Profile list contains separate hand/pocket resources but no enforcement coupling: `survey-recorder/SurveyRecorder/RouteProfile.swift:22-31`, `LivePositioningView.swift:4-64`.
- Pocket profile calibration uses anchor-interpolated truth, not ARKit: `profiles/plumeria-l478-pocket.json:3120-3125`.
- Office pose-tag confound documented: `docs/STATUS.md:41-45`.

**Suggested tests to expose it**

1. Full pose matrix per route: hand-profile/hand-carry, hand-profile/pocket-carry, pocket-profile/pocket-carry, pocket-profile/hand-carry; expected wrong combinations should not silently complete.
2. Add an app warning when `profile.route.devicePose` disagrees with selected `livePose`, unless explicitly allowed by manifest.
3. Record true pocket + hand + bag data on at least two routes and devices; current schema supports `bag` (`survey-recorder/SurveyRecorder/Models.swift:10-14`) but current profile/data does not validate it.
4. Add a lightweight carry-mode classifier or at least post-run diagnostics to detect obvious mismatches.

**Likely false confidence in current metrics**

High for production. Lab users can select the right pose/profile; real users may not, and the data already contains a survey/live pose mismatch that still “passes” in status.

---

### 7. High — OFF state and re-entry only cover local recovery; distant re-entry and detours are untested

**Why this can pass current evals but fail real use**

The OFF model is local: re-entry is centered on the last confident on-route mode (`analysis/grid-filter.js:362-383`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:229-249`). Architecture docs explicitly say there is no global relocalization after jumping to a distant segment (`docs/architecture.md:171-177`, `:211-216`). That is fine for brief detours but not for “leave route at A, re-enter at D,” wrong entrance, elevator/stair repositioning, or shortcut paths.

**Evidence**

- JS local re-entry kernel: `analysis/grid-filter.js:362-383`.
- Swift local re-entry kernel: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:229-249`.
- Docs state no arbitrary/distant global relocalization: `docs/architecture.md:171-177`, `docs/architecture.md:211-216`.
- Out-of-order replay did not sustain off-route: Ravi `...100523` reached max `P(OFF)=0.50` but no off-route flag in current JS replay; route-order limitation documented at `docs/STATUS.md:95`.

**Suggested tests to expose it**

1. Record explicit `offRoute` sessions: leave the route, walk in a nearby room/corridor for 20–60 s, re-enter at a later checkpoint.
2. Required behavior should be product-defined: either remain `OFF` until manual fallback, or relocalize only after a strong absolute cue. Do not silently resume at stale route order.
3. Add negative tests for physically adjacent magnetic impostors and repeated corridors.

**Likely false confidence in current metrics**

Medium-high. Clean-route metrics do not measure the most important safety behavior: refusing to make claims after a real detour.

---

### 8. Medium-high — Transition / weak-segment semantics are inconsistent with the current grid filter

**Why this can pass current evals but fail real use**

The profile builder labels short spans as `transition` and `useForMatching:false` (`analysis/build-profile.js:489-502`). However, the grid filters still concatenate every segment’s magnetic means into the global map (`analysis/grid-filter.js:207-228`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:86-104`) and the observation loop scores every bin without skipping transition segments (`RouteBeliefFilter.swift:386-404`; JS equivalent `analysis/grid-filter.js:440-458` in the observe implementation). That means current evals may rely on transition/weak magnetic evidence or dead-reckoning over transition-heavy routes despite the metadata implying those spans are not distinctive.

**Evidence**

- Builder transition classification and `useForMatching:false`: `analysis/build-profile.js:489-502`.
- Global profiles retain transition segments and bins: `analysis/grid-filter.js:220-228`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:96-104`.
- Swift observation scores all bins/segments without checking `isTransition`: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:386-404`.
- Office profile has transition segments at `profiles/office-right-wing-forward.json:1060` and `:1567`; STATUS says half the segments are transitions and the back half is a soft spot (`docs/STATUS.md:41-45`).

**Suggested tests to expose it**

1. Add a “transition ablation” eval: replay with transition segment magnetic means flattened or observation skipped, and compare checkpoint fires/false advances.
2. Require profile QA to report percent of route bins/steps in transition and to downgrade acceptance if many checkpoints depend on transitions.
3. Add off-route/cross-route specificity tests concentrated in transition-heavy sections.

**Likely false confidence in current metrics**

Medium. A short route can pass by route-order/dead-reckoning and checkpoint spacing while not having enough distinctive signal to reject wrong movement.

---

### 9. Medium-high — JS↔Swift parity proves only core math, not live behavior where most failures happen

**Why this can pass current evals but fail real use**

Even ignoring the specific confinement mismatch in item 1, parity fixtures are op-level tests for `RouteBeliefFilter` only. They do not validate live step detection, live turn detection, terminal freeze, magnetometer-accuracy gating, pose gating, checkpoint order/debounce, sustained off-route timing, UI/display ratchets, or trace scoring.

**Evidence**

- Test comment: parity drives `RouteBeliefFilter` through ops generated from JS and asserts posterior matches (`survey-recorder/Tests/FilterParityTests.swift:3-8`).
- Fixture operations are just `predictStep`, `observe`, `applyUnobservedLeak`, `observeTurn`, and `predictIdle` (`FilterParityTests.swift:69-82`).
- Fixture generator uses offline full-trace step detection and raw turn detection, not live incremental detectors (`analysis/make-parity-fixture.js:28-37`, `:54-82`).
- JS offline step detector uses whole-replay median/MAD (`analysis/grid-filter.js:174-196`), while Swift live step detector uses a rolling recent window (`survey-recorder/SurveyRecorder/LivePositioningController.swift:648-690`).
- Live turn detector is a separate Swift implementation (`LivePositioningController.swift:576-645`).

**Suggested tests to expose it**

1. Add a controller-level deterministic replay harness in Swift that ingests JSONL `dm` samples and asserts checkpoints/status events.
2. Export live step/turn events from Swift and compare against JS offline events on the same traces, with allowed timing/count tolerances.
3. Add tests specifically for magnetometer `.uncalibrated`, terminal region freeze, pocket pose turn disabling, checkpoint consecutive debounce, and sustained `P(OFF)` semantics.

**Likely false confidence in current metrics**

Medium-high. `npm test` can pass while the app’s live decisions differ from JS replay in exactly the gates that prevent false advances.

---

### 10. Medium — Current coverage is below the documented commercial gate and device/venue diversity is thin

**Why this can pass current evals but fail real use**

The commercial gate requires ≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand and pocket carry (`docs/research/SYNTHESIS.md:38-40`, `docs/STATUS.md:102-104`). Current `recordings-new/` metadata has two device models in the inspected inventory (`iPhone14,5` and `iPhone16,2`), pocket is mostly Plumeria L478, and several non-home profiles are 2-pass smoke only.

**Evidence**

- Commercial gate: `docs/research/SYNTHESIS.md:38-40`, `docs/STATUS.md:102-104`.
- Session metadata includes device model and pose: `survey-recorder/SurveyRecorder/SessionWriter.swift:38-56`.
- Representative device/pose data: Plumeria clean hand `iPhone14,5` at `recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl:1`; Office/Ravi/LIS traces use `iPhone16,2` or `iPhone14,5` at `recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl:1`, `recordings-new/Ravi-place_Home_forward_hand_live_20260619-100523.jsonl:1`.
- 2-pass profiles: `profiles/office-right-wing-forward.json:10-13`, `profiles/office-near-lis-forward.json:10-13`, `profiles/ravi-place-home-forward.json:10-13`.

**Suggested tests to expose it**

1. Eval report must stratify by venue, route, phone model, pose, survey/live, and pass type.
2. Do not aggregate pocket and hand; do not aggregate 2-pass smoke with 3-pass acceptance-grade routes.
3. Add at least one more iPhone model and pocket data outside Plumeria before claiming commercial-level robustness.

**Likely false confidence in current metrics**

Medium. Current metrics are useful prototype evidence, but not evidence of production robustness across devices, carrying styles, or venues.

## Cross-cutting test suite that would make these weaknesses visible

1. **Manifest-first eval.** Add an eval manifest that declares profile, session, scenario label, expected outcome, independent truth availability, and whether the session is in the profile source list.
2. **Acceptance-grade LOO.** For all routes with ≥3 clean passes, rebuild temp profiles per fold and assert trigger error in meters when ARKit truth exists.
3. **Negative suite.** Require zero checkpoint fires for pacing, standing, off-route, reverse, mid-route start, out-of-order, wrong-profile, and pose-mismatch cases.
4. **Controller parity.** Run JSONL through JS replay and Swift live-controller logic; compare checkpoint events, `pOff`, status, step counts, turn events, and confinement behavior.
5. **Profile QA.** Fail/downgrade profiles with <3 clean passes, weak segments (`r < ~0.85`), too many transition segments, no negative coverage, or unsupported pose/device combinations.

## Bottom line

Current clean-route results are promising, but the current eval can overstate readiness because it mostly validates “correct profile, correct pose, start at first anchor, walk ordered route.” The highest-priority fix is to close the JS/Swift live-controller mismatch around confinement/pacing, then build a manifest-driven eval that treats reverse/out-of-order/off-route/pose-mismatch traces as first-class negative tests rather than anecdotes.
