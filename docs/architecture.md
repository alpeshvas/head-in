# Architecture Sketch

## Survey Recorder

Captures timestamped phone sensor samples during a known route walk.

- magnetometer
- accelerometer
- gyroscope
- step count or detected steps
- optional barometer (recorded for future use only; not used at runtime)
- checkpoint anchors

## Processing Pipeline

Turns raw survey sessions into route-segment fingerprints.

- clean noisy readings
- split samples between anchors
- align samples to route distance
- normalize for device orientation where possible
- store segment-level magnetic signatures

## Runtime Matcher

Compares live sensor windows against known fingerprints and map constraints.

- estimate route segment
- update distance along route with steps
- detect turns with gyroscope
- constrain candidates to walkable path geometry
- emit confidence-scored positioning events

## Product Contract

The first product promise should be checkpoint and zone confidence, not exact indoor GPS.

## Out of Scope (v1)

- Floor detection and multi-floor routes. Routes are single-floor; the floor a route belongs to is metadata only.
- Barometer/altimeter fusion at runtime. Barometer samples are still recorded during surveys so the data exists if floor detection returns to scope.
