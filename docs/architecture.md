# Architecture

This prototype is a **route-constrained indoor positioning system**. It does not try to locate a phone anywhere inside a building. It estimates progress along a known, surveyed route and emits conservative checkpoint/zone confidence.

## Survey Recorder

The Survey Recorder captures timestamped phone sensor samples during a known route walk and writes them as JSONL session files.

### Sensor streams

- **Device motion / calibrated magnetic field** — `CMDeviceMotion` is requested at `100Hz` via `SensorRecorder.sampleRateHz`. The app records calibrated magnetic field, attitude quaternion, rotation rate, user acceleration, and gravity. Timestamps are preserved, so downstream tooling can use the actual sample times if delivery jitters.
- **Raw magnetometer** — raw `CMMagnetometerData` is also requested at `100Hz` as a fallback/debug stream.
- **Steps** — survey files record Apple `CMPedometer` step updates. Offline and live matching can also detect step timing from user-acceleration peaks, because the filter needs step times, not only cumulative OS step count.
- **Barometer** — relative altitude and pressure are recorded for future use only. Floor detection is out of scope for v1.
- **Checkpoint anchors** — known route points that the surveyor marks while walking, such as Start, doorway, turn, room entry, or route end. They are stored as timestamped `anchor` JSONL records with `index` and `name`. Anchors split survey data into route segments and provide validation truth; normal live users do not tap these.
- **Optional ARKit ground truth** — surveyor-only 6-DoF pose logging for offline metric evaluation. The end-user runtime remains camera-free.

Primary implementation files:

- `survey-recorder/SurveyRecorder/SensorRecorder.swift`
- `survey-recorder/SurveyRecorder/RecordingController.swift`
- `survey-recorder/SurveyRecorder/SessionWriter.swift`
- `survey-recorder/SurveyRecorder/ARPoseRecorder.swift`

## Processing Pipeline

The processing pipeline turns repeated survey sessions into reusable route profiles.

1. **Parse JSONL sessions** and prefer calibrated `dm.mag` readings over raw magnetometer fallback.
2. **Apply anchor edits** such as `anchor_undo`.
3. **Split samples between checkpoint anchors** to form route segments.
4. **Resample each segment** into a fixed number of route bins, currently 240 bins per segment in the profile builder.
5. **Compute magnetic fingerprint statistics** for every bin across repeated passes.
6. **Detect turns** from gyro rotation projected onto gravity, then keep majority-vote route turn signatures.
7. **Classify short spans** as `transition` segments so they are not treated as distinctive magnetic fingerprints.
8. **Fit profile calibration** values used by the runtime observation model.

Implemented tools:

- `analysis/analyze-repeatability.js` checks repeated-pass magnetic quality with Pearson correlation and DTW deviation.
- `analysis/build-profile.js` builds profile JSON with route segments, magnetic mean/stddev arrays, turn signatures, and calibration.
- `analysis/ground-truth.js` converts surveyor ARKit poses into true along-route meters for offline scoring.
- `analysis/splice-pauses.js` removes standing pauses for pocket-survey profiles.

## Profile Data Structure

Profiles are JSON files under `profiles/*.json` and bundled app copies live under `survey-recorder/SurveyRecorder/Resources/*.json`.

At the top level, a profile contains:

- `route` — venue, route id, direction, device pose, and floor metadata.
- `anchors` — ordered checkpoint names and indexes.
- `segments` — route spans between adjacent anchors.
- `turns` — optional route turn signatures.
- `calibration` — optional fitted noise parameters for the filter.

Each `segments[]` item stores metadata plus `magneticMagnitude` arrays:

```json
{
  "index": 0,
  "from": "Start",
  "to": "Room exit",
  "kind": "fingerprint",
  "useForMatching": true,
  "quality": "moderate",
  "detectedSteps": { "median": 9 },
  "magneticMagnitude": {
    "mean": [41.03, 40.98, 41.00],
    "stddev": [0.42, 0.39, 0.45]
  }
}
```

- **Magnetic mean** is the average magnetic-field magnitude measured at a route bin across survey passes.
- **Stddev** is the typical spread around that mean at the same bin.
- **Variance** is `stddev²`; the code stores stddev because it is easier to read, while probability calculations use variance-like noise terms internally.

Turn signatures are stored on the profile's global route-bin axis:

