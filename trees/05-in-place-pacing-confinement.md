# In-place pacing / confinement research

## TL;DR

The current confinement gate is a useful cheap guardrail: it blocks checkpoint fires when an 8 s magnetic-magnitude window has too little range versus the venue profile. But it is only a final firing gate, not a displacement model; the filter can still march belief forward on steps and then fire as soon as the range ratio rises. Best next step is to model **IN_PLACE / no-displacement walking** explicitly using three evidence families: phone IMU activity classification, posterior-local magnetic sequence displacement statistics, and turn/circle sequence consistency.

Recommendation: keep the existing gate as one conservative feature, but add a posterior-aware in-place likelihood that can switch detected steps to a “stay/diffuse” transition and block checkpoint firing. Validate as an ablation on existing normal/live/pacing recordings and parity fixtures before changing runtime behavior.

## External findings with source links

1. **Stationary stepping is a known PDR failure mode and can be classified from phone IMU.** Wu/Ma et al. define “stationary stepping” as taking steps in the same place; they explicitly set step length to zero (`lambda = 0`) even though it has walking-like accelerometer characteristics. Their held-phone HAR uses 2 s windows and a hierarchical SVM+decision-tree classifier; the decision tree separates normal walking, lateral walking, and stationary stepping using acceleration magnitude mean and x-axis acceleration variance with 99.44% mean accuracy, and overall HAR accuracy is >98.44%. [HAA-PDR, Remote Sensing 2021](https://www.mdpi.com/2072-4292/13/11/2137)

2. **Handheld phone motion can be decoupled from actual body displacement.** Susi/Renaudin/Lachapelle classify mobile-phone user motion into static/no-location-change, walking with quasi-stable phone, walking with swinging hand, and irregular hand motion. They emphasize that stepping on the spot and irregular hand motions must be treated as static/no-displacement or PDR will incorrectly propagate position. Their features use accelerometer/gyro energy, variance, and dominant frequencies over 2.56 s windows; irregular-motion detection was 94%, and step detection was >97% across modes. [Sensors 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3649428/)

3. **Magnetic evidence should be sequence/shape evidence, not only point/range evidence.** Magil localizes using only geomagnetic sequence matching, mean-removing local magnetic windows to handle device offsets and using modified Smith-Waterman alignment plus path construction; it is robust to walking-speed variation because sequence shape is preserved. This supports using magnetic sequence statistics as independent evidence of actual traversal rather than trusting step count. [Magil / EWSN 2017 PDF](https://www.cse.ust.hk/~gchan/papers/EWSN17_magil.pdf)

4. **Magnetic first differences and gravity-frame components are widely used to reduce heterogeneity.** A TCN magnetic-positioning system preprocesses magnetic trajectories with coordinate transformation, moving average, and first-order differencing; it uses horizontal, vertical, and intensity features and reports 99.8% accuracy on trained smartphones, with lower but usable accuracy on unseen phones. This aligns with adding vertical/horizontal magnetic difference features to the repo’s current magnitude-only confinement gate. [Sensors 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC9921884/)

5. **PDR+magnetic sequence matching works best when trajectory plausibility is explicit.** Kuang et al. use a magnetic-field sequence plus a PDR trajectory contour; a 7 m magnetic sequence improved distinguishability over single-point magnetic fingerprints and achieved RMS errors of 0.64 m in an office, 1.87 m in a lobby, and 2.34 m in a shopping mall. For pacing, the inverse implication matters: if steps imply meters of traversal but the magnetic sequence does not show route-scale traversal, that is negative evidence for displacement. [Sensors 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6308508/)

6. **Turns are strong landmarks, but circling needs cumulative turn logic.** HAA-PDR found turning-based trajectory optimization was the dominant improvement: baseline PDR mean error was 37.73 m; turn-only optimization reduced it to 1.92 m; full HAA-PDR was 1.79 m. Their turn detector uses heading range over a ~1.5 s window with 75°/135° thresholds for 90°/180° turns. For this repo, single-turn anchors are already present, but pacing/circling needs windowed cumulative-yaw and route-turn-sequence consistency, not just single U-turn handling. [HAA-PDR](https://www.mdpi.com/2072-4292/13/11/2137)

## Critique of current confinement approach

Local citations:

- `/Users/alpesh/codebase/indoor-positioning/analysis/grid-filter.js` — `PARAMS.confinementWindowSec`, `confinementFireMin`, `profileTypicalWindowRange()`, replay `confinementRatio()`, checkpoint `ok` guard.
- `/Users/alpesh/codebase/indoor-positioning/survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` — Swift parity constants and `GlobalRouteProfile.typicalWindowRange`.
- `/Users/alpesh/codebase/indoor-positioning/survey-recorder/SurveyRecorder/LivePositioningController.swift` — live `confinementRatio(at:)` and checkpoint fire condition.
- `/Users/alpesh/codebase/indoor-positioning/survey-recorder/Tests/FilterParityTests.swift` — explicit pacing parity tests: `testPacingTraceParity`, `testL478PacingTraceParity`, `testRaviPlacePacingTraceParity`, plus clean/normal comparators.

Current behavior, as implemented:

- Computes a venue-normalized confinement ratio: `live 8s magnetic magnitude range / median profile ~6-step window range`.
- Uses `confinementFireMin = 0.8`, `confinementWindowSec = 8`, `confinementMinSamples = 30`.
- Blocks checkpoint fires when the ratio is low, but leaves belief tracking, step prediction, magnetic observation, and OFF probability otherwise unchanged.
- Code comments state the empirical split used for this threshold: forward walks measured >=0.9x profile range; pacing <=0.70x; weak-gradient office forward still 1.48x.

Strengths:

- Very cheap, deterministic, and JS/Swift identical.
- Directly targets the observed false-fire mode: “steps but no net displacement.”
- Conservative because it blocks fires rather than perturbing tracking.
- Already represented in parity coverage through pacing fixtures.

Weaknesses:

1. **It is a gate, not a motion model.** During pacing, step prediction can keep pushing posterior mass forward. If the ratio later rises above 0.8 because of phone rotation, a local magnetic anomaly, or circling, stored progress can immediately satisfy the checkpoint tail condition.
2. **Global normalization is blunt.** `profileTypicalWindowRange()` uses a route-wide median. Real expected field variation is segment/posterior dependent; a flat corridor, transition segment, or unusually strong local gradient can miscalibrate the ratio.
3. **Min/max range is not robust.** One magnetic spike, MagSafe disturbance, nearby metal object, or phone rotation can inflate range without displacement.
4. **Magnitude-only leaves information unused.** The recorder stores magnetic vector and gravity; current confinement ignores gravity-frame vertical/horizontal magnetic components, vector direction changes, and sequence derivatives.
5. **It assumes low magnetic variation means in-place.** That is often true but not universal; true walking in a weak field can be low-range, and in-place circling near a strong anomaly can be high-range.
6. **It does not classify IMU stationary stepping.** `LivePositioningController` treats any step detected while `motionMode == .walking` as displacement-capable; there is no `stationaryStepping` / `pacing` mode.
7. **Circling is under-modeled.** Single unmatched U-turns can inject OFF, but repeated turns/circles need cumulative yaw and route-turn-sequence checks. A circle can have lots of magnetic variation while zero net route progress.

## Alternate / additional features

### 1. Add an explicit `IN_PLACE` hypothesis

Do not force in-place pacing into `OFF`. The user may be physically on the route but not progressing. Add either:

- a lightweight controller-level `pInPlace` score that blocks checkpoint firing and reduces step advancement, or
- a filter state parallel to route/OFF: `ROUTE_PROGRESS`, `IN_PLACE_ON_ROUTE`, `OFF`.

Runtime effect when `pInPlace` is high:

- step transition becomes mostly stay/diffuse instead of forward stride;
- checkpoint firing remains blocked;
- OFF is reserved for evidence that the route no longer explains the magnetic/turn sequence.

### 2. Posterior-local magnetic displacement ratio

Replace or augment global range ratio with candidate/posterior-aware ratios:

- `localRangeRatio = liveRange(W) / E_profile[range(s, W) | posterior]`
- `diffEnergyRatio = RMS(stride-lag first differences in live window) / E_profile[RMS(stride-lag first differences at s) | posterior]`
- `magProgressLLR = log p(live sequence | route-progress) - log p(live sequence | confined/no-displacement)`

Why: existing filter already uses stride-lag first differences for magnetic observation; use the same statistic for confinement instead of separate min/max range.

### 3. IMU stationary-stepping / pacing classifier

Start with interpretable 2–3 s windows; no deep model required initially.

Candidate features from external work and existing buffers:

- accelerometer magnitude mean, range, stddev, skew/kurtosis, zero-crossing rate;
- gyro magnitude energy/variance and dominant frequency;
- step interval regularity and cadence;
- rotation-per-step and cumulative yaw over the window;
- gravity-frame vertical acceleration amplitude vs horizontal/forward-ish components;
- phone pose flag (`hand` vs `pocket`) because features differ.

Output should be a probability or score, not a hard label: `pStationaryStep`, `pNormalWalk`, `pPhoneMotion`, `pCircle`.

### 4. Magnetic sequence repetition / backtracking score

Pacing often revisits the same small spatial patch. Add step-indexed sequence statistics:

- self-DTW/correlation between first and second halves of the recent magnetic window;
- alternating sign consistency of stride-lag magnetic differences;
- repeated local minima/maxima without route-bin progression;
- high similarity to a short earlier window while step count increased.

This directly catches back-and-forth pacing where total range may be nontrivial but net displacement is low.

### 5. Turn/circle consistency features

Use existing turn detector output, but aggregate over a rolling window:

- cumulative absolute yaw per 6–10 s;
- net yaw and number of sign changes;
- count of route-supported turn matches vs unmatched turns;
- `abs(cumulativeYaw) >= 270°` or repeated 90° turns without posterior support near route-turn bins ⇒ strong in-place/circling evidence;
- after an unmatched route-inconsistent turn sequence, keep `reversalActive`-like suppression until normal route evidence resumes.

### 6. Multi-channel magnetic confinement

The current parser has calibrated mag vector and gravity available in recordings. Compute:

- magnitude `|B|`;
- vertical component `Bv = dot(B, gravityUnit)`;
- horizontal magnitude `Bh = sqrt(|B|^2 - Bv^2)`;
- first differences for each channel.

Use differences to reduce device offsets and recalibration jumps, consistent with the current observation model.

## Concrete eval matrix using existing recordings / fixtures

Primary success criteria:

- **Pacing negatives:** zero checkpoint fires; in-place/off-route/circle score rises within <=8–12 s; no later “stored progress” fire after the gate clears.
- **Normal/live positives:** no new missed checkpoints; checkpoint delay stays within current replay tolerance where anchors exist; false off-route/in-place blocks remain rare and short.
- **Feature separation:** pacing distributions should separate from normal/live for `rangeRatio`, `localRangeRatio`, `diffEnergyRatio`, `pStationaryStep`, and cumulative-yaw features.

| Dataset / artifact | Existing local citation | Role | Eval assertions |
|---|---|---|---|
| Plumeria normal profile source passes | `/Users/alpesh/codebase/indoor-positioning/profiles/plumeria-test-forward.json` lists `Plumeria_Test_forward_hand_normal_20260611-104309.jsonl`, `...104347.jsonl`, `...104421.jsonl` | Clean normal survey baseline | No in-place block during true progress; feature values define normal distribution by segment; checkpoint timing remains OK. |
| Plumeria live example | `/Users/alpesh/codebase/indoor-positioning/README.md` replay example: `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl` | Real live hand-carry behavior | No false in-place block on live walking; compare current gate vs proposed features in shadow mode. |
| Clean walk parity fixture | `/Users/alpesh/codebase/indoor-positioning/survey-recorder/Tests/FilterParityTests.swift` → `testCleanWalkTraceParity()` and fixture generated by `/analysis/make-parity-fixture.js` | JS↔Swift positive control | Posterior parity unchanged for existing filter; proposed feature extractor should label as progress-capable. |
| Generic pacing parity fixture | `FilterParityTests.swift` → `testPacingTraceParity()` | Negative pacing baseline | Current confinement should block fires; proposed `IN_PLACE` score should also suppress step advancement. |
| L478 pacing parity fixture | `FilterParityTests.swift` → `testL478PacingTraceParity()`; turn comments in `/analysis/grid-filter.js` mention L478 pacing false match risk | Turn/pacing stress | Detect route-inconsistent turns/circling; avoid turn-signature snap from posterior tail; zero checkpoint fires. |
| Ravi normal fixture | `FilterParityTests.swift` → `testRaviPlaceTraceParity()` | Non-Plumeria positive control | No regression on legitimate turn matches; local/posterior range normalization should work across venue. |
| Ravi pacing fixture | `FilterParityTests.swift` → `testRaviPlacePacingTraceParity()`; `/analysis/grid-filter.js` comments mention Ravi pacing U-turn mean-sigma separation | Hard pacing negative with route-like turn magnitude | Proposed cumulative-turn and in-place score should reject route progress even when turn magnitude resembles a signature turn. |

Ablations to run on each row:

1. **Current:** existing grid filter + current confinement gate.
2. **Current + metrics only:** log `rangeRatio`, `localRangeRatio`, `diffEnergyRatio`, IMU scores, yaw scores; no behavior change.
3. **Fire gate v2:** checkpoint fire requires current gate AND local magnetic displacement ratio AND low `pStationaryStep`.
4. **Transition mix:** if in-place score high, replace step transition with `stay/diffuse` mixture; checkpoint gate unchanged.
5. **Full:** transition mix + fire gate v2 + cumulative turn/circle suppression.

Metrics table per run:

- checkpoint false fires per pacing session;
- checkpoint detection delay / misses on normal sessions;
- total seconds blocked while true walking;
- first detection time for pacing/circling;
- max posterior progress reached during pacing;
- max `pOff` and proposed `pInPlace`;
- per-feature P10/P50/P90 split by `normal`, `live`, `pacing`.

## Recommendation confidence

- **Keep current confinement gate as a temporary guardrail:** high confidence. It is simple and already has local pacing parity coverage.
- **Do not rely on it as the sole pacing defense:** high confidence. It is a checkpoint gate only and uses a single global magnitude-range statistic.
- **Add IMU stationary-stepping / irregular-motion classifier:** medium-high confidence externally; medium local confidence until trained/tuned on the repo’s recordings.
- **Add posterior-local magnetic difference/range ratios:** high confidence architecturally because it reuses the current differenced magnetic observation model; medium-high confidence empirically pending ablation.
- **Add explicit `IN_PLACE` transition/state:** medium confidence. It is the cleanest model separation, but needs replay validation to avoid suppressing legitimate slow/flat-field progress.
- **Add cumulative yaw / circling features:** medium-high confidence for hand pose; lower for pocket pose because current code already disables/down-weights turn evidence in pocket.

Overall recommendation confidence: **medium-high** that combined IMU + posterior-local magnetic sequence + cumulative-turn features will reduce pacing/circling false fires without hurting normal route walks, provided they are first run in shadow-mode on the existing pacing/live/normal recordings.

## Sources kept / dropped

Kept:

- HAA-PDR (Remote Sensing 2021) — direct stationary-stepping / zero-step-length evidence and turn optimization. https://www.mdpi.com/2072-4292/13/11/2137
- Susi et al. (Sensors 2013) — direct irregular/no-displacement handheld-phone motion classification. https://pmc.ncbi.nlm.nih.gov/articles/PMC3649428/
- Magil (EWSN 2017) — magnetic sequence matching without pedometer dependency. https://www.cse.ust.hk/~gchan/papers/EWSN17_magil.pdf
- Kuang et al. (Sensors 2018) — PDR trajectory contour + magnetic sequence matching. https://pmc.ncbi.nlm.nih.gov/articles/PMC6308508/
- Magnetic TCN (Sensors 2023) — gravity-frame magnetic components and first differences. https://pmc.ncbi.nlm.nih.gov/articles/PMC9921884/
- Robust PDR C-INS (Sensors 2018) — motion constraints and short-window inertial displacement caveats. https://pmc.ncbi.nlm.nih.gov/articles/PMC5982656/

Dropped / de-emphasized:

- Wi-Fi/BLE/UWB papers — outside no-beacon/no-installed-hardware scope.
- Generic step-counting-only papers — useful for step detection, but they do not distinguish displacement from in-place steps.
- Heavy deep magnetic models such as recent ResNet/Transformer/LSTM papers — promising but too heavyweight for the immediate repo problem and not necessary before interpretable feature ablations.

## Gaps / next research steps

- Need actual per-recording feature distributions from the local pacing/live/normal traces; current conclusions are based on code inspection and external literature, not newly computed local metrics.
- Need pocket-specific pacing recordings; hand-pose turn/yaw features may not transfer.
- Need deliberate circling recordings distinct from back-and-forth pacing.
- Need segment-level labels for flat vs high-gradient magnetic zones to tune local confinement thresholds safely.
