# Indoor-positioning research synthesis (trees 01–10)

Scope: read all research artifacts `trees/01` through `trees/10`; inspected repo only to resolve conflicts and update current-code facts. No source/project files were modified; this file is the requested output artifact.

## 1) Concise problem statement from the codebase

This repo is a **phone-only, no-installed-hardware, route-constrained indoor checkpoint trigger** prototype. It is not trying to be arbitrary indoor GPS / blue-dot positioning.

Evidence from the codebase:

- `README.md:17-25` defines the product target: survey known indoor routes, anchor at checkpoints, build route-segment magnetic profiles, run a route-constrained grid Bayes filter over route bins plus explicit `OFF`, and emit conservative checkpoint/progress/off-route/manual-fallback events.
- `README.md:93-100` constrains v1: no installed hardware, no runtime camera, ARKit only for surveyor ground truth, single-floor routes, 1-D surveyed route profile rather than 2-D floor-plan mesh.
- `docs/architecture.md:87-98` names the JS reference filter and Swift runtime port.
- `docs/architecture.md:124-137` makes the central assumption explicit: on-route belief moves along one route-bin axis, route start/end are barriers, turns are expected near stored turn bins, and checkpoints fire in route order.
- `docs/architecture.md:171-177` and `:211-216` explicitly exclude global relocalization / arbitrary far-segment jumps from v1.

So the core problem is:

> Given a selected known route/profile, a known start, and a user walking that route in order, infer conservative checkpoint/zone progress and when to fall back. The current sharp failures are false confidence when the user violates those assumptions: in-place pacing, reverse/mid-route/out-of-order walking, carry-pose/profile mismatch, weak survey segments, and insufficient negative validation.

## 2) Dataset and evaluation criteria summary

### Current dataset inventory

Repo inspection found **59 JSONL sessions** under `recordings-new/` and **9 JSON profiles** under `profiles/`. Artifacts 01 and 07 reported 57/58 files; current repo state is 59.

Current `recordings-new/` counts by metadata:

| Group | Count / notes |
|---|---:|
| `Test / Test / hand` old schema | 5 no-passType, no GT |
| `Meadows / Test / hand` | 5 old no-passType + 1 `normal` GT with no anchors; historical only |
| `Plumeria / Test / hand` | 5 `normal` GT, 3 `live`, 1 explicit `pacing`; primary clean trio is `20260611-104309/104347/104421`; exclude `20260610-233908` for no anchors |
| `Plumeria / L478 / hand` | 3 `normal` GT, 4 `live`; rich 43 m loop with turns/repeated hallway |
| `Plumeria / L478 / pocket` | 6 `normal` no-GT files = 3 raw + 3 `_anchors-fixed`; 3 `live`; use `_anchors-fixed` with `--splice-pauses` |
| `Office / Right wing garden` | 2 `normal` GT tagged `pocket` but apparently held, 2 hand `live`; pose confound |
| `Office Near / LIS / hand` | 5 `normal` GT = 3 legacy named-checkpoint + 2 current generic-checkpoint; 4 `live`; do not mix legacy/current checkpoint variants |
| `Ravi place / Home / hand` | 3 `normal` GT = 1 ad-hoc bootstrap + 2 profile-source reuse passes; 7 `live`, including out-of-order and pacing scenarios |
| Explicit negatives | Only 1 explicit `passType=pacing`; no explicit `offRoute` or `standing` files despite schema support |
| Device models | Only `iPhone14,5` and `iPhone16,2` observed; commercial target asks for 3+ iPhone models |

Schema evidence:

- `Models.swift:18-45` defines pass types `normal`, `pacing`, `offRoute`, `standing`, `live`; negatives should be intentional failures.
- `SessionWriter.swift:38-56` writes venue/route/direction/pose/passType/groundTruth/checkpoints/deviceModel/profileResource metadata.

### Profile inventory / validation strength

Checked-in profiles and calibration strength:

