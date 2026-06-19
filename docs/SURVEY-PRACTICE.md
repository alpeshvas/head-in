# Survey Practice — how to record routes that actually track

Practical, field-learned guidance for surveying a venue so the live filter
tracks reliably. Grounded in the validated runs; each rule cites the evidence.

## The rules

### 1. Space checkpoints evenly; never let one leg cross open space unbroken
**This is the single most important rule.** A checkpoint fires on accumulated
step-progress + magnetic corroboration near the anchor — it does **not** need a
good fingerprint, just a re-anchor opportunity. Long legs through open,
non-repeatable space are where tracking dies.

- **Evidence:** Office-Near "LIS" first survey had one long open-office leg
  (Paundha→Finance) with magnetic repeatability **r=0.36**. Live, the filter
  flailed for **106 s** and stalled at 6/7. Re-surveyed with **evenly-spaced
  checkpoints** (~6–10 s of walking each), every middle segment jumped to
  **r≥0.95** and the live walk completed **7/7** — even recovering from a
  transient P(OFF)=1.0 because a checkpoint was close enough to re-anchor.
- **Rule of thumb:** drop a checkpoint roughly every 5–15 steps / at every
  doorway, corner, or recognizable landmark. When in doubt, more checkpoints.
  Open rooms need *more* checkpoints than corridors, not fewer.

### 2. Aim for r ≥ 0.85 per segment; treat weak segments as a survey problem, not a code problem
Check the `build-profile` segment table after surveying. `r` is pass-to-pass
magnetic repeatability (see [route-belief-filter-qna](route-belief-filter-qna.md)).
Weak segments (r < ~0.5) mean the field there doesn't reproduce between walks.

- No filter trick recovers a signal that isn't in the field. Emission
  down-weighting was **built, measured, and rejected** — it made the weak-leg
  case *worse* (2/7 vs 6/7), because there was genuinely nothing to lean on.
- The fix for a weak segment is always physical: **split it with a checkpoint**,
  or **route through more distinctive space** (hug walls/corridors rather than
  crossing an open floor).

### 3. Walk every pass the same way, at a steady pace
Open-space segments only repeat if you trace roughly the same line. Pace
matters too: the LIS failure walk took 106 s through a leg the good walk did in
38 s — wandering/pausing through a weak zone is what breaks it. Steady, repeat
the same path, don't backtrack.

### 4. Record ≥3 clean passes for a shippable profile (2 is the minimum)
- `build-profile` needs ≥2 passes for stddev and majority turn-voting.
- **But 2 passes cannot be validated:** leave-one-out then uses a 1-pass profile,
  which is degenerate (no real stddev, in-sample calibration) and fails
  spuriously. With 3 passes, LOO holds one out against a real 2-pass profile —
  the honest offline metric.
- Avoid mixing a slow exploratory pass with fast clean ones — the outlier drags
  down repeatability (the original 3-pass LIS included a 114 s ad-hoc pass and
  scored worse than the later 2 consistent passes).
- **The ad-hoc bootstrap pass (pass 1) is NOT a survey pass — exclude it from the
  build.** Dropping-and-naming checkpoints makes pass 1 slow and uneven (pauses
  while typing), so its magnetic trace doesn't match the natural-pace reuse
  passes. Treat pass 1 purely as the checkpoint-naming step; build the
  fingerprint from the faster predefined-reuse passes (2+). Evidence: Ravi-place
  pass 1 (82 s, ad-hoc) made the back half weak (r 0.22 / −0.02); rebuilding from
  the two reuse passes (51 s, 43 s) made the same segments strong (r 0.88 / 0.85).

### 5. Turn on ARKit ground truth; hold the phone so the camera sees the space
GT enables true-meter scoring and per-venue calibration fitting from arc length.
Point at textured surfaces, not blank walls. Tracking ~95%+ is healthy. (Pocket
surveys can't track — see rule 7.)

### 6. Use ad-hoc mode for a new venue; reuse the list for later passes
- Pass 1: leave the Setup checkpoint field **empty** → drop-and-name as you walk
  (type the name while approaching, tap **at** the spot so the timestamp is
  exact). Auto-named "Checkpoint N" is fine; rename offline.
- After pass 1 the names auto-populate Setup, so **passes 2+ are the fast
  predefined tap-through** with matching names (build-profile merges segments by
  name — they must match across passes).

### 7. Pocket surveys: pause ≥3 s at each checkpoint (can't tap pocketed)
If surveying with the phone pocketed, you can't tap anchors. Stand still ~3 s at
each checkpoint; `analysis/splice-pauses.js` recovers anchor times from the
standing signature and removes the pauses (pause bins become flat-field
attractors under the differenced emission otherwise). Build with
`--splice-pauses`. Turn evidence is auto-disabled for pocket pose (leg-swing
distorts gyro turns).

## Quick checklist
- [ ] Checkpoints every ~5–15 steps, at doorways/corners; extra in open rooms
- [ ] ARKit GT on, phone held with camera on textured surfaces
- [ ] Pass 1 ad-hoc (drop + name); passes 2–3 tap-through the reused list
- [ ] ≥3 clean passes, same path, steady pace, no outlier
- [ ] After building: every segment r ≥ ~0.85? If not, add checkpoints / reroute, re-survey
- [ ] Validate: 3-pass leave-one-out replay fires all checkpoints before trusting live
