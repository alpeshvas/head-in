# Evaluation harness + dataset splits — current-codebase/data only

## TL;DR

- Use `analysis/grid-filter.js` as the primary evaluator: it is the JS reference for the live Swift filter, scores recorded anchors and ARKit meters when present, and includes the current checkpoint/off-route/confinement gates.
- Current data supports **rigorous clean leave-one-out (LOO)** for two AR-backed hand routes: `Plumeria/Test/hand` and `Plumeria/L478/hand`; **behavioral LOO** for `Plumeria/L478/pocket`; and **2-pass smoke validation** for Office/Ravi profiles. It does **not** yet satisfy the commercial gate because only 2 iPhone models are present and several routes have only 2 usable clean passes.
- Live traces are valuable for regression/parity, but most have no independent ground truth. `cp_fired` lines are filter outputs, not truth.
- A real harness needs a small manifest that labels clean/negative/live scenarios, prevents mixing checkpoint-list variants, and records expected outcomes for live negatives such as pacing/reverse/out-of-order.
- Minimal implementation: add `analysis/eval-harness.js` + `analysis/eval-manifest.json`; run existing `build-profile`, `ground-truth`, and `grid-filter` under temporary profiles for LOO; compute structured JSON/HTML metrics. No filter-math change is needed.

## Dataset table

### Canonical data roots

- Prefer `recordings-new/*.jsonl`. The root and `recordings/` copies are older/duplicates by basename; `recordings-new/` currently contains the unique 58 session basenames.
- `profiles/*.json` has 9 profiles; `survey-recorder/SurveyRecorder/Resources/*.json` bundles 7 runtime profiles. `profiles/plumeria-loo.json` and `profiles/plumeria-l478-loo.json` are historical held-out artifacts, not primary runtime resources.

| Group | Current profile(s) | Usable normal/train sessions | Live/negative/eval sessions | Harness role / notes |
|---|---|---|---|---|
| Plumeria / Test / forward / hand | `profiles/plumeria-test-forward.json`; `profiles/plumeria-loo.json` | Primary 3 AR clean passes: `recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl`, `...104347.jsonl`, `...104421.jsonl`. Extra old clean candidate: `...20260610-233814.jsonl`. Exclude `...233908.jsonl` (no anchors). | Positive live: `...live_20260611-113118.jsonl`, `...121903.jsonl`. Pacing/resume live: `...122245.jsonl`. Survey negative: `...pacing_20260610-234034.jsonl`. | Primary AR 3-fold LOO; good short-route regression; extra 233814 should be flagged as an external/older route variant because AR length/tracking differs. |
| Plumeria / L478 / forward / hand | `profiles/plumeria-l478-forward.json`; `profiles/plumeria-l478-loo.json` | 3 AR clean passes: `recordings-new/Plumeria_L478_forward_hand_normal_20260611-123833.jsonl`, `...124255.jsonl`, `...124358.jsonl`. | Positive live: `...hand_live_20260611-125057.jsonl`, `...132738.jsonl`, `...20260612-140544.jsonl`. Pacing negative: `...125529.jsonl`. | Primary AR 3-fold LOO; strong multi-segment/turn regression; includes known pacing/circling hole history. |
| Plumeria / L478 / forward / pocket | `profiles/plumeria-l478-pocket.json` | Use only pause-recovered files as train/test: `recordings-new/Plumeria_L478_forward_pocket_normal_20260611-133605_anchors-fixed.jsonl`, `...134156_anchors-fixed.jsonl`, `...134318_anchors-fixed.jsonl`. Do not train on the raw un-fixed siblings except for diagnostics. | Positive live: `...pocket_live_20260612-134410.jsonl`, `...135652.jsonl`. Wrong-profile/mis-profiled live: `...133233.jsonl`. | Behavioral LOO only: no AR meters; use `--splice-pauses`; score anchor timing/checkpoint recall, not ±5 m acceptance. |
| Office / Right wing garden / forward | `profiles/office-right-wing-forward.json` | 2 AR clean passes: `recordings-new/Office_Right-wing-garden_forward_pocket_normal_20260619-013707.jsonl`, `...013756.jsonl`. | Positive live: `...hand_live_20260619-014811.jsonl`, `...014934.jsonl`. | 2-fold smoke only. Profile route says `devicePose=pocket`, but live pose is hand; use `profileResource`/manifest mapping, not route+pose equality alone. |
| Office Near / LIS / forward / current generic checkpoints | `profiles/office-near-lis-forward.json` | 2 AR clean passes: `recordings-new/Office-Near_LIS_forward_hand_normal_20260619-030626.jsonl`, `...030752.jsonl`. | Positive live: `...hand_live_20260619-031601.jsonl`. Reverse/misuse negative: `...031803.jsonl`. | 2-fold smoke only; important reverse-walk negative. |
| Office Near / LIS / forward / legacy named checkpoints | No stable current profile snapshot; resource name later reused | 3 AR normal passes with named checkpoints: `...normal_20260619-023522.jsonl`, `...023742.jsonl`, `...023914.jsonl`. | Live with named checkpoints: `...live_20260619-024630.jsonl`, `...024824.jsonl`. | Do **not** mix with generic `Checkpoint 1..8` profile. Optional: reconstruct a temporary legacy profile from these sessions for historical regression only. |
| Ravi place / Home / forward / hand | `profiles/ravi-place-home-forward.json` | Profile sources are 2 reuse passes: `recordings-new/Ravi-place_Home_forward_hand_normal_20260619-095345.jsonl`, `...095845.jsonl`. Exclude/diagnose ad-hoc bootstrap `...095202.jsonl`. | Positive live: `...live_20260619-101048.jsonl`. Negatives: out-of-order `...100523.jsonl`, pacing `...102451.jsonl`, longer pacing `...105724.jsonl`. Unlabeled/partial candidates: `...102433.jsonl`, `...115128.jsonl`. | 2-pass smoke plus negative hardening; not rigorous clean LOO unless a third reuse clean pass is added. |
| Meadows / Test / forward / hand | `profiles/meadows-test-forward.json` | 5 old anchored sessions with no AR/passType: `recordings-new/Meadows_Test_forward_hand_20260610-200257.jsonl`, `...200332.jsonl`, `...200404.jsonl`, `...200434.jsonl`, `...200514.jsonl`. | `recordings-new/Meadows_Test_forward_hand_normal_20260610-233734.jsonl` has AR but no anchors; no live traces. | Historical repeatability/behavioral LOO only; not acceptance. |
| Test / Test / forward / hand | No profile checked in | 5 old one-segment anchored sessions: `recordings-new/Test_Test_forward_hand_20260610-193139.jsonl`, `...193441.jsonl`, `...194428.jsonl`, `...194457.jsonl`, `...194527.jsonl`. | None. | Optional historical profile/repeatability only; exclude from primary harness until product relevance is clear. |

Profile-level summary from checked-in profiles:

| Profile | Route/pose | Source passes | Anchors / segments | AR meters available? | Calibration | Notes |
|---|---:|---:|---:|---:|---|---|
| `profiles/plumeria-test-forward.json` | Plumeria/Test/hand | 3 | 4 / 3 | yes, ~13 m | AR LOO, `diffSigmaUT=2.556`, `offLL=-4.863` | one turn; 2 fingerprint + 1 transition segment |
| `profiles/plumeria-l478-forward.json` | Plumeria/L478/hand | 3 | 7 / 6 | yes, ~46 m | AR LOO, `2.84/-3.946` | six turns; harder loop/repeated hallway |
| `profiles/plumeria-l478-pocket.json` | Plumeria/L478/pocket | 3 | 7 / 6 | no | anchor-interpolated, `2.684/-5.052` | requires pause splicing; turn evidence disabled at replay/live for pocket pose |
| `profiles/office-right-wing-forward.json` | Office/Right wing/pocket-tagged | 2 | 5 / 4 | yes, ~18 m | AR LOO over 2 passes, `1.218/-3.418` | only 2 passes; 2 transition segments |
| `profiles/office-near-lis-forward.json` | Office Near/LIS/hand | 2 | 8 / 7 | yes, ~61 m | AR LOO over 2 passes, `2.172/-3.623` | current generic checkpoint variant |
| `profiles/ravi-place-home-forward.json` | Ravi place/Home/hand | 2 | 5 / 4 | yes, ~29 m | AR LOO over 2 passes, `3.573/-3.174` | weak-ish field; important pacing negatives |
| `profiles/meadows-test-forward.json` | Meadows/Test/hand | 5 | 4 / 3 | no | none | old schema/no AR |