| Profile | Source passes | Truth/calibration | Strength / caveat |
|---|---:|---|---|
| `profiles/plumeria-test-forward.json` | 3 clean hand passes (`:11-15`) | AR LOO, `diffSigmaUT=2.556`, `offLogLik=-4.863` (`:1570+`) | acceptance-grade short hand route |
| `profiles/plumeria-l478-forward.json` | 3 hand passes (`:10-14`) | AR LOO, `2.84/-3.946` (`:3132+`) | acceptance-grade richer hand route |
| `profiles/plumeria-l478-pocket.json` | 3 `_anchors-fixed` pocket passes (`:10-14`) | anchor-interpolated LOO, `2.684/-5.052` (`:3120+`) | viable pocket route, not meter-grade AR acceptance |
| `profiles/office-right-wing-forward.json` | 2 passes (`:10-13`) | AR LOO over 2 passes, `1.218/-3.418` (`:2072+`) | smoke only; pose tag says pocket but live held hand |
| `profiles/office-near-lis-forward.json` | 2 current generic passes (`:10-13`) | AR LOO over 2 passes, `2.172/-3.623` (`:3624+`) | smoke only; important reverse negative |
| `profiles/ravi-place-home-forward.json` | 2 reuse passes (`:10-13`) | AR LOO over 2 passes, `3.573/-3.174` (`:2079+`) | smoke only; weak-field/pacing stress route |
| `profiles/meadows-test-forward.json` | 5 old passes (`:11-17`) | no calibration | historical only |

Profile builder facts:

- `analysis/build-profile.js:17-22` uses 240 bins/segment and labels short spans (`<=4 s` or `<=5` steps) as `transition`.
- `analysis/build-profile.js:470-524` builds segments, stores repeatability, `kind`, `useForMatching`, source files, and magnetic arrays.
- `analysis/build-profile.js:604-699` fits per-profile magnetic-difference noise and OFF likelihood by leave-one-out where possible.
- `analysis/build-profile.js:742-793` supports `--splice-pauses` for pocket profile builds.

### Evaluation criteria

Use three tiers, not one blended metric:

1. **Acceptance-grade clean AR-backed held-out metrics**
   - From `docs/research/SYNTHESIS.md:38-40`: before going past Phase 3 / commercial launch, require **≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand and pocket carry**, with low false advances and permanent manual fallback.
   - From `docs/SURVEY-PRACTICE.md:42-47`: ≥3 clean passes are required for honest leave-one-out; 2-pass routes are smoke tests.
   - From `docs/SURVEY-PRACTICE.md:24-35`: target per-segment repeatability `r >= ~0.85`; weak segments are survey/checkpoint-layout problems.

2. **Behavioral/pocket/live metrics**
   - Pocket with pause-derived anchors is valuable, but without ARKit it is not true ±5 m acceptance.
   - Live traces usually have `groundTruth:false`; historical `cp_fired` is app output, not truth.
   - `grid-filter.js:858-866` labels any detected checkpoint with no truth anchor as `FALSE ADVANCE`; artifacts correctly flag this as cosmetic unless a manifest labels the trace as a deliberate negative.

3. **Negative/misuse metrics**
   - For `pacing`, `standing`, `offRoute`, reverse, mid-route, out-of-order, and wrong-profile/carry cases, the primary metric is **zero checkpoint fires** before real route entry/re-entry.
   - Secondary metrics: time-to-off-route, max/sustained `P(OFF)`, confinement ratio, `pInPlace`/blocked seconds if implemented.

Current JS scorer:

- `analysis/grid-filter.js:845-907` prints checkpoint truth/detected/delay/verdict, max `P(OFF)`, turn log, and AR mean/P50/P75 where available.
- It does not yet compute trigger error in meters at fire time; a manifest-driven harness should add that.

## 3) Ranked recommended approaches

### 1. Build a manifest-driven eval scorecard before more algorithm tuning — **High confidence**

Why:

- All artifacts converge that the repo already has a plausible route-HMM/filter architecture; the biggest blocker is knowing what actually passes/fails across the full matrix.
- Current live trace semantics are ambiguous without labels: live `cp_fired` is output, not truth; replay `FALSE ADVANCE` is cosmetic on ungraded live traces.
- Prevents profile/source leakage by ensuring held-out sessions are not in `profile.sourceFiles`.

Implementation shape if approved: `analysis/eval-manifest.json` + `analysis/eval-harness.js`, using `grid-filter.replay()` (`analysis/grid-filter.js:999`) and temporary LOO profiles under `/tmp`.

### 2. Close in-place pacing with live/controller validation, then decide whether an explicit `IN_PLACE` model is needed — **High confidence for current gate; medium-high for explicit model**

Why:

- Current repo implements a cheap venue-normalized confinement gate: `analysis/grid-filter.js:87-98`, `:761-777`, `:822-825`; Swift has matching `confinementRatio` and checkpoint/display gate at `LivePositioningController.swift:373-390`, `:412-416`, `:439-445`.
- Read-only replays during synthesis show current JS produces **0 fires** on Ravi long pacing, L478 circling-pacing, and Plumeria Test pacing, while LIS reverse still false-advances.
- However, current gate is a **fire/display gate only**: both JS and Swift still call `predictStep()` while confined (`grid-filter.js:793-803`; `LivePositioningController.swift:280-317`). That means hidden belief can still march; live pacing→resume should be tested and, if it bursts, implement a stay/diffuse or `IN_PLACE` transition.

### 3. Treat guided-route start/order as a product contract first; use absolute start cues before gait-heading guards — **High confidence for product arming; medium confidence for gait-heading research**

Why:

- The model initializes at route start (`RouteBeliefFilter.swift:160-167`) and predicts positive stride (`:189-266`); reverse/mid-route/out-of-order is outside the 1-D ordered route model.
- Magnetic-only start arming and compass/device heading were already rejected in the artifacts.
- `docs/research/direction-and-entrance-anchoring.md:68-84` recommends gait-heading + route heading as the lightest sensor-only reverse guard, but `:111-135` says the current crude implementation is **NO-GO** due to inconsistent sign resolution between forward passes.

Recommended near-term: explicit “Start at entrance”/manual confirmation or QR/NFC/GPS entrance cue. Keep gait-heading offline until per-step gait-cycle sign resolution is proven.

### 4. Collect missing validation data and add profile QA gates — **High confidence**

Why:

- Commercial gate cannot be certified now: only two iPhone model IDs, limited pocket truth, several 2-pass profiles, and no explicit `offRoute`/`standing` negatives.
- Survey practice already explains real failures and fixes: checkpoint every 5–15 steps, add checkpoints in open rooms, r≥~0.85, ≥3 clean passes, exclude ad-hoc bootstrap pass (`docs/SURVEY-PRACTICE.md:8-86`).

Recommended: one standing + one off-route negative per major profile, third clean reuse pass for Office/Ravi/LIS, at least one more iPhone model, and pocket outside Plumeria.

### 5. Harden pocket mode with pose-specific profiles and mismatch detection — **Medium-high confidence**

Why:

- Local evidence supports separate pocket profiles and pause splicing; hand-profile+pocket is brittle.
- Current code intentionally disables turn evidence for pocket: JS `grid-filter.js:729-735`; Swift `LivePositioningController.swift:17-21`, `:250-269`; UI carry picker at `LivePositioningView.swift:224-234`.
- Do not silently switch profiles mid-run; first warn/block on profile route pose vs selected carry mismatch, then collect labeled data for a lightweight pose classifier.

### 6. Add sequence-emission/reliability experiments, not a broad estimator rewrite — **Medium confidence**

Why:

- External research in artifacts 03/05/09 supports sequence matching, multi-window first differences, DTW/derivative-DTW, and reliability/distinctiveness scores.
- The current grid filter is already the right family for a 1-D route state; exact grid inference is better than a particle filter for this state size.
- Good next experiments: multi-window magnetic emissions, posterior-local confinement ratio, DTW/reranker diagnostics, Viterbi/offline smoother for parameter diagnostics.

