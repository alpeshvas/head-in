# Hardware-Less Indoor Positioning Research

Date: 2026-06-05

## Problem Statement

Build a phone-first indoor positioning system that does not require venue-installed hardware. The current product constraint is stricter than generic "no extra hardware": the default solution should also avoid a camera dependency and should support iPhone. The near-term product should provide route, checkpoint, and zone confidence rather than claiming a precise indoor GPS blue dot.

## Executive Verdict

The most reliable default path is not a single sensor. It is a constrained fusion system:

1. Magnetic fingerprinting from the phone magnetometer.
2. Pedestrian dead reckoning from steps, accelerometer, gyroscope, and device motion.
3. A venue route graph with turn and checkpoint constraints. A full floor-plan graph can also encode wall/non-walkable constraints; the current prototype uses an ordered 1D route profile rather than polygonal wall geometry. Routes are single-floor in v1.
4. Confidence scoring and explicit fallback when the signal is ambiguous.

Floor detection (barometer/altimeter fusion, stair/elevator events, multi-floor routes) is out of scope for v1. Barometer samples are still recorded during surveys for future use.

This is the best fit for the current constraints because it uses only sensors already present in phones, avoids iOS Wi-Fi scan limitations, avoids installed beacons/anchors, and can be made useful as route-constrained positioning before it is accurate enough for general free-form navigation.

Camera use should be treated as the last option. Visual-inertial localization can be highly reliable when paired with known landmarks, posters, signs, exhibits, QR codes, or AR image anchors, but it changes the user experience and violates the preferred no-camera dependency. It belongs only in explicit recovery, high-stakes confirmation, or later premium workflows after the passive phone-sensor approach has been exhausted.

## Why Wi-Fi Is Not The Default

Wi-Fi fingerprinting is attractive in papers and Android prototypes, but it is not reliable as the iPhone-first default.

Apple's iOS Wi-Fi API overview says iOS has no general-purpose API for Wi-Fi scanning and configuration. NEHotspotHelper needs a special entitlement and is only intended for hotspot integration, with restrictions against Wi-Fi based location use. Apple Developer Forums also state that the iOS SDK has no general-purpose API for real-time Wi-Fi or cellular signal strength.

That means an ordinary iPhone app cannot build a robust live RSSI fingerprint vector from nearby APs. It can sometimes get the current SSID/BSSID under entitlement and authorization conditions, but that is too sparse for positioning.

Wi-Fi RTT/FTM is promising on Android and newer Wi-Fi standards, but it depends on device, OS, and AP support. It also needs AP location knowledge or AP-provided location metadata. This makes it an optional Android/venue-specific enhancement, not the product's hardware-less iPhone baseline.

## Candidate Ranking

### 1. Magnetic Fingerprinting + PDR + Route/Map Constraints

Recommended as the default.

Record both raw and calibrated magnetic samples as spatial fingerprints. Use steps, cadence, accelerometer, gyro turn detection, and device motion to estimate motion between anchors. Restrict all hypotheses to a route graph or walkable floor-plan graph. The general algorithm family is probabilistic localization: particle filter, HMM/grid filter, or a simpler route-segment belief model.

Current codebase status:

- Sensor recording: `SensorRecorder` samples Core Motion at 100 Hz. `RecordingController` writes calibrated device-motion magnetic field samples to `dm.mag.x/y/z` with calibration accuracy, and raw magnetometer samples to `mag.x/y/z`.
- Profile building: `analysis/build-profile.js` prefers calibrated `dm.mag` samples when available and falls back to raw `mag` samples only if needed.
- Unit: iOS magnetic field values are in microteslas (µT). Magnetic magnitude means `sqrt(x² + y² + z²)`, so it is also in µT.
- Gradients/deltas: the current matcher uses stride-scale first differences, e.g. "how much did magnetic magnitude change over roughly one step?" This compares `(live[k + lag] - live[k])` against the profile difference at the candidate route position. The difference is in µT; if normalized by physical distance it becomes µT/m.
- Map/route recording: the prototype does not yet store a full floor-plan or wall polygons. The survey app records route metadata, an ordered checkpoint list, and `anchor` taps. `build-profile.js` turns consecutive anchors into profile `segments[]` with `from`, `to`, magnetic means/stddevs, step statistics, calibration, and optional turn signatures. That profile is the current route map.
- Runtime algorithm: the app currently uses `RouteBeliefFilter`, a discrete-grid Bayes filter / HMM over concatenated route-position bins plus one explicit `OFF` state. It is not a particle filter. A particle filter would keep many sampled candidate states and reweight them; this code instead stores `belief[]`, a probability for every route bin, plus `pOff`. It is closest to a fine-grained route-segment belief model.
- Current wall constraint behavior: because no wall geometry is stored, the app does not literally know walls. It prevents impossible movement by allowing probability only along the surveyed route profile; if the live sensor evidence cannot be explained by that route, probability moves into the `OFF` state.

