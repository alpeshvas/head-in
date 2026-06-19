# TL;DR

Scope note: the requested `/Users/alpesh/codebase/indoor-positioning/context.md` file was not present, so this roadmap is based on the repo README, docs, source, profiles, and recordings inspected directly. The project is already a route-constrained checkpoint/zone-confidence prototype, not a blue-dot system: survey recorder, JSONL sessions, profile builder, JS replay filter, Swift live filter, OFF state, turn anchors, per-venue calibration, and pocket-profile support are all implemented. The next highest-value work is not another broad estimator rewrite; it is (1) closing the in-place pacing gate with live validation and regression coverage, (2) building a one-command scorecard aligned to the commercial gate, and (3) collecting the missing negative/device/pose data needed to know what actually fails.

Key current facts:
- Product target: route/checkpoint/zone confidence, not arbitrary indoor GPS (`README.md:17-25`, `README.md:93-100`, `docs/architecture.md:205-216`).
- Current architecture: 1-D route grid Bayes filter plus OFF state; checkpoint fires require posterior mass past the decision bin, recent observation, low `pOff`, no reversal, and debounce (`docs/STATUS.md:35-37`, `analysis/grid-filter.js:714-832`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:385-456`).
- Strong validated cases exist: Plumeria short route 3/3 with P50 0.22 m / P75 0.71 m, L478 hand after differenced emission P75 0.72 m, Office right wing live 4/4 twice, and L478 pocket live 6/6 once (`docs/STATUS.md:15-29`, `docs/STATUS.md:39-61`).
- Main unresolved product/design holes: route-order/reverse/mid-route misuse, validation breadth below commercial gate, sparse off-route/standing negatives, user-selected carry pose, and a controller-level pacing gate that is offline-validated but needs live re-test/coverage (`docs/STATUS.md:64-104`).
- Commercial gate: ≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand and pocket carry, with false advances low enough that manual fallback remains a fallback (`docs/research/SYNTHESIS.md:38-40`, `docs/STATUS.md:102-104`).

# Top 10 Ranked Bets

## 1. Close the in-place pacing gate live and lock it into regression coverage

**Type:** quick win / highest immediate false-advance reduction.

**Hypothesis:** The current venue-normalized confinement gate is the best near-term fix for pacing false advances: it blocks checkpoint firing when steps occur but magnetic range remains confined, while leaving belief/tracking untouched and preserving forward walks.

**Code areas:**
- `analysis/grid-filter.js` — `confinementWindowSec`, `confinementFireMin`, `profileTypicalWindowRange()`, replay fire gate (`analysis/grid-filter.js:87-103`, `analysis/grid-filter.js:766-825`).
- `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` — matching constants and profile `typicalWindowRange` (`RouteBeliefFilter.swift:42-49`, `RouteBeliefFilter.swift:76-128`).
- `survey-recorder/SurveyRecorder/LivePositioningController.swift` — live `confinementRatio`, display freeze, checkpoint block, “Holding position” status (`LivePositioningController.swift:373-456`).
- `survey-recorder/Tests/FilterParityTests.swift` — filter parity exists, but this gate is controller-level and needs separate coverage (`FilterParityTests.swift:1-86`).

**Data needed:**
- Existing negatives: `recordings-new/Ravi-place_Home_forward_hand_live_20260619-102451.jsonl`, `recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl`, `recordings-new/Plumeria_L478_forward_hand_live_20260611-125529.jsonl`, `recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl`.
- Existing forward controls: Plumeria Test/L478/Office right wing/Ravi forward traces.
- One new post-gate live pacing trace on Ravi-place or L478. The old Ravi long-pacing live trace still contains recorded historical false fires at `recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl:2375` and `:2478`; use a new trace to verify the installed build, not those old `cp_fired` lines.

**Eval command / metric:**
- Replay matrix: `node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl` and equivalent for L478/Test/Ravi forward controls.
- Swift parity after any filter math change: `npm test` (`package.json:13`).
- Acceptance: all pacing/confined traces produce 0 replay fires; forward controls keep their previous checkpoint counts and P50/P75; new live post-gate trace has 0 `cp_fired` events during pacing and no misleading displayed progress.

**Expected impact:** High. This directly targets the highest-cost false-advance class documented in Ravi/L478 while preserving the current route-filter design.

**Risk:** Medium-low. The documented caveat is an ~8 s suppression tail after pacing resumes, and the gate is not covered by filter parity because it lives in controller/replay decision logic (`docs/STATUS.md:89-94`).

**Citations:** `docs/STATUS.md:87-94`, `analysis/grid-filter.js:96-103`, `analysis/grid-filter.js:766-825`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:373-456`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:42-49`.

---

## 2. Build a one-command replay scorecard aligned to the commercial gate

**Type:** quick win / evaluation infrastructure.

**Hypothesis:** The repo has the core replay pieces, but evaluation is still too manual and not exactly aligned to the product gate. A matrix runner that classifies sessions, replays them, and reports trigger accuracy/false advances/off-route delay will speed every subsequent research bet and prevent regressions.

**Code areas:**
- New: `analysis/eval-matrix.js` or `analysis/scorecard.js`.
- Reuse exports from `analysis/grid-filter.js` (`analysis/grid-filter.js:999`).
- Reuse script wiring in `package.json` (`package.json:7-13`).
- Reuse `analysis/analyze-repeatability.js` for segment quality and `analysis/ground-truth.js` for ARKit arc-length truth.

**Data needed:**
- All profiles under `profiles/*.json` and app-bundled profile list (`survey-recorder/SurveyRecorder/RouteProfile.swift:22-30`).
- All `recordings-new/*.jsonl`, grouped by `meta.passType`, route/profile, device model, carry pose, and whether ARKit truth is available.
- Explicit negative labels for pacing/offRoute/standing/reverse/out-of-order sessions.

**Eval command / metric:**
- New command to implement: `node analysis/eval-matrix.js --matrix analysis/eval-matrix.json --out analysis/scorecard.html`.
- Metrics: checkpoint trigger rate within ±5 m when ARKit truth exists, checkpoint trigger delay vs taps, false advances per negative session, off-route detection delay/false alarms, P50/P75 along-route error, coverage by venue/device/pose.
- Keep `node analysis/grid-filter.js <profile> <session> [--out html] [--calibrate]` as per-session drill-down (`docs/STATUS.md:73-77`, `analysis/grid-filter.js:845-903`).

**Expected impact:** High. Converts “promising prototype” into measurable research iteration and maps directly to the commercial gate.

**Risk:** Low-medium. Live traces without truth currently get confusing labels; status calls the live `FALSE ADVANCE` scorer issue cosmetic, so the matrix must avoid treating every live replay fire as a true false advance unless the trace is a labeled negative/reverse/out-of-order (`docs/STATUS.md:9-12`).

**Citations:** `docs/STATUS.md:9-12`, `docs/STATUS.md:73-85`, `analysis/grid-filter.js:845-903`, `analysis/grid-filter.js:999`, `package.json:7-13`, `docs/research/SYNTHESIS.md:38-40`.

---

## 3. Collect the missing validation data before tuning more parameters

**Type:** quick win / data bet.

**Hypothesis:** The biggest blocker to deciding what to build next is validation breadth, not lack of filter sophistication. The recorder already supports the needed pass types; the missing pieces are off-route/standing negatives, more pocket passes, 3-pass profiles for thin routes, and a third iPhone model.

**Code areas:**
- Mostly no code; use `survey-recorder/` as-is.
- `survey-recorder/SurveyRecorder/Models.swift` already defines `normal`, `pacing`, `offRoute`, `standing`, and `live` pass types (`Models.swift:18-39`).
- `RecordingController` records device motion, raw mag, pedometer, barometer, anchors, ARKit poses, and final checkpoints (`RecordingController.swift:43-169`, `RecordingController.swift:235-253`).
- `analysis/build-profile.js`, `analysis/analyze-repeatability.js`, and `analysis/grid-filter.js` process the data.

**Data needed:**
- At least one `offRoute` and one `standing` negative per major profile.
- Post-gate live pacing re-test on Ravi-place and/or L478.
- Third clean pass for two-pass profiles: Office right wing, Office-Near LIS, Ravi-place (`profiles/office-right-wing-forward.json:9-13`, `profiles/office-near-lis-forward.json:9-13`, `profiles/ravi-place-home-forward.json:9-13`).
- More true pocket surveys/live runs outside Plumeria L478; Office right wing is tagged `pocket` but was visibly held, per status (`docs/STATUS.md:39-45`).
- Third iPhone model; current inspected meta examples include `iPhone14,5` and `iPhone16,2`, while the commercial gate requires 3+ models (`recordings-new/Plumeria_Test_forward_hand_normal_20260611-104347.jsonl:1`, `recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030752.jsonl:1`, `docs/STATUS.md:102-104`).

**Eval command / metric:**
- `npm run analyze -- <3 clean sessions> --out analysis/<route>-repeatability.html`.
- `npm run build-profile -- <3 clean sessions> --out profiles/<route>.json`.
- `node analysis/grid-filter.js profiles/<route>.json recordings-new/<heldout-or-live>.jsonl --out analysis/<route>-replay.html`.
- Acceptance: ≥3 clean passes per shippable profile, segment `r >= ~0.85` where possible, 0 fires on standing/off-route/pacing negatives, no regression on normal live walks.

**Expected impact:** High. This is required to know whether current code is enough for guided routes and to avoid optimizing against too few traces.

**Risk:** Medium. Survey logistics, ARKit tracking quality, and consistency of path/pose can dominate results.

**Citations:** `survey-recorder/SurveyRecorder/Models.swift:18-39`, `docs/STATUS.md:64-85`, `docs/STATUS.md:102-104`, `docs/SURVEY-PRACTICE.md:42-86`, `profiles/office-right-wing-forward.json:9-13`, `profiles/office-near-lis-forward.json:9-13`, `profiles/ravi-place-home-forward.json:9-13`.

---

## 4. Add profile QA gates and survey feedback before accepting a route

**Type:** quick win / productized research workflow.

**Hypothesis:** Many failures are survey/route-quality failures: long open-space legs and weak repeatability should trigger resurvey or added checkpoints, not filter tweaks. A profile QA report can catch this before a route is bundled.

**Code areas:**
- Extend `analysis/analyze-repeatability.js` output and/or add `analysis/profile-qa.js`; it already reports per-segment r, DTW, and verdict (`analysis/analyze-repeatability.js:287-307`).
- Extend `analysis/build-profile.js` to fail/warn on weak segments, too few passes, too-long checkpoint gaps, and overuse of transition segments; transition classification is currently duration ≤4 s or steps ≤5 (`analysis/build-profile.js:21-22`, `analysis/build-profile.js:489-521`).
- Optional app-side feedback in `survey-recorder/SurveyRecorder/Views/SessionsView.swift` or a separate desktop report.

**Data needed:**
- Good/bad LIS surveys, Office right wing short transition-heavy route, Ravi-place pass 1 vs reuse passes, existing Plumeria/L478 strong controls.
- Minimum policy encoded from survey practice: checkpoint every ~5–15 steps, ≥3 clean passes, exclude slow ad-hoc bootstrap pass from final profile, target `r >= ~0.85` (`docs/SURVEY-PRACTICE.md:8-86`).

**Eval command / metric:**
- `npm run analyze -- recordings-new/<route>_normal_*.jsonl --out analysis/<route>-repeatability.html`.
- New acceptance gate: `node analysis/profile-qa.js profiles/<route>.json --sessions <sessions...>` exits nonzero or emits “needs resurvey” when any segment has weak repeatability, only 2 passes, long open leg, or too many transitions before a checkpoint.
- Metric: weak segment count, transition-only span count, expected checkpoint spacing, and subsequent live completion rate.

**Expected impact:** High for field reliability. It prevents burning engineering time on physically weak routes.

**Risk:** Medium-low. Over-strict gates can block routes that are acceptable with more checkpoints or product fallback; output should recommend resurvey actions, not just fail.

**Citations:** `docs/SURVEY-PRACTICE.md:8-86`, `analysis/analyze-repeatability.js:287-307`, `analysis/build-profile.js:21-22`, `analysis/build-profile.js:489-521`, `docs/STATUS.md:39-45`.

---

## 5. Add explicit start/entrance arming via product flow or absolute cue, not magnetic-only

**Type:** medium implementation bet / false-advance guard.

**Hypothesis:** Reverse and mid-route false advances are caused by missing start/direction evidence. The safest near-term fix is to make “Start at the entrance” an explicit product contract and optionally support an absolute entrance cue (QR/NFC/GPS near semi-outdoor starts), rather than relying on magnetic-only start confirmation.

**Code areas:**
- `survey-recorder/SurveyRecorder/LivePositioningController.swift` already tells users to stand at the first anchor and tap Start/Reset (`LivePositioningController.swift:103-104`).
- `analysis/grid-filter.js` initializes belief at route start (`analysis/grid-filter.js:296-300`); Swift does the same in `RouteBeliefFilter` (`RouteBeliefFilter.swift:160-168`).
- Potential new code: live arming state in `LivePositioningController`, optional QR/NFC/GPS entrance event API, and trace fields for `entrance_armed` / `manual_start_confirmed`.

**Data needed:**
- Reverse trace: `recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl` (historical false fires at lines `:1268`, `:2046`, `:2698`, `:2886`, `:3096`).
- Out-of-order trace: `recordings-new/Ravi-place_Home_forward_hand_live_20260619-100523.jsonl`.
- Normal starts on all profiles to ensure no start friction/regression.
- If testing GPS entrance: semi-outdoor venue traces with accuracy-gated location metadata.

**Eval command / metric:**
- Replay/score reverse and mid-route traces as negatives: 0 checkpoint fires before explicit entrance cue; normal starts unchanged.
- Live acceptance: starting away from the first checkpoint shows “Stand at Start” / manual fallback rather than advancing; starting at the first checkpoint behaves as before.

**Expected impact:** High. It closes deliberate misuse and accidental wrong-start cases without compromising the core guided-route model.

**Risk:** Medium. Magnetic-only arming was already tried and reverted because it suppressed reverse but regressed short routes to 0 checkpoints; do not repeat that path without an absolute cue or product confirmation (`docs/STATUS.md:96-100`).

**Citations:** `docs/STATUS.md:95-100`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:103-104`, `analysis/grid-filter.js:296-300`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:160-168`, `docs/research/SYNTHESIS.md:34-40`.

---

## 6. Prototype a proper per-step gait-heading reverse guard offline

**Type:** risky research fork, but targeted.

**Hypothesis:** Compass/device heading cannot solve wrong-way walking, but a proper PCA-GA gait-heading estimator with per-step gait-cycle sign resolution may separate forward vs reverse enough to gate checkpoint firing on low-turn routes.

**Code areas:**
- Existing spike: `analysis/gait-heading-direction.js` computes crude gravity-aligned acceleration PCA vs field-bearing and documents the result (`analysis/gait-heading-direction.js:1-63`).
- Future: add `analysis/gait-heading.js` with per-step PCA-GA / stance-phase sign resolution; optionally add route-heading arrays to `analysis/build-profile.js` from ARKit ground truth.
- Only after offline proof: Swift live port in `LivePositioningController` and filter/decision gate.

**Data needed:**
- LIS forward and reverse traces with ARKit GT where available.
- Forward/reverse pairs for at least two more routes, both hand and pocket if possible.
- Multiple devices/holding styles, because sign resolution may be carry-mode-specific.

**Eval command / metric:**
- New offline command: `node analysis/gait-heading.js --profile profiles/office-near-lis-forward.json --sessions <forward...> --reverse <reverse...> --out analysis/gait-heading-lis.html`.
- Metrics: per-step/per-segment heading-vs-route residual, forward-vs-reverse separation, false guard rate on normal walks, missed guard rate on reverse/mid-route walks.
- Go/no-go: do not integrate live unless forward passes have stable per-segment expected heading and reverse mismatch is consistently near 180° with comfortable margin.

**Expected impact:** High if it works: route-direction misuse is the main current design hole that does not require venue hardware.

**Risk:** High. The existing crude spike found a promising 136° forward/reverse split but then a no-go for per-segment guard because sign resolution flipped inconsistently; a usable guard requires substantial signal processing and repeatability proof (`docs/research/direction-and-entrance-anchoring.md:86-133`).

**Citations:** `docs/research/direction-and-entrance-anchoring.md:12-31`, `docs/research/direction-and-entrance-anchoring.md:68-83`, `docs/research/direction-and-entrance-anchoring.md:86-133`, `analysis/gait-heading-direction.js:1-63`, `docs/STATUS.md:96-100`.

---

## 7. Harden pocket mode with pose/profile selection checks and more live pocket data

**Type:** medium bet / data + UX.

**Hypothesis:** Pocket-specific profiles are viable, but the system is still brittle because live carry pose is user-selected, turn evidence must be disabled for pocket, and profile/pose mix-ups can silently degrade tracking.

**Code areas:**
- `survey-recorder/SurveyRecorder/Views/LivePositioningView.swift` — Hand/Pocket picker is user-selected and disabled during a run (`LivePositioningView.swift:220-233`).
- `survey-recorder/SurveyRecorder/LivePositioningController.swift` — `livePose` controls turn evidence and trace meta (`LivePositioningController.swift:17-21`, `LivePositioningController.swift:153-162`, `LivePositioningController.swift:254-259`).
- `analysis/grid-filter.js` — replay disables turn evidence for non-hand pose (`analysis/grid-filter.js:729-735`, `analysis/grid-filter.js:881-884`).
- `profiles/plumeria-l478-pocket.json` and app resource list (`RouteProfile.swift:22-30`).

**Data needed:**
- New live pocket walk on L478 with phone pocketed until the actual route end.
- At least one pocket profile and live pocket test outside Plumeria L478.
- Intentional profile/pose mismatch traces: hand profile with pocket carry and pocket profile with hand carry.

**Eval command / metric:**
- `node analysis/grid-filter.js profiles/plumeria-l478-pocket.json recordings-new/Plumeria_L478_forward_pocket_live_20260612-135652.jsonl --out analysis/l478-pocket-live.html`.
- Repeat with wrong profile/pose to quantify mismatch signature.
- Metrics: checkpoint count, final checkpoint fired, `P(OFF)` spikes/recovery, turn-log disabled status, profileResource correctness in trace meta.

**Expected impact:** Medium-high. Pocket carry is part of the commercial gate and already has one live success; hardening it reduces field surprises.

**Risk:** Medium. Automatic pose detection may be noisy; a better first step may be profile/pose mismatch warning and clearer UI rather than full classifier.

**Citations:** `docs/STATUS.md:54-64`, `docs/STATUS.md:60-61`, `survey-recorder/SurveyRecorder/Views/LivePositioningView.swift:220-233`, `survey-recorder/SurveyRecorder/LivePositioningController.swift:17-21`, `analysis/grid-filter.js:729-735`, `analysis/grid-filter.js:881-884`.

---

## 8. Fit turn-anchor parameters and test soft missing-turn requirements only after more negatives

**Type:** medium-risk algorithm bet.

**Hypothesis:** Turn anchors are valuable, but the remaining parameters are hand-chosen and some seemingly logical variants regress real walks. A data-driven sweep can decide whether soft turn requirements/missing-turn evidence are worth shipping.

**Code areas:**
- `analysis/turn-events.js` — turn detector thresholds (`turn-events.js:15-19`, `turn-events.js:78-106`).
- `analysis/build-profile.js` — turn signature clustering and majority-vote survival (`build-profile.js:528-602`).
- `analysis/grid-filter.js` and `RouteBeliefFilter.swift` — `observeTurn`, support/proximity gates, reversal suppression (`analysis/grid-filter.js:501-556`, `RouteBeliefFilter.swift:277-331`).
- `survey-recorder/Tests/FilterParityTests.swift` and parity fixtures must be regenerated if filter math changes (`docs/STATUS.md:81-82`).

**Data needed:**
- More negative traces with true off-route turns, pacing arcs, standing, reverse, and normal route U-turns.
- Existing L478/Ravi/Test traces as controls.
- Hand only at first; pocket turn evidence is net harmful and should remain disabled.

**Eval command / metric:**
- New sweep: `node analysis/turn-sweep.js --matrix analysis/eval-matrix.json --out analysis/turn-sweep.html`.
- Metrics: false advances on pacing/reverse/off-route, missed checkpoints on clean walks, missed-turn false positives, P50/P75 on normal runs.
- Acceptance: any new turn requirement must beat current confinement gate + proximity gate without bricking known clean walks.

**Expected impact:** Medium. Could improve route-consistency on turn-rich routes and reduce false advances, but lower priority than pacing-gate live closure and data coverage.

**Risk:** Medium-high. Backward prediction and strict turn requirements have already shown regression modes; real route turns can fail support/proximity gates, so overusing turn evidence can break legitimate walks (`docs/STATUS.md:81`, `docs/STATUS.md:89-94`).

**Citations:** `docs/STATUS.md:81-82`, `docs/STATUS.md:89-94`, `analysis/turn-events.js:15-19`, `analysis/turn-events.js:78-106`, `analysis/build-profile.js:528-602`, `analysis/grid-filter.js:501-556`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:277-331`.

---

## 9. Add tour-context anchors: audio/dwell prior and semi-outdoor GPS entrance

**Type:** medium integration bet.

**Hypothesis:** Guided-tour context gives free priors that phone sensors alone do not: playback/dwell timing near stops, user interaction, and semi-outdoor GPS near entrances can reduce late/missed fires and prevent premature route arming.

**Code areas:**
- Current repo has no tour-app event input; add a small event API to live positioning rather than baking it into the filter first.
- Candidate live events: `audio_started`, `audio_completed`, `dwell_started`, `manual_confirmed`, `gps_entrance_fix` written to JSONL trace and mapped to soft priors in replay.
- Potential integration outside this repo with Dex GPS trigger files described in `docs/dex-gps-vs-indoor-positioning.md` (`docs/dex-gps-vs-indoor-positioning.md:10-36`, `docs/dex-gps-vs-indoor-positioning.md:79-96`).

**Data needed:**
- Live indoor traces with synchronized audio/playback/dwell events.
- Semi-outdoor entrance traces with iOS location accuracy values.
- Manual confirmation events for low-confidence cases.

**Eval command / metric:**
- New replay mode: `node analysis/grid-filter.js <profile> <session-with-events.jsonl> --events audio,gps --out analysis/event-prior.html`.
- Metrics: checkpoint trigger delay, missed checkpoints, false advances before audio/dwell readiness, entrance arming success/failure.

**Expected impact:** Medium-high where tours have strong stop structure. It may be the cheapest way to improve product reliability without pretending the sensor model solved every case.

**Risk:** Medium. Requires tour-app integration and careful false-prior handling; GPS is only useful near entrances/outdoors and should not be sold as indoor precision.

**Citations:** `docs/research/SYNTHESIS.md:34-40`, `docs/dex-gps-vs-indoor-positioning.md:10-36`, `docs/dex-gps-vs-indoor-positioning.md:79-96`, `README.md:17-25`.

---

## 10. Keep any-order/free-roam positioning as a separate risky fork, not a tuning task

**Type:** risky fork / strategic product branch.

**Hypothesis:** If the product must support out-of-order rooms, shortcuts, reverse walks, or “where am I in this building?”, the current 1-D ordered route model cannot be tuned into that behavior. It needs a separate architecture: route graph, independent per-zone matching, absolute room cues, or eventually 2-D/particle filtering with much denser surveys.

**Code areas:**
- New branch rather than edits to `RouteBeliefFilter`: profile schema for zones/graph nodes, zone fingerprints, transition graph, independent zone classifier, or 2-D state.
- Current architecture explicitly only constrains to a surveyed 1-D route and lacks global relocalization (`docs/architecture.md:126-128`, `docs/architecture.md:175-177`, `docs/architecture.md:193-203`).
- Current out-of-scope list excludes arbitrary blue-dot and global relocalization (`docs/architecture.md:211-216`).

**Data needed:**
- Room/zone-labeled traces, arbitrary movement traces, shortcut/out-of-order/reverse traces, and dense spatial surveys if attempting 2-D.
- More absolute cues if available: QR/NFC/BLE room identifiers.

**Eval command / metric:**
- New benchmark, not current route replay: zone classification accuracy, wrong-room false positives, time-to-zone, manual fallback rate, and comparison against route-mode on ordered tours.
- Success metric should be “correct room/zone confidence,” not blue-dot meters, unless dense 2-D ground truth exists.

**Expected impact:** High only if product scope demands non-linear movement. Otherwise it distracts from the guided-route commercial gate.

**Risk:** Very high. It requires a new map/profile/data model and much more survey coverage; current docs warn 2-D would likely be less reliable at first with current route-only data.

**Citations:** `docs/STATUS.md:95-100`, `docs/architecture.md:126-128`, `docs/architecture.md:175-177`, `docs/architecture.md:193-216`, `README.md:99-100`.

# Recommended First 3 Actions

1. **Run and live-validate the pacing gate.** Use the existing Ravi/L478/Test pacing traces for replay and record one new post-gate live pacing trace. Do not tune other algorithms until this is confirmed live.
2. **Implement the replay scorecard.** One command should report current commercial-gate status, including normal vs negative sessions, venue/device/pose coverage, trigger accuracy, false advances, off-route delay, and P50/P75.
3. **Collect missing validation data.** Prioritize: one standing negative, one off-route negative, one Ravi or L478 post-gate pacing live trace, third clean pass for the two-pass profiles, and one new iPhone model.

# 1-Week Experiment Plan

## Day 1 — Freeze the baseline matrix
- Create an explicit matrix of profiles and sessions: Plumeria Test, Plumeria L478 hand, Plumeria L478 pocket, Office right wing, Office-Near LIS, Ravi-place, Meadows.
- For each, label `normal`, `live-normal`, `pacing`, `reverse`, `out-of-order`, `standing`, `offRoute`.
- Run current per-session commands and save outputs under `analysis/` or `/tmp`.
- Success: baseline table with checkpoint count, false fires, P(OFF), P50/P75 where ARKit truth exists.

## Day 2 — Close pacing-gate evidence
- Replay all existing pacing/confined traces against current code.
- Perform one live post-gate pacing re-test on Ravi-place or L478.
- Success: 0 fires on pacing, forward controls unchanged, documented suppression tail behavior.

## Day 3 — Scorecard skeleton
- Implement or specify the one-command scorecard enough to run the frozen matrix.
- Include a warning class for live traces without ground-truth anchors so they are not mislabeled as true false advances.
- Success: one HTML/Markdown scorecard with pass/fail rows and commercial-gate summary.

## Day 4 — Data collection sprint
- Record one standing negative and one off-route negative.
- Record a third clean pass for one thin profile (Office right wing, Office-Near LIS, or Ravi-place).
- If possible, record one additional pocket live/survey pass without pulling the phone out at the end.
- Success: new JSONLs with correct `passType`, device model, profileResource, and ARKit truth where appropriate.

## Day 5 — Profile QA and resurvey decision
- Run repeatability and profile build on the new clean pass.
- Identify weak segments, too-long legs, transition-heavy spans, and whether resurvey/checkpoint insertion beats code changes.
- Success: explicit keep/resurvey decisions for Office/Ravi/LIS profiles.

## Day 6 — Reverse/entrance branch go/no-go
- Re-score LIS reverse and Ravi out-of-order traces.
- Decide whether product-level Start-at-entrance copy/manual confirmation is enough for guided-route v1, or whether to schedule the gait-heading research fork.
- Success: documented decision; no magnetic-only arming retry unless paired with absolute cue.

## Day 7 — Roadmap update and next implementation batch
- Update the scorecard and roadmap rankings with measured results.
- Choose either: (a) harden eval/data/QA for commercial gate, or (b) start the gait-heading offline experiment if reverse/mid-route misuse is product-critical.
- Success: next week’s implementation scope is driven by measured failures, not hallway intuition.