### 7. Use ML only as constrained augmentations after more labels — **High confidence against end-to-end neural now; medium confidence for tiny classifiers later**

Why:

- Artifact 09 correctly concludes the dataset is far too small for local LSTM/TCN/Transformer odometry or route-position estimation.
- Feasible later: logistic/isotonic emission calibrator, tiny HAR-style `pacing/offRoute/pose` classifier, small DTW/template reranker with session-level splits.
- Do not random-split overlapping windows; use session/device/pose grouped splits.

### 8. Any-order/free-roam support is a separate product fork — **High confidence**

Why:

- `docs/architecture.md:211-216` excludes arbitrary blue-dot/global relocalization.
- Out-of-order/shortcut traces are not solvable by tuning a forward ordered 1-D filter; they need a route graph, per-zone matching, absolute room cues, or dense 2-D surveys.

## 4) Experiments to run next, with exact commands/files

All commands below are read-only or write to `/tmp` unless explicitly implementing a new harness later.

### A. Freeze current baseline replay matrix

```sh
cd /Users/alpesh/codebase/indoor-positioning

# Negatives / known limitations
node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl
node analysis/grid-filter.js profiles/plumeria-l478-forward.json recordings-new/Plumeria_L478_forward_hand_live_20260611-125529.jsonl
node analysis/grid-filter.js profiles/plumeria-test-forward.json recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl
node analysis/grid-filter.js profiles/office-near-lis-forward.json recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-100523.jsonl

# Positive controls
node analysis/grid-filter.js profiles/plumeria-test-forward.json recordings-new/Plumeria_Test_forward_hand_live_20260611-113118.jsonl
node analysis/grid-filter.js profiles/plumeria-l478-forward.json recordings-new/Plumeria_L478_forward_hand_live_20260611-125057.jsonl
node analysis/grid-filter.js profiles/office-right-wing-forward.json recordings-new/Office_Right-wing-garden_forward_hand_live_20260619-014811.jsonl
node analysis/grid-filter.js profiles/ravi-place-home-forward.json recordings-new/Ravi-place_Home_forward_hand_live_20260619-101048.jsonl
node analysis/grid-filter.js profiles/plumeria-l478-pocket.json recordings-new/Plumeria_L478_forward_pocket_live_20260612-135652.jsonl
```

During this synthesis, current JS replay observed:

- Ravi long pacing `...105724`: 0 checkpoint fires, max `P(OFF)=0.50`, no off-route flag.
- L478 pacing `...125529`: 0 checkpoint fires, max `P(OFF)=0.50`, no off-route flag.
- LIS reverse `...031803`: false-advanced Checkpoint 2–6, max `P(OFF)=0.37`, no off-route flag.

### B. Run acceptance-grade LOO where possible

Plumeria Test hand fold example; rotate held-out file across the three clean passes:

```sh
cd /Users/alpesh/codebase/indoor-positioning
mkdir -p /tmp/indoor-eval

node analysis/build-profile.js \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104347.jsonl \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104421.jsonl \
  --out /tmp/indoor-eval/plumeria-test-holdout-104309.json

node analysis/grid-filter.js \
  /tmp/indoor-eval/plumeria-test-holdout-104309.json \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl
```

L478 hand fold example; rotate held-out file across the three clean passes:

```sh
node analysis/build-profile.js \
  recordings-new/Plumeria_L478_forward_hand_normal_20260611-124255.jsonl \
  recordings-new/Plumeria_L478_forward_hand_normal_20260611-124358.jsonl \
  --out /tmp/indoor-eval/l478-hand-holdout-123833.json

node analysis/grid-filter.js \
  /tmp/indoor-eval/l478-hand-holdout-123833.json \
  recordings-new/Plumeria_L478_forward_hand_normal_20260611-123833.jsonl
```

L478 pocket behavioral LOO example; rotate held-out among `_anchors-fixed` files and use `--splice-pauses`:

