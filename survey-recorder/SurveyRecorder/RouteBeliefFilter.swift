import Foundation

/// Discrete-grid Bayes filter over global route position with an explicit OFF-route
/// state. Direct Swift port of analysis/grid-filter.js (the Phase 2 estimator from
/// docs/research/SYNTHESIS.md), validated offline against recorded passes before
/// being wired into the Live tab. Keep the two implementations in sync.
///
/// Parameters marked "fitted" come from `node analysis/grid-filter.js --calibrate`
/// against the held-out Plumeria clean pass. Re-fit per venue/pose as data grows;
/// offLogLikPerPoint is only valid for the sensorSigmaUT it was fitted under.
enum FilterParams {
    static let diffSigmaUT = 2.42           // fitted: single homoscedastic first-difference noise (µT)
    static let offLogLikPerPoint = -4.99    // fitted (valid for diffSigmaUT 2.42, windowSteps 6)
    static let minWindowRangeUT = 3.0
    static let windowSteps = 6
    static let stepNoiseFrac = 0.35
    static let kernelFloor = 1e-4
    static let obsIndependenceBins = 8.0
    static let offLeakPerStep = 0.02
    static let unobservedOffLeak = 0.04    // extra leak when a step had no magnetic corroboration
    static let observationRecencySteps = 2 // checkpoint decisions need an observation this recent
    static let offStay = 0.95
    static let reentrySigmaStrides = 2.0   // OFF re-entry kernel width around last confident mode
    static let confidentPOff = 0.3         // posterior counts as confidently on-route below this
    static let idleDiffusionSigma = 0.6
    static let checkpointTau = 0.8
    static let offRouteTau = 0.5
    // Turn-anchor observation (Phase 3) — see analysis/grid-filter.js for the
    // validated reference values.
    static let turnMatchToleranceDeg = 55.0
    static let turnLikFloor = 0.05
    static let turnOffLik = 0.3
    static let turnNegativeMinDeg = 100.0
    static let turnUTurnOffLeak = 0.5
    static let turnReversalLeakPerStep = 0.12
    static let turnReversalSteps = 8
    static let turnMatchMinSupport = 0.1
}

/// All profile segments concatenated onto one global bin axis.
struct GlobalRouteProfile {
    struct Segment {
        let index: Int
        let from: String
        let to: String
        let isTransition: Bool
        let startBin: Int
        let count: Int
        let binsPerStep: Double
    }

    let mean: [Double]
    let std: [Double]
    let segments: [Segment]
    /// Ordered checkpoint decisions: every anchor after the start, with the bin it
    /// sits at and the decision bin (half a stride early, so end-of-route anchors
    /// are not a single unreachable boundary bin).
    let checkpoints: [(name: String, bin: Int, decisionBin: Int)]
    let turns: [RouteTurn]
    /// Per-venue emission calibration (profile-carried; FilterParams fallback).
    let diffSigmaUT: Double
    let offLogLikPerPoint: Double
    let bins: Int

    init(profile: RouteProfile) throws {
        var mean: [Double] = []
        var std: [Double] = []
        var segments: [Segment] = []

        for seg in profile.segments {
            guard let m = seg.magneticMagnitude?.mean, m.count >= 2 else {
                throw RouteProfileError.noMatchingSegments
            }
            let s = seg.magneticMagnitude?.stddev ?? []
            let startBin = mean.count
            for i in 0..<m.count {
                mean.append(m[i])
                std.append(i < s.count && s[i].isFinite ? max(s[i], 0.2) : 1.0)
            }
            segments.append(Segment(
                index: seg.index,
                from: seg.from,
                to: seg.to,
                isTransition: seg.isTransition,
                startBin: startBin,
                count: m.count,
                binsPerStep: Double(m.count) / max(seg.medianSteps, 1)
            ))
        }

        self.mean = mean
        self.std = std
        self.segments = segments
        self.bins = mean.count

        var checkpoints: [(String, Int, Int)] = []
        for seg in segments {
            let bin = seg.startBin + seg.count - 1
            let decision = max(0, Int((Double(bin) - 0.5 * seg.binsPerStep).rounded()))
            checkpoints.append((seg.to, bin, decision))
        }
        self.checkpoints = checkpoints
        self.turns = profile.turns ?? []
        self.diffSigmaUT = profile.calibration?.diffSigmaUT ?? FilterParams.diffSigmaUT
        self.offLogLikPerPoint = profile.calibration?.offLogLikPerPoint ?? FilterParams.offLogLikPerPoint
    }

