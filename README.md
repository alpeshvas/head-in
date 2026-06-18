# Indoor Positioning

Prototype workspace for phone-only indoor positioning using magnetic fingerprinting, inertial sensors, and map constraints.

## Research First

The most important artifact right now is the research log:

- [Indoor Positioning Research Notes](docs/research-notes.md)
- [Architecture Sketch](docs/architecture.md)

## Product Direction

The first useful target is route-constrained positioning, not free-form indoor GPS:

- Record magnetic, accelerometer, gyroscope, and step data while surveying known indoor routes.
- Anchor survey sessions at known checkpoints or map positions.
- Build fingerprint profiles for route segments.
- Match live phone sensor readings against those profiles.
- Emit confidence-scored events such as `near_checkpoint`, `wrong_segment`, or `low_confidence`.

## MVP Milestones

1. Survey recorder — **done** (`survey-recorder/`, see below)
2. Checkpoint anchoring workflow — **done** (anchor button + undo in the recorder)
3. Local survey session format — **done** (JSONL, schema in [research notes](docs/research-notes.md))
4. Fingerprint processing pipeline — **started** (`analysis/`, repeatability + profile builder)
5. Route-segment matcher — **started** (offline matcher)
6. Confidence scoring and fallback rules

## Survey Recorder (iOS)

A standalone SwiftUI app in `survey-recorder/` that records `CMDeviceMotion`
(calibrated magnetic field, attitude, rotation, acceleration), raw magnetometer,
pedometer, and barometer samples at 100Hz into JSONL session files, with a
checkpoint anchor button. Sessions are exportable via the share sheet and the
Files app.

```sh
brew install xcodegen           # one-time
cd survey-recorder
xcodegen generate               # produces SurveyRecorder.xcodeproj (gitignored)
open SurveyRecorder.xcodeproj   # set your signing team, run on a physical iPhone
```

Sensors don't exist on the simulator — surveys require a real device.

## Repeatability Analysis (feasibility spike)

After walking the same route 3-5 times with the recorder, compare passes:

```sh
npm run analyze -- session1.jsonl session2.jsonl session3.jsonl --out analysis/report.html
```

Per anchor-to-anchor segment it reports pass-over-pass Pearson correlation and
DTW deviation of the magnetic magnitude trace, plus an HTML report with
overlaid traces. STRONG (r >= 0.8) means magnetic fingerprinting is viable on
that route; WEAK means the venue is magnetically hostile and no matcher will
fix it.

## PDR + Magnetic Replay Prototype

After collecting 3+ sessions, run a leave-one-session-out replay that builds a
fingerprint from the other passes, estimates route progress from accelerometer
step peaks, and uses magnetic matching as a correction near the PDR prior:

```sh
npm run position -- session1.jsonl session2.jsonl session3.jsonl --out analysis/pdr-report.html
```

This is not a production tracker yet. With only Start/End anchors, its error
metric is measured against normalized replay time. Add intermediate anchors to
validate real checkpoint/position error.

## Route Profile + Offline Matcher

Build a reusable fingerprint profile from repeated walks:

```sh
npm run build-profile -- Meadows_Test_forward_hand_*.jsonl --out profiles/meadows-test-forward.json
```

Then replay a session against that profile:

```sh
npm run match -- profiles/meadows-test-forward.json Meadows_Test_forward_hand_20260610-200257.jsonl --out analysis/meadows-match.html
```

The profile builder classifies very short/adjacent anchor spans as
`transition` segments and excludes them from magnetic matching. The matcher uses
recorded anchors only to split offline validation segments; a production runtime
matcher still needs a live segment-state model.

## Notes

- No venue-installed hardware.
- No camera dependency.
- Routes are single-floor. Floor detection is out of scope for v1.
- Design for checkpoint or zone accuracy before promising a precise blue dot.