```sh
node analysis/build-profile.js \
  recordings-new/Plumeria_L478_forward_pocket_normal_20260611-134156_anchors-fixed.jsonl \
  recordings-new/Plumeria_L478_forward_pocket_normal_20260611-134318_anchors-fixed.jsonl \
  --out /tmp/indoor-eval/l478-pocket-holdout-133605.json \
  --splice-pauses

node analysis/grid-filter.js \
  /tmp/indoor-eval/l478-pocket-holdout-133605.json \
  recordings-new/Plumeria_L478_forward_pocket_normal_20260611-133605_anchors-fixed.jsonl
```

### C. Profile QA / repeatability checks for thin routes

```sh
cd /Users/alpesh/codebase/indoor-positioning
mkdir -p /tmp/indoor-eval

npm run analyze -- \
  recordings-new/Office_Right-wing-garden_forward_pocket_normal_20260619-013707.jsonl \
  recordings-new/Office_Right-wing-garden_forward_pocket_normal_20260619-013756.jsonl \
  --out /tmp/indoor-eval/office-rw-repeatability.html

npm run analyze -- \
  recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030626.jsonl \
  recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030752.jsonl \
  --out /tmp/indoor-eval/office-lis-current-repeatability.html

npm run analyze -- \
  recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095345.jsonl \
  recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095845.jsonl \
  --out /tmp/indoor-eval/ravi-repeatability.html
```

Interpretation: these are 2-pass smoke checks only. Add a third consistent reuse pass before claiming validation.

### D. Check Swift core parity after any filter math change

```sh
cd /Users/alpesh/codebase/indoor-positioning
npm test
```

Caveat: `FilterParityTests.swift:3-8` and `project.yml:25-34` cover `RouteBeliefFilter` op parity, not `LivePositioningController` step detection, confinement UI/firing gates, checkpoint order/debounce, magnetometer accuracy gating, or live turn detector. If pacing/resume remains risky, implement a controller-level replay test.

### E. Re-run gait-heading spike on LIS forward/reverse

```sh
cd /Users/alpesh/codebase/indoor-positioning
node analysis/gait-heading-direction.js \
  recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030626.jsonl \
  recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030752.jsonl \
  recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
```

Expected from existing research: forward/reverse separation exists, but crude sign resolution is not stable enough to gate production. Only proceed if replacing this with per-step gait-cycle sign resolution and grouped repeatability evaluation.

### F. Pocket/profile mismatch replay

```sh
cd /Users/alpesh/codebase/indoor-positioning

# Correct pocket profile/live pocket trace
node analysis/grid-filter.js profiles/plumeria-l478-pocket.json recordings-new/Plumeria_L478_forward_pocket_live_20260612-135652.jsonl

# Hand profile against known pocket/misprofile-ish live trace
node analysis/grid-filter.js profiles/plumeria-l478-forward.json recordings-new/Plumeria_L478_forward_pocket_live_20260612-133233.jsonl

# Pocket profile against pocket live trace that ended early/old build
node analysis/grid-filter.js profiles/plumeria-l478-pocket.json recordings-new/Plumeria_L478_forward_pocket_live_20260612-134410.jsonl
```

Use this to define mismatch warnings and decide whether a pose classifier is worth implementing.

## 5) Disagreements across branches / artifacts