    func segment(ofBin bin: Int) -> Segment {
        for seg in segments where bin < seg.startBin + seg.count {
            return seg
        }
        return segments[segments.count - 1]
    }
}

final class RouteBeliefFilter {
    let profile: GlobalRouteProfile
    private(set) var belief: [Double]
    private(set) var pOff: Double = 0
    private var reversalStepsLeft = 0
    /// Last mode while confidently on-route — OFF re-entry anchors here
    /// (route-constrained-fusion.md: "re-entry kernel centered on last
    /// on-route mode").
    private var lastConfidentMode = 0

    init(profile: GlobalRouteProfile) {
        self.profile = profile
        belief = [Double](repeating: 0, count: profile.bins)
        for i in 0..<min(8, profile.bins) {
            belief[i] = exp(-Double(i) / 3)
        }
        normalize()
    }

    private func normalize() {
        var sum = pOff
        for v in belief { sum += v }
        guard sum > 0 else {
            let u = 1.0 / Double(belief.count)
            for i in belief.indices { belief[i] = u }
            pOff = 0
            return
        }
        for i in belief.indices { belief[i] /= sum }
        pOff /= sum
        if pOff < FilterParams.confidentPOff { lastConfidentMode = modeBin() }
    }

    private func modeBin() -> Int {
        var best = 0
        for i in 1..<belief.count where belief[i] > belief[best] { best = i }
        return best
    }

    /// One detected step: advance by the per-segment stride with noise, a small
    /// backward/stay tail, and a leak into OFF.
    func predictStep() {
        let gp = profile
        var next = [Double](repeating: 0, count: gp.bins)
        var leaked = 0.0

        for i in 0..<gp.bins {
            let p = belief[i]
            if p <= 0 { continue }
            let m = gp.segment(ofBin: i).binsPerStep
            let sigma = max(0.8, FilterParams.stepNoiseFrac * m)
            let lo = Int((Double(i) - m).rounded(.down))
            let hi = Int((Double(i) + 3 * m).rounded(.up))
            var kernelSum = 0.0
            for j in lo...hi {
                let d = (Double(j - i) - m) / sigma
                kernelSum += exp(-0.5 * d * d) + FilterParams.kernelFloor
            }
            let stay = p * (1 - FilterParams.offLeakPerStep)
            for j in lo...hi {
                let d = (Double(j - i) - m) / sigma
                let k = exp(-0.5 * d * d) + FilterParams.kernelFloor
                let share = stay * (k / kernelSum)
                if j < 0 {
                    next[0] += share          // route start is a barrier
                } else if j >= gp.bins {
                    // Route end is a barrier too: a sharp posterior walking the
                    // last meters naturally overflows half a kernel; leaking it
                    // to OFF blocked the final checkpoint once the differenced
                    // emission tightened tracking. Pacing-past-the-end is
                    // covered by turn anchors + reversal suppression.
                    next[gp.bins - 1] += share
                } else {
                    next[j] += share
                }
            }
            leaked += p * FilterParams.offLeakPerStep
        }

        // OFF re-entry kernel centered on the LAST CONFIDENT on-route mode —
        // not proportional to the current shape, which after an emission
        // crushes the true mode is whatever impostor bins were least bad
        // (a mirrored corridor 1100 bins away captured re-entry live).
        let reenter = pOff * (1 - FilterParams.offStay)
        if reenter > 0 {
            let center = lastConfidentMode
            let sigma = FilterParams.reentrySigmaStrides * gp.segment(ofBin: center).binsPerStep
            let lo = max(0, Int((Double(center) - 3 * sigma).rounded(.down)))
            let hi = min(gp.bins - 1, Int((Double(center) + 3 * sigma).rounded(.up)))
            var kernelSum = 0.0
            for i in lo...hi {
                let d = (Double(i) - Double(center)) / sigma
                kernelSum += (next[i] + 1e-12) * exp(-0.5 * d * d)
            }
            if kernelSum > 0 {
                for i in lo...hi {
                    let d = (Double(i) - Double(center)) / sigma
                    next[i] += reenter * ((next[i] + 1e-12) * exp(-0.5 * d * d)) / kernelSum
                }
            }
        }
        belief = next
        pOff = pOff * FilterParams.offStay + leaked
        // Steps taken while the heading is unexplained (after an unmatched
        // U-turn) are not credible route progress.
        if reversalStepsLeft > 0 {
            reversalStepsLeft -= 1
            var mass = 0.0
            for i in belief.indices {
                let leak = belief[i] * FilterParams.turnReversalLeakPerStep
                belief[i] -= leak
                mass += leak
            }
            pOff += mass
        }
        normalize()
    }