## Proposed splits

### 1. Clean LOO split — acceptance-grade where AR + ≥3 clean passes exist

Run each fold as: train on all clean normal passes except one; build a temporary profile; replay the held-out session; aggregate checkpoint and meter errors.

- **Plumeria/Test/hand:** LOO over `104309`, `104347`, `104421`. Keep `233814` as external stress only; exclude `233908`.
- **Plumeria/L478/hand:** LOO over `123833`, `124255`, `124358`.
- **Plumeria/L478/pocket:** LOO over the three `*_anchors-fixed.jsonl` files using `--splice-pauses`; score only checkpoints with held-out anchor truth and mark meters unavailable.

Acceptance-grade aggregate should be computed only from AR-backed folds. Pocket folds are valuable for product behavior but cannot count toward ±5 m meter acceptance without another truth source.

### 2. Clean 2-pass smoke split — useful but not rigorous

Use these to detect regressions, not to claim generalization:

- Office Right wing: train pass A → test pass B and train B → test A.
- Office Near LIS current generic: train `030626` → test `030752` and reverse.
- Ravi Home: train `095345` → test `095845` and reverse. Do not include `095202` in profile training; treat it as ad-hoc/bootstrap stress if used at all.

Reason: docs explicitly warn that 2 clean passes cannot produce honest LOO because the training profile becomes a 1-pass profile.

### 3. Fixed-profile positive replay split

Use checked-in profiles to replay positive live/known-good sessions for regression:

- `profiles/plumeria-test-forward.json` × `Plumeria_Test_forward_hand_live_20260611-113118.jsonl`, `...121903.jsonl`.
- `profiles/plumeria-l478-forward.json` × `Plumeria_L478_forward_hand_live_20260611-125057.jsonl`, `...132738.jsonl`, `...20260612-140544.jsonl`.
- `profiles/plumeria-l478-pocket.json` × `Plumeria_L478_forward_pocket_live_20260612-134410.jsonl`, `...135652.jsonl`.
- `profiles/office-right-wing-forward.json` × `Office_Right-wing-garden_forward_hand_live_20260619-014811.jsonl`, `...014934.jsonl`.
- `profiles/office-near-lis-forward.json` × `Office-Near_LIS_forward_hand_live_20260619-031601.jsonl`.
- `profiles/ravi-place-home-forward.json` × `Ravi-place_Home_forward_hand_live_20260619-101048.jsonl`.

These should be reported separately as “live route-completion regression”, not ground-truth acceptance, unless a manifest supplies independent notes.

### 4. Negative-test split

Strict expected outcome for all negative cases: **zero checkpoint fires before any documented genuine route entry/resume**. Off-route flag is desirable for off-route/standing, but pacing may only be fire-blocked by confinement and not always show sustained `P(OFF)>0.5`.

- Pacing/in-place: `Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl`; `Plumeria_L478_forward_hand_live_20260611-125529.jsonl`; `Ravi-place_Home_forward_hand_live_20260619-102451.jsonl`; `Ravi-place_Home_forward_hand_live_20260619-105724.jsonl`.
- Reverse/direction misuse: `Office-Near_LIS_forward_hand_live_20260619-031803.jsonl`.
- Out-of-order/shortcut misuse: `Ravi-place_Home_forward_hand_live_20260619-100523.jsonl`.
- Wrong profile/carry mismatch: `Plumeria_L478_forward_pocket_live_20260612-133233.jsonl` should be labeled explicitly because older traces did not record `profileResource`.
- Cross-route specificity: replay clean sessions against non-matching route profiles (e.g., Plumeria Test clean against L478/Ravi/Office profiles) and require no accepted checkpoint triggers. Keep this as a secondary “specificity” test because the product normally selects a profile before tracking.

### 5. Exclusions / quarantine

- `recordings-new/Plumeria_Test_forward_hand_normal_20260610-233908.jsonl`: no anchor taps.
- `recordings-new/Meadows_Test_forward_hand_normal_20260610-233734.jsonl`: AR but no anchors.
- Raw pocket normal siblings without `_anchors-fixed` should not be in profile training unless specifically testing pause-splice recovery.
- `Office-Near_LIS_*023*` and `*024*` should not be mixed with the generic-checkpoint LIS profile; they are a legacy checkpoint-list variant.
- Live traces with no `end` line or no scenario label can be replayed for diagnostics but should not affect pass/fail aggregates.

