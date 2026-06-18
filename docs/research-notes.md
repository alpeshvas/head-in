# Indoor Positioning Research Notes

## Current Goal

Build a no-installed-hardware indoor positioning prototype that works on phones, with the first focus on iPhone support.

The target is not full indoor GPS. The target is route-constrained confidence:

- detect whether the user is near a checkpoint
- estimate progress along a known route
- identify when confidence is low
- fall back to manual confirmation when needed

## Product Constraints

- No venue-installed hardware for the default approach.
- No camera dependency for the current prototype.
- iPhone support matters.
- Office and museum-like indoor spaces are both relevant.
- Routes are single-floor. Floor detection and multi-floor routes are out of scope for v1.
- The product should avoid promising exact blue-dot location until validated.

## Approaches Discussed

### 1. Wi-Fi RSSI / Fingerprinting

Uses signal strength readings from nearby Wi-Fi access points and matches them to a prebuilt fingerprint map.

Pros:

- Can reuse existing Wi-Fi access points.
- Fastest Wi-Fi approach to deploy if the platform can access scans.
- Useful for rough zone detection.

Cons:

- Accuracy is often around 5-15 meters in real venues.
- Signal strength changes with crowds, walls, device model, phone orientation, and access point changes.
- iOS is a major blocker because normal apps cannot freely scan the surrounding Wi-Fi environment.

Verdict:

Not a good default path for Dex-style iPhone-first indoor positioning. Could be useful only as an Android-only or backend-assisted signal in specific venues.

Reference:

- https://navigine.com/blog/wifi-for-indoor-positioning-and-navigation/

### 2. Wi-Fi RTT / ToF

RTT means Round Trip Time. ToF means Time of Flight. The system estimates distance by measuring signal travel time.

Pros:

- More precise than RSSI in favorable conditions.
- Can reach roughly 1-2 meters in optimized environments.

Cons:

- Requires compatible access points.
- Device support is limited, especially for iPhone app use.
- Still infrastructure-dependent in practice.

Verdict:

Interesting technically, but not a good no-hardware, iPhone-first default.

### 3. AoA

AoA means Angle of Arrival. The receiver estimates the direction a radio signal came from using multiple antennas.

Pros:

- Can be more accurate than RSSI.
- Useful for installed indoor positioning systems.

Cons:

- Requires specialized anchors or access points with antenna arrays.
- Normal consumer routers are usually not enough.
- Phone-only AoA is not practical for this product direction.

Verdict:

Reliable only when venues install infrastructure. Good for high-commitment venues, not for the default no-hardware path.

### 4. BLE Beacons / UWB

Uses installed beacons or anchors to estimate proximity or precise position.

Pros:

- BLE can be decent for zone or proximity detection.
- UWB can be highly accurate.
- Purpose-built for indoor positioning.

Cons:

- Requires physical devices.
- Requires install, maintenance, battery replacement or wiring, and venue cooperation.
- Only a few venues may be willing to do this.

Verdict:

Good optional premium path for committed venues, but not the default.

### 5. QR / NFC Checkpoints

Users scan a code or tap a tag at known points.

Pros:

- Very reliable.
- Cheap.
- Simple to operate.
- Good as a fallback or explicit confirmation.

Cons:

- Requires visible labels or tags.
- Not automatic.
- Can feel less magical than passive positioning.

Verdict:

Excellent fallback and validation anchor, but it does require some physical marker in the venue.

### 6. Camera / Visual Recognition

Uses the phone camera to recognize exhibits, rooms, signs, or landmarks.

Pros:

- Strong semantic confirmation.
- No installed electronic hardware.
- Especially good for museums and object-based spaces.

Cons:

- Current prototype direction excludes camera.
- Requires user action or visible environment.
- Lighting, occlusion, and privacy expectations matter.

Verdict:

Potentially very strong for Dex, but not part of this phone-sensor-only prototype.

### 7. Magnetic Fingerprinting

Uses the phone magnetometer to read indoor magnetic distortions caused by steel, wiring, elevators, HVAC, reinforced concrete, and other building materials. These distortions create a fingerprint that can be mapped during setup and matched at runtime.

Pros:

- No venue-installed hardware.
- No camera dependency.
- Available on phones.
- Can work well when constrained to known routes.
- Useful for checkpoint arrival and route progress.

Cons:

- Requires venue survey.
- Accuracy is building-dependent.
- Repetitive corridors and open-plan offices can be ambiguous.
- Phone orientation and placement matter.
- Environmental changes can reduce confidence.

Expected accuracy:

- Favorable building and well-surveyed route: about 1-3 meters.
- Typical office or average real-world deployment: about 3-6 meters.
- Weak or repetitive magnetic environment: 5-10+ meters or ambiguous.

Verdict:

Best no-camera, no-installed-hardware default candidate. Should be combined with inertial sensing and map constraints.

### 8. PDR / Inertial Sensing

PDR means Pedestrian Dead Reckoning. It estimates motion using accelerometer, gyroscope, step count, turns, and sometimes barometer.

Useful iPhone signals:

- magnetometer
- accelerometer
- gyroscope
- Core Motion pedometer / step count
- device motion attitude
- barometer where available (recorded for future use only; runtime floor detection is out of scope)

Pros:

- No installed hardware.
- Helps smooth and constrain magnetic matching.
- Steps estimate distance since the last anchor.
- Gyro helps detect turns.
- Barometer can help with floor changes (deferred; out of scope for v1).

Cons:

- Drifts over time.
- Step length varies by user.
- Phone placement affects readings.
- Needs map and route constraints to stay reliable.

Verdict:

Should accompany magnetic fingerprinting. Magnetometer alone is too weak; magnetic + PDR + map constraints is the practical approach.

## Recommended Direction

Build a phone-only system using:

- magnetic fingerprinting
- step detection / Core Motion pedometer
- gyroscope turn detection
- indoor map constraints
- known route and checkpoint sequence
- confidence scoring
- manual confirmation fallback

The product should first emit events like:

- `near_checkpoint`
- `progressed_to_segment`
- `possibly_off_route`
- `low_confidence`

It should not initially promise exact real-time blue-dot positioning.

## Out of Scope (v1)

- Floor detection and multi-floor routes. Every route lives on exactly one floor; the floor id is metadata only.
- Barometer/altimeter fusion, stair/elevator/escalator event detection, and any `floor_changed` runtime event.
- Barometer samples are still captured during surveys (cheap, and impossible to backfill) so floor detection can return to scope later without re-surveying.

## Survey Setup Workflow

Each venue or route needs a survey pass before runtime matching can work.

1. Prepare the indoor map.
2. Define walkable route geometry and checkpoints. Routes must stay on a single floor; the floor is metadata only.
3. Open an internal survey mode.
4. Select venue, floor, tour, route, and starting checkpoint.
5. Start recording sensor samples.
6. Walk the route.
7. Tap anchors at checkpoints or known map positions.
8. Repeat 3-5 passes per route segment.
9. Record reverse-direction passes when useful.
10. Process raw sessions into route-segment fingerprints.
11. Validate with test walks on different phones.

## Survey Tool MVP

The first survey tool should be route-constrained, not free-form map drawing.

Minimum features:

- select venue / floor / route
- show indoor map and ordered checkpoints
- start and stop recording
- tap anchor when arriving at a checkpoint
- record timestamped sensor samples
- save locally if upload fails
- upload complete survey session

Minimum sample fields:

- timestamp
- magnetometer x/y/z
- accelerometer x/y/z
- gyroscope x/y/z
- device motion attitude if available
- step count or step event
- optional barometer (recorded for future use; not consumed at runtime in v1)
- checkpoint anchors
- device model
- route id, floor id (metadata only), venue id

Rough effort:

- basic recording tool: 2-5 days
- checkpoint anchoring and upload: 1-2 weeks
- quality feedback and repeatable survey workflow: 2-4 weeks
- first matching prototype: 2-6 weeks
- production reliability across venues and devices: 2-4+ months

## Runtime Matching Sketch

At runtime, the matcher should combine multiple weak signals into a stateful route estimate.

Inputs:

- live magnetic samples
- recent step count and cadence
- recent gyroscope turn events
- route geometry
- checkpoint order
- previous estimated segment

Current prototype process:

- maintain a probability distribution over route-position bins, plus an explicit `OFF` state
- call `predictStep()` when a step is detected to move probability along the route
- call `observe(...)` to compare recent magnetic first-difference windows against stored fingerprints
- call `observeTurn(...)` for hand-carry turn landmarks and unmatched U-turn/off-route evidence
- constrain on-route belief to the surveyed 1D route profile rather than arbitrary indoor `(x,y)`
- fire checkpoints only from posterior probability and confidence guards, not dead reckoning alone
- emit confidence-scored events

Implemented algorithm:

- Discrete-grid Bayes filter / HMM over route-position bins plus one `OFF` state.

Related future algorithm families:

- Particle filter constrained to route geometry, especially if the state expands to 2D `(x,y,heading)`.
- Dynamic Time Warping or learned sequence matching as richer magnetic observation models.
- Simpler sliding-window similarity only as a baseline, not the current live matcher.

For current implementation details and thresholds, see [Architecture](architecture.md) and [Route Belief Filter Q&A](route-belief-filter-qna.md).

## Office-Specific Notes

Offices can work, but reliability is uneven.

Good signals:

- elevators
- wiring closets
- steel framing
- HVAC-heavy zones
- reinforced concrete
- server rooms

Hard cases:

- repetitive open-plan spaces
- identical corridors
- glass partitions
- adjacent rooms through a wall
- exact desk-level positioning

Expected office accuracy:

- good office: about 2-4 meters
- typical office: about 3-6 meters
- repetitive office: about 5-10 meters or ambiguous

Best office use cases:

- room or zone arrival
- meeting-room cluster detection
- corridor segment detection
- route progress along known corridors

Avoid:

- exact desk-level positioning
- high-confidence blue-dot navigation in open areas

## Open Questions

- How stable are magnetic fingerprints across iPhone models?
- How much does phone placement affect matching: hand, pocket, bag?
- How many survey passes are needed for acceptable confidence?
- Can route-constrained matching detect checkpoint arrival within 2-5 meters?
- What confidence threshold avoids annoying false auto-advances?
- How often do venue changes require re-surveying?

## Initial Success Metric

For one pilot route, detect checkpoint arrival within about 2-5 meters at least 80-90% of the time, while correctly entering `low_confidence` instead of making false claims when the signal is ambiguous.
