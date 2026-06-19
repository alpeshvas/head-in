# Research: travel-direction & entrance anchoring for hand-held magnetic PDR

Date: 2026-06-19 · Web research prompted by the LIS reverse-walk false-advance
(walking a forward route backward still fired forward checkpoints). Question:
how do smartphone PDR / magnetic-fingerprint systems get **travel direction**
and **initialize position** when the phone is hand-held (attitude decoupled from
walking direction), camera-free, IMU + magnetometer only?

## Headline correction to our prior conclusion

We concluded "a hand-held phone can't reveal travel direction." Half right: the
**compass/device heading** can't (it reflects how the phone is held), but
**gait analysis of the accelerometer can**. Travel-heading-≠-device-heading is a
named, largely-solved problem with two solution families — one of them light
enough to use without training data.

## 1. Travel heading independent of device orientation

**Gait / PCA methods (lightweight, no training).** The body's forward axis is the
direction of maximum horizontal-acceleration variance over a stride; project
acceleration to a gravity-aligned frame and take the principal component. The
known catch is a **180° forward/backward ambiguity**, resolved from gait-cycle
asymmetry — the sign of forward acceleration during the stance phase, gyro
trough-vs-peak within a stride, or cross-correlation with vertical acceleration —
and the resolution method is chosen per carrying mode (handheld / swinging /
pocket / calling). Reported accuracy **P50 5.6°, P75 9.2°** across modes, using
only accel + gyro.
- PCA-GA / motion-mode recognition: [Sensors 2018, 18(6):1811](https://www.mdpi.com/1424-8220/18/6/1811) ([PMC6021937](https://pmc.ncbi.nlm.nih.gov/articles/PMC6021937/))
- Per-mode heading & ambiguity (RA-PCA): [Guo, Mobile Information Systems 2021](https://onlinelibrary.wiley.com/doi/10.1155/2021/1193268)
- Misalignment (device→body) angle estimation is its own well-patented subfield (TDK/InvenSense): US 10371516, US 11199410.

**Neural inertial odometry (heavyweight, needs training data).** Regress 2D
velocity + heading in a Heading-Agnostic Coordinate Frame (gravity-aligned,
horizontally arbitrary; random horizontal rotations in training). RoNIN's body-
heading network cut Mean Angle Error from **90.6° (device heading) to 13.2°**,
and drift is ~3–5 m/min.
- RoNIN: [ar5iv 1905.12853](https://ar5iv.labs.arxiv.org/html/1905.12853), [project site](https://ronin.cs.sfu.ca/) · survey: [Deep Learning for Inertial Positioning, arXiv 2303.03757](https://arxiv.org/html/2303.03757)
- Caveat for us: iOS CoreMotion tops out at 100 Hz (RoNIN trained at 200 Hz); commercial use needs own training data (license) — Phase-4 territory.

## 2. Why magnetic magnitude can't tell direction (confirmed)

The literature confirms our empirical finding: **forward trajectories produce the
inverse magnetic pattern of backward trajectories**, and with true north unknown
only 2 of the 3 field components are independently usable (horizontal + vertical
intensity, or total + inclination). A single-point magnitude is weakly
distinguishable; systems compensate with **sequence matching combined with the
trajectory contour (heading)** — i.e. they add a directional signal, they don't
get direction from magnitude.
- [How feasible is the use of magnetic field alone for indoor positioning? IEEE](https://ieeexplore.ieee.org/document/6418880/) ([RG PDF](https://www.researchgate.net/publication/261310654))
- [Magnetic-field positioning with TCNs, PMC9921884](https://pmc.ncbi.nlm.nih.gov/articles/PMC9921884/)
- FollowMe (our closest system): step-indexed DTW over the differenced magnetic
  sequence + turn/level detection — direction comes from the *ordered sequence*,
  not the magnitude: [MobiCom 2015](https://yshu.org/paper/mobicom15followme.pdf)

## 3. Entrance / initialization without GPS

Absolute cues are the standard answer: **BLE / NFC / RFID beacons** at entrances
seed a particle filter from beacon proximity, then PDR propagates. Entrance
detectors can even classify *entering vs exiting* from the direction of movement
through the doorway. Magnetic-alone initialization needs a **sequence plus
convergence time** (~10–20 s of walking; the "stand near each beacon ~10 s to
converge" pattern).
- [BLE beacons + PDR particle filter, Applied Sciences 2023, 13(7):4415](https://www.mdpi.com/2076-3417/13/7/4415)
- [IMU + BLE SLAM/mapping, PMC7506668](https://pmc.ncbi.nlm.nih.gov/articles/PMC7506668/) · [RFID cooperative, PMC5795377](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5795377/)

## Implications for this project (decision)

The reverse-walk false-advance is fundamentally a **missing travel-direction
signal**, not a magnetic problem. Options, cheapest first:

1. **Gait-based travel heading + route heading check** *(recommended, no new
   hardware/training).* Add a per-step travel heading via PCA-GA-style analysis
   of logged acceleration, with the 180° resolved from gait asymmetry; compare it
   to the route's expected heading at the hypothesized bin (the survey's ARKit GT
   gives the route heading profile). A sustained ~180° mismatch ⇒ reverse/wrong
   way ⇒ don't fire. Expected heading error ~6–9° is ample to separate forward
   from reverse. This is the literature-backed version of the turn-sequence idea,
   and it works on low-turn routes where turn-matching is weak.
2. **Turn-sequence direction check** — a weaker subset (only informative at
   corners; noisy in open offices, per our LIS data).
3. **Absolute entrance cue (NFC/QR/BLE)** — most robust initialization, needs
   hardware; natural fit if venues get tap-in points.
4. **RoNIN-class odometry** — only if pocket-carry drift later demands it
   (Phase 4; training-data + license cost).

## Experiment run (2026-06-19): gait travel-heading on the LIS traces

`analysis/gait-heading-direction.js` — per ~1.2 s window, PCA principal axis of
gravity-aligned horizontal **user acceleration** (travel axis), sign resolved by
integrated-velocity projection, expressed relative to the world-frame magnetic
field bearing (cancels the per-session arbitrary frame). Result:

| Walk | circMean(travelHeading − fieldBearing) |
|---|---|
| FWD survey p1 | ~122° |
| FWD survey p2 | (same cluster) |
| REVERSE walk | ~−15° |
| **Separation** | **136°** (vs **1°** for the device-compass attitude test) |

**Conclusion: travel direction IS recoverable from gait/acceleration** — a clear
136° forward/reverse split where the device compass gave 1°. The hypothesis holds.
Caveats: the gap from the ideal 180° and the wide spread (~90°) come from the
**crude sign resolution** (1.2 s-window velocity integration, no ZUPT). A temporal
sign-continuity tweak made it *worse* (65°; the two forward passes diverged to
−77°/−136°) — confirming the sign must be resolved **per step from gait-cycle
asymmetry** (the literature method), not propagated. Production path: per-step
PCA-GA with gait-cycle sign resolution (lit. P50 heading error 5.6°) → clean
~180° gate → reject reverse/wrong-way before firing. This validates option (a) in
the decision list above as the right direction.

### Go/no-go follow-up (2026-06-19): per-segment repeatability — NO-GO for a guard with crude sign resolution

To build a wrong-way GATE you need a stable per-segment "expected heading" the
live value can be compared against. Computed per anchor-segment
(travelHeading − fieldBearing) for the **two LIS forward passes** — they should
agree. They don't:

| Segment | fwd p1 | fwd p2 |
|---|---|---|
| Cp1→Cp2 | 103° | 98° ✓ |
| Cp2→Cp3 | −22° | 75° ✗ |
| Cp4→Cp5 | 49° | −144° ✗ |
| Cp6→Cp7 | 70° | 175° ✗ |
| Cp7→Cp8 | −51° | 173° ✗ |

Segments disagree by ~100–170° **between two forward passes of the same route** —
the crude integrated-velocity sign resolution flips inconsistently (±180°). With
no stable forward reference, a guard cannot separate "wrong-way" from normal
pass-to-pass noise. **NO-GO** for a gait-heading wrong-way guard at this effort
level. A usable guard requires proper per-step **gait-cycle sign resolution**
(PCA-GA stance-phase, lit. 5.6° P50) — substantial signal processing, and
cross-pass/pose repeatability still unproven. Decision: do **not** ship a reverse
guard on the guided-tour branch; the reverse/out-of-order cases remain documented
out-of-design limitations, and "any-order" support is the free-roam branch's job
(per-zone matching), not a heading guard.
