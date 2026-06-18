# Dex GPS vs Indoor Positioning Checkpoint Triggers

Updated: 2026-06-17

## Bottom line

For **outdoor route arrival**, Dex's existing GPS trigger is appropriate and simple. For **indoor checkpoint detection**, this repository's route-constrained indoor positioning approach is the stronger implementation.

The indoor system should be treated as a checkpoint/zone-confidence engine, not a precise blue-dot replacement.

## Current Dex GPS trigger

Dex currently auto-advances outdoor path checkpoints from GPS distance-to-destination logic in `../dex-ios`:

- `src/feature/GPS/GPSModule.tsx`
- `src/feature/GPS/hooks/useGPSPathTrigger.ts`
- `src/feature/GPS/hooks/useGPSTriggers.ts`
- `src/feature/GPS/utils/GPSEngineUtils.ts`

It is enabled only when the current checkpoint is a path segment, the tour map is `geojson`, GPS triggers are enabled, and location permission is granted.

The trigger point is the current path segment destination. Dex watches device location, computes distance to that destination, and fires `TRIGGER_NEXT_POINT` once the user has stayed inside the dynamic radius long enough.

### Practical GPS accuracy

Dex uses GPS accuracy tiers:

| GPS accuracy | Trigger behavior |
| --- | --- |
| ≤15m | 2 inside-radius hits + 2s dwell |
| ≤40m | 3 hits + 5s dwell |
| ≤80m | 3 hits + 8s dwell |
| >80m | fallback/manual advancement |

The radius is dynamic: `baseRadius + 0.5 * accuracy`, capped at 50m. In practice this makes Dex GPS auto-advance a roughly **15–50m outdoor arrival detector**, depending on sensor quality.

This is not a global nearby-checkpoint detector. It only checks the current route/path destination.

### Connectivity requirement

The GPS trigger itself is local to the device and does not need a server round trip. Network/Wi-Fi/cellular can still help iOS obtain a faster or better-assisted location fix, and tour/media/map assets may need connectivity unless cached.

## Indoor positioning implementation

This repository implements a phone-only, route-constrained indoor tracker using:

- magnetic fingerprint matching,
- step-based dead reckoning,
- gyro turn anchors,
- route/map constraints,
- an explicit `OFF` route state,
- confidence-gated checkpoint firing.

Primary runtime files:

- `survey-recorder/SurveyRecorder/LivePositioningController.swift`
- `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift`

Checkpoint firing is posterior-based and deliberately conservative. A checkpoint can fire only when:

- recent magnetic evidence exists,
- posterior mass has crossed the next checkpoint decision bin,
- off-route probability is low,
- no unresolved reversal is active,
- the condition is satisfied consecutively.

Conceptually:

```swift
stepsSinceObservation <= 2
probBeyond(checkpointDecisionBin) / onRoute > 0.8
pOff < 0.5
!reversalActive
```

This means dead reckoning alone should not silently advance a checkpoint.

## Why the indoor implementation is better indoors

Compared with Dex GPS, the indoor implementation has the right failure model for museums, apartments, and indoor venues:

- GPS degrades indoors; magnetic and inertial signals remain available.
- It follows a known route rather than using raw radial distance.
- It can identify off-route or low-confidence states instead of forcing a checkpoint.
- It can use turn landmarks and repeated magnetic signatures to distinguish route progress.
- It can work offline if the route profile is already bundled/downloaded.

Validated prototype results in `docs/STATUS.md` show sub-meter checkpoint replay accuracy on tested routes, including live hand and pocket runs. Those numbers are promising, but they are not yet a product-wide guarantee.

## Caveats before using it in Dex

The indoor system is not a drop-in replacement for Dex GPS. It needs:

- surveyed route profiles per venue/path,
- per-venue magnetic distinctiveness checks,
- route-start alignment,
- hand vs pocket carry handling,
- broader validation across venues and iPhone models,
- manual fallback for low-confidence/off-route states.

Keep the product promise to **checkpoint/zone confidence**, not continuous exact indoor position.

## Recommendation

Use both systems by environment:

- **Outdoor geo routes:** keep Dex GPS triggers.
- **Indoor guided routes with prepared profiles:** use this indoor positioning engine for checkpoint detection.
- **Unknown/unsurveyed indoor spaces:** do not promise automatic checkpoint detection; provide manual advancement or camera/QR-assisted fallback.
