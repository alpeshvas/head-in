# Pocket Pose Robustness: hand vs pocket carry

## TL;DR

- **Do not merge hand and pocket into one universal profile yet.** This repo already has evidence that hand-profile + pocket-run is brittle, while a spliced **per-pocket profile** is viable. Keep pose-specific profiles/calibration as the primary strategy, selected before the run.
- **Add lightweight live pose detection as a guardrail, not as the localization model.** Use it to confirm the user-selected Hand/Pocket carry, block/disable turn evidence in pocket, and warn/stop on profile/carry mismatch. Do not silently switch profiles mid-run until that transition behavior is evaluated.
- **Keep the current magnetic baseline:** magnitude + stride-lag first differences + per-pose fitted likelihoods. Test gravity-frame horizontal/vertical magnetic components as an optional feature branch, but treat raw XYZ as pose/orientation-sensitive.

## External evidence with links

1. **Hand-vs-pocket carry pose can be detected with cheap IMU features, but not perfectly.** Incel’s phone-placement study used 2 s windows and found accelerometer motion-only features around ~70% accuracy, improving to ~85% when motion, orientation, and rotation features were combined; reduced in-pocket detection reached ~93% with accelerometer-only features. Random forest was the strongest lightweight classifier, while adding gyro to acceleration improved one dataset to ~95.9% average and ~97.6% pocket accuracy. [Analysis of Movement, Orientation and Rotation-Based Sensing for Phone Placement Recognition](https://pmc.ncbi.nlm.nih.gov/articles/PMC4634510/)

2. **Temporal smoothing matters because phone location changes slowly.** Antos et al. used 2 s accelerometer clips, an SVM, and an HMM over activity-location pairs. Assuming one fixed phone location when the phone was actually elsewhere dropped activity tracking to 56.8%, while training on all locations recovered 88.1%; phone-location tracking reached 95.0%, and the joint classifier’s marginalized phone-location accuracy was 96.4%. This supports a smoothed pose state rather than per-window hard switching. [Hand, belt, pocket or bag: Practical activity tracking with mobile phones](https://pmc.ncbi.nlm.nih.gov/articles/PMC3972377/)

3. **PDR/heading strategy should be pose-specific.** Deng et al. explicitly select different heading estimators by carrying position: attitude/yaw-offset for hand-held/phone-call, and RMPCA for in-pocket/swinging-hand. Their pose classifier used 2 s / 50%-overlap acceleration windows, simple mean/variance/max/min features over XYZ plus acceleration magnitude, and Random Forest achieved 97.8% average carrying-position classification. They also detect carry transitions separately to avoid confusing phone handling with user turns. [Carrying Position Independent User Heading Estimation for Indoor Pedestrian Navigation with Smartphones](https://www.mdpi.com/1424-8220/16/5/677)

4. **Magnetic localization benefits from orientation-invariant/normalized features and sequence differences.** A TCN magnetic-positioning system transforms magnetometer readings into horizontal/vertical components plus intensity using gravity, applies moving-average smoothing and first-order differencing, then classifies magnetic trajectories. It reported 99.8% accuracy on trained phones and 95.2% / 88.2% / 84.3% on three untrained phones, showing that normalization + differencing helps heterogeneous devices. [Magnetic-Field-Based Indoor Positioning Using Temporal Convolutional Networks](https://pmc.ncbi.nlm.nih.gov/articles/PMC9921884/)

5. **Deep pose-robust magnetic localization exists but is too heavy for this prototype path.** A 2025 ResNet+Transformer+LSTM model reports 0.21 m average error across calling, dangling, handheld, and pocketed modes using magnetic magnitude, but it uses 20 residual blocks, 3 transformer modules, 3 LSTM units, a GPU training setup, one Nexus 5X, and a 20 m × 20 m lab. It is evidence that pose-robust learning is possible, not evidence to replace this repo’s route filter now. [Robust Magnetic Fingerprint Positioning in Complex Indoor Environments Using Res-T-LSTM](https://pmc.ncbi.nlm.nih.gov/articles/PMC12736867/)

## Recommended pose strategy

1. **Near term: pose-specific profiles + manual live carry selection.**
   - Keep separate `hand` and `pocket` route profiles with separately fitted `calibration{}` values.
   - Require the live run to select both the route profile and carry pose before starting. If `profile.route.devicePose` and the carry toggle disagree, warn and prevent start or mark diagnostics red.
   - If the pose classifier later detects sustained mismatch, stop or ask the user to reset with the correct profile; do **not** silently swap the filter’s profile/calibration while belief is already in flight.

2. **Pocket policy: disable turn observations.**
   - This matches current runtime behavior: turn observations are gated by `livePose == .hand`.
   - Keep pocket localization driven by step prediction + magnetic first-difference emissions + OFF/re-entry logic. Revisit pocket turn signatures only after collecting enough pocket-specific live traces and proving they improve false-fire/late-fire metrics.

3. **Survey/profile policy: keep pause splicing for pocket.**
   - Pocket survey pauses are not a small artifact; they create flat magnetic stretches that become attractors under the differenced emission. Keep `build-profile --splice-pauses` as mandatory for pause-derived pocket anchors.
   - Prefer survey UX that records pocket anchors without phone pull-out transients; until then, pause-derived anchors + splice are the safe workflow.

4. **Magnetic normalization policy.**
   - Keep magnitude and stride-lag first differences as the production baseline: orientation-invariant, bias/recalibration-resistant, already implemented in JS and Swift.
   - Evaluate gravity-frame horizontal/vertical components (`mh`, `mv`, `|B|`) only as an experiment, behind replay metrics. They can add discriminative information, but depend on reliable attitude/gravity during leg swing.
   - Avoid raw magnetometer XYZ for cross-pose matching; it is too coupled to phone orientation.

## Classifier/features

**Goal:** lightweight live classifier that outputs `hand`, `pocket`, and `transition/unknown`, with confidence and hysteresis. It should protect the current route filter rather than replace it.

Recommended feature window: **1.8–2.0 s**, 50% overlap where possible, aligned with the existing live motion classifier window.

Feature set, using streams already logged by the app:

- **User acceleration magnitude:** mean, stddev, RMS, range, MAD, peak count, step cadence, inter-step variance, first few FFT coefficients / cadence-band energy.
- **Gravity/orientation:** mean/stddev/range of gravity XYZ; pitch/roll mean and range; orientation stability. Pocket should show stronger periodic leg-driven orientation changes than a steadily held phone.
- **Gyro/rotation:** rotation magnitude mean/stddev/RMS/range; axis variances; yaw/roll-rate energy. Pocket and swinging hand usually have higher periodic rotation than hand-held route viewing.
- **Magnetic secondary features:** magnitude stddev/range and first-difference energy. Use these cautiously to avoid venue overfitting; prefer normalized/range features over absolute field level.
- **Existing live diagnostics to reuse:** `recentMotionStepCount`, `motionMeanUserAcceleration`, `motionMeanRotation`, and `motionMagneticStdDev` already exist in `LivePositioningController`.

Classifier choice:

- Start with **Random Forest or a shallow decision tree / logistic model** trained offline and exported as thresholds or a tiny model. Literature supports Random Forest on these features, and it is interpretable enough to debug.
- Add **HMM/hysteresis smoothing**: pose changes are rare, transition windows are noisy, and a single bad window must not flip localization behavior.
- Practical policy: require confidence ≥0.8 for 2–3 consecutive windows before declaring a mismatch; emit `transition/unknown` during phone handling and block checkpoint firing / turn observations until stable.

## Eval protocol

1. **Data matrix.** For each route/venue, collect at least 5 clean hand passes and 5 clean pocket passes, plus standing, pacing, off-route, reverse/misuse, and explicit hand↔pocket transition traces. Include at least 2–3 iPhone models before treating a classifier as product-safe.

2. **Pose classifier metrics.** Report hand/pocket precision, recall, F1, confusion during walking vs standing, transition latency, false toggles per minute, and mismatch-detection latency. Use leave-one-session-out first; move to leave-one-user/device-out once enough data exists.

3. **Localization replay matrix.** For every route, replay:
   - hand pass × hand profile
   - pocket pass × pocket profile
   - pocket pass × hand profile and hand pass × pocket profile (intentional mismatch)
   - optional universal mixed profile
   - with/without turn observations
   - with/without pocket pause splicing
   - magnitude first-diff baseline vs optional H/V magnetic features

4. **Localization success metrics.** Use the repo’s current promise: correct checkpoints in order, no false fires on negatives, checkpoint delay, P50/P75 position error where ARKit/anchor truth exists, max `pOff`, recovery after transient OFF, and final checkpoint behavior at recording edges.

5. **Live validation.** After offline replay passes, run live tests with the correct profile+carry selection and with deliberate mismatches. A mismatch should produce a clear warning/fallback, not false route progress.

## Risks

- **Classifier false confidence:** a bad pose classifier can make the app worse if it silently swaps profiles or enables pocket turn evidence.
- **Transition ambiguity:** pulling the phone from pocket to hand looks like a turn/handling event and should be treated as `transition/unknown`, not a route observation.
- **Pocket profile data cost:** per-pose profiles double survey needs, but current local history shows this is safer than universal matching.
- **Pocket anchors/end transients:** phone pull-out at checkpoints or route end can corrupt profiles and final emissions; keep splicing and improve survey UX.
- **Clothing/device variation:** front/back pocket, tight/loose pockets, walking style, and iPhone model can shift IMU signatures. Validate beyond one user/device before productizing.
- **Magnetic feature overfitting:** pose classifier magnetic features may learn venue gradients instead of carry pose; keep IMU primary.
- **Deep-model temptation:** multi-module pose-robust magnetic models are promising but conflict with this repo’s lightweight, route-filtered path and need much more data.

## Exact local citations

- **Product constraints and route-only promise:** `README.md` → “Product Direction” and “Notes” say the app is phone-only, no installed hardware, no runtime camera, single-floor, route-constrained, and should promise checkpoint/zone confidence rather than indoor blue dot.
- **Sensor streams available for classifier/features:** `docs/architecture.md` → “Sensor streams” lists calibrated magnetic field, attitude quaternion, rotation rate, user acceleration, gravity, raw magnetometer fallback, steps, barometer, anchors, and surveyor-only ARKit truth.
- **Runtime filter architecture:** `docs/architecture.md` → “Runtime Matcher” and “Magnetic observation update” describe the 1-D route grid + `OFF` state and stride-lag first-difference magnetic magnitude emissions.
- **Pose metadata model:** `survey-recorder/SurveyRecorder/Models.swift` → `enum DevicePose { hand, pocket, bag }`, `RouteSetup.devicePose`, and `PassType.live`.
- **Survey UI pose picker:** `survey-recorder/SurveyRecorder/Views/SetupView.swift` → `Picker("Device pose", selection: $devicePose)` persists the survey pose.
- **Session metadata includes pose/profile:** `survey-recorder/SurveyRecorder/SessionWriter.swift` → session filename and `meta` write `devicePose`; live traces can include `profileResource`.
- **Pocket profile is bundled:** `survey-recorder/SurveyRecorder/RouteProfile.swift` → `bundledProfiles` includes `("Plumeria L478 (pocket)", "plumeria-l478-pocket")`.
- **Pocket profile artifact:** `profiles/plumeria-l478-pocket.json` → `route.devicePose = "pocket"`, three pocket source files, and route segments with pocket magnetic profiles.
- **Pocket pause-splicing rationale and thresholds:** `analysis/splice-pauses.js` → header comment explains pocket checkpoint pauses create flat-field attractors; `spliceSession()` uses `TH=0.08`, `MIN_PAUSE_S=0.7`, 0.5 s smoothing, drops samples inside pauses, and snaps anchors to the splice point.
- **Pocket splicing wired into profile build:** `analysis/build-profile.js` → CLI `--splice-pauses`; `main()` splices each input before parsing, turn extraction, and calibration.
- **Per-pose route identity:** `analysis/build-profile.js` → `routeFromMeta()` and `routeKey()` include `devicePose`, so hand/pocket sessions are distinct route/profile identities.
- **Per-profile calibration:** `analysis/build-profile.js` → `fitCalibration()` fits `diffSigmaUT` and `offLogLikPerPoint`; `RouteBeliefFilter.swift` → `GlobalRouteProfile` reads `profile.calibration` with `FilterParams` fallback.
- **First-difference emission implementation:** `analysis/grid-filter.js` → `perPointLogLik()` documents stride-scale differencing; `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` → `observe(windowForSegment:)` implements the same first-difference Gaussian update.
- **Live pose-toggle constraint:** `survey-recorder/SurveyRecorder/LivePositioningController.swift` → comment above `var livePose = DevicePose.hand` says runtime cannot yet detect pocketing and turn evidence is hand-only because pocket leg swing distorts turn magnitudes; turn observation is guarded by `if livePose == .hand`.
- **Live carry UI:** `survey-recorder/SurveyRecorder/Views/LivePositioningView.swift` → `Picker("Carry")` exposes Hand/Pocket, is disabled while running, and comments that runtime cannot yet detect pocketing and turn evidence must be off in pocket.
- **Pocket history / result basis:** `docs/STATUS.md` → “L478 apartment loop route” pocket subsections document: hand-profile+pocket failure, pocket-profile experiment, pause-splice fix, pocket turn evidence net harmful, bundled `plumeria-l478-pocket`, and live pocket validation to 6/6 after re-entry fix.

## Sources kept / dropped

Kept:

- Incel 2015 phone placement recognition — best direct evidence for lightweight hand/pocket pose features and classifiers.
- Antos et al. 2014 SVM+HMM — evidence for temporal smoothing and location-aware activity/pose handling.
- Deng et al. 2016 carrying-position-independent heading — evidence for pose-specific PDR/turn/heading strategies and cheap transition detection.
- Ouyang et al. 2023 magnetic TCN — evidence for magnetic coordinate transform, smoothing, and first-order differencing.
- Res-T-LSTM 2025 — evidence that cross-posture magnetic localization is possible, but kept as a long-term/deep-learning reference only.

Dropped:

- “Efficient In-Pocket Detection with Mobile Devices” PDF — fetch returned no usable content in this research pass.
- Generic phone-location deep-learning papers — less directly actionable than the IMU/RF/HMM evidence above.
- New/uncorroborated rotation-invariant magnetic arXiv-style results — lower priority than peer-reviewed/open full-text sources and this repo’s own replay history.

## Gaps

- No new offline replay was run for this note; recommendations are based on repo history plus external literature.
- Exact classifier thresholds and feature importances must be learned from this repo’s own hand/pocket sessions.
- Bag carry is modeled in `DevicePose` but not validated; keep it unsupported until data exists.
- Cross-device and cross-user pocket robustness remains unproven locally.