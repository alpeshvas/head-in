# Magnetic fingerprinting + route-constrained Bayesian filters

## TL;DR

External evidence strongly supports this repo's current direction: **phone-only magnetic fingerprinting works best when fused with PDR and constrained to a route/map**, using HMM/grid/particle-style Bayesian state estimation rather than one-shot magnetic matching. The local implementation is already aligned with the literature: it surveys route fingerprints, uses step prediction, stride-scale magnetic first-difference emissions, turn landmarks, an explicit `OFF` state, and conservative checkpoint gates. The next useful experiments should stay route-first: richer sequence emissions, route-direction/start arming, graph/HMM extensions, and reliability/off-route recovery—**not a premature 2D blue-dot rewrite**.

## Relevant external findings

1. **Magnetic fingerprints are a good no-infrastructure signal, but only as a probabilistic/fused signal.** The 2022 magnetic-localization survey summarizes the core trade-off: magnetic fields are ubiquitous, infrastructure-free, relatively temporally stable, and little affected by people moving nearby; but raw magnetic measurements have low discernibility, phone-orientation/device-heterogeneity issues, calibration burdens, and map-construction/maintenance cost. It explicitly lists HMM, Kalman/EKF, particle-filter, DTW/sequence, SLAM, and neural methods as common magnetic localization families. [Ouyang & Abed-Meraim 2022](https://www.mdpi.com/2079-9292/11/6/864)

2. **Single-point magnetic matching is ambiguous; sequence + PDR contour is the recurring fix.** Kuang et al. use smartphone magnetic-field sequences plus an INS/PDR trajectory contour, then align those sequences to a magnetic map and feed matches back into an EKF. Reported RMS errors were 0.64 m in an office corridor, 1.87 m in a lobby, and 2.34 m in a shopping mall; they also note worse performance when turns hurt trajectory accuracy and when magnetic gradients are gentler. [Kuang et al. 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6308508/)

3. **Magnetic + PDR + particle filters commonly land in the meter-range, but rely on assumptions this repo should keep explicit.** Ning & Chen's smartphone-only modified particle filter combines magnetic map differences with PDR and walking-range constraints; on a corridor route with checkpoints and 30 users, they report ~0.6–0.8 m accuracy and 80% within 1 m. MaLoc / reliability-augmented PF reports 1–2 m average in a large building using dynamic step length, hybrid magnetic measurement, adaptive sampling, and kidnapped-robot/failure handling. [Ning & Chen 2020](https://www.mdpi.com/1424-8220/20/1/185), [Xie et al. / MaLoc abstract](https://dl.acm.org/doi/10.1145/2632048.2632057), [Reliability-Augmented PF abstract](https://www.scilit.com/publications/f8cc0648c4ba33e8d564aad7fc84b64d)

4. **A full particle filter is not inherently better than a discrete grid/HMM when the state is already 1D.** Magnetic terrain-navigation work shows the canonical Bayesian decomposition—motion/PDR prediction, magnetic map likelihood, resampling/reinitialization—and demonstrates smartphone magnetic map matching, but it also shows global convergence may take ~10–15 s/meters and can fail on many sessions without a good motion model. For this repo's state (`route bin + OFF`), exact grid belief avoids particle sampling noise and is consistent with HMM map-matching theory. [Solin et al. 2016](https://users.aalto.fi/~kannalj1/publications/enc2016.pdf), [Newson & Krumm 2009](https://www.microsoft.com/en-us/research/publication/hidden-markov-map-matching-noise-sparseness/)

5. **Route/map constraints are a proven way to turn noisy motion into usable indoor tracking.** Newson & Krumm's HMM map matcher is not indoor/magnetic, but it is the canonical formulation: observations are noisy, states live on a constrained network, transitions encode network layout and plausible travel distance, and Viterbi/forward inference finds route-consistent state sequences. Indoor work applies the same pattern to floor-plan graphs: AiFiMatch abstracts indoor road segments as a directed graph and uses an HMM over subtrajectory/activity observations; other smartphone systems use particle-filter map constraints to keep PDR in valid corridors/rooms and recover at turns. [Newson & Krumm 2009](https://www.microsoft.com/en-us/research/publication/hidden-markov-map-matching-noise-sparseness/), [AiFiMatch abstract](https://link.springer.com/article/10.1007/s11431-018-9346-3), [Tian et al. 2015](https://pmc.ncbi.nlm.nih.gov/articles/PMC4721747/)

6. **Predefined-path / reference-trace systems match this repo's product better than free-form localization.** Magil surveys predefined paths, identifies matching geomagnetic segments online, and connects them with a modified shortest-path formulation, reporting >30% error reduction over prior schemes. FollowMe is even closer to a route-following product: a leader records geomagnetic + motion cues, a follower matches a reference trace, and reported 95% spatial error was ≤2 m in a four-story campus building with energy savings. These systems validate a route/checkpoint contract instead of arbitrary indoor GPS. [Magil record](https://repository.hkust.edu.hk/ir/Record/1783.1-84114), [FollowMe PDF](https://yshu.org/paper/mobicom15followme.pdf)

7. **Landmarks/turns help, but should be probabilistic and fail-soft.** Surveyed magnetic/inertial landmark systems such as UnLoc/SemanticSLAM use distinctive sensor patterns to reset or constrain PDR; the survey reports median errors of 1.69 m for UnLoc and 0.53 m for SemanticSLAM, while warning about missed landmarks and data-association ambiguity. This supports the repo's turn landmarks and `OFF` state, but argues against hard turn requirements that brick a route after one missed turn. [Ouyang & Abed-Meraim 2022](https://www.mdpi.com/2079-9292/11/6/864)

## How those findings map to the current code/data

- **Problem statement alignment.** The repo's README says the product is not free-form indoor GPS; it is phone-only route/checkpoint/zone confidence using magnetic, inertial, and route constraints. That is exactly the literature-backed lane: magnetic fingerprinting is useful, but only with PDR, sequence matching, and map/route constraints. Local citation: `README.md`.

- **Data model already matches sequence-based evidence.** `analysis/build-profile.js` builds 240-bin route segments from repeated anchor-to-anchor survey passes, stores magnetic magnitude mean/stddev arrays, step statistics, turn signatures, and per-profile calibration. This matches the surveyed-path / magnetic-sequence approach in Kuang, Magil, and FollowMe. Local citations: `analysis/build-profile.js`, `profiles/plumeria-test-forward.json`, `profiles/office-right-wing-forward.json`.

- **Runtime already implements an HMM/grid Bayes filter.** `analysis/grid-filter.js` and `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` keep exact belief over concatenated route bins plus `pOff`; steps are transitions; magnetic windows and turns are observations; checkpoint decisions sum posterior mass beyond decision bins. This is the 1D exact-grid version of the HMM/particle-filter family described externally. Local citations: `analysis/grid-filter.js`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift`, `docs/architecture.md`, `docs/route-belief-filter-qna.md`.

- **The first-difference emission is externally well-motivated.** The current filter compares stride-lag first differences of magnetic magnitude, not raw absolute magnitude. That maps to the literature's repeated point that magnetic sequences/differences are more robust to device bias, heading/calibration changes, and single-point ambiguity. Local citations: `analysis/grid-filter.js`, `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift`.

- **Evaluation is already stronger than most toy demos, but still narrow.** Local status shows multiple routes/profiles and ARKit-assisted ground truth: Plumeria Test (~12 m) achieved grid-filter P50 0.22 m / P75 0.71 m in leave-one-out; L478 (~43 m) improved to P75 ~0.72 m after differenced emission; Office right wing achieved LOO P50 0.46 m / P75 1.75 m and live 4/4 on two hand walks. However, the same status file says commercial gate is ≥90% correct triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand+pocket, and known limitations remain for reverse/out-of-order walking and some pacing cases. Local citation: `docs/STATUS.md`.

- **Current constraints are deliberately route-only, not wall/floor-plan geometry.** The local architecture states the map constraint is a 1D surveyed route profile; no full 2D wall polygons, floor-plan mesh, or arbitrary free movement. External evidence says this is a good first product choice: map constraints help, but full 2D localization requires denser maps, stronger heading/pose handling, and more survey coverage. Local citations: `README.md`, `docs/architecture.md`, `docs/route-belief-filter-qna.md`.

## 3–5 actionable algorithm experiments

1. **Multi-window magnetic sequence emission.** Add an offline experiment that scores a mixture of stride-differenced windows, e.g. 4/6/8/10 steps, optionally with DTW-like local stretch within a small band. Keep the current 6-step first-difference Gaussian as baseline; compare using identical replay matrix. This targets hallway/repetitive-segment ambiguity without changing the product model.

2. **Forward-backward/Viterbi replay harness for route HMM diagnostics.** Add an analysis-only smoother that replays the same transition/emission model and outputs most-likely checkpoint sequence, posterior entropy, and where online decisions diverge from full-trace evidence. This should not replace live filtering, but it will tune transition/noise/off-route parameters using a principled HMM view.

3. **Start/direction arming as a gated feature, not a mandatory rewrite.** Test a proper gait-heading/PCA-GA travel-direction estimator against the ARKit route-heading profile, but only as a checkpoint-fire gate: do not fire until start region and forward direction are corroborated. The local direction research found crude sign resolution is not shippable; the experiment should require per-step gait-cycle sign resolution and cross-pass repeatability before it can gate production.

4. **Reliability-augmented `OFF` and re-entry model.** Borrow from reliability-augmented PF / kidnapped-robot handling: compute an observation reliability/distinctiveness score per live window and let global re-entry happen only after several high-distinctiveness, route-consistent windows. Compare against current local re-entry near last confident mode.

5. **Soft landmark/turn gate behind checkpoints.** Instead of requiring every stored turn, learn a soft prior: checkpoints behind high-confidence route turns get boosted after matched turns, but missed turns decay/expire after N strong magnetic observations. Include doors/corners/checkpoint taps as possible landmarks where the data supports them. This preserves the repo's conservative no-false-advance product while avoiding the previously observed “missed turn bricks route” failure.

## Expected metrics impact

| Experiment | Primary metric to watch | Expected impact if it works | Regression risk |
|---|---|---|---|
| Multi-window emission | P75/P90 meters, false wrong-mode stretches, `pOff` spikes | Lower P75 on repetitive corridors; fewer mode flips; cleaner pocket/end regions | More latency; overfitting short local data; false confidence in flat fields |
| HMM smoother diagnostics | Calibration residuals, online-vs-smoothed disagreement, entropy | Better parameter fits and clearer failure labels; likely no direct live metric until changes are ported | Analysis-only unless accidentally used as oracle |
| Start/direction arming | Reverse-walk false fires, start-delay seconds, checkpoint recall | Suppress reverse/mid-route misuse before checkpoint firing | Sign ambiguity; may delay or block short routes if arming is too strict |
| Reliability/global re-entry | Recovered off-route traces, false global jumps, wrong-segment fires | Better recovery after transient `OFF`; fewer stale/wrong reentries | Similar magnetic segments can cause teleport/jump false positives |
| Soft landmark/turn gate | Pacing false fires, clean route recall, missed-turn recovery | Reduce pacing/U-turn false advances while keeping clean walks firing | Turn detection remains pose-sensitive; pocket turns are known harmful |

Target acceptance should stay tied to local criteria: ≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand+pocket; false auto-advance should be treated as more costly than late/manual fallback. Local citation: `docs/STATUS.md`.

## Risks/gaps

- **Validation breadth is still the main gap.** Current live validation is promising but narrow: few venues, one or very few devices, and pose-specific fragility remains. External papers often use controlled phone pose, known starts, dense maps, or Android APIs; that does not automatically transfer to iPhone-first production.
- **Route-order assumption is real.** A 1D ordered route filter cannot represent arbitrary room order, shortcuts, reverse walks, or “where am I in this building?” without a route graph or free-roam branch. Local citation: `docs/STATUS.md`.
- **Magnetic ambiguity will not disappear.** Repeated corridors, weak-gradient rooms, and adjacent similar magnetic patches can defeat magnetic-only emissions; the correct behavior is `low_confidence`/manual fallback, not forced checkpoint advancement.
- **Phone pose/device heterogeneity remains under-tested.** Pocket carry already required pause-spliced profiles and turn disabling; external literature repeatedly flags device/pose calibration as a core limitation.
- **Global relocalization is dangerous without stronger observations.** Local re-entry near last confident mode is safer for route tours. Global re-entry should be gated by high distinctiveness and likely needs route-start/absolute cues for production.

## Local file/path citations

- `README.md` — problem statement and product contract: phone-only route/checkpoint/zone confidence, no camera/hardware, no arbitrary blue dot.
- `docs/architecture.md` — sensor streams, profile structure, 1D grid Bayes filter + `OFF`, turn observations, checkpoint gates, 2D future scope.
- `docs/route-belief-filter-qna.md` — predict/observe explanation, magnetic first-difference likelihood, turn thresholds, checkpoint decision thresholds.
- `analysis/build-profile.js` — survey parsing, 240-bin segment resampling, repeatability metrics, transition detection, turn signatures, per-profile calibration.
- `analysis/grid-filter.js` — JS reference filter: step transition, magnetic first-difference emission, `OFF` dynamics/re-entry, turn observation, pacing/confinement gate.
- `survey-recorder/SurveyRecorder/RouteBeliefFilter.swift` — Swift runtime port of the grid filter.
- `survey-recorder/SurveyRecorder/LivePositioningController.swift` — live Core Motion wiring, window construction, checkpoint gating, hand/pocket turn behavior.
- `analysis/ground-truth.js` — ARKit surveyor-only ground-truth conversion to route meters for evaluation.
- `profiles/plumeria-test-forward.json`, `profiles/office-right-wing-forward.json` — concrete route profiles with anchors, segments, correlations, step counts, and magnetic arrays.
- `docs/STATUS.md` — current dataset inventory, replay/live metrics, known holes, commercial gate.
- `docs/research/direction-and-entrance-anchoring.md` — local research and failed/partial attempts on reverse-walk/start-direction gating.