    /// Turn-anchor observation (Phase 3, UnLoc-style landmark reset), ported
    /// from analysis/grid-filter.js observeTurn. A matched turn re-concentrates
    /// belief that already has support near the signature bin; an unmatched
    /// U-turn-scale rotation is a transition into OFF plus a sustained leak
    /// while the heading stays unexplained. Returns true on a signature match.
    /// True while recent motion is unexplained (after an unmatched U-turn):
    /// checkpoint decisions must not fire on progress made in this state.
    var reversalActive: Bool { reversalStepsLeft > 0 }

    @discardableResult
    func observeTurn(deltaDeg: Double) -> Bool {
        var matches = profile.turns.filter {
            ($0.deltaDeg < 0) == (deltaDeg < 0) &&
                abs(deltaDeg - $0.deltaDeg) <= FilterParams.turnMatchToleranceDeg
        }
        if !matches.isEmpty {
            // Posterior-support gate: a match from across the route is no match.
            var support = 0.0
            var onRoute = 0.0
            for i in belief.indices {
                onRoute += belief[i]
                if matches.contains(where: { abs(Double(i) - Double($0.bin)) <= 3 * $0.sigmaBins }) {
                    support += belief[i]
                }
            }
            if onRoute > 0 && support / onRoute < FilterParams.turnMatchMinSupport { matches = [] }
        }
        if matches.isEmpty {
            guard abs(deltaDeg) >= FilterParams.turnNegativeMinDeg else { return false }
            var moved = 0.0
            for i in belief.indices {
                let leak = belief[i] * FilterParams.turnUTurnOffLeak
                belief[i] -= leak
                moved += leak
            }
            pOff += moved
            reversalStepsLeft = FilterParams.turnReversalSteps
            normalize()
            return false
        }
        for i in belief.indices {
            var lik = FilterParams.turnLikFloor
            for turn in matches {
                let d = (Double(i) - Double(turn.bin)) / turn.sigmaBins
                lik += exp(-0.5 * d * d)
            }
            belief[i] *= lik
        }
        pOff *= FilterParams.turnOffLik
        reversalStepsLeft = 0
        normalize()
        return true
    }

    /// A step happened but magnetic evidence could not corroborate it (flat window,
    /// uncalibrated sensor): motion without verification raises route uncertainty.
    func applyUnobservedLeak() {
        var mass = 0.0
        for i in belief.indices {
            let leak = belief[i] * FilterParams.unobservedOffLeak
            belief[i] -= leak
            mass += leak
        }
        pOff += mass
        normalize()
    }