Expected reliability:

- Strong magnetic structure, surveyed routes: checkpoint detection around 1-3 m is plausible.
- Typical office or museum route: 3-6 m zone/segment confidence is a realistic expectation.
- Repetitive corridors or open-plan areas: 5-10+ m or ambiguous; system should emit low confidence.

Why it is reliable enough:

- Magnetic field localization is infrastructure-free and low-cost.
- Indoor magnetic fields are often temporally stable unless the building changes significantly.
- PDR provides continuity but drifts, so it must be periodically corrected by magnetic and map evidence.
- Floor-plan constraints can stop impossible wall-crossing; the current prototype gets a narrower version of this benefit by constraining belief to the surveyed route and using `OFF` when the route no longer explains the sensors.

Primary risks:

- Requires fingerprint survey and validation walks.
- Magnetic fingerprints are not equally distinctive everywhere.
- Phone pose and device model differences matter.
- PDR heading and step-length errors accumulate.
- Furniture, renovations, and major electrical changes can require re-surveying.

Implementation shape:

- Survey each route segment 3-5 times per direction.
- Store samples by normalized route distance, not only timestamp.
- Use magnetic magnitude (µT) plus stride-scale gradients/deltas (µT change over movement) to reduce device orientation and model bias.
- Detect turns and pauses; reject candidates inconsistent with route geometry.
- Keep multiple hypotheses until a checkpoint or distinctive magnetic landmark resolves them.
- Emit `near_checkpoint`, `progressed_to_segment`, `possibly_off_route`, and `low_confidence`.

### 2. Core Location / OS-Level Location As A Coarse Prior

Useful but not enough.

On iOS, Core Location can sometimes include indoor floor information. Apple also uses Wi-Fi, cellular, GPS, and Bluetooth internally for Location Services. However, app-level precision and availability are venue-dependent and usually too coarse for route progress by itself.

Best role:

- Determine approximate building/venue entry.
- Initialize candidate route when entering from outdoors.
- Coarse floor hint via `CLLocation.floor` is deferred along with floor detection (out of scope for v1).

Primary risks:

- Availability is inconsistent.
- Not enough for checkpoint/segment detection.
- Opaque to the app.

### 3. Barometer + Stair/Elevator Detection

Deferred — floor detection is out of scope for v1. Routes are single-floor, so none of the runtime logic below ships in v1. Barometer samples are still recorded during surveys (cheap to capture, impossible to backfill) so this can return to scope without re-surveying.

Good vertical helper, not a full positioning system.

Use Core Motion altimeter and pedometer floor data to detect floor changes and vertical transitions. Barometric pressure is relative and environment-dependent, so it should be fused with map constraints and known stair/elevator positions.

Best role:

- Multi-floor route filtering.
- Detect stair/elevator/escalator events.
- Reject route hypotheses on the wrong floor.

Primary risks:

- Not available on all devices.
- HVAC and weather changes affect pressure.
- Cannot localize within a floor.

### 4. Existing Wi-Fi / BLE Signals Without Installing Anything

Optional opportunistic signal, not the baseline.

On Android, Wi-Fi scans and Wi-Fi RTT can be useful where allowed. On iPhone, ordinary Wi-Fi RSSI scanning is blocked and current network info is sparse. Existing BLE advertisements might help in special venues, but scanning policies, privacy, and signal instability make it unreliable as the core method.

Best role:

- Android-only enhancement.
- Coarse venue/floor/zone prior when permissions and APIs allow.
- Enterprise deployments where the venue can expose infrastructure metadata.

Primary risks:

- iPhone API limitations.
- AP/beacon movement and reconfiguration.
- Crowds and multipath.
- Requires fingerprinting or infrastructure metadata.

### 5. Manual Checkpoints Without Camera

Recommended fallback before camera.

Use explicit user confirmations, map-tap checkpoints, turn-by-turn prompts, short semantic questions, or staff/operator confirmation to re-anchor the route state. This is less automatic, but it preserves the no-camera product constraint and is often enough for the first route-constrained product.

Expected reliability:

- High when checkpoints are unambiguous to the user.
- Strong for route start, route branch, room/zone arrival, and low-confidence recovery.
- Weaker when users are distracted or checkpoints are hard to identify.

Best role:

- Start-of-route initialization.
- Recovery when magnetic/PDR confidence is low.
- Validation during survey and pilot testing.
- High-stakes transitions where false auto-advance is worse than asking.

Primary risks:

- Adds user friction.
- Requires good map labels and checkpoint naming.
- Not suitable for invisible/passive tracking.

### 6. Pure PDR / IMU-Only

Not reliable enough alone.

PDR is essential as an input, but by itself it drifts too quickly for indoor positioning. Use it only inside a map-constrained Bayesian filter and reset/correct it through magnetic fingerprints, non-camera checkpoints, OS-level priors, or, only as a last resort, camera confirmations.

### 7. QR / Printed Marker Checkpoints

Camera-based, so use only near the end of the fallback ladder.

Use QR codes, App Clip Codes, posters, or other printed markers at known checkpoints. This is not installed electronic hardware, but it is still a physical marker and requires user action plus camera access.

Expected reliability:

- Near-certain when the marker is visible and scannable.
- Exact semantic checkpoint confirmation.

Best role:

- Emergency recovery when passive and manual non-camera confirmation are not enough.
- Ground-truth collection for survey and evaluation.
- High-stakes checkpoints where false auto-advance is unacceptable.

Primary risks:

- Requires camera.
- Less magical.
- Requires placement and maintenance of visible markers.

### 8. Camera-Assisted Visual-Inertial Localization

Last option, despite being technically strong.

Use ARKit/VIO or image recognition to localize against known features: signs, room labels, exhibits, wall posters, printed markers, or saved AR maps. This uses no installed electronic hardware, but it does require camera use and sometimes physical visual markers.

Expected reliability:

- Very high for explicit QR/image markers or recognizable exhibits/signage.
- Strong for ARKit relative tracking over short paths in visually rich, well-lit spaces.
- Less reliable in blank corridors, poor lighting, repeated visual patterns, or changed layouts.

Best role for this product:

- Last-resort recovery when passive sensing and manual confirmation fail.
- Later museum/exhibit recognition workflows where camera use is expected.
- Debug/survey tooling to anchor collected magnetic tracks.

Primary risks:

- Violates the preferred no-camera experience.
- Requires user attention and privacy-friendly UX.
- Relative VIO drifts unless relocalized to known maps/anchors.
- Lighting and visual change can break relocalization.

## Recommended System Architecture

### Survey Pipeline

1. Import or draw the route graph. Each route lives on exactly one floor; the floor id is metadata only.
2. Define checkpoints and route segments.
3. Record magnetometer, accelerometer, gyroscope, device motion, pedometer, and optional altimeter samples (altimeter is recorded for future use only).
4. Tap anchors at known checkpoints.
5. Repeat each segment multiple times and in both directions when useful.
6. Normalize samples by estimated route distance.
7. Build per-segment magnetic signatures using magnitude, vector statistics, gradient features, and turn landmarks.
8. Validate with different phones and phone poses.

### Runtime Matcher

Use a belief-state model instead of a single blue-dot estimate.

State:

- route id
- segment id
- progress along segment
- heading/turn state
- confidence

Floor is route metadata, not filter state — floor detection is out of scope for v1.

Observations:

- magnetic window similarity
- magnetic gradient/landmark match
- step distance since last anchor
- turn events
- optional Core Location venue prior
- last-resort visual checkpoint

Algorithms:

- Current prototype: discrete-grid Bayes filter / HMM over route-distance bins, with magnetic first-difference observations, PDR step transitions, turn observations, and an explicit `OFF` state.
- Simpler MVP alternative: sliding-window magnetic sequence similarity plus route graph constraints.
- Segment-level alternative: HMM over route segments and checkpoint states.
- Free-form/map-rich alternative: particle filter over route-distance or floor-plan states with map constraints and magnetic observation weights.

### Confidence Contract

The system should prefer saying "I don't know" over falsely advancing the user.

Emit:

- `near_checkpoint`
- `checkpoint_confirmed`
- `progressed_to_segment`
- `possibly_off_route`
- `wrong_segment`
- `low_confidence`

(`floor_changed` is deferred along with floor detection.)

Do not promise:

- exact desk-level position
- always-on blue-dot navigation
- room-level certainty without survey validation
- tracking when the phone is in arbitrary pose without confidence degradation

## MVP Recommendation

Build a route-constrained checkpoint detector first.

Pilot requirements:

- One venue.
- Single-floor route (required — floor detection is out of scope for v1).
- 6-12 checkpoints.
- 3-5 survey passes per route direction.
- At least two iPhone models.
- Test hand-held, pocket, and bag separately.

Success metric:

- 80-90% checkpoint arrival detection within 2-5 m on the pilot route.
- False auto-advance rate low enough that manual confirmation feels like a fallback, not a correction habit.
- In ambiguous segments, the system emits `low_confidence` instead of inventing precision.

## Practical Decision

For this product, the most reliable hardware-less solution is:

Magnetic fingerprinting + PDR + route graph + confidence scoring + manual non-camera fallback.

Camera should remain the final fallback, not the next product layer:

Visual checkpoint/landmark recognition + ARKit/VIO + PDR + map constraints.

The best commercial-grade answer is not to choose one forever. Start with the no-camera magnetic/PDR route-constrained baseline, add manual non-camera confirmations for difficult checkpoints, use opportunistic OS/Wi-Fi/floor priors where they are genuinely available, and reserve visual confirmation for cases where all non-camera options fail.

## Sources

- Apple Core Motion documentation: https://developer.apple.com/documentation/coremotion
- Apple CMMotionManager documentation: https://developer.apple.com/documentation/coremotion/cmmotionmanager
- Apple CMMagnetometerData magneticField documentation: https://developer.apple.com/documentation/coremotion/cmmagnetometerdata/magneticfield
- Apple CMPedometer documentation: https://developer.apple.com/documentation/coremotion/cmpedometer
- Apple CMAltimeter documentation: https://developer.apple.com/documentation/coremotion/cmaltimeter
- Apple TN3111 iOS Wi-Fi API overview: https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
- Apple Developer Forums, iOS Network Signal Strength: https://developer.apple.com/forums/thread/721067
- Apple CLFloor documentation: https://developer.apple.com/documentation/corelocation/clfloor
- Apple ARKit tracking quality documentation: https://developer.apple.com/documentation/ARKit/managing-session-life-cycle-and-tracking-quality
- Apple ARWorldTrackingConfiguration documentation: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration
- Android Wi-Fi RTT documentation: https://developer.android.com/develop/connectivity/wifi/wifi-rtt
- A Review of Indoor Localization Methods Leveraging Smartphone Sensors and Spatial Context, Sensors 2024: https://www.mdpi.com/1424-8220/24/21/6956
- A Survey of Magnetic-Field-Based Indoor Localization, Electronics 2022: https://www.mdpi.com/2079-9292/11/6/864
- Towards Persistent Spatial Awareness: A Review of Pedestrian Dead Reckoning-Centric Indoor Positioning with Smartphones, IEEE TIM 2024: https://research.polyu.edu.hk/en/publications/towards-persistent-spatial-awareness-a-review-of-pedestrian-dead-/
- Smartphone-Based Indoor Localization Systems: A Systematic Literature Review, Electronics 2023: https://www.mdpi.com/2079-9292/12/8/1814
- Indoor Positioning Based on Pedestrian Dead Reckoning and Magnetic Field Matching for Smartphones, Sensors 2018: https://www.mdpi.com/1424-8220/18/12/4142
- Multi-Floor Indoor Pedestrian Dead Reckoning with a Backtracking Particle Filter and Viterbi-Based Floor Number Detection, Sensors 2021: https://pmc.ncbi.nlm.nih.gov/articles/PMC8271586/
- IndoorAtlas positioning accuracy FAQ: https://support.indooratlas.com/support/solutions/articles/36000035912-what-is-the-positioning-accuracy-of-indooratlas-
- IndoorAtlas map quality article: https://www.indooratlas.com/blog/ensuring-high-quality-indooratlas-maps/
