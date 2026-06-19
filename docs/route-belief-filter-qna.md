# Predict / Observe in the Route Belief Filter

In this codebase, **predict / observe** is the core Bayes-filter loop in:

`survey-recorder/SurveyRecorder/RouteBeliefFilter.swift`

Think of it as:

> **Predict:** “Given the user moved, where could they be now?”
> **Observe:** “Given the sensor readings, which of those guesses look plausible?”

## 1. State: what the filter tracks

The app does **not** track one location. It tracks probabilities across route bins:

```swift
belief[bin] = probability user is at this route position
pOff = probability user is off the surveyed route
```

The route profile is built by concatenating all segment fingerprints into one long 1D route axis.

So if a route has:

```text
Start → Room exit → Hall → Bedroom
```

the filter stores probability over all positions along that route.

### Why probabilities?

The logic is to keep **many possible positions alive at the same time** instead of committing too early. Indoor signals are ambiguous: two hallway spots can look magnetically similar, and PDR step length is never exact. A probability distribution lets the filter keep both possibilities until stronger evidence separates them.

On every update:

1. **Predict** shifts probability based on motion.
2. **Observe** multiplies each bin by how well the sensors match that bin.
3. **Normalize** rescales everything so the probabilities sum to 1:

```text
sum(belief) + pOff = 1
```

So if magnetic or turn evidence matches bin 120 well, `belief[120]` rises. If the live evidence does not match the surveyed route, `pOff` rises.

## 2. Predict step

When a walking step is detected:

```swift
filter.predictStep()
```

### Why call `predictStep()` here?

This is called because a detected step is the filter's **motion update**.

Without `predictStep()`, the filter would keep probability stuck near the previous route bins and would keep comparing new sensor readings against the old position. The step says: “the user probably moved forward about one stride, but we are not sure exactly how far.”

So the order matters:

1. A step is detected.
2. `predictStep()` moves the route-position probabilities forward.
3. It spreads them because the exact stride length is uncertain.
4. Magnetic and turn observations then correct or reject those predicted positions.

So `predictStep()` moves probability forward by about one stride before magnetic evidence corrects it.

Example:

```text
Before step:
bin 100: 60%
bin 105: 20%
OFF: 5%

After predict:
bin 115-ish: most mass
nearby bins: some mass
OFF: slightly more mass
```

It does not move everything to exactly one bin because step length is uncertain. So it spreads belief using a Gaussian-like kernel.

Important details:

- Uses each segment’s `binsPerStep`.
- Adds step noise: `stepNoiseFrac = 0.35`.
- Allows some uncertainty/backtracking via kernel spread.
- Leaks a little probability into `OFF` each step.
- Route start/end are barriers, so belief cannot walk outside the route.

So predict is mostly PDR / dead reckoning.

## 3. Observe magnetic evidence

After prediction, the app asks:

```swift
filter.observe(windowForSegment: ...)
```

This checks whether the recent magnetic readings match each possible route position.

Current matcher uses **first differences**, not raw absolute values:

```text
live change over one stride
vs
profile change over one stride
```

Example:

```text
Live magnetic pattern:
42.1 → 43.4 → 41.9 µT

Profile near bin 120:
42.0 → 43.2 → 42.1 µT
good match

Profile near bin 600:
39.0 → 39.1 → 39.0 µT
bad match
```

Good matching bins get their probability boosted. Bad matching bins get reduced.

The `OFF` state also has a likelihood. If the magnetic window matches nowhere on the route, `pOff` grows.

### Magnetic match strength

Magnetic matching does **not** have one fixed boost ratio. It is data-dependent.

For each candidate bin, `observe(...)` computes a Gaussian log-likelihood from the difference between:

```text
live magnetic first-difference
profile magnetic first-difference at this bin
```

Then the bin is multiplied by that likelihood and everything is normalized.

Current constants:

- `diffSigmaUT`: usually profile-calibrated; fallback is `2.42 µT`.
- `obsIndependenceBins = 8`.
- `offLogLikPerPoint`: usually profile-calibrated; fallback is `-4.99`.

Rule of thumb with the fallback constants:

- A candidate whose residual is about **1 sigma better** than another gets roughly `exp(0.5 × 8) ≈ 55×` more magnetic likelihood.
- A candidate whose residual is about **2 sigma better** gets roughly `exp(2 × 8) ≈ 8.9M×` more likelihood.

So magnetic evidence can be much stronger than a turn observation when the magnetic pattern is distinctive. In flat or ambiguous magnetic areas, it may be weak or skipped.

## 4. Observe turn events

Turns are also observations:

```swift
filter.observeTurn(deltaDeg: turn.deltaDeg)
```

If the user makes a turn that exists in the route profile near where the posterior already thinks they are, the filter boosts that area.

If the user makes a big unmatched U-turn, it pushes probability into `OFF`.

This helps detect pacing/backtracking.

### When turn detection is used

Turn detection is used in two places:

1. **Offline profile building:** `analysis/build-profile.js` calls `analysis/turn-events.js` on survey passes. Repeatable turns become profile `turns[]` landmarks such as `{ bin, deltaDeg, sigmaBins }`.
2. **Live hand-carry positioning:** `LivePositioningController` computes gravity-axis yaw from every `CMDeviceMotion` sample. When `LiveTurnDetector` closes a turn region, the app calls `filter.observeTurn(deltaDeg:)`.

It is **not** the main tracker. It is a sparse landmark/correction signal layered on top of step prediction and magnetic observation.

Current limitation: live turn evidence is only used when `livePose == .hand`. It is disabled for pocket mode because leg swing distorted turn magnitudes and caused harmful false `OFF` injections in replays.

### Current turn match numbers

Turn observations have more fixed-looking multipliers than magnetic observations.