## Metrics

### Clean AR-backed route metrics

For each held-out survey pass with AR poses and anchors:

1. **Checkpoint recall:** `truth checkpoints fired / truth checkpoints`.
2. **Checkpoint precision / false advances:** `correct fires / all fires`; any fire with no corresponding true checkpoint, wrong order, duplicate, or outside tolerance is a false advance.
3. **Signed trigger error in meters:** for checkpoint `i`, compute true checkpoint meter `M_i = truthMetersAt(anchor_i.t)` and detection meter `M_det = truthMetersAt(firedAt)`; report `M_det - M_i` and `abs(...)`.
4. **Acceptance trigger rate:** percent of checkpoints with `abs(trigger_error_m) <= 5m`. This matches the repo’s commercial gate; do not substitute seconds when AR meters exist.
5. **Route-position error:** over step updates between start/end anchors, report mean, P50, P75, P90/P95, and max `abs(binToMeters(meanBin) - truthMetersAt(t))`. Current `grid-filter.js` already prints mean/P50/P75.
6. **Off-route behavior during clean walks:** max `P(OFF)`, any sustained off-route flag, and whether off-route false-positive blocks checkpoint completion.

### Clean non-AR / pocket metrics

- Checkpoint recall and order.
- Signed delay seconds vs anchor taps; current `grid-filter.js` uses `|delay| <= 6s` as a console verdict, but this is a fallback metric only.
- Anchor/segment fraction error if AR is absent.
- Mark as “behavioral only; not ±5 m acceptance”.

### Negative metrics

- **False-fire count:** must be zero for pure negative windows.
- **Time to first false fire:** if any, fail and report first checkpoint/time.
- **Off-route detection:** `offRouteAt`, max `P(OFF)`, duration above `P(OFF)>0.5`; required for off-route/standing, optional for pacing if fire blocking is working.
- **Confinement gate diagnostics:** min/median confinement ratio for pacing; useful because current fire gate is based on normalized field-range confinement.

### Profile/input quality metrics

- Per-segment repeatability `meanCorrelation` and `meanDtwMicrotesla`; flag `r < 0.85` as survey risk and `r < 0.5` as hostile/weak.
- Transition segment count and whether a route relies heavily on dead reckoning.
- Calibration source: `arkit` vs `anchor-interpolated`, LOO vs in-sample, pass count.
- AR tracking quality by segment; exclude or downgrade segments below existing `match-route` threshold (`0.6`) for meter scoring.

### Aggregate gates

- Report by route, venue, pose, and device model.
- Commercial gate from docs: **≥90% correct triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand+pocket**. Current data has only two device models (`iPhone14,5`, `iPhone16,2`) and limited pocket meter truth, so current harness can measure progress but cannot certify that gate.

## Command matrix

| Purpose | Current script/command to run | Needed extension |
|---|---|---|
| Inventory sessions/profiles | New harness should parse all `recordings-new/*.jsonl` and `profiles/*.json`. Today this requires ad-hoc Node one-liners. | Add `analysis/eval-harness.js inventory --data recordings-new --profiles profiles`. |
| Repeatability by group | `npm run analyze -- <same-route normal sessions...> --out /tmp/eval/<group>-repeatability.html` | Harness should run this per manifest group and ingest r/DTW from profiles or stdout. |
| Build temporary LOO profile | `npm run build-profile -- <train normal files...> --out /tmp/eval/<fold>.json`; for pocket add `-- --splice-pauses` after script args if invoking through npm, or `node analysis/build-profile.js ... --splice-pauses`. | Harness should create temp profiles per fold and never write into `profiles/` during evaluation. Optional: export build-profile pure functions to avoid child processes. |
| Inspect AR truth | `npm run ground-truth -- <session.jsonl> --out /tmp/eval/<session>-gt.html` | Harness should compute AR coverage/segment meters automatically. |
| Replay primary filter | `node analysis/grid-filter.js <profile.json> <session.jsonl> [--out /tmp/eval/<case>.html]` | Harness should call exported `replay()` and produce structured JSON metrics instead of parsing console text. |
| Legacy heuristic comparison | `npm run match -- <profile.json> <session.jsonl> --out /tmp/eval/<case>-match.html` | Optional only; primary acceptance should use `grid-filter.js`. |
| JS↔Swift parity after filter/harness-affecting changes | `npm test` | If filter math changes, regenerate fixtures with `analysis/make-parity-fixture.js`; harness changes alone should not require fixture regeneration. |

