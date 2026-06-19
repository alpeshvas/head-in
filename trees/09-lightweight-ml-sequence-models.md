# Lightweight ML / Sequence-Model Options for the Current Indoor-Positioning Dataset

## TL;DR

The confirmed profile-backed dataset is **too small for end-to-end neural sequence models or neural odometry**: the current Plumeria/Test forward/hand profile is built from **3 normal survey passes**, 4 anchors, 3 short segments, and only ~46 seconds of anchored route motion by median segment durations; there is also one referenced forward/hand live replay without ARKit ground truth. Use ML only as **small, constrained augmentations** to the existing route Bayes/HMM filter: DTW/derivative-DTW template scores, a regularized learned emission calibrator, and eventually tiny OFF/pacing/pose classifiers once negative/pose data exists.

Recommended order: **(1) DTW/contrastive-template diagnostics now**, **(2) learned emission calibration/reranking with leave-one-session-out evaluation**, **(3) tiny OFF/pacing/pose classifiers only after collecting labeled negatives and pose diversity**, **(4) neural odometry only as pre-trained/external research, not local training**.

## Current local dataset and evaluation grounding

- **Confirmed route/profile scale:** `profiles/plumeria-test-forward.json` contains route `Plumeria/Test/forward/hand/floor 7`, `sourceFiles` with exactly 3 normal survey recordings, 4 anchors (`Start`, `Room exit`, `Bedroom entry`, `Bedroom exit`), 3 segments, and `resamplePoints: 240` per segment. Segment 0 is `moderate` with `passes: 3`, median 6.185 s / 9 steps, mean correlation 0.727 and mean DTW 1.624 µT; segment 1 is a short `transition` excluded from matching; segment 2 is `strong` with mean correlation 0.895 and mean DTW 0.480 µT. The profile has one repeatable turn signature (`-159° @ bin 350`) and leave-one-out ARKit calibration over 3 passes (`diffSigmaUT: 2.556`, `offLogLikPerPoint: -4.863`). Local citation: `profiles/plumeria-test-forward.json`.
- **Sensor/runtime shape:** the recorder captures calibrated CoreMotion magnetic field, attitude, rotation rate, user acceleration, gravity at 100 Hz, raw magnetometer fallback, pedometer, barometer, anchors, and optional ARKit truth. Local citation: `docs/architecture.md`.
- **Current algorithm/eval target:** the product target is route/checkpoint/zone confidence, not arbitrary blue-dot localization. Initial success metric is checkpoint arrival within about **2–5 m** at least **80–90%** while entering low-confidence rather than making false claims. Local citation: `docs/research-notes.md`.
- **Filter acceptance criteria already encoded:** the grid filter is a 1D route-bin Bayes/HMM with explicit `OFF`. Checkpoint fire requires recent magnetic evidence, posterior mass beyond checkpoint >0.8 of on-route mass, `pOff < 0.5`, no unresolved reversal, and 2 consecutive good updates. Offline replay scores checkpoint timing against anchor taps, flags missed/early/false advances, reports max `P(OFF)`, and when ARKit exists reports mean/P50/P75 meter error. Local citations: `docs/architecture.md`, `docs/route-belief-filter-qna.md`, `analysis/grid-filter.js`.

## External evidence with source links

