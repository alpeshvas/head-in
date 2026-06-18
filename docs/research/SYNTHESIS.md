# Research Synthesis: Robust Route-Constrained Positioning

Date: 2026-06-10 · Distilled from five deep-research reports in this directory:
[magnetic-fingerprinting](magnetic-fingerprinting.md) · [pdr-neural-odometry](pdr-neural-odometry.md) · [route-constrained-fusion](route-constrained-fusion.md) · [opportunistic-anchors](opportunistic-anchors.md) · [landscape-benchmarks](landscape-benchmarks.md)

## Verdict

The approach is validated and the field-test failures we hit are all known, solved problems. The closest published system to ours — **FollowMe (MobiCom 2015)**: follow a previously recorded sensor trace along a route — achieved **95% of errors < 2 m, phone-pose-free, on 2015 hardware**. Our realistic target (from the benchmarks report): **1–3 m P50 along-track in hand, 90–95% checkpoint triggers within ±5 m**, degrading to 3–6 m in pocket. The product framing must stay "checkpoint triggering with a permanent one-tap manual fallback," never a blue dot — every commercial player that promised more (IndoorAtlas: $27.5M raised → $1.3M ARR) hit the same wall: survey/maintenance economics and over-promised accuracy.

## Where the reports converge (independent agreement = high confidence)

1. **Our 2 s Pearson window is below the literature floor.** Magicol needs ~20 s of walking to disambiguate from scratch; MagNet uses 4 s windows with learned features; FollowMe matches differenced signals over step-indexed windows. Convergent fix: **4–8 s windows, resampled per-step (spatially), matched on first-differences, gated by raw window variance** (magnetic report §2; fusion report §2 independently demands mean-removal — differencing subsumes it).

2. **The progress ratchet and threshold gates must be replaced by a posterior.** The fusion report's central recommendation — a **discrete-grid Bayes filter over 1-D route position + one explicit OFF-route state** — independently diagnoses the exact bug we hit in field testing ("never ratchet the point estimate"). The magnetic report's Mahalanobis observation model (using the so-far-unused survey `stddev[]` channel) is the emission density that filter needs. These two reports compose into one architecture with zero conflict.

3. **Turn anchors are the single best free win.** Ranked #1 or #2 by two independent agents (PDR report: "biggest accuracy win per effort"; anchors report: "largest drift reset per engineering hour"). Gyro turn events matched against the route's known turn sequence snap progress and expose off-route walking — directly fixing route-blind step accumulation (the pacing-in-the-room failure). UnLoc's landmark resets: 1.69 m median error.

4. **Survey recording must be upgraded before more surveys happen.** Both the PDR and magnetic reports demand it: record raw magnetic vectors + gravity (enables the Bv vertical-component channel later), ARKit 6-DoF pose (turns every survey pass into neural-odometry training data), CMPedometer events, carry-mode annotation, and deliberate negative passes (pacing, off-route, reverse). Data not recorded now cannot be backfilled.

5. **Everything tunes offline from replays, not in hallway walks.** Newson & Krumm's recipe: fit every noise parameter from replayed recordings (emission σ from MAD of residuals at true positions; OFF-state level from cross-matching wrong segments). The EvAAL/IPIN metric standard: P75 error, checkpoint detection rate, false-advance rate, time-to-detection, off-route detection delay. The replay harness is the prerequisite for all algorithm work.

## The composite architecture (one paragraph)

A discrete-grid Bayes filter over route arc-length (+1 OFF state). **Transition:** step events advance belief by a per-segment calibrated stride with ~20% noise and a small backward tail; standing = identity; λ leak into OFF. **Emission:** per-point Gaussian on *differenced, per-step-resampled* magnetic magnitude (later + vertical component Bv) against survey mean/stddev, variance-gated, frozen when `CMCalibratedMagneticField.accuracy < .medium`. **Discrete anchors enter as strong observations:** matched route turns, stair events, accuracy-gated GPS fixes (semi-outdoor venues), audio-playback + dwell behavioral prior (anchor at every tour stop by construction — apparently novel), NFC taps where deployed. **Outputs:** checkpoint advance when P(s ≥ checkpoint) > τ (τ from explicit false-advance vs miss cost ratio); off-route when P(OFF) sustained; UI shows posterior-derived progress that can honestly retreat.

## Sequenced plan

**Phase 0 — survey recorder upgrades (days, do first):** log raw mag vector + gravity, ARKit pose, CMPedometer, carry-mode tag, and record negative passes. Every survey before this is a weaker asset.

**Phase 1 — replay harness (days):** run recorded sessions (incl. Meadows) through the matcher offline with labeled checkpoint times; produce the §5 metrics + likelihood-ridge heatmaps. Kills hallway-debugging.

**Phase 2 — estimator rebuild (1–2 weeks):** grid filter + OFF state; differenced per-step magnetic emission with stddev noise model; parameters fitted from Phase-1 replays; shadow-mode against the current heuristic before flipping the UI.

**Phase 3 — anchors (days each, by venue type):** turn matching → audio/dwell prior → accuracy-gated GPS + entrance initialization (semi-outdoor venues approach VoiceMap-grade triggering with GPS alone) → stair events.

**Phase 4 — scale (weeks, post-validation):** per-segment distinctiveness maps (PDR-only zones by design), crowdsourced fingerprint refinement from confident user traverses (every real tour becomes a survey pass — directly attacks the IndoorAtlas survey-economics trap), RoNIN-class neural odometry via Core ML if pocket-carry replay metrics demand it (license requires own training data for commercial use — which Phase 0's ARKit logging accrues).

## Commercial gate (from the landscape report)

Before investing past Phase 3: **≥90% correct checkpoint triggers within ±5 m across ≥3 venues, 3+ iPhone models, hand and pocket carry**, with false-advance rate low enough that manual confirm feels like a fallback. Keep one-tap manual selection permanently. Before any commercial launch: FTO pass over the IndoorAtlas patent family (magnetic map generation from survey walks; sequence-based matching).