Concrete manual examples until the harness exists:

```sh
# Plumeria/Test fold: hold out 104309
TMP=/tmp/indoor-eval-plumeria-test-104309.json
node analysis/build-profile.js \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104347.jsonl \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104421.jsonl \
  --out "$TMP"
node analysis/grid-filter.js "$TMP" \
  recordings-new/Plumeria_Test_forward_hand_normal_20260611-104309.jsonl

# Pocket fold/profile build requires pause splicing
node analysis/build-profile.js \
  recordings-new/Plumeria_L478_forward_pocket_normal_20260611-133605_anchors-fixed.jsonl \
  recordings-new/Plumeria_L478_forward_pocket_normal_20260611-134318_anchors-fixed.jsonl \
  --out /tmp/indoor-eval-l478-pocket-fold.json \
  --splice-pauses

# Negative replay examples
node analysis/grid-filter.js profiles/plumeria-test-forward.json \
  recordings-new/Plumeria_Test_forward_hand_pacing_20260610-234034.jsonl
node analysis/grid-filter.js profiles/office-near-lis-forward.json \
  recordings-new/Office-Near_LIS_forward_hand_live_20260619-031803.jsonl
node analysis/grid-filter.js profiles/ravi-place-home-forward.json \
  recordings-new/Ravi-place_Home_forward_hand_live_20260619-105724.jsonl
```

## Gaps in labels / ground truth

1. **No automated LOO rotation yet.** `docs/STATUS.md` calls this out explicitly; profile building has calibration LOO internally, but evaluation LOO is not automated.
2. **Live traces lack independent truth.** They record filter state and `cp_fired`, but no anchor taps or AR; `cp_fired` should be treated as observed app output, not correctness.
3. **Profile snapshot drift.** Some live traces have missing `profileResource`; some resource names were reused after rebuilding profiles (notably Office Near LIS named vs generic checkpoints). A profile hash or embedded source profile snapshot is absent.
4. **Negative labels are incomplete.** Only schema/passType supports `pacing`, `offRoute`, `standing`, and `live`; current data contains explicit `pacing` for Plumeria Test, while many live negative scenarios are known only from docs/filename/context. No explicit `passType=offRoute` or `passType=standing` files are present in the current data inventory.
5. **Pocket has no AR meter truth.** Pocket surveys use pause-derived anchors and anchor-interpolated calibration; score checkpoint behavior but not ±5 m acceptance.
6. **Two-pass routes cannot be rigorous.** Office Right wing, current Office Near LIS, and Ravi production profiles have 2 clean reuse passes; 2-fold train/test is useful but not the honest 3-pass LOO recommended by survey practice.
7. **Device diversity is short.** Current `recordings-new` metadata covers two device models, while acceptance asks for 3+ iPhone models.
8. **Route misuse policy needs separation.** Reverse and out-of-order traces expose known 1-D route-order assumptions. Keep them as a “misuse/robustness” bucket unless product decides they are acceptance blockers.
9. **Old schema/duplicate data.** Early `Meadows`/`Test` files lack `passType`; raw and fixed pocket files share basenames aside from suffix; harness must de-dupe and prefer fixed variants where appropriate.

## Minimal harness implementation plan

1. **Add `analysis/eval-manifest.json`.** Encode route groups, profile sources, clean LOO candidates, live positives, negatives, exclusions, expected outcomes, and notes. This is required because metadata alone cannot distinguish current vs legacy LIS, ad-hoc bootstrap vs trainable pass, or live pacing/reverse/out-of-order.
2. **Add `analysis/eval-harness.js`.** Responsibilities:
   - Discover/parse sessions from `recordings-new/`.
   - Validate manifest paths and checkpoint signatures.
   - Build temp profiles for LOO using `analysis/build-profile.js` (child process is fine initially; optional later export pure functions).
   - Run `grid-filter.replay()` from `analysis/grid-filter.js` for each case.
   - Compute structured metrics: checkpoint recall/precision, trigger error meters/seconds, position error percentiles, false-fire count, `P(OFF)`/offRouteAt, profile repeatability/calibration summaries.
   - Emit `analysis/eval-summary.json` and `analysis/eval-summary.html` (or configurable `--out` paths).
