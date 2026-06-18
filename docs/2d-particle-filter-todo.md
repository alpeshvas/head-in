# 2D Particle Filter TODO

Goal: move from 1D route progress to single-floor 2D positioning on a venue floor plan. Floors are out of scope; each venue map is one 2D coordinate plane.

## Product Direction

- Build a web floor-plan editor for fast iteration; do not make iPhone polygon editing the primary workflow.
- Load the exported venue map into the iOS app for survey, heatmap visibility, and runtime positioning.
- Include rooms from the beginning so the runtime can report both `x,y` and room/zone confidence.
- Use ARKit only during survey to attach sensor samples to floor-plan `x,y`; runtime remains camera-free.
- Use a full 2D particle filter for runtime experiments, not a 1D route graph first.

## Web Floor-Plan Editor

- Import a floor-plan image or PDF.
- Set scale by selecting two points and entering real-world distance.
- Store map geometry in meters; image pixels are only a background/reference layer.
- Draw and edit walkable polygons.
- Draw and edit walls or blocked polygons.
- Draw and name room polygons.
- Mark named entrances and start points.
- Mark named AR alignment points for survey calibration.
- Export `venue-map.json` and referenced floor-plan image assets.

## iOS Survey Mode

- Load `venue-map.json` and render the floor plan with geometry overlays.
- Align ARKit coordinates to map coordinates using at least two known alignment points; prefer three or more points for least-squares correction.
- Record each survey sample with timestamp, AR pose, map `x,y`, magnetic vector, magnetic accuracy, gravity vector, user acceleration, rotation rate, and inferred room id.
- Compute magnetic features from recorded vectors: magnitude `|B|` and vertical component `Bv = dot(B, gravityUnit)`.
- Show live survey trail on the map.
- Show iOS heatmap overlays during and after survey.

## iOS Heatmap Modes

- Survey strength mode: visualize sample/pass coverage per map cell.
- Magnetic field change mode: visualize local magnetic texture/gradient strength from `|B|` and later `Bv`.
- Use shared map rendering for survey and runtime diagnostics.
- Keep heatmap layers visible in the app, not only in web reports.

## Magnetic Map Builder

- Bucket aligned survey samples into fixed-size cells, initially 0.5 m.
- Store sample count, pass count, mean/stddev of `|B|`, mean/stddev of `Bv`, and magnetic-change score per cell.
- Smooth or interpolate sparse cells with a bounded radius; preserve unsurveyed/low-confidence cells.
- Generate exported `magnetic-grid.json` for runtime.

## Runtime Particle Filter

- Particle state: `x`, `y`, `heading`, `weight`.
- Initialize from a known entrance/start point first.
- Use gyro for relative heading change; allow heading hypotheses to converge through map constraints and magnetic observations.
- Predict each step with stride length/noise and heading noise.
- Penalize particles that leave walkable areas or cross walls.
- Reweight particles using recent `|B|`/`Bv` window likelihood against the magnetic map.
- Resample when effective particle count falls below threshold.
- Render estimated `x,y`, confidence radius, likely room, and heatmap/debug overlays in iOS.

## Validation

- Replay held-out survey walks before live runtime tests.
- Track P50/P75/P90 `x,y` error, room accuracy, convergence time, wrong-room transitions, off-map detection, and confidence calibration.
- Keep one-tap/manual fallback UX even if the 2D estimate is available.
