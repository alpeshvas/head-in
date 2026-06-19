# Indoor Positioning

Prototype workspace for phone-only indoor positioning using magnetic fingerprinting, inertial sensors, and route constraints.

## Research / Reference Docs

Start here:

- [Hardware-less Indoor Positioning Research](docs/hardware-less-solutions-research.md)
- [Architecture](docs/architecture.md)
- [Route Belief Filter Q&A](docs/route-belief-filter-qna.md)
- [Indoor Positioning Research Notes](docs/research-notes.md)
- [Dex GPS vs Indoor Positioning Checkpoint Triggers](docs/dex-gps-vs-indoor-positioning.md)

## Product Direction

The first useful target is route-constrained positioning, not free-form indoor GPS:

- Record magnetic, accelerometer, gyroscope, gravity/device-motion, step, and optional barometer data while surveying known indoor routes.
- Anchor survey sessions at known checkpoints.
- Build fingerprint profiles for route segments.
- Run a route-constrained grid Bayes filter over route-position bins plus an explicit `OFF` state.
- Emit conservative events such as checkpoint arrival, route progress, off-route/low-confidence state, or manual-fallback prompts.

The product should promise **checkpoint / route / zone confidence**, not an arbitrary indoor blue dot.

## Current Prototype Status

1. Survey recorder — **done** (`survey-recorder/`).
2. Checkpoint anchoring workflow — **done** (anchor button + undo in the recorder).
3. JSONL session format — **done** (schema notes in [research notes](docs/research-notes.md)).
4. Fingerprint profile builder — **done for prototype use** (`analysis/build-profile.js`).
5. Offline replay/reference filter — **done** (`analysis/grid-filter.js`).
6. Live iOS route filter — **done for prototype use** (`RouteBeliefFilter.swift` + `LivePositioningController.swift`).
7. Confidence/off-route/fallback behavior — **implemented, still validation-driven**.

## Survey Recorder (iOS)

A standalone SwiftUI app in `survey-recorder/` records:

- `CMDeviceMotion` calibrated magnetic field, attitude, rotation, user acceleration, and gravity at 100Hz
- raw magnetometer fallback/debug samples
- pedometer updates
- barometer samples for future use only
- checkpoint anchor taps
- optional surveyor-only ARKit ground truth for offline evaluation

```sh
brew install xcodegen           # one-time
cd survey-recorder
xcodegen generate               # produces SurveyRecorder.xcodeproj (gitignored)
open SurveyRecorder.xcodeproj   # set your signing team, run on a physical iPhone
```

Sensors don't exist on the simulator — surveys require a real device.

## Build a Route Profile

After walking the same route 3-5 times with anchors, build a reusable magnetic route profile:

```sh
npm run build-profile -- recordings-new/Plumeria_Test_forward_hand_normal_*.jsonl --out profiles/plumeria-test-forward.json
```

The profile contains:

- ordered anchors/checkpoints
- route segments
- magnetic magnitude mean/stddev arrays in route bins
- median step counts per segment
- optional turn signatures
- fitted calibration for magnetic observation likelihoods

## Replay the Grid Filter Offline

Replay a recorded session against a route profile:

```sh
node analysis/grid-filter.js profiles/plumeria-test-forward.json recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl --out analysis/replay.html
```

The offline JS filter is the reference implementation for the Swift runtime filter. Keep them in sync and regenerate parity fixtures when filter math changes.

## Useful Commands

```sh
npm run analyze -- session1.jsonl session2.jsonl session3.jsonl --out analysis/report.html
npm run build-profile -- session1.jsonl session2.jsonl session3.jsonl --out profiles/name.json
node analysis/grid-filter.js profiles/name.json session.jsonl --out analysis/filter-report.html
npm test
```

## Notes

- No venue-installed hardware for the default approach.
- No camera dependency for the end-user runtime.
- ARKit is surveyor-only ground truth tooling.
- Routes are single-floor; floor detection is out of scope for v1.
- Current map constraint is a 1D surveyed route profile, not a full 2D wall/floor-plan mesh.
- Design for checkpoint or zone accuracy before promising precise blue-dot location.
