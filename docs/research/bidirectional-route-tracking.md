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
easier problem than the documented free-roam NO-GO, and the central hypothesis is
**supported by the literature and by this codebase's own measured properties**:

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
   continuous-gait-heading signal that was a NO-GO at this effort level.
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

**Boundary (explicit):** this is NARROWER than free-roam (arbitrary rooms, any
order, shortcuts), which is a documented NO-GO on the `free-roam` branch (37%
held-out without anchors). To-and-fro fixes the **return leg and repeated
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
- Arbitrary room order / shortcuts — free-roam NO-GO (`free-roam` branch, 37%).

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
that was the documented NO-GO. The literature supports the *ingredients* (gyro U-turn
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

NO-GO conditions that would downgrade it: reverse emission does NOT ridge (would mean the
differenced reverse-read doesn't actually discriminate on real data — refutes §2);
end U-turn reliably missed even in hand; or the latch regresses forward walks the way
the rejected backward-prediction did (STATUS L92).

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

**Out of scope (unchanged):** free-roam / any-order / shortcuts (free-roam NO-GO);
backward-from-far-end cold start (needs entrance anchoring, STATUS L96–L100);
pocket-carry latch (turn evidence disabled in pocket — §3.1).