1. **Magnetic localization benefits from sequence matching, not point fingerprints.** Magil frames geomagnetic localization as sequence matching plus path construction, uses mean-removed local magnetic variation to handle device offsets, and avoids heavily tuned pedometers/particle filters. It reports lower error than particle-filter baselines and ~498 ms/step processing on phone, but still needs survey paths and enough walking distance. [Magil / EWSN 2017 PDF](https://www.cse.ust.hk/~gchan/papers/EWSN17_magil.pdf)
2. **Magnetic sequence + PDR/motion contour is a strong fit for this codebase.** Kuang et al. note single-point magnetic fingerprints have low distinguishability, while magnetic-field sequences combined with trajectory contour improve matching. They also discuss derivative/sequence DTW variants, map constraints, and smartphone pose challenges; their experiments use multiple buildings/phones/participants and report RMS errors from 0.64 m office to 2.34 m mall, far more data/diversity than the current local profile. [Sensors 2018](https://pmc.ncbi.nlm.nih.gov/articles/PMC6308508/)
3. **Tiny HAR-style classifiers are plausible, but public baselines use much larger datasets and careful splits.** UCI HAR used 30 subjects, 6 activities, 50 Hz accelerometer/gyroscope, 2.56 s windows with 50% overlap, and subject-level train/test partitioning. [UCI HAR dataset](https://archive.ics.uci.edu/ml/datasets/human+activity+recognition+using+smartphones)
4. **Window leakage can make small sensor classifiers look much better than they are.** A HAR study found accuracy varied from 99.8% to 77.6% depending on information sharing between train/test splits, and recommends reporting the split/leakage level. This is directly relevant because route windows from the same 15 s walk are highly correlated. [Sensors 2022 information-sharing study](https://mdpi-res.com/d_attachment/sensors/sensors-22-02280/article_deploy/sensors-22-02280.pdf?version=1647402775)
5. **Contrastive/self-supervised wearable models are not plug-and-play on tiny datasets.** A KDD/CL-HAR study says contrastive learning on small-scale wearable tasks is sensitive to augmentations, backbones, positive/negative construction, cross-person generalization, wearing diversity, and windowing. A 2024 SSL-HAR comparison found MAE stronger than SimCLR, but used a combined dataset of 147 subjects, 10 activities, ~151 hours of usable data—orders of magnitude beyond this repo’s confirmed route data. [CL-HAR paper](https://ar5iv.labs.arxiv.org/html/2202.05998), [SSL-HAR 2024](https://arxiv.org/html/2404.15331)
6. **Neural inertial odometry needs hours of accurate ground truth, not 3 short route passes.** RoNIN uses 42.7 hours of IMU + 3D ground truth from 100 subjects and evaluates ATE/RTE. OxIOD/L-IONet uses 158 sequences, 14.72 hours, 42.587 km, 4 attachments, multiple phones/users, and motion-capture/Tango ground truth. The current local ARKit survey data is useful for evaluation/calibration but not enough to train odometry. [RoNIN](https://ronin.cs.sfu.ca/), [L-IONet / OxIOD PDF](https://www.cs.ox.ac.uk/files/11749/L-IONet.pdf)
7. **Small deployed models are feasible once data exists.** TinyML HAR work shows quantized/pruned CNN/LSTM-style models can run on edge devices with small footprints, but it still uses UCI-HAR-style supervised data rather than a 3-pass route dataset. [TinyML HAR PDF](https://eprints.gla.ac.uk/330318/1/330318.pdf)

## Feasible vs non-feasible ML paths

### Feasible now / low risk

1. **DTW / derivative-DTW / Smith-Waterman-style template scoring** — Best immediate addition. It needs little or no training, matches the magnetic-sequence evidence, and aligns with current local files: `analysis/analyze-repeatability.js` already computes Pearson + DTW deviation, and `profiles/plumeria-test-forward.json` already records segment DTW quality. Use it as an offline comparator or extra emission feature, not as a replacement for the Bayes filter.
   - Candidate score: first-difference or z/mean-removed magnetic magnitude over 4–8 steps vs per-pass templates/profile mean.
   - Output: candidate-bin score, segment-rank score, or “distinctive enough?” reliability flag.
   - Guardrail: route-bin posterior and OFF logic remain in `analysis/grid-filter.js` / `RouteBeliefFilter.swift`.

2. **Learned emission calibration/reranking with very small models** — Feasible only if treated as calibration, not high-capacity ML. Train a regularized logistic/isotonic calibrator or shallow tree on features derived from candidate windows:
   - existing Gaussian first-difference log-likelihood;
   - DTW/derivative-DTW distance;
   - live magnetic range and profile local gradient;
   - profile stddev / segment quality;
   - step-window length and stride consistency;
   - turn-match proximity/support when present.
   The target can be “candidate bin near ARKit true bin” vs “far bin,” but evaluation must group by held-out session because candidate bins within one walk are not independent.

3. **Non-neural contrastive templates** — Feasible as a metric-learning diagnostic, not a neural contrastive model. Treat windows from the same route bin across survey passes as positives and far-apart route windows as negatives, then test simple distances or a small linear projection. With only 3 passes, this should remain an offline ranking experiment.

### Feasible after modest data collection

4. **Tiny OFF / pacing / pose classifiers** — Useful, but current data does not confirm enough labels. The code already has a hand-engineered pacing/confinement gate and hand-vs-pocket turn policy; a tiny classifier could eventually improve these decisions.
   - Suggested classes: `on_route_progressing`, `pacing/in_place`, `off_route/detour`, `still`, `hand`, `pocket`, `bag`.
   - Suggested model: logistic regression, linear SVM, small XGBoost/RandomForest, or a <=10–50k parameter 1D CNN only after enough data.
   - Suggested features: acceleration RMS/MAD, cadence, step interval variance, gyro yaw integral/range, gravity/attitude stability, magnetic range ratio vs profile, magnetometer calibration accuracy, confinement ratio, recent filter entropy/`pOff`.
   - Use as a **gate or prior**: e.g., suppress checkpoint fires during pacing, disable turn observations in pocket, increase OFF leak under off-route features.

5. **Personalized stride/step calibration** — A tiny regression over segment-bin progress vs detected steps is plausible after collecting multiple users/poses. Current profile uses segment median steps; a per-user scalar stride multiplier could be learned conservatively from early route evidence.

### Not feasible from the current local dataset

6. **End-to-end LSTM/TCN/Transformer route-position estimator** — Not recommended. Current confirmed data is ~3 short aligned route passes for one route/pose/phone, which is far below what sequence neural models need. It would memorize the Plumeria profile and fail on held-out users/phones/poses.

7. **Neural inertial odometry trained locally** — Not realistic. RoNIN/OxIOD-scale work uses tens of hours, many subjects, many attachments, and precise ground truth. The current ARKit-enabled passes can evaluate/fit filter calibration, but cannot train odometry.

8. **2D learned indoor localization** — Not realistic for current data model. Local architecture is a 1D surveyed route profile, not dense 2D magnetic map plus walkable geometry.

## Data requirements

| Goal | Minimum to run | Minimum to trust | Notes |
|---|---:|---:|---|
| DTW/template baseline | current 3 survey passes | 5–10 survey passes + 3+ held-out live walks per route/pose | Can run now as diagnostic; do not infer deployment accuracy from same-pass/profile leakage. |
| Learned emission calibration | current 3 passes only as toy LOO | 8–15 passes per route/pose/phone plus held-out live sessions | Keep model linear/regularized; use session-level splits. |
| OFF/pacing classifier | not enough confirmed labels | 10–20 independent sessions per class per route family; include true off-route, pacing, U-turns, still, route-progress | Need negative examples; otherwise the classifier only learns “normal route.” |
| Pose classifier/gates | not enough confirmed pose diversity | hand/pocket/bag recordings across users and phones; at least several sessions per pose | Current code already disables turn evidence for pocket based on replay findings; ML needs labeled pose data. |
| Neural odometry | no | hours to tens of hours with accurate trajectory truth, multiple users/phones/poses | External evidence: RoNIN 42.7 h / 100 subjects; OxIOD 14.72 h / 42.6 km. |

## Experiments that can run now

1. **Leave-one-survey-pass-out emission sanity check**
   - Build three temporary profiles: train on two normal survey passes, test on the third ARKit-enabled pass.
   - Compare current Gaussian first-difference likelihood vs DTW/derivative-DTW/template ranking.
   - Metrics: truth-bin negative log likelihood, top-k route-bin hit rate, mean/P50/P75 meter error vs ARKit, checkpoint miss/early/late/false advance.
   - Local hooks: `analysis/build-profile.js`, `analysis/grid-filter.js`, `analysis/ground-truth.js`, `profiles/plumeria-test-forward.json`.

2. **Candidate-bin score export**
   - For every observed step window, export candidate features: current log-likelihood, DTW distance, live range, profile gradient, segment id/quality, profile stddev, distance to true ARKit bin when available.
   - Train only session-held-out logistic/isotonic calibration. Reject any model that does not improve held-out NLL/checkpoint behavior over current calibration.

3. **DTW as an emission/reranker ablation**
   - Add an offline-only replay mode that blends current Gaussian log-likelihood with a DTW score using a single tunable weight.
   - Sweep the weight by leave-one-pass-out. Success criterion: no false checkpoint advances, same or lower ARKit meter error, no increase in `P(OFF)` on normal route.

4. **Pacing/OFF feature audit without training**
   - Log current confinement ratio, step cadence, magnetic range, gyro/yaw features, posterior entropy, and `pOff` on the known normal live replay.
   - This can establish “normal route” ranges. Do not train OFF/pacing until actual negative recordings exist.

5. **Data collection checklist for next ML tranche**
   - For each route: 5–10 normal passes, 3+ held-out live passes, forward/reverse if product needs reverse, hand/pocket/bag poses, 2+ phones, 2+ users.
   - Negative set: pacing in place near each checkpoint, off-route detours, U-turns, standing pauses, wrong starting point, route re-entry.
   - Keep ARKit/surveyor truth on as many internal passes as possible.

## Overfitting risks and guardrails

- **Overlapping-window leakage:** adjacent 100 Hz / step windows from the same 15 s route walk are almost duplicates. Do not random-split windows. Use session/pass/user/phone/pose grouped splits. External warning: HAR accuracy can fall from 99.8% to 77.6% when leakage is removed.
- **Profile contamination:** testing on a pass used to build `profiles/plumeria-test-forward.json` overstates emission performance. For ML claims, rebuild profile without the held-out pass.
- **Pseudo-sample inflation:** candidate bins create thousands of “training examples,” but they all come from a few walks and are highly correlated. Count independent sessions, not rows.
- **Negative-class absence:** current confirmed data mostly covers normal forward hand route. OFF/pacing classifiers trained without real negatives will be brittle or silently biased.
- **Route/segment memorization:** a model can learn segment-specific magnetic levels or timestamps rather than general match quality. Prefer first differences, local shape, held-out sessions, and report per-segment metrics.
- **Pose/device confounding:** current confirmed recordings are iPhone14,5 hand-pose. Do not claim pocket/bag/cross-device robustness from this dataset.
- **Metric mismatch:** optimizing ARKit meter error alone may hurt product behavior. Gate recommendations by checkpoint false-advance/miss rate, `pOff`, low-confidence behavior, and current product thresholds.

## Local file/path citations

- `README.md` — product target is route-constrained checkpoint/route/zone confidence; profile is built from 3–5 passes; example live replay uses `Plumeria_Test_forward_hand_live_20260611-113118.jsonl`.
- `docs/research-notes.md` — v1 constraints and initial success metric: checkpoint arrival within ~2–5 m, 80–90%, low-confidence instead of false claims.
- `docs/architecture.md` — 100 Hz sensor capture, 240 bins/segment, route profile structure, grid Bayes filter, first-difference magnetic emission, turn/OFF/checkpoint decision rules.
- `docs/route-belief-filter-qna.md` — predict/observe/normalize loop and checkpoint thresholds.
- `profiles/plumeria-test-forward.json` — confirmed dataset/profile size, segment quality, DTW/correlation stats, turn signature, calibration fields.
- `recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl`, `...104347.jsonl`, `...104421.jsonl` — normal survey recordings with `groundTruth: true`, `deviceModel: iPhone14,5`, `devicePose: hand`.
- `recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl` — referenced live replay recording with `groundTruth: false`.
- `analysis/analyze-repeatability.js` — existing Pearson/DTW repeatability tooling.
- `analysis/build-profile.js` — profile builder and segment statistics.
- `analysis/grid-filter.js` — replay, calibration, checkpoint scoring, OFF scoring, ARKit meter-error scoring.
- `analysis/ground-truth.js` — ARKit arc-length truth extraction and per-segment progress mapping.