    /// Standing/idle: tiny diffusion only.
    func predictIdle(dt: Double) {
        let sigma = FilterParams.idleDiffusionSigma * max(dt, 0)
        guard sigma >= 0.05 else { return }
        let radius = Int((3 * sigma).rounded(.up))
        var kernel: [Double] = []
        var ks = 0.0
        for d in -radius...radius {
            let k = exp(-0.5 * pow(Double(d) / sigma, 2))
            kernel.append(k)
            ks += k
        }
        var next = [Double](repeating: 0, count: profile.bins)
        for i in 0..<profile.bins {
            let p = belief[i]
            if p <= 0 { continue }
            for d in -radius...radius {
                let j = min(profile.bins - 1, max(0, i + d))
                next[j] += p * (kernel[d + radius] / ks)
            }
        }
        belief = next
        normalize()
    }

    /// Emission update. `windowForSegment` returns the live magnitude window
    /// resampled to that segment's bin rate (per detected step), or nil when
    /// unavailable/flat. Returns false when no window was usable.
    func observe(windowForSegment: (GlobalRouteProfile.Segment) -> [Double]?) -> Bool {
        let gp = profile
        var logLik = [Double](repeating: .nan, count: gp.bins)
        var windowCache: [Int: [Double]?] = [:]
        var anyWindow = false

        // First-difference emission at ONE STRIDE of lag (SYNTHESIS convergence
        // pt. 1, FollowMe/MaLoc): direction-sensitive, device-invariant, immune
        // to mid-walk iOS recalibration, subsumes mean removal. Adjacent-bin
        // deltas are noise-dominated; stride-scale deltas carry the structure.
        // Single fitted homoscedastic difference noise (Magicol: one sigma per
        // building) — the per-bin survey std is NOT used: adjacent-bin map
        // errors are common-mode and cancel in differences.
        let v = gp.diffSigmaUT * gp.diffSigmaUT
        for s in 0..<gp.bins {
            let seg = gp.segment(ofBin: s)
            if windowCache[seg.index] == nil { windowCache[seg.index] = windowForSegment(seg) }
            guard let live = windowCache[seg.index] ?? nil else { continue }
            let L = live.count
            guard s - L + 1 >= 0 else { continue }
            let lag = max(2, Int(seg.binsPerStep.rounded()))
            guard L > lag else { continue }

            var ll = 0.0
            var k = 0
            while k + lag < L {
                let idx = s - L + 1 + k
                let resid = (live[k + lag] - live[k]) - (gp.mean[idx + lag] - gp.mean[idx])
                ll += -0.5 * (resid * resid / v + log(2 * Double.pi * v))
                k += 1
            }
            logLik[s] = (ll / Double(L - lag)) * FilterParams.obsIndependenceBins
            anyWindow = true
        }
        guard anyWindow else { return false }

        let offLL = gp.offLogLikPerPoint * FilterParams.obsIndependenceBins
        var maxLL = offLL
        for ll in logLik where ll.isFinite && ll > maxLL { maxLL = ll }
        for s in 0..<gp.bins where logLik[s].isFinite {
            belief[s] *= exp(logLik[s] - maxLL)
        }
        pOff *= exp(offLL - maxLL)
        normalize()
        return true
    }

    var meanBin: Double {
        var m = 0.0
        var w = 0.0
        for i in belief.indices {
            m += Double(i) * belief[i]
            w += belief[i]
        }
        return w > 0 ? m / w : 0
    }

    /// On-route probability mass at or beyond `bin` (OFF mass excluded).
    func probBeyond(bin: Int) -> Double {
        guard bin < belief.count else { return 0 }
        var p = 0.0
        for i in bin..<belief.count { p += belief[i] }
        return p
    }

    /// Posterior standard deviation in bins — a concentration/confidence signal.
    var beliefStdDev: Double {
        let m = meanBin
        var v = 0.0
        var w = 0.0
        for i in belief.indices {
            v += belief[i] * pow(Double(i) - m, 2)
            w += belief[i]
        }
        return w > 0 ? (v / w).squareRoot() : 0
    }
}