A live turn counts as a route-turn match only if:

- it has the same left/right sign as a stored profile turn
- its angle is within `55°` of that profile turn
- at least `10%` of current on-route probability is already near that turn bin

If it matches, each route bin gets this multiplier:

```text
turnLikelihood = 0.05 + exp(-0.5 × d²)
```

where:

```text
d = distance from this bin to the matched turn bin, measured in turn sigma units
```

So approximately:

- at the turn center: `0.05 + 1.0 = 1.05×`
- far from the turn: `0.05×`
- center vs far-away route bins: `1.05 / 0.05 ≈ 21×`
- `OFF` state multiplier on matched turns: `0.3×`
- turn-center vs `OFF`: `1.05 / 0.3 ≈ 3.5×`

If the turn does **not** match and is a large turn (`>= 100°`), the filter moves `50%` of on-route probability into `OFF` and starts `8` reversal-suppression steps where checkpoints cannot fire.

So: a matched turn is a strong landmark, but usually less numerically explosive than a very distinctive magnetic match.

## 5. If no useful observation

Sometimes magnetic evidence is skipped:

- magnetometer uncalibrated
- magnetic window too flat
- not enough steps yet
- terminal route region

Then the app calls:

```swift
filter.applyUnobservedLeak()
```

Meaning:

> “The user moved, but the route was not magnetically corroborated, so become less confident.”

This increases `pOff`.

## 6. Decision layer

After predict/observe, the app computes outputs:

```swift
filter.probBeyond(bin: checkpointDecisionBin)
filter.pOff
filter.meanBin
filter.beliefStdDev
```

### `filter.probBeyond(bin: checkpointDecisionBin)`

This adds up the probability mass at or beyond the next checkpoint decision bin.

It asks:

> “How much of the current route belief says the user has reached or passed this checkpoint?”

In the live code it is not a boolean by itself. The decision is roughly:

```swift
let onRoute = max(1 - pOff, 1e-9)
let enoughPastCheckpoint = filter.probBeyond(bin: cp.decisionBin) / onRoute > 0.8
```

So the current threshold is **80% of on-route probability**, not 50%.

The app also requires:

- `stepsSinceObservation <= 2`
- `pOff < 0.5`
- no reversal is active
- the condition holds for two consecutive updates

### `filter.pOff`

This is the probability that the user is not currently explained by the surveyed route.

Important threshold:

```swift
pOff < 0.5
```

is required for checkpoint firing. If `pOff` rises above `0.5`, the UI can show `Off route?`.

### `filter.meanBin`

This is the probability-weighted average route bin:

```text
meanBin = Σ(binIndex × belief[binIndex]) / Σ(belief[binIndex])
```

It is the single-number “best estimate” of route progress, conditional on being on the route. It should be read together with `pOff` and `beliefStdDev`.

### `filter.beliefStdDev`

This is the spread of the route-position belief in bins.

- Low `beliefStdDev`: probability is concentrated near one place.
- High `beliefStdDev`: probability is spread out; location is ambiguous.

It does not include `pOff`, so a low `beliefStdDev` is not enough by itself. If `pOff` is high, the route estimate may be confidently wrong or stale.

### Why two consecutive updates?

The checkpoint condition must be true for **2 consecutive filter updates** before firing.

That `2` is currently fixed in the live controller as a small debounce:

- 1 good update: wait
- 2 good updates in a row: fire checkpoint
- any failed update: reset the counter

This prevents one noisy magnetic match from advancing the route.

## Short version

```text
Predict:
  motion says where the user could have moved

Observe:
  magnetic + turn evidence says which guesses are believable

Normalize:
  convert scores back into probabilities

Decide:
  checkpoint / off-route / low confidence
```

The current implementation is a **grid Bayes filter / HMM**, not a particle filter. It is like tracking thousands of tiny possible route positions at once, but deterministically in an array instead of as random particles.

## Particle filter vs this grid filter

A **particle filter** represents belief using many random samples instead of a full probability array.

Example particle:

```text
{ positionBin: 120, heading: forward, weight: 0.04 }
```

Prediction moves particles. Observation reweights them. Bad particles disappear during resampling.

For the current route-constrained problem, the grid filter is usually better because:

- the state is only 1D route position
- the app can afford to store every route bin exactly
- there is no sampling noise
- checkpoint decisions can sum exact probability mass with `probBeyond(...)`

A particle filter becomes more attractive when the state becomes large or continuous, especially 2D.

## Is 2D possible?

Yes, but it is a bigger product and data-model change.

Current system:

```text
state = route bin along a known path
```

A 2D system would need something like:

```text
state = x, y, heading, maybe stride length, maybe floor
```

That means adding:

- a floor-plan coordinate system
- walkable / non-walkable geometry
- dense magnetic fingerprints tied to `(x, y)`, not just route bins
- heading tracking and heading uncertainty
- a 2D prediction model
- a 2D observation model
- more survey coverage and validation

Based on the current codebase state, 2D is **moderate-to-hard**.

It would likely be worse at first because the current data is optimized for a 1D surveyed route. In 1D, step error only moves belief forward/back along the path. In 2D, small heading errors also create sideways drift, and that drift grows every step.

Also, the current magnetic profile only knows magnetic patterns along surveyed route bins. It is not a dense 2D magnetic map. Without denser survey data or stronger anchors, a 2D filter has more possible states but weaker observations per state.

Practical expectation:

- current 1D route filter: best for known route/checkpoint triggering
- 2D particle filter with current data only: likely noisier and less reliable
- 2D with dense surveys + map constraints + optional anchors: possible, but larger scope

So 2D is possible, but it is not automatically a better next step unless the product needs free movement, branching paths, nearest-exhibit detection, or true map-level localization.
