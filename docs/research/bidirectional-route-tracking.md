# Research: bidirectional ("to-and-fro") traversal of a single surveyed 1-D path

Date: 2026-06-19 · Web research + code-grounded analysis prompted by the question:
can the route-constrained 1-D magnetic-PDR grid-Bayes filter be extended so a user
can walk a surveyed path to the end, **U-turn, and walk back along the same path**
(repeatedly) with correct position tracking and sensible checkpoint behavior in
**both directions**? Anchored to [SYNTHESIS.md](SYNTHESIS.md); builds directly on
[direction-and-entrance-anchoring.md](direction-and-entrance-anchoring.md).

---

## Headline finding

**CONDITIONAL-GO.** To-and-fro on a *single* surveyed path is a fundamentally
easier problem than full free-roam (open free-roam still needs more work — see the
`free-roam` branch, currently at 37% held-out without anchors), and the central
hypothesis is **supported by the literature and by this codebase's own measured
properties**:

1. The magnetic and PDR machinery already in the filter tracks a retraced path in
   reverse *for free in principle* — the field is the same field walked backward,
   and the differenced emission is direction-sensitive (a reversed walk produces a
   reversed-and-negated difference sequence). **The only hard blocker is that
   `predictStep` hardcodes forward drift (kernel mean `+stride`); the belief
   representation itself already carries backward mass.** (Confirmed from code,
   §1–§2.)
2. The reversal at the route end is a **discrete, gyro-detectable ~180° U-turn**,
   and rotation rate is **travel-coupled** (turning your body around yaws the phone
   too) — unlike the absolute compass, which gave only 1° forward/reverse
   separation because phone attitude is decoupled from travel direction
   ([direction-and-entrance-anchoring.md](direction-and-entrance-anchoring.md) §2,
   STATUS L98). So a **binary forward/backward "direction latch"** toggled by
   detected unmatched ~180° turns is a *plausible* substitute for the
   continuous-gait-heading signal (which was harder than expected at the effort
   tried — a discrete latch sidesteps it).
3. **FollowMe (MobiCom 2015), our closest cited system, already does exactly this
   bidirectionally** — its deviation-recovery replays the trace "in the reverse
   direction" to guide the user back, and it states plainly that "the reverse
   navigation works the same as the normal forward navigation" (§6, quoted below).
   The "All the Way There and Back" backtracking system (arXiv 2401.08021) is an
   even more direct precedent: pocket-phone, inertial+magnetic, map-free retrace.

But it is **CONDITIONAL**, not GO, because:

4. The latch has **measured failure modes in this repo** — pocket pose compresses
   turn magnitudes ~30–40% (a real end U-turn could miss a ≥100° threshold), slow
   circling U-turns emit **no turn event at all** (the documented circling-pacing
   hole), and pacing-in-place false U-turns would wrongly toggle the latch (§3).
   A *missed* end U-turn is the dangerous case: the belief is pinned at the end
   barrier and the return leg has no reverse mode (§3.4).
5. **There is no round-trip recording anywhere in `recordings/` or
   `recordings-new/` — every trace is `forward`** (verified). The entire verdict
   is therefore gated on capturing one out-and-back trace with ARKit ground truth
   before any Swift/live work. The offline validation plan (§7) is the real
   deliverable; the design sketch is provisional until that trace exists.

**Boundary (explicit):** this is NARROWER than full free-roam (arbitrary rooms, any
order, shortcuts), which is a harder open problem on the `free-roam` branch (37%
held-out so far without anchors — see that branch for the path forward). To-and-fro
fixes the **return leg and repeated
back-and-forth on ONE path walked end-to-end**. It does **not** solve "user starts
by walking the route backward from the far end" (cold start still assumes the
Start press = entrance anchor, §5).

---

## 1. Belief representation: does anything prevent tracking BACKWARD?

**No — the representation is direction-agnostic; only the transition kernel is
forward-only.** Confirmed from `RouteBeliefFilter.swift` / `grid-filter.js`:

- The belief is a distribution over concatenated arc-length bins (`belief[]`) plus
  one OFF scalar. Nothing in the array structure encodes a direction; bin *i−1* is
  as representable as bin *i+1*.
- `init` seeds bins 0–7 with `exp(-i/3)` and normalizes (`grid-filter.js:300`,
  `RouteBeliefFilter.swift:163`). That is a *prior*, not a structural constraint.
- `predictStep` builds a Gaussian kernel **centered at `i + m`** where `m =
  binsPerStep` (`grid-filter.js:334-344`): `lo = floor(i - m)`, `hi = ceil(i + 3m)`,
  kernel weight `exp(-0.5·((j - i - m)/σ)²)`. The kernel support *does* include
  backward bins (`lo = i − m`, the documented "small backward tail",
  route-constrained-fusion.md §5), but its **mean is +m** — every step pushes mass
  one stride *forward*. This is the single hardcoded directional assumption.
- The route **start AND end are absorbing barriers** (`grid-filter.js:346-357`):
  mass overflowing below bin 0 piles at bin 0; mass past the last bin piles at
  `bins-1`. On a return leg the end barrier is *helpful* (you start the return
  pinned there) but the start barrier means a return leg's mass will pile at bin 0
  on arrival, which is correct (you're back at the entrance).

**Conclusion:** to track backward, `predictStep` must center the kernel at `i − m`
when a "backward" direction state is active. No other representational change is
required. The OFF re-entry kernel (centered on `lastConfidentMode`,
`grid-filter.js:369-384`) and `probBeyond` already work on absolute bins and are
direction-neutral; `probBeyond` semantics for checkpoints need a direction-aware
rethink (§4), but the mechanism is intact.

> **Extrapolation flag:** the claim "only the kernel mean blocks backward tracking"
> is my reading of the code, not a cited result. It is directly checkable in the
> offline replay (§7) — run a reversed-time replay through a kernel patched to
> `i−m` and confirm tracking.

## 2. The emission in reverse: is the field match actually GOOD?

**Yes — on a retraced path the magnetic evidence is as good as forward; direction
is the only missing piece, not the field match.** This is the load-bearing reason
to-and-fro is feasible where free-roam is not.

The emission (`perPointLogLik`, `grid-filter.js:263-290`) compares the **stride-lag
first-difference** of a per-step-resampled live window to the same difference of the
profile around the hypothesized bin:

```
resid = (live[k+lag] - live[k]) - (mean[idx+lag] - mean[idx])
```

Walking the path backward, the live magnitude sequence is the forward sequence
**retraced in reverse** (you pass the same physical field samples in reverse order).
So the live first-difference sequence is the forward difference sequence **reversed
and negated**. Two consequences:

- **The raw field is symmetric** (magnitude at a point is the same regardless of
  travel direction) — this is *why* the forward profile would still false-advance a
  reverse walk with raw magnitude (STATUS L96, the LIS reverse-walk bug). The
  literature confirms this is fundamental: "forward trajectories produce the inverse
  magnetic pattern of backward trajectories"
  ([direction-and-entrance-anchoring.md](direction-and-entrance-anchoring.md) §2,
  citing [IEEE 6418880](https://ieeexplore.ieee.org/document/6418880/)).
- **The differenced emission is direction-sensitive** — a reversed-negated difference
  sequence does NOT match the forward profile's positive-going differences at the
  true bin under a *forward* window read (STATUS L53: "reversed walk = reversed-negated
  diff sequence"). It WILL match if the profile window is **read in the latch
  direction**: i.e., when the latch is "backward", compute the residual against the
  profile difference taken in the reverse direction (negate the lag term / read the
  profile window decreasing). Concretely, the minimal change is: when backward,
  compare `(live[k+lag]-live[k])` against `(mean[idx]-mean[idx+lag])` (the profile
  difference walked the other way), and map the window's newest sample to the
  *lower* bin edge instead of the upper.

This is precisely how **FollowMe** operates: it "filter[s] out the high-frequency
components of the magnetic field sensing and then utilize[s] the **differential
magnetic field information that is independent of the absolute values**" and uses
"only the magnitude of the magnetic signal" (FollowMe §5.1–5.2). Its step-constrained
DTW aligns the live differential sequence to the reference; **the same DTW, walked in
reverse, is what powers its return-navigation** (§6 quote below). The "All the Way
There and Back" backtracker formalizes the reverse match as a **directed graph indexed
by way-in time and return time, "assum[ing] the walker moves in the same direction as
the reversed way-in path"** with node cost = magnetic-vector discrepancy
([arXiv 2401.08021](https://arxiv.org/abs/2401.08021)) — a literal reversed-sequence
alignment.

**Magnitude-symmetry literature (cited):**
- "How feasible is the use of magnetic field alone for indoor positioning?"
  ([IEEE 6418880](https://ieeexplore.ieee.org/document/6418880/),
  [RG PDF](https://www.researchgate.net/publication/261310654)) — with true north
  unknown only 2 of 3 field components are independently usable; a single point is
  weakly distinguishable; systems compensate with **sequence matching + trajectory
  contour (heading)**, i.e. they *add* a directional signal, they don't get direction
  from magnitude.
- FollowMe ([MobiCom 2015 PDF](https://rtcl.eecs.umich.edu/rtclweb/assets/publications/2015/mobicom15followme.pdf))
  — Fig. 5 shows the magnetic *shape* is stable across devices and carry modes even
  as absolute level varies; differencing exploits exactly that.

**Conclusion:** on the return leg the field evidence is *good* (you are on a known
path). The differenced emission already gives the direction-discriminating structure;
it just needs to be **read in the latch direction**. The two concrete edits:
(a) window→bin mapping anchors the newest sample at the low edge when backward;
(b) the sign/order of the profile first-difference flips. No new sensor, no new
training.

> **Extrapolation flag:** that the reverse-read emission will actually *score the
> true reverse position highest* is asserted from the difference-sequence algebra and
> FollowMe's reverse-DTW precedent, **not measured on this venue's data** (no
> round-trip trace exists). This is the #1 thing the validation trace (§7) must show:
> a likelihood ridge along the *decreasing-bin* diagonal on the return leg.

## 3. The latch mechanism and its failure modes

**Proposal under evaluation:** a binary `direction ∈ {forward, backward}` state,
toggled by a detected **unmatched ~180° turn** (the existing `observeTurn` already
classifies turns as matched-route-turn vs unmatched-U-turn). Forward: kernel mean
`+m`, forward emission read. Backward: kernel mean `−m`, reverse emission read.

The existing turn detector (`turn-events.js`) is the toggle source: gyro rotation-rate
projected onto the gravity axis, integrated over a contiguous turning region, with the
half-rotation point localized in time. It fires only when rotation **stops for ≥0.5 s**
(`mergeGapS`) and the integrated change exceeds `minTurnDeg`=35°. `observeTurn` treats
an unmatched rotation ≥`turnNegativeMinDeg`=100° as a reversal (OFF injection +
8-step reversal leak). **The latch toggle would hook the same unmatched-≥100° event**
that already drives `reversalActive`.

This is literature-aligned: FollowMe's recovery is triggered by detecting a deviation
and then **"notifies the user to make a U-turn"** and replays the trace in reverse —
the U-turn is the explicit direction-reversal event (§6). PDR systems detect
"quick about-turns where a pedestrian makes a substantially 180° turn... by checking
whether azimuth values before and after differ by 180°"
([Tandfonline PDR context](https://www.tandfonline.com/doi/full/10.1080/10095020.2024.2338225)).

### 3.1 Pocket pose compresses turn magnitudes ~30–40% (measured)

STATUS L54/L57: in pocket replays, leg-swing compressed route-turn magnitudes ~30–40%,
**zero pocket turn matches in any pass**, and the pocket turn signature was systematic
but distorted (+91/−72/+150/+139 vs hand). A genuine end-of-route U-turn of true ~180°
would land at ~110–125° in pocket — *still* above the 100° threshold, **but barely**,
and a 160° route U-turn would compress toward ~100–112° and risk missing. Turn evidence
is already **disabled for pocket pose** in both filters (`grid-filter.js:732`,
STATUS L57). **So in pocket, the latch toggle is unavailable** — a to-and-fro pocket
walk has no reliable reversal signal. This caps the conditional-GO to **hand carry**
unless an alternate toggle (e.g. a magnetic-shape reversal detector, see §3.5) is added.

### 3.2 Slow-arc / circling U-turns emit NO turn event (the circling-pacing hole)

STATUS L53: "the turn detector only emits when rotation stops for 0.5 s, so pacing in
slow circles... produces no turn events." A user who **rounds the end of the path in a
wide arc** (rather than a crisp pivot) produces continuous sub-threshold rotation → no
unmatched-U-turn event → **the latch never flips** → the return leg is tracked as if
still forward (false-advance past the already-fired end, or pile at the end barrier).
This is the same hole that defeats the pacing gate and is **unsolved at the turn-detector
level**. Mitigation is the magnetic-shape reversal cross-check (§3.5), not the gyro.

### 3.3 Pacing-in-place false U-turns wrongly toggle the latch

The "Ravi pacing" saga (STATUS L89–L94): in-place pacing on a route whose own turn is a
U-turn emits U-turns that already cause trouble. **For to-and-fro specifically, is a
wrong backward march more or less harmful than the current forward false-advance?**

- *Current forward-only design:* a false U-turn injects OFF + reversal-leak; the belief
  is held but **keeps marching forward** on step count once the leak expires (the
  unsolved march, STATUS L91). Damage: premature forward checkpoint fire.
- *With a latch:* a false U-turn would flip to **backward**, and the kernel would march
  the belief *backward*. If the user is actually pacing in place, backward march is
  **arguably less harmful** — it retreats from un-reached checkpoints rather than firing
  them early, and the *next* false U-turn flips back to forward (pacing emits U-turns in
  pairs). The belief oscillates around the true patch instead of marching off the end.
  This echoes the **REJECTED "reversal-aware backward prediction"** (STATUS L92) — but
  that was rejected because it broke *legit forward walks whose own U-turn failed to
  match* (Test-clean −178° at support 0.02 → backward-stepping broke the real walk).
  **The latch inherits that exact risk:** a route's own U-turn that fails the
  support/proximity match would wrongly flip the latch backward mid-forward-walk.

**This is the sharpest design tension.** The mitigation is the existing
matched-vs-unmatched machinery: a latch toggle must fire **only on an unmatched U-turn
that also fails to be a route turn AND occurs where the belief is at/near the route end**
(for the intended end-of-route reversal) — not on any unmatched ≥100° rotation. See §3.6.

### 3.4 A MISSED end-of-route U-turn (the dangerous case)

If the end U-turn is missed (pocket compression §3.1, slow arc §3.2, or the user pivots
during the ≥0.5 s the detector needs but keeps moving): the belief is **pinned at the end
absorbing barrier** (`grid-filter.js:354`), the latch stays forward, and the return leg
has **no reverse mode**. Forward `predictStep` keeps trying to push past `bins-1` (all
mass stays at the barrier). The return-leg field evidence would then *mismatch* the
forward profile read at the end bin → P(OFF) climbs → eventually flags "Off route?".
That is the **safe** failure (no false fire), but it means **the return leg simply
doesn't track** until a reversal is detected. A magnetic-shape reversal cross-check
(§3.5) is the backstop: if the live differenced window starts matching the profile read
*backward* from the end bin for ≥N steps while the latch is forward, force-flip the latch.

### 3.5 Distinguishing a route's OWN turn from a genuine reversal

The route may legitimately contain turns (L478 has a +181° route U-turn at bin 786,
plus +215°, −133°, etc. — see `plumeria-l478-forward.json` turns[]). `observeTurn`
already separates these: a **matched** route turn (sign+magnitude within 55°, posterior
mean within 3σ of the turn bin, ≥10% support) re-concentrates belief and does NOT set
`reversalActive`; only an **unmatched** ≥100° rotation does. **The latch must reuse this
exact gate:** flip direction only when `observeTurn` returns the unmatched-U-turn branch
(`grid-filter.js:529-544`), never on a matched route turn. A route that contains its own
U-turn (L478 +181° at bin 786) is correctly handled: that turn *matches the signature*
and so does not flip the latch — provided the proximity/support gates hold (the known
weakness: STATUS L92, a legit U-turn at low support is misclassified unmatched).

### 3.6 Net latch-toggle rule (proposed)

Flip `direction` on an `observeTurn` event that is (a) unmatched, (b) |Δ| ≥ ~140°
(tighter than the 100° OFF threshold — a *reversal* is near-180°, a 100° corner is not),
(c) the posterior is near the relevant terminus for the intended leg (forward→backward
flip expects belief near the end barrier; backward→forward flip near bin 0), and
(d) corroborated within N steps by the magnetic-shape reversal cross-check (the live
differenced window scoring higher read in the new direction than the old). Conditions
(c)+(d) are what separate a genuine end-of-path turnaround from a mid-route pacing U-turn.

> **Extrapolation flag:** the 140° threshold, the terminus-proximity condition, and the
> magnetic cross-check corroboration are **my synthesis**, not from a cited source.
> They are the natural composition of the repo's existing gates (proximity/support,
> reversal-suppression) with the latch idea, and **must be tuned/validated on a
> round-trip trace before being trusted** (§7).

## 4. Checkpoint semantics on the return leg (product decision — options, not a verdict)

Today checkpoints are a **strict forward ratchet**: `reachedCheckpoints` only
increments, "only the next checkpoint can fire" (`LivePositioningController.swift:407-430`),
`displayBin` is floored at the last reached checkpoint and never retreats
(`:436-446`). The decision test is `P(s ≥ decisionBin) > τ` via `probBeyond`
(`grid-filter.js:573-577`, OFF mass excluded). On a return leg, `probBeyond` (mass at
**or beyond** a bin) is the wrong primitive — walking backward, you *re-cross*
checkpoints from above, so `P(s ≥ X)` stays high (you're still beyond early
checkpoints) and `P(s ≤ X)` is the natural "returning past X" test.

Options (a product call, deliberately not decided here):

- **(A) Re-fire on return (symmetric):** treat each checkpoint as fireable in both
  directions; on the return leg fire when `P(s ≤ decisionBin)` crosses τ. Gives the
  user "now passing Room 3 (returning)" events. Requires un-ratcheting
  `reachedCheckpoints` into a per-direction cursor.
- **(B) Distinct "returning past X" events:** fire a *different* event type on the
  return so the UI/tour can react differently (e.g. "heading back, last stop X"). The
  FollowMe model — reverse navigation "works the same as forward" — supports symmetric
  events; a guided-tour product may want distinct semantics.
- **(C) Suppress on return:** the return is just egress; fire nothing, only update the
  position/progress display. Simplest; matches "the tour is over, walk out."
- **(D) Lap counting:** for repeated back-and-forth, each full out-and-back is a "lap";
  checkpoints fire once per direction per lap. Needed only if the product wants rep
  counting (e.g. a walking-exercise framing).

**Mechanical note:** whichever is chosen, the `displayBin` floor (`:436-446`) and the
UI timeline "fire-once-forward" ratchet (`:432`) must be made direction-aware or they
will fight the return (the segment card would freeze at the end and the rings could
not retreat). This is UI plumbing, not filter math.

## 5. Cold start boundary (explicit confirmation)

To-and-fro **still assumes the user STARTS forward at the entrance.** The filter seeds
belief at bin 0 (`init`, §1); the product stance is "Start press = entrance anchor"
(STATUS L100 option (b): "the user pressing Start at the entrance IS the entrance
anchor"). To-and-fro fixes the **return leg and repeated back-and-forth after a forward
start**; it does **NOT** solve:

- "User starts by walking the route **backward from the far end**" — that is the LIS
  reverse-walk bug (STATUS L96), unsolved without entrance anchoring (magnetic-only
  entrance arming was ATTEMPTED and REVERTED, STATUS L97; GPS/NFC entrance cue is the
  research-aligned fix, blocked on hardware/venue).
- Arbitrary room order / shortcuts — full free-roam, a separate open problem
  (`free-roam` branch, 37% held-out so far without anchors).

This boundary is **clean and defensible**: a guided tour enters at the start by
construction. To-and-fro is "you reached the end of the tour and now walk back out the
way you came," which is a real, common physical behavior — not misuse.

## 6. Literature: how the field handles bidirectional / retraced 1-D paths

**FollowMe (Shu, Shin, He, Chen — MobiCom 2015)** — the closest cited system, and it is
*already bidirectional on one path*:
- Architecture (Fig. 1): Magnetometer + Gyroscope + Accelerometer + Barometer feeding a
  **Turn Detector** and **Step Detector**; navigation by step-constrained DTW
  synchronization of the live differential-magnetic sequence to a recorded reference
  trace.
- Magnitude-only, differential: "only the magnitude of the magnetic signal may be used
  in practice"; "utilize the differential magnetic field information that is independent
  of the absolute values" (§5.1–5.2). **Direct precedent for this repo's differenced
  emission.**
- Turn detection from gyro in the gravity-aligned (LVLH) frame, "**turn detection is
  independent of Z-axis**" (§6.2) — **identical in spirit to `turn-events.js`** (yaw
  rate projected on the gravity axis).
- **Bidirectional recovery (§5.3 / §6, verbatim):** "it notifies the user to make a
  **U-turn** and navigates him back to the correct path. Specifically, FollowMe replays
  (**in the reverse direction**) turning or stair climbing actions the user took on the
  smartphone screen. ... the walking progress estimator ... synchronizes the geomagnetic
  observations before and after the **U-turn**. Note that **the reverse navigation
  component can also be used to guide the user back to a previously visited place. Since
  the reverse navigation works the same as the normal forward navigation**, in what
  follows we will focus on deviation detection." → FollowMe treats the U-turn as the
  reversal event and the return as the *same DTW walked in reverse*. **This is the
  published version of the direction-latch idea, modulo that FollowMe re-runs DTW rather
  than flipping a discrete state in a grid filter.**
- Result: 95% of spatial errors < 2 m, phone-pose-free, 2015 hardware
  ([PDF](https://rtcl.eecs.umich.edu/rtclweb/assets/publications/2015/mobicom15followme.pdf)).

**"All the Way There and Back" (arXiv 2401.08021, 2024)** — the most *direct*
bidirectional-retrace precedent:
- Phone-in-pocket, **inertial + magnetic sensors only**, smartwatch UI; **backtracking
  "requires no map knowledge"** (map-free retrace of the outbound path)
  ([abstract](https://arxiv.org/abs/2401.08021)).
- Backtracking via a **directed graph indexed by way-in time and return time**, expanding
  as the walker progresses, edges accounting for different step lengths, **"assum[ing]
  the walker moves in the same direction as the reversed way-in path"**; node cost =
  Euclidean magnetic-vector discrepancy; alignment = min-cost path (reversed-sequence
  DTW/Viterbi). Tested with 7 blind participants in a campus building.
- **Takeaway:** a deployed system retraces a single outbound path in reverse using
  pocket inertial+magnetic, with an explicit "same direction as the reversed path" model
  — validating both (a) reverse retrace is real and (b) the reversed-sequence match is
  the right primitive.

**On "heading parity" / discrete direction-state filters specifically:** I did **not**
find a paper that names a binary "heading-parity" or "direction latch" state flipped by
gyro U-turns in a 1-D grid/HMM. The closest are (i) FollowMe's U-turn-triggered reverse
DTW (a *procedure*, not a state variable), (ii) the backtracker's reversed-way-in
directed graph (a *graph construction*, not a runtime latch), and (iii) PDR ~180°
about-turn detectors that flip heading by checking the azimuth difference is ~180°
([Tandfonline](https://www.tandfonline.com/doi/full/10.1080/10095020.2024.2338225)),
which is a continuous-heading correction, not a path-direction state. **So the
"heading-parity state" framing remains an extrapolation** (STATUS L53 flagged it as
not-from-the-literature) — but it is a *reasonable discretization* of mechanisms the
literature does use, and it is strictly cheaper than the gait-heading continuous signal
(which was harder than expected at the effort tried). The literature supports the *ingredients* (gyro U-turn
detection is travel-coupled and reliable for ~180° pivots; reversed-sequence magnetic
match works); it does not pre-package the exact latch.

**Bidirectional transitions in HMM/particle path filters:** standard HMM/grid map-matching
permits backward transitions by construction (the transition kernel can have backward
mass); production matchers (Newson-Krumm, Valhalla Meili) are direction-agnostic over the
road graph (route-constrained-fusion.md §1). The 1-D specialization here just needs the
kernel mean to follow the latch. Pedestrian particle filters with direction states exist
([Directional Particle Filter](https://www.academia.edu/109692591/A_Directional_Particle_Filter_Based_Multi_Floor_Indoor_Positioning_System)),
but for *heading* over a 2-D map, not a binary path-parity — not a direct fit.

## 7. Verdict, minimal design, and the offline validation plan

### Verdict: CONDITIONAL-GO (hand carry, single path, forward start)

GO conditions, in order of how load-bearing they are:
1. A round-trip recording must exist and show a **reverse-direction likelihood ridge**
   (reverse emission scores the true decreasing-bin position highest on the return leg).
   *Nothing is built until this is measured.*
2. The end U-turn must be **reliably detected** in hand carry on that trace (gyro
   unmatched-U-turn event near the end barrier). If it is, the latch is viable; if it
   slips (slow arc), the magnetic cross-check (§3.5) must catch it.
3. The latch toggle must **not mis-fire on the route's own turns** (reuse the
   matched/unmatched + proximity/support gates).

Conditions that would force a rethink of the approach: reverse emission does NOT ridge
(would mean the differenced reverse-read doesn't actually discriminate on real data —
refutes §2); end U-turn reliably missed even in hand; or the latch regresses forward
walks the way the rejected backward-prediction did (STATUS L92). Each has a known next
lever if hit (e.g. magnetic-shape reversal confirm, recapture anchors).

### Minimal design sketch (provisional, gated on §7 validation)

- **State:** add `direction ∈ {forward, backward}` to the filter (default forward).
- **Direction-aware `predictStep`:** kernel mean `+m` when forward, `−m` when backward;
  start/end barriers swap roles (backward: start bin 0 is the "absorbing end").
- **Direction-aware emission:** when backward, anchor the live window's newest sample at
  the *low* bin edge and compare against the profile first-difference taken in reverse
  (`mean[idx] - mean[idx+lag]`). Keep `diffSigmaUT`/`offLogLikPerPoint` as fitted.
- **Latch toggle:** on `observeTurn`'s unmatched branch, if |Δ| ≥ ~140° AND posterior is
  near the relevant terminus AND a magnetic-shape reverse cross-check corroborates within
  N steps → flip `direction`. Reuse `reversalActive` to suppress fires during the flip.
- **Magnetic-shape reverse cross-check (the backstop for missed/slow U-turns):** run a
  cheap parallel score of the live differenced window read in the *opposite* direction at
  the current mode; if it beats the current-direction score for ≥N consecutive steps,
  force-flip the latch even without a gyro U-turn. This closes the circling-pacing hole
  for to-and-fro (where free-roam can't use it, because here there's a single known path
  to match against).
- **Checkpoints:** pick a §4 option (recommend (A) symmetric re-fire with `P(s ≤ X)` on
  the return, or (C) suppress, per product); make `displayBin` floor and UI ratchet
  direction-aware.
- **Parity:** all of this must stay JS↔Swift identical and regenerate the
  `FilterParityTests` fixtures (STATUS outstanding #2). The magnetic cross-check is pure
  magnitude math (no turn-detector parity gap), like the confinement gate.

### THE OFFLINE VALIDATION PLAN (the actual blocker)

**No round-trip trace exists — every recording is `forward` (verified).** Capture this
FIRST, before any code:

1. **Recording to capture:** on an existing surveyed venue (Plumeria Test ~12 m, or
   L478 43 m for a turn-rich case), record ONE continuous **out-and-back** pass:
   walk the route forward to the end, **physically U-turn**, walk back to the start —
   ideally **2–3 laps** in one recording to test repeated reversal. **Hand carry**
   (turn evidence requires it). **ARKit ground truth ON** (surveyor camera) so the true
   arc-length-vs-time is known across the reversal. Tap anchors on the forward leg as
   usual; the return leg's truth comes from ARKit. Also capture a **pocket** out-and-back
   (to confirm the §3.1 pocket-latch limitation empirically) and a **slow-arc turnaround**
   variant (to exercise §3.2).
2. **Pre-code analysis (no Swift, no filter edits):**
   - **Reverse likelihood ridge:** extend `grid-filter.js`'s heatmap/`perPointLogLik` to
     score the return-leg windows against the profile read backward; plot logLik(bin × t).
     **PASS if the true (ARKit) decreasing-bin trajectory is a visible ridge on the
     return leg**, comparable in contrast to the forward ridge. This validates §2.
   - **U-turn detectability:** run `turn-events.js` on the trace; confirm an unmatched
     ~180° event at the physical turnaround (time-localized near the end-barrier crossing),
     in hand carry. Measure its magnitude in pocket (expect compression, §3.1).
   - **Latch prototype in JS only:** add a `direction` state to a *copy* of the replay
     (not the shipped filter), toggle on the unmatched-U-turn, and score: does the belief
     track the return leg (P50/P75 m vs ARKit on the return), and do checkpoints behave
     per the chosen §4 policy? **PASS target: return-leg P50 within the same 1–3 m band
     as forward (SYNTHESIS), 0 false fires during the reversal, latch flips within a few
     steps of the true turnaround.**
3. **Metrics that confirm/refute (EvAAL/IPIN-style, SYNTHESIS pt. 5):** return-leg P50/P75
   along-track error vs ARKit; checkpoint behavior correctness on the return (per policy);
   latch-flip delay (steps between true turnaround and latch flip); false-advance count
   during reversal; lap-to-lap repeatability over 2–3 laps; pocket-vs-hand latch
   reliability. **Only if the JS prototype passes does Swift/live work start.**

This mirrors the repo's proven discipline (SYNTHESIS pt. 5, route-constrained-fusion.md §6):
everything tunes offline from replays; no hallway debugging; the live port follows a green
offline matrix.

---

## Decision summary

| Question | Answer |
|---|---|
| Feasible at reasonable effort? | **CONDITIONAL-GO** — hand carry, single path, forward start |
| Belief representation a blocker? | No — only `predictStep`'s forward kernel mean (§1) |
| Is the reverse field match good? | Yes — differenced emission is direction-sensitive; field evidence is as strong as forward; direction is the only missing piece (§2) |
| Is the latch idea literature-backed? | The *ingredients* yes (FollowMe reverse-DTW on U-turn; backtracker reversed-way-in graph); the exact binary "heading-parity latch" is an **extrapolation** (§6) |
| Hardest failure mode? | Missed/slow end U-turn (latch never flips, return leg untracked) + false-toggle from a route's own U-turn (§3.2–3.5) — both mitigated by a magnetic-shape reverse cross-check |
| Blocking prerequisite? | **Capture ONE hand-carry out-and-back recording with ARKit GT; show a reverse likelihood ridge and a clean latch flip in a JS-only prototype BEFORE any Swift work** (§7) |

**Out of scope here (separate open problems, each with a known next lever):**
full free-roam / any-order / shortcuts (`free-roam` branch, 37% so far — needs
anchors or a room-graph HMM); backward-from-far-end cold start (entrance
anchoring, STATUS L96–L100); pocket-carry latch (turn evidence currently
hand-only — §3.1, a pocket turn model would extend it).

---

## 8. First round-trip recordings captured & analyzed (2026-06-19)

Two out-and-back traces on **Office-Near LIS** (hand, ARKit GT), the first
round-trip recordings in the repo (prior to this, every trace was `forward`):
- `recordings-new/Office-Near_LIS_roundtrip_hand_normal_20260619-163708.jsonl`
  (rounded turnarounds, ~2 laps)
- `recordings-new/Office-Near_LIS_roundtrip_hand_normal_20260619-165928_crisp-pivot.jsonl`
  (single clean out-and-back, crisp in-place pivot)

Research harness: `analysis/bidir-replay.js` (standalone; does NOT touch the
shipped `grid-filter.js` / `RouteBeliefFilter.swift`). Latch report, reverse
emission read, and a direction-aware `DirectionalFilter` prototype with ARKit
ground truth for both legs (turnaround located from the gyro U-turn, not
displacement — a square route makes displacement-from-start useless).

### 8.1 VALIDATED: the latch-toggle mechanism (§3) — crisp pivot gives a clean U-turn

On the crisp-pivot trace, `turn-events.js` measured the in-place turnaround as
**−200°**, cleanly separated from the route's own corners (the square's corners
all read ≤90°: +86/−54/+71/+89 outbound). With `UTURN_MIN_DEG`=140 the
turnaround is the *only* event that flips the latch; the corners are correctly
ignored. **This answers the single biggest open question from §3: a gyro U-turn
CAN reliably flag the reversal when the user pivots in place.** The first
(rounded) trace confirms the §3.2 failure mode is real too — of its ~3 physical
turnarounds only 1 produced a clean ≥140° event; the others fragmented into
~75–86° pieces (rounded arc → sub-threshold rotation regions). So: crisp pivot
→ reliable latch; rounded turnaround → the magnetic-shape reverse cross-check
(§3.5) is **load-bearing, not optional**.

### 8.2 NOT ANSWERED on this venue: the §2 reverse-tracking claim — LIS field too weak

The reverse-tracking validation (does the differenced emission, read backward,
track the return leg at the same 1–3 m as forward?) **could not be answered on
LIS**, for a venue reason, not a code reason:

- The bare-emission **argmax** does not ridge even FORWARD here (1/68 within 1.5
  strides of truth) — pointwise magnitude is too weakly discriminative (the
  documented LIS weak-field finding; offLogLik −3.6). What makes the shipped
  filter localize is the step prior accumulating over time, not the emission
  argmax — so an argmax probe is the wrong test.
- The full **shipped `grid-filter.js`** saturates **P(OFF)=1.0 even on the LIS
  profile's OWN survey passes** (`...023522`, `...023742`) — the filter cannot
  hold a confident posterior on this venue at all. With no clean forward
  baseline, there is nothing to compare reverse tracking against.

The direction-aware `DirectionalFilter` replay therefore produced untrustworthy
numbers (forward leg P50 ~17 m — diverging like the shipped filter does here),
so **no §2 verdict** is drawn from LIS. The harness's hand-rolled event loop
also lacks the shipped `replay()` stabilizers (idle ticks, terminal freeze,
unobserved-leak) — a second reason its absolute numbers aren't comparable; the
proper integration is to drive the real `replay()` path, deferred.

### 8.3 What this changes / next step

- Verdict UNCHANGED: **CONDITIONAL-GO**. The latch mechanism is now empirically
  validated (8.1); the reverse-tracking claim (§2) remains *untested*, not
  refuted.
- **The §2 test needs a STRONG-FIELD venue round-trip** (Plumeria Test ~12 m or
  L478, which track sub-meter forward) — exactly what §7 anticipated. Capture
  one clean single out-and-back (crisp pivot, ARKit GT) at a Plumeria route;
  then `bidir-replay.js --oracle` / `--filter` gives a trustworthy answer
  because the forward baseline is clean there.
- Harness TODO when resumed: integrate direction-awareness into
  `grid-filter.js`'s real `replay()` rather than the parallel loop, so absolute
  metrics match the shipped filter.

## 9. SHIPPED: backward-walk detection latch (2026-06-19, §3.6 + §4-C)

Built the **detect-reversal-and-suppress** increment (NOT reverse tracking,
which stays deferred per §8.2) into the shipped filters, in JS↔Swift parity:

- **`returning` latch** (`grid-filter.js` + `RouteBeliefFilter.swift`): a
  persistent forward/backward state. Toggled in `observeTurn`'s unmatched
  branch when |Δ| ≥ `turnReversalMinDeg`=140° AND the posterior is at the
  relevant **terminus** (last segment → flip to backward; first segment → flip
  to forward). The terminus guard is the §3.6(c) condition and is what prevents
  a route's OWN mid-route U-turn from flipping the latch.
- **`reversalActive()`** now returns `reversalStepsLeft > 0 || returning`, so
  checkpoint fires stay suppressed for the WHOLE return leg, not just the
  8-step reversal window. UI surfaces "Returning" (`LivePositioningController`).
- **Zero regressions** (replay matrix, graded cases identical: Test P50 0.62
  ok×3, L478 P50 0.27 ok×6, Ravi P50 0.37 ok,ok,ok,MISSED). **Iteration 1
  regressed Ravi** (a mid-route +178° unmatched turn flipped the latch →
  Checkpoint 2 ok→late); **the terminus guard fixed it** — the spurious turn
  fires when belief is mid-route, not in the last segment.
- **Parity green**: 6/6 `FilterParityTests` pass including a new
  `parity-fixture-lis-roundtrip` fixture; `reversalActive` is now asserted in
  the fixture so a JS↔Swift latch-wiring divergence is caught.
- Unit-checked in isolation: latch flips on an at-end ≥140° U-turn, flips off
  at start, ignores mid-route turns and <140° turns.

**Known limitation (same root as §8.2):** on the LIS round-trip the `returning`
latch does **not** actually engage, because the weak field keeps the posterior
mid-route (bin ~460) when the physical U-turn fires at ~27 m (bin ~1670) — so
the terminus guard correctly refuses to flip. The latch is therefore *built and
parity-safe but not yet demonstrated engaging end-to-end*; that demonstration
needs a **strong-field round-trip** (Plumeria) where forward tracking reaches
the terminus. The mechanism is correct (unit-checked); the venue is the blocker.

## 10. EXPERIMENTAL: −stride reverse position tracking (2026-06-19, §1+§2)

Added the actual reverse-*tracking* (not just suppression) to the shipped filter,
gated behind `returning` so it is **provably inert forward** (zero matrix
regressions; 6/6 parity green incl. the round-trip fixture):
- **Direction-aware `predictStep`**: kernel mean ±stride by the latch; asymmetric
  tail flips (3 strides with the drift, 1 against). Barriers already correct
  (backward overflow piles at bin 0 = back at entrance).
- **Direction-aware emission** (`perPointLogLik(..., reverse)`): on the return
  leg the window (newest-sample-last, always) maps the newest sample to the
  current bin and older samples to HIGHER bins, and the profile first-difference
  is read downward. **A newest-first indexing bug in the first cut scored 0/7;
  fixed to newest-last → the emission math localizes a synthesized return window
  24/24 (worst |diff| 0 bins) on Plumeria Test.** (Note: `bidir-replay.js`'s
  `perPointLogLikReverse` still has the old newest-first bug — research harness,
  superseded by the shipped path.)

**Integration result — works on clean geometry, FRAGILE on ambiguous routes
(NOT yet shippable enabled):** driving the real filter in `returning` mode through
a synthesized clean return leg on **L478**: the unambiguous middle tracks
near-perfectly (errors 1–9 bins over a long stretch), but it **collapses on the
twice-traversed hallway** — the belief slides to a mirrored lower-bin position and
runs to the start barrier (P50 108 bins / P75 278 bins overall), pOff staying 0
throughout. Root cause = the **same mirrored-corridor ambiguity the forward filter
has on L478** (STATUS L50), but worse going backward: there is no route-U-turn
anchor to recapture on the return, so once the `−stride` march locks onto the
mirror it cannot recover. On unambiguous routes this would not occur, but the
filter cannot tell ahead of time.

**Verdict:** the `−stride` idea is correct and the emission math is proven; reverse
*tracking* is real but **inherits (and amplifies) the forward filter's
mirrored-geometry weakness**, so it must NOT be enabled live on arbitrary routes
yet. It stays in the code, forward-inert, as the foundation. To make it shippable
needs either (a) a recapture anchor on the return (the reversed turn sequence), or
(b) restricting it to routes without mirrored/ambiguous segments, plus the
still-pending strong-field live round-trip to validate against real sensor data
(this test used synthesized clean windows, which isolate the math but omit live
noise). The deployed live build uses the **detect+suppress** behavior (§9), which
is safe; the −stride tracking is not wired into the Live decision path.

## 11. Reversed turn-sequence RECAPTURE — makes the office (LIS) return leg work (2026-06-19, §3.5)

Built option (a) from §10's verdict: on the return leg, match detected turns
against the profile's turn signature read in **reverse order with flipped sign**,
and on a match perform a **landmark RESET** (UnLoc-style) — replace belief with a
Gaussian at that corner's bin. Harness: `bidir-replay.js --recapture`.

**Measured on the real LIS crisp-pivot round-trip vs ARKit GT** (the venue whose
weak field defeated plain −stride tracking, §8/§10):
- The return-leg corners match the reversed signature cleanly and **in order**
  (the order constraint is essential — LIS corners are 76°/92°, too close to
  disambiguate by magnitude; a `_revCursor` consumes the signature end-first):
  −79°→bin 1452, −90°→bin 1211, −71°→bin 516.
- **Return-leg P50: 34 m → 10 m, P75: 38 m → 18 m** (a 3.4× improvement). Right
  after each corner re-pin the error collapses to 2–8 m; it then drifts up over
  the long weak-field segment until the next corner resets it (classic
  landmark-reset sawtooth).
- Same result with the **real gyro flip** as with the oracle flip (the crisp
  pivot fires the U-turn at the true turnaround), so this is the honest
  end-to-end number, not an oracle artifact.

**Honest framing of "10 m":** it is NOT smooth 1–3 m tracking. But on LIS the
**forward** leg's raw posterior mean is *also* ~17 m off — forward only "works"
live via the displayBin ratchet + ordered checkpoint fires (step-count ticking on
a mostly-transition route), NOT via a confident magnetic position (P(OFF)=1.0 even
on LIS's own survey passes). So recapture brings the **return leg up to the same
regime as the forward leg** on this weak venue: corner-grade re-localization, good
enough to tick "returning past X" checkpoints, with honest drift between corners.

**Status:** validated in the harness on one real round-trip against ARKit; **not
yet ported to the shipped filter** (would be `observeTurn` reverse-signature
matching gated on `returning`, in JS↔Swift parity + fixtures). It is the
mechanism that makes to-and-fro work on a cornered route — the recapture carries
the return where the raw emission alone drifts.

## 12. CORRECTION: LIS is NOT a weak-field venue — old profile was the problem (2026-06-19)

§8.2/§10/§11 concluded "LIS field too weak, forward only ticks checkpoints
(P(OFF)=1.0)". **That was wrong — it came from a stale 2-pass LIS profile built
from sloppy passes.** Two fresh clean normal passes (`...201023`, `...201754`,
hand, ARKit GT) rebuild a much better profile:
- **6 of 7 segments STRONG** (r 0.87–1.00); only segment 5 Kitchen→Ops table is
  weak (r 0.34, a long open stretch). Calibration σ2.09 / offLL −3.73.
- **Leave-one-out forward vs ARKit: A→B 7/7 ok, P50 0.91 m / P75 2.01 m;
  B→A 7/7 fired, P50 0.69 m** (P75 27 m tail from segment 5's wrong-mode
  excursion, recovered). **LIS forward genuinely tracks sub-meter** — the user
  was right that "forward worked", and the earlier weak-field verdict was a
  profile artifact, not a venue property.

**Re-grounded backward result on the crisp-pivot round-trip with the FRESH
profile:**
- Forward leg: **P50 3.54 m** (was a bogus 17 m under the stale profile).
- Backward, plain −stride: P50 13.6 m (drifts on weak segment 5).
- Backward, **+ reversed-turn recapture: P50 7.59 m / P75 10.70 m** — corners
  re-pin cleanly (1463→1219→514), ~2× the forward error, remaining gap
  concentrated on the one weak segment between corners.

**Net:** with a properly-built profile, LIS forward is ~0.7–0.9 m (leave-one-out)
and the backward return tracks at ~7.6 m with recapture (corner-grade, limited by
the single weak segment). The bundled profile + parity fixture were updated to
the fresh passes (6/6 parity still green). This is the real grounding: to-and-fro
**does** work on the office once the profile is good; the recapture is what
carries the weak segment on the return.

## 13. CORRECTION #2: the 7.6 m was a STALE-HARNESS artifact — the SHIPPED filter does P50 3.26 m; the real blocker is the LIFECYCLE, not the math (2026-06-19)

Re-measured the crisp-pivot round-trip through the **actual shipped path**
(`grid-filter.js` `replay()` + the real `RouteGridFilter` class, which now carries
the latch + −stride + reverse emission + reversed-turn recapture since commit
`62f6fb7`) instead of `bidir-replay.js`'s `--filter` mode. **This closes the §8.3
TODO** (drive the real `replay()`, not the parallel loop) and overturns the §12
number.

**Measured (shipped `replay()`, crisp-pivot, vs ARKit GT projected onto the
outbound path — same GT as §11/§12):**
- Forward leg: **P50 3.43 m / P75 5.21 m**
- Return  leg: **P50 3.26 m / P75 6.29 m** — i.e. the return leg tracks *as well
  as the forward leg*, NOT at 7.6 m.

The latch engages cleanly: the −200° turnaround flips `returning` false→true
(`revCursor`=2), and the three reversed-signature corners re-pin in order
(−79°→1463, −90°→1219, −71°→514, `revCursor` 2→1→0→−1). The return trajectory is
sub-4 m for most of the leg; the only blemish is one ~7 s excursion on weak
segment 5 (t+76–84) where pOff saturates to 1.0 and the mean teleports back toward
the end (bin ~1581, err ~28 m) — fully recovered by the −71° corner recapture
(0.59 m immediately after). That single excursion is the entire P75 tail; the rest
of the return is ~1–4 m.

**Why §12's 7.59 m was wrong:** `bidir-replay.js --filter` runs a *stale parallel
loop* (`DirectionalFilter` + `directionalReplay`) written BEFORE the logic was
ported into the shipped class. It (a) uses `perPointLogLikReverse`, which still has
the newest-first indexing bug §10 fixed in the shipped `perPointLogLik(...,reverse)`,
and (b) lacks the shipped `replay()` stabilizers (mode-anchored OFF re-entry,
terminal freeze, unobserved leak). **`bidir-replay.js`'s `--filter`/`--recapture`/
`--oracle` numbers are superseded — use the shipped `replay()`.** (Its `latchReport`
and `--ridge` building-block probes are still valid.)

**THE REAL BLOCKER (lifecycle, proven):** the return leg only tracked because the
crisp-pivot trace's **last forward checkpoint (Arcade/ATH) never fired** — the user
U-turned ~2 m short of its decision zone (forward mean reached bin 1604; decision
bin ~1640), so `checkpointStates.every(fired)` stayed false and the turnaround was
delivered to `observeTurn`. **The typical to-and-fro — walk to the end, last
checkpoint fires, THEN U-turn — is the BROKEN case**, because:
- `grid-filter.js:924` skips ALL turn events once every checkpoint has fired
  (`if (checkpointStates.every((cp) => cp.firedAt !== null)) continue;`), and
- the Live controller is stricter still: `completeRoute()`
  (`LivePositioningController.swift:508`) sets `isComplete=true`, `isRunning=false`,
  stops the recorder and closes the trace; `handleDeviceMotion` bails on
  `!isComplete` (L233). **Once the forward route completes, the Live filter is dead
  — no steps, no turns, no chance to flip the latch.**

Proof the guard is load-bearing: monkeypatching the turnaround U-turn to be dropped
(simulating "all forward checkpoints fired ⇒ turn skipped") collapses the return
leg from **P50 3.26 m → 18.89 m / P75 32.45 m** (belief stays pinned near the end
barrier, never reverses). So the difference between a tracked and an untracked
return leg is literally whether the terminus U-turn reaches `observeTurn`.

**Reframed verdict (POSITION):** the return-leg position track is already good on a
strong-profile route (≈ forward, ~3 m P50). See §14 for the sharper, decision-level
picture — position-good is NOT the same as trigger-ready. **One blocker is that the
decision path terminates filtering at forward completion.** The fix is a lifecycle
change, not a filter change:
1. After forward completion, do NOT tear down — enter a bounded "return watch":
   keep the filter alive, keep feeding steps + turns.
2. Deliver a terminus U-turn (≥140°, posterior at end) to `observeTurn` even
   post-completion so it flips `returning` (today's guard suppresses exactly this).
3. Once `returning`, the existing −stride + recapture track the return leg; pick a
   §4 checkpoint policy (suppress, or re-fire "returning past X" with `P(s ≤ X)`).
4. Guard against garbage: only enter return-tracking on a genuine end U-turn
   followed by continued stepping; otherwise stop as today (a user who finishes and
   stands still / walks off-route must still "complete").

**Caveat (data gap):** this is ONE clean single out-and-back, and it sits in the
lucky regime (last checkpoint unfired). The fix is proven *negatively* (suppressing
the turnaround breaks it) but not yet demonstrated end-to-end on a trace where the
forward leg fires ALL checkpoints and then U-turns — that trace does not exist
(the 163708 round-trip is ~2 laps; the single-out-and-back GT mapper can't score
it). The smallest unblocking recording: **one hand round-trip where the user fully
enters the final checkpoint (so it fires) before the crisp U-turn**, to confirm the
post-completion return-watch tracks the same ~3 m.

**Committed this session (offline only; no device deploy):**
- `analysis/bidir-replay.js --shipped` — drives the REAL `replay()` and scores
  both legs vs ARKit (the honest 3.43 m / 3.26 m). The `--filter/--oracle/
  --recapture` DirectionalFilter path is now banner-marked SUPERSEDED (it is the
  source of the stale 7.59 m).
- `grid-filter.js` `replay()` turn guard relaxed: after forward completion, a
  terminus U-turn (≥`turnReversalMinDeg`) is still delivered to `observeTurn` so
  the latch can flip post-completion (the offline mirror of the Live
  return-watch). **Zero graded-metric regression** across the forward matrix
  (Test-clean 3/3 P50 0.35, L478-clean 6/6 P50 0.34, LIS-fwd 7/7 P50 0.59,
  pacing negatives still 0 fires — all identical; the only diff is post-route
  turn-log lines + a post-route P(OFF) reflecting the now-observed surveyor
  turn-around, off-route still not flagged). Verified: Test-clean's forward leg
  fires all 3 checkpoints and its +192° end turn-around now flips the latch
  post-completion — confirming the flip is reached even on a fully-completing
  forward leg (what the crisp-pivot couldn't show). `npm test` parity green;
  the parity fixture is unaffected (`make-parity-fixture.js` has its own loop
  that already delivers all turns). **The remaining gap is purely the Live
  `LivePositioningController.completeRoute()` teardown** (`:508`) — the Swift
  controller still tears down at completion; the parallel return-watch change
  there is offline-untestable and deferred to a device session.

## 14. The decision metric is harsher than the position metric: return TRIGGERS are 4/7 within ±5 m (2026-06-20)

§13's headline (return P50 3.26 m) measures *position*. The commercial gate
(STATUS L104 / SYNTHESIS) is **≥90 % checkpoint triggers within ±5 m** — a
*decision* metric. Measured the return-leg trigger accuracy directly: drive the
shipped `replay()`, and for each checkpoint fire the §4-A "returning past X"
policy (`P(s ≤ decisionBin) > τ` twice consecutively while `returning`,
pOff < 0.5), then compare where the user TRULY was (ARKit) at the fire instant.

**Result on the crisp-pivot round-trip: only 4/7 within ±5 m** — fails the gate.

| Checkpoint (return order) | true cross-back | est fire | trigger err |
|---|---|---|---|
| Arcade/ATH | t+48.5 | t+50.8 | 2.38 m ✅ |
| Ops table | t+55.1 | t+57.6 | 2.84 m ✅ |
| Kitchen | t+62.1 | t+72.6 | **9.78 m** ❌ |
| Finance | t+70.2 | t+85.9 | **16.20 m** ❌ |
| Diwal | t+77.5 | t+85.9 | **9.45 m** ❌ |
| Paundha | t+83.5 | t+85.9 | 2.70 m ✅ |
| Sleeping bench | t+89.9 | t+91.4 | 1.79 m ✅ |

**The 4 passing checkpoints are the ones at/near corners** (recapture re-pins the
belief there, error ~2 m). **The 3 failing ones are mid-route, around weak
segment 5** (Kitchen→Ops, r 0.34) — and they fail *together*: during the
weak-segment OFF blackout (t+76–84, pOff→1.0, §13) the mid-route checkpoints
cannot fire (pOff > 0.5 gate), then the −71° corner recapture jumps the belief
PAST several decision bins at once → **a batch of late fires** (Finance + Diwal +
Paundha all declared at t+85.9, long after the user physically crossed them).
Kitchen fails by a different mechanism — 10 s of pre-blackout drift delays its
`P(s ≤ X)` crossing.

**So the position number flattered the result.** The recapture sawtooth keeps P50
low because it nails the corners, but the *between-corner* return positions — which
is where the mid-route checkpoints live — drift then black-out then batch-recover.
For a guided tour whose checkpoints sit between corners (rooms along a corridor,
exactly LIS), the return leg is **NOT trigger-ready** despite a 3 m P50.

**Root cause, chased to the bottom — it is a STRIDE-CALIBRATION mismatch on the
open segment, NOT an emission/OFF problem.** Two experiments, both run through the
shipped `replay()`:

1. **Dead-reckoning OFF re-entry (TRIED, reverted).** Made the OFF re-entry center
   coast −stride/step through the blackout (the OFF analog of the §10 −stride
   `predictStep`), gated to `returning` so it is forward-inert (forward matrix
   byte-identical, confirmed). It *did* fix the symptom it targeted — the belief
   no longer teleports to bin ~1581 during the blackout, it coasts 992→865 — but
   **return triggers stayed 4/7 and P50/P75 were byte-identical.** Reverted (no
   gate movement; the teleport it removed was already masked by the OFF flag).
   Why it failed: the belief enters the blackout *already ~8 m behind*, and it
   coasts at the same (wrong) stride, so it never catches up.

2. **Where the ~8 m pre-blackout lag comes from (the real cause).** On seg5 the
   belief advances ~30 % too slowly *before* the blackout (pOff still ~0). Measured
   stride on seg5: profile `binsPerStep` = **11.7**, but the live walk strides
   **20.7 bins/step forward and 17.5 backward** (ratio 1.5–1.8×). The surveyor
   took ~20 short steps over seg5 where the walker takes ~12 — seg5 is "a long open
   stretch" and the survey pace there is anomalous (every other segment:
   binsPerStep 14–30, matching its live stride). So the ±stride model
   *structurally* undershoots seg5 for any normal walker. Forward survives because
   the strong bracketing segments (seg4/seg6) re-localize before its checkpoints
   fire; the return leg's mid-segment checkpoints (Diwal, Finance) are crossed
   during the uncorrected undershoot, before the next corner recapture.

3. **Naive stride fix makes it WORSE (TRIED).** Bumping seg5 `binsPerStep`
   11.7→18.5 (to match the live stride) drops return triggers to 3/7 and raises
   P50 3.26→5.71. Reason: `binsPerStep` is not just the PDR stride — it is also the
   **differenced-emission lag** (`lag = round(binsPerStep)`, `grid-filter.js:294`)
   and the kernel width, all fitted together. Changing it desyncs the emission on
   seg5. So the PDR stride and the emission lag are **coupled**, and correcting the
   stride alone breaks the match.

**Updated verdict:** to-and-fro return tracking is *position-good* (~3 m P50) but
*trigger-marginal* (4/7 within ±5 m, below the ≥90 % gate) on LIS, whose seg5 is a
weak (r 0.34) AND survey-stride-anomalous open stretch with checkpoints sitting
between corners. Two blockers remain, in order:
- **(1) Live lifecycle teardown** (§13) — fix specified, offline-validated,
  device-deploy deferred. This is the clean, ready blocker.
- **(2) seg5 stride/emission coupling** — the harder one. NOT fixable by the OFF
  re-entry or a naive `binsPerStep` bump (both tried). Proper fixes are Phase-4 /
  data: (a) decouple the PDR stride (prediction) from the emission lag (matching)
  and re-fit — architectural; (b) adaptive per-step stride from live cadence
  (RoNIN-class); or (c) re-survey seg5 at a consistent walking stride so the
  profile stride matches reality — a survey-process fix, cheapest to try.

**The single most useful next datum is a STRONG-ROUTE round-trip** (Plumeria Test
~12 m or L478 43 m — both track sub-meter forward with consistent strides). It
would settle whether to-and-fro triggering is fundamentally fine and only needs the
§13 lifecycle change (likely — corner recaptures + good emission, no anomalous
segment), or whether the mid-segment trigger problem generalizes beyond LIS's seg5.
On the available LIS data the two are confounded.