3. **Optionally factor scoring out of `grid-filter.js`.** Current replay is exported, but console scoring is not. A small exported `scoreReplay(profile, session, replay, expected)` would prevent duplicate metric logic.
4. **Do not change filter math in the harness work.** If filter math later changes, regenerate parity fixtures and run `npm test`.
5. **Future recorder improvement:** write a profile hash/sourceFiles snapshot into live trace meta, not just `profileResource`, so old live traces can be replayed against exactly what ran.

## Exact file/path citations

- Product target is route/checkpoint/zone confidence, not blue-dot GPS: `README.md:17-25`; `docs/architecture.md:3-4`, `docs/architecture.md:205-216`.
- Recorder streams, anchors, and AR truth: `README.md:37-47`; `docs/architecture.md:7-16`.
- Profile build/replay commands and profile contents: `README.md:57-90`; `docs/architecture.md:25-55`.
- Runtime filter state/model/checkpoint logic: `docs/architecture.md:87-95`, `docs/architecture.md:100-145`, `docs/architecture.md:179-191`.
- Current phase/gap note for replay harness and LOO: `docs/STATUS.md:9-10`; data inventory notes and existing commands: `docs/STATUS.md:73-77`.
- Commercial gate and constraints: `docs/STATUS.md:102-104`.
- Survey practice: 3-pass LOO requirement and ad-hoc bootstrap exclusion: `docs/SURVEY-PRACTICE.md:42-57`; AR GT guidance: `docs/SURVEY-PRACTICE.md:59-62`; pocket pause/splice protocol: `docs/SURVEY-PRACTICE.md:72-78`; validation checklist: `docs/SURVEY-PRACTICE.md:80-86`.
- Pass types and negative semantics: `survey-recorder/SurveyRecorder/Models.swift:18-44`.
- JSONL file naming/meta fields including `profileResource`: `survey-recorder/SurveyRecorder/SessionWriter.swift:30-57`; live traces write profile resource: `survey-recorder/SurveyRecorder/LivePositioningController.swift:150-163`.
- Live filter state and `cp_fired` trace lines: `survey-recorder/SurveyRecorder/LivePositioningController.swift:394-423`.
- Bundled runtime profiles list: `survey-recorder/SurveyRecorder/RouteProfile.swift:22-31`.
- `analysis/analyze-repeatability.js` purpose, usage, and r thresholds: `analysis/analyze-repeatability.js:1-14`, `analysis/analyze-repeatability.js:176-180`, `analysis/analyze-repeatability.js:232-247`.
- `analysis/build-profile.js` profile builder constants/CLI/session parsing/profile fields: `analysis/build-profile.js:17-30`, `analysis/build-profile.js:78-151`, `analysis/build-profile.js:470-524`; turn signatures: `analysis/build-profile.js:527-601`; calibration fitting: `analysis/build-profile.js:604-699`; CLI write path: `analysis/build-profile.js:742-793`.
- Pocket pause splicing: `analysis/splice-pauses.js:1-15`, `analysis/splice-pauses.js:44-71`.
- `analysis/ground-truth.js` AR arc-length truth and segment truth APIs: `analysis/ground-truth.js:1-17`, `analysis/ground-truth.js:60-120`.
- `analysis/grid-filter.js` reference replay/scoring basis: `analysis/grid-filter.js:1-28`; parameters including checkpoint/off-route/confinement gates: `analysis/grid-filter.js:40-99`; replay checkpoint/off-route update loop: `analysis/grid-filter.js:730-839`; console scoring and AR error output: `analysis/grid-filter.js:845-909`.
- Legacy heuristic matcher, optional comparison only: `analysis/match-route.js:1-11`, `analysis/match-route.js:398-428`, `analysis/match-route.js:570-606`.
- Parity fixture generation and XCTest linkage: `analysis/make-parity-fixture.js:1-11`; package scripts: `package.json:6-13`.