| Disagreement | Resolution / current repo evidence |
|---|---|
| Artifact 08 claims JS replay freezes belief during confinement while Swift live advances hidden belief. | Current repo does **not** show JS confinement freeze. JS calls `filter.predictStep()` on every step (`analysis/grid-filter.js:793-803`) and uses confinement only in checkpoint gate (`:822-825`). Swift also predicts every step (`LivePositioningController.swift:280-317`) and uses confinement to block fires/freeze display (`:385-390`, `:412-416`, `:439-445`). So the JS-vs-Swift mismatch claim is stale/incorrect, but the hidden-progress risk is real in both. |
| Artifact counts differ: 57 vs 58 sessions. | Current repo has 59 `recordings-new/*.jsonl`. Synthesis uses current count and notes only 2 device models. |
| Pacing “closed” vs “still a hole”. | Current JS replay says existing pacing traces produce 0 fires, but the gate is controller-level and does not alter belief. Needs a new installed-build live pacing→resume test or controller replay before declaring product-closed. |
| Pocket is “validated 6/6” vs “final checkpoint misses at edge”. | Both are true in context: `...135652` historically/live completed 6/6, while other pocket traces end early or suffer pull-out/end transients. Treat pocket-specific profiles as viable at Plumeria L478, not yet generalized. |
| Office Right Wing pose is pocket vs hand. | Profile/survey metadata says `pocket`; docs say phone was visibly held and live traces are hand. Manifest should map intended profile/session role explicitly; do not enforce route+pose equality blindly for historical Office RW. |
| Reverse guard: gait-heading is promising vs no-go. | Compass/device heading is rejected. Gait/PCA has signal, but current crude implementation is no-go (`docs/research/direction-and-entrance-anchoring.md:111-135`). Do not ship; keep offline research or use product/absolute entrance arming. |
| Transition segments are marked `useForMatching:false`, but filters may use them. | Builder sets transition flags (`build-profile.js:489-502`), but grid filters concatenate and score all bins. This is a real unresolved semantics risk; run transition ablation before relying on transition-heavy routes. |
| Live `FALSE ADVANCE` scorer rows are failures vs cosmetic. | Cosmetic for ungraded live positives; real failure for manifest-labeled negatives like LIS reverse/out-of-order/pacing. A manifest is required. |
| ML enthusiasm vs dataset reality. | Artifacts agree once normalized: use tiny/calibrated ML only after labels; no end-to-end neural route-position/odometry on current data. |

## 6) Residual unknowns

1. **Installed Swift live pacing/resume behavior**: current JS replay gates fires, but no controller-level replay or fresh live trace proves no post-confinement checkpoint burst.
2. **Reverse/mid-route/out-of-order product requirement**: if these must be supported, current route model is insufficient; if guided tours always start at entrance, product arming may be enough.
3. **Off-route/standing behavior**: no explicit `offRoute` or `standing` sessions exist in current data.
4. **Pocket robustness beyond Plumeria L478**: no AR meter truth for pocket and little cross-venue/device/user pocket data.
5. **Device diversity**: only two iPhone model identifiers observed; target requires 3+.
6. **2-pass route validity**: Office RW, LIS current, and Ravi are smoke-only until third consistent clean passes are collected.
7. **Transition-segment semantics**: unclear whether current grid-filter use of transition magnetic arrays helps or hides weak-profile failures.
8. **Profile snapshot drift**: live traces often record `profileResource`, not a profile hash/source snapshot; historical replay may not match the installed profile that produced `cp_fired`.
9. **Gait-heading viability**: proper per-step gait-cycle sign resolution is unimplemented and unproven on local data.
10. **Global/far re-entry**: current `OFF` re-entry is local near last confident mode; distant re-entry requires a product decision and likely new architecture.

## 7) Short meta-prompt for an implementation worker

> Implement a manifest-driven evaluation harness for `/Users/alpesh/codebase/indoor-positioning` without changing filter math. Add `analysis/eval-manifest.json` and `analysis/eval-harness.js` that classify `recordings-new` sessions into clean LOO, smoke, live-positive, and negative/misuse cases; rebuild temporary LOO profiles under `/tmp`; call/export `analysis/grid-filter.js` replay; prevent source-file leakage; and emit JSON/HTML/Markdown metrics: checkpoint recall/precision, trigger error in meters when ARKit exists, delay seconds fallback, false fires on negatives, max/sustained `P(OFF)`, confinement stats, and coverage by venue/pose/device. Treat live `cp_fired` as app output, not truth. Do not modify `RouteBeliefFilter`, `LivePositioningController`, or profile JSONs. Validate with representative commands from this synthesis plus `npm test` if any shared filter code is touched.