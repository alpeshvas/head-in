# Gait-heading reverse-route guard research

## TL;DR

Phone IMU gait analysis **can** estimate travel heading independently of phone/device heading, and the classical lightweight path is PCA over gravity-horizontal acceleration plus gait-cycle sign disambiguation. That could reject the repo's observed reverse-route/wrong-direction false-advances without camera or venue hardware by comparing live travel heading to the route's surveyed heading.

However, this is **not a quick guard to ship from the current crude prototype**. Existing local experiments show travel direction is present in the signals, but crude 1.2 s PCA + integrated-velocity sign resolution flips between forward survey passes; a reliable guard requires per-step gait-cycle asymmetry sign resolution and offline proof across the existing recordings before touching runtime checkpoint firing.

## External evidence with source links

1. **PCA gives a travel axis, but the sign is inherently ambiguous.** Fujii & Sakuma explicitly call out PCA's “indeterminacy problem” that allows direction reversal because the PCA component is non-directed. That exactly matches the guard problem: PCA alone can say “along the corridor,” not “forward vs backward.” Source: [Suppression of performance degradation in traveling direction estimation by using IMU and PCA for PDR](https://www.jstage.jst.go.jp/article/ijnc/8/2/8_328/_article/-char/en).
2. **Pocket PCA can resolve front/back from gait-cycle asymmetry.** Kunze et al. project acceleration into the horizontal plane, take the first PCA component, and distinguish front/back by integrating the signal over time; they report mean difference about 5° vs GPS heading on straight outdoor pocket walks. Assumptions: forward-facing user, trouser pocket, fairly straight segment. Source: [Which Way Am I Facing](http://kaikunze.de/papers/pdf/kunze2009way.pdf).
3. **RMPCA resolves the 180° ambiguity with stance-phase gyroscope behavior.** Deng et al. rotate pocket-phone acceleration into a reference frame, apply PCA to horizontal acceleration over a stride, then resolve the 180° ambiguity using the sign of rotation around the user right-axis near the stance-phase acceleration peak. Reported pocket heading errors: P50 4.6°, P75 12.1%; no noisy indoor compass is needed for the local direction extraction. Source: [Heading Estimation for Indoor Pedestrian Navigation Using a Smartphone in the Pocket](https://www.mdpi.com/1424-8220/15/9/21518).
4. **PCA-GA generalizes this across motion/carry modes.** Wang et al. classify movement state and phone pose, use PCA on global accelerations to infer the pedestrian right-vector for swinging/pocket poses, then remove the 180° ambiguity using accelerometer/gyroscope pose-specific gait cues. They report 92.4% combined motion/pose recognition, pocket heading P50/P75 5.6°/9.2°, and about 3.5 m mean localization error over a 164 m route for harder dynamic poses. Source: [Pedestrian Dead Reckoning Based on Motion Mode Recognition Using a Smartphone](https://www.mdpi.com/1424-8220/18/6/1811).
5. **WalkCompass is the strongest practical “device heading is not travel heading” evidence.** It uses heel-strike as a gait anchor, extracts the swing-phase deceleration segment that best represents walking direction, compensates phone-coordinate instability with gyro, projects to the horizontal plane, and averages away sway. It reports local direction median errors around ±5° palm, ±3° pocket, ±8° swinging-hand, and convergence after about 4–6 steps after sharp turns. Source: [I am a Smartphone and I can Tell my User’s Walking Direction / WalkCompass](https://www.cs.umd.edu/~nirupam/images/2_publication/papers/WalkCompass_MobiSys14_nirupam.pdf).
6. **Heading-agnostic neural odometry confirms the general framing but is heavier.** RoNIN uses a heading-agnostic gravity-aligned frame so arbitrary phone yaw/carry pose does not define travel direction; it works across hand/pocket/bag natural handling but requires large training data and 200 Hz Android-style data in the published setup. Useful as Phase 4 context, not the first reverse guard. Source: [RoNIN](https://ar5iv.labs.arxiv.org/html/1905.12853).
7. **Magnetic route following is feasible, but it assumes route/order context.** FollowMe is close to this repo's route-following design: reference trace + follower trace, magnetometer/accelerometer/gyro/barometer, step-constrained DTW on differenced magnetic magnitude, no installed infrastructure; it achieved 95% spatial errors ≤2 m but assumes the follower starts at the same origin and follows the reference route. Source: [FollowMe / Last-Mile Navigation Using Smartphones](https://yshu.org/paper/mobicom15followme.pdf).
8. **Magnetic magnitude alone is weak and orientation-constrained, so it should not be the direction oracle.** Magicol explains that 3D magnetic vectors are hard to use without continuous attitude or fixed pose, so magnitude/sequence matching is used; it vectorizes per-step magnetic sequences and uses DTW/particle filtering. It achieved 90th-percentile magnetic-only accuracy of 5 m office / 1 m garage / 8 m supermarket, but it still needs PDR/map constraints and sufficient sequence length. Source: [Magicol](https://yshu.org/paper/jsac15magicol.pdf).

Kept sources were primary papers/docs with direct gait-heading, PCA ambiguity, or route-magnetic evidence. Dropped/low-weight sources included generic PDR surveys, SEO-style summaries, and infrastructure-heavy BLE/RFID return-navigation papers because they do not directly answer the no-camera/no-hardware gait-heading guard question.

## Required signals and assumptions

### Signals already available in this repo

- 100 Hz `CMDeviceMotion`: attitude quaternion, rotation rate, user acceleration, gravity, calibrated magnetic field and calibration accuracy.
- Raw magnetometer fallback/debug stream.
- Step timing from custom acceleration peak detection; `CMPedometer` step updates are also recorded.
- Survey-only ARKit pose for route-heading/ground-truth evaluation; runtime remains camera-free.
- Profile route bins, ordered anchors/checkpoints, magnetic magnitude profile, detected-step medians, turn signatures, and per-profile calibration.

### Additional assumptions needed for a usable guard

1. **A route-heading reference exists.** Best: derive route tangent by bin from survey ARKit pose. Alternative: profile expected gait heading relative to local magnetic-field bearing from repeated survey passes. Current profile schema does not yet carry such a heading profile.
2. **Carry mode is known or classified.** Sign resolution differs for hand, swinging hand, and pocket. The app currently has a user-selected `livePose`; it does not automatically detect pocketing.
3. **Enough normal walking exists before firing.** PCA/gait methods need at least a stride, preferably several steps; turns and very short transition segments should be skipped or down-weighted.
4. **The user is walking normally along a path.** Side-stepping, shuffling, backing up while facing forward, running, stairs, or phone-in-bag motion can break classical gait-cycle sign cues.
5. **The guard is confidence-gated.** If sign confidence, route-heading quality, or posterior support is weak, it should abstain and fall back to existing conservative behavior/manual fallback rather than block true progress.

## Implementation sketch for this codebase

### 1. Keep it offline first

Create/extend an analysis-only gait-heading evaluator before any Swift runtime change. The existing `analysis/gait-heading-direction.js` is a good spike but uses crude 1.2 s PCA windows and integrated-velocity sign; keep it as baseline, then replace the sign logic with per-step gait-cycle asymmetry.

Core algorithm:

1. Parse `dm` samples (`q`, `ua`, `rot`, `g`, `mag`) and step times.
2. Transform `userAcceleration` into a gravity-aligned frame. Do **not** use device/compass heading as travel heading; the repo already rejected that.
3. For each stride or short multi-step window, compute horizontal acceleration covariance and PCA principal axis.
4. Resolve 180° sign using gait-cycle asymmetry, selected by carry mode:
   - pocket: stance/swing peak pattern and thigh-rotation gyro sign as in RMPCA/PCA-GA;
   - hand/swing: heel-strike anchor plus swing-phase max-deceleration window and gyro de-rotation as in WalkCompass;
   - fallback sign propagation should not be trusted by itself, because the local experiment showed it can make forward passes diverge.
5. Output `(t, heading, confidence, carryMode, skippedReason)`.

### 2. Build a surveyed heading profile

For each profile/bin or segment, store an optional heading signature:

```json
"travelHeading": {
  "frame": "arkit-route-tangent" | "relative-to-field-bearing" | "survey-gait",
  "meanDeg": 123.4,
  "r": 0.82,
  "passes": 3,
  "quality": "strong"
}
```

Prefer ARKit route tangent when available because it directly represents route direction. Where ARKit is absent, derive a survey-gait signature only if forward survey passes agree per segment.

### 3. Add a replay-only wrong-direction observation/gate

In `analysis/grid-filter.js` first:

- For each live gait-heading window, compare live heading to the expected heading over current posterior support.
- Compute a reverse probability or mismatch score, e.g. mass-weighted `P(|wrap(live - expected)| > 120°)`.
- Start as a **checkpoint fire gate**, not a hard belief rewrite:
  - if `pReverse > 0.8` for `N` gait windows and heading confidence is high, block checkpoint firing and set a `wrongDirection`/`startMismatch` diagnostic;
  - if quality is low, abstain.
- Only after replay success, consider moving probability to `OFF` or adding a forward/reverse parity state.

This guard is a special-case misuse detector. It does **not** make the 1D ordered-route filter support arbitrary shortcuts, any-order room visits, or free-roam positioning.

### 4. Port to Swift only after replay proof

If offline metrics pass, mirror the JS implementation in Swift and add parity fixtures. Keep the decision close to the existing checkpoint gate so dead reckoning alone still cannot fire, and wrong-direction evidence cannot silently teleport the filter.

## Proposed eval using existing recordings

Use existing `recordings/`, `recordings-new/`, profiles, and replay tooling. Proposed matrix:

1. **Reproduce the current spike.** Run `analysis/gait-heading-direction.js` on the LIS two forward passes plus reverse trace. Expected current baseline: forward/reverse separation exists (~136°), but per-segment forward-vs-forward repeatability fails. This validates signal presence but not production readiness.
2. **Forward repeatability leave-one-pass-out.** For each route with multiple survey/live runs, build heading signature from all but one forward pass and evaluate the held-out pass:
   - Plumeria/Test hand,
   - Plumeria L478 hand,
   - Plumeria L478 pocket,
   - Office right wing,
   - Ravi-place,
   - Meadows/LIS if recordings are present.
3. **Negative traces.** Evaluate against known negatives documented locally:
   - LIS reverse walk (`..._live_20260619-031803`),
   - Ravi out-of-order/shortcut (`..._live_20260619-100523`),
   - Ravi pacing traces,
   - Plumeria/Test pacing,
   - L478 circling-pacing,
   - any standing/off-route sessions already pulled.
4. **Checkpoint regression.** Replay baseline vs guard and require no loss of normal-route checkpoint fires that currently pass.
5. **Pose-stratified metrics.** Score hand and pocket separately; do not let hand-trained sign logic judge pocket runs.

Suggested pass/fail gates before runtime work:

- Forward held-out windows: segment circular error P50 <30°, P90 <60°, and circular concentration `r >= 0.7` on segments where guard is enabled.
- Reverse/wrong-way: sustained reverse score must appear before the first false checkpoint would fire.
- Forward regression: no reduction in checkpoint count on the currently passing clean/live matrix; checkpoint delay should not grow by more than a small tolerance except where the guard explicitly abstains.
- Negative improvement: false checkpoint fires reduced on reverse/out-of-order negatives without creating new false `OFF`/blocked states on clean passes.

## Expected false-positive / false-negative failure modes

### False positives: guard blocks a valid forward walk

- PCA sign flips within a stride because stance/swing or heel-strike detection is wrong.
- Curves, U-turns, or cluttered room transitions contaminate “straight-walk” windows.
- Pocket leg swing, hand swing, texting/phone manipulation, or bag carry violates the assumed carry-mode sign cue.
- Very slow gait, short steps, pauses, stairs, or running weaken gait-cycle features.
- Route profile heading is stale or noisy, especially if derived from only anchors/time rather than ARKit route tangent.
- Route itself contains a U-turn; a local ~180° heading difference may be legitimate near the U-turn unless compared at the right posterior-supported bin.

### False negatives: reverse/wrong direction still passes

- Wrong route happens to have the same local travel heading as the expected route segment.
- There are too few reliable gait-heading windows before the first checkpoint decision.
- The user walks backward physically while facing the route direction, or side-steps, producing gait signatures not covered by forward-walking assumptions.
- Magnetic posterior is already on an impostor bin whose expected heading matches the wrong walk.
- The guard abstains due to low confidence on exactly the segments where reverse detection is needed.
- Out-of-order room visits with locally plausible heading remain a free-roam/zone-matching problem, not a reverse-route problem.

Mitigations: quality flags, sustained evidence, skip turns/short transitions, pose-specific models, keep manual fallback, and treat start/entrance anchoring as the product-level safety net.

## Exact local citations

- Sensor streams: `survey-recorder/SurveyRecorder/SensorRecorder.swift:6-56` starts 100 Hz device motion/raw magnetometer, pedometer, and barometer; `survey-recorder/SurveyRecorder/RecordingController.swift:37-82` writes `dm` quaternion/rotation/user-acceleration/gravity/calibrated magnetic field; `RecordingController.swift:107-127` writes pedometer/barometer; `RecordingController.swift:129-146` writes survey-only ARKit pose.
- Profile/runtime data model: `survey-recorder/SurveyRecorder/RouteProfile.swift:20-31` lists bundled route profiles; `RouteProfile.swift:45-82` defines route/segment/step/magnetic profile fields; `RouteProfile.swift:86-97` defines calibration and turn signatures.
- Current route-order checkpoint logic: `survey-recorder/SurveyRecorder/LivePositioningController.swift:385-409` only evaluates the next checkpoint and requires recent observation, no reversal, confinement, posterior tail, and low `pOff`; `LivePositioningController.swift:412-420` floors displayed progress after a checkpoint fires.
- Current carry-pose limitation: `LivePositioningController.swift:17-23` says runtime cannot detect pocketing and turn evidence is hand-only; `LivePositioningController.swift:249-267` observes turns only when `livePose == .hand`.
- Current step/magnetic loop: `LivePositioningController.swift:276-313` detects walking steps, calls `filter.predictStep()`, then magnetic observation or unobserved leak.
- Current filter forward bias and reverse handling: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift:183-251` advances each detected step by a positive per-segment stride with only a backward/stay tail; `RouteBeliefFilter.swift:253-318` turns unmatched U-turns into `OFF`/reversal suppression; `RouteBeliefFilter.swift:343-379` uses stride-lag first-difference magnetic emission.
- JS note that magnetic first-differences are direction-sensitive but not a complete start/direction guard: `analysis/grid-filter.js:247-253` says reversed walks produce reversed-negated difference sequences unlike raw magnitude.
- Profile building/eval data: `analysis/build-profile.js:420-505` creates anchor-to-anchor segments with magnetic traces and detected steps; `analysis/build-profile.js:505-568` builds majority turn signatures; `analysis/build-profile.js:571-658` fits per-venue calibration. `docs/STATUS.md:75-77` lists existing `recordings/`, `recordings-new/`, profiles, and replay commands.
- Documented limitations: `docs/STATUS.md:95` route-order assumption/out-of-order walks fire route order; `docs/STATUS.md:96-100` reverse/mid-route false-advance, failed magnetic-only start arming, rejected compass check, and recommended gait-heading route check.
- Existing gait-heading spike: `analysis/gait-heading-direction.js:1-50` implements crude PCA heading vs field-bearing analysis; `analysis/gait-heading-direction.js:52-63` records the LIS result: forward/reverse separation exists, but proper per-step PCA-GA/gait-cycle sign resolution is needed.
- Existing research note: `docs/research/direction-and-entrance-anchoring.md` documents the compass-vs-gait correction, LIS experiment, per-segment no-go result for crude sign resolution, and recommendation not to ship a guard until proper gait-cycle sign resolution is proven.