```json
{ "bin": 350, "deltaDeg": -159, "sigmaBins": 18, "passes": 3 }
```

This means: across the survey passes, a roughly `-159°` turn repeatedly appeared near global bin `350`, with expected location spread `sigmaBins`.

## Runtime Matcher

The current matcher is a **grid Bayes filter** over a 1-D route axis plus an explicit `OFF` state.

Reference and runtime files:

- JS reference/offline replay: `analysis/grid-filter.js`
- Swift runtime port: `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift`
- Live app wiring: `survey-recorder/SurveyRecorder/LivePositioningController.swift`
- Swift parity tests: `survey-recorder/Tests/FilterParityTests.swift`

### State model

All profile segments are concatenated into one global array of route bins. The filter keeps:

- probability for each route bin: “the user may be here on the known route”
- `pOff`: probability that the route no longer explains the live motion/readings

### Predict step

When a step is detected, the filter shifts probability forward by the segment's learned stride in bins. The stride comes from the survey profile's median detected steps for that segment:

```text
binsPerStep = segmentBinCount / medianSurveySteps
```

Different users can have shorter or longer strides, so the filter does not move all probability by exactly one fixed distance. It uses a noisy step kernel (`stepNoiseFrac = 0.35`) with a small backward/stay tail, then lets magnetic windows and turns correct drift over time. This is probabilistic stride handling, not per-user stride calibration.

### Path constraints

“Path constraints” means the filter only considers positions along the surveyed route, not arbitrary indoor x/y coordinates.

Concretely:

- on-route belief can move only by plausible step transitions along the route-bin axis
- route start and route end are barriers
- transitions can include uncertainty and limited backward motion, but not teleporting while still on-route
- turns are expected only near stored turn-signature bins
- checkpoints fire in route order
- unmatched large turns and uncorroborated movement can move probability into `OFF`

### Magnetic observation update

After steps, the live magnetic magnitude window is resampled per step and compared against candidate route bins. The current filter uses stride-lag **first differences**, not raw absolute magnitude, because differences are more robust to device bias and mid-walk magnetic recalibration.

The observation model reweights bins whose profile magnetic pattern best explains the live window. Flat windows or uncalibrated magnetometer periods are treated cautiously; motion without magnetic corroboration leaks probability into `OFF`.

### Turn observations

For hand-carry live runs, gyro rotation is projected onto the gravity axis to detect signed yaw turns. A live turn can:

- match a stored profile turn near the current posterior support and re-concentrate belief there
- fail to match any expected route turn, in which case a U-turn-scale rotation injects probability into `OFF` and temporarily suppresses checkpoint firing

Turn evidence is disabled/down-weighted for pocket mode because leg swing distorts turn magnitudes.

### OFF state and re-entry

If the route stops explaining the live readings, probability moves into `OFF`. This lets the app say “Off route?” instead of forcing a bad checkpoint.

The current implementation supports **local re-entry**: `OFF` probability can leak back onto route bins near the last confident on-route mode. It is designed for cases like brief detours, drift recovery, or leaving and rejoining near the same area.

It does **not** currently implement global relocalization to an arbitrary far-away segment after a teleport-like jump. Supporting “leave at segment A, re-enter at distant segment D” would require a wider/global re-entry model and stronger ambiguity handling so similar magnetic segments do not cause false jumps.

### Checkpoint firing

A checkpoint fires only when all of these are true:

- recent magnetic evidence exists
- posterior route mass is past the checkpoint decision bin
- `pOff` is below the off-route threshold
- no unresolved reversal is active
- the condition holds for consecutive updates

This is intentionally conservative: dead reckoning alone should not silently advance the tour.

## Product Contract

The first product promise should be **checkpoint and zone confidence**, not exact indoor GPS.

For the Dex integration comparison and trigger-selection recommendation, see [Dex GPS vs Indoor Positioning Checkpoint Triggers](dex-gps-vs-indoor-positioning.md).

## Out of Scope (v1)

- Floor detection and multi-floor routes. Routes are single-floor; the floor a route belongs to is metadata only.
- Barometer/altimeter fusion at runtime. Barometer samples are still recorded during surveys so the data exists if floor detection returns to scope.
- Arbitrary indoor blue-dot positioning.
- Global relocalization after jumping to a distant route segment.
