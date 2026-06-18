import CoreMotion
import Foundation
import Observation
import UIKit

/// Live route positioning driven by RouteBeliefFilter (grid Bayes filter + OFF state),
/// the estimator validated offline by analysis/grid-filter.js. Steps drive prediction,
/// per-step magnetic windows drive observation, and all UI state derives from the
/// posterior — no ratchets, no threshold gates.
@MainActor
@Observable
final class LivePositioningController {
    let profile: RouteProfile

    let deviceMotionAvailable: Bool

    private(set) var isRunning = false
    private(set) var isComplete = false
    private(set) var statusText = "Ready"
    private(set) var totalSampleCount = 0
    private(set) var detectedSteps = 0
    private(set) var magneticMagnitude = 0.0
    private(set) var magneticAccuracy = CMMagneticFieldCalibrationAccuracy.uncalibrated
    private(set) var motionModeLabel = "Starting"
    private(set) var recentMotionStepCount = 0
    private(set) var motionMeanUserAcceleration = 0.0
    private(set) var motionMeanRotation = 0.0
    private(set) var motionMagneticStdDev = 0.0

    // Posterior-derived outputs
    private(set) var pOff = 0.0
    private(set) var posteriorStdBins = 0.0
    private(set) var globalProgress = 0.0
    private(set) var segmentProgress = 0.0
    private(set) var reachedCheckpoints = 0
    private(set) var displayBin = 0.0
    private(set) var magneticUpdates = 0
    private(set) var lastWindowStatus = "warming up"
    private(set) var lastAdvanceReason: String?

    @ObservationIgnored private let gp: GlobalRouteProfile
    @ObservationIgnored private var filter: RouteBeliefFilter
    @ObservationIgnored private let recorder = SensorRecorder()
    @ObservationIgnored private var runIdentifier = 0
    @ObservationIgnored private var stepDetector = LiveStepDetector()
    @ObservationIgnored private var motionMode = LiveMotionMode.starting
    @ObservationIgnored private var recentMotionSamples: [MotionClassifierSample] = []
    @ObservationIgnored private var recentStepTimes: [TimeInterval] = []
    @ObservationIgnored private var magBuffer: [(t: TimeInterval, v: Double)] = []
    @ObservationIgnored private var stepTimes: [TimeInterval] = []
    @ObservationIgnored private var lastIdleTick: TimeInterval?
    @ObservationIgnored private var checkpointConsecutive = 0
    @ObservationIgnored private var stepsSinceObservation = Int.max
    @ObservationIgnored private var traceWriter: SessionWriter?

    private let motionWindowDuration = 1.8
    private let standingUserAccelerationThreshold = 0.035
    private let standingRotationThreshold = 0.08
    private let magBufferSeconds = 30.0

    init(profile: RouteProfile) throws {
        self.profile = profile
        gp = try GlobalRouteProfile(profile: profile)
        filter = RouteBeliefFilter(profile: gp)
        deviceMotionAvailable = recorder.isDeviceMotionAvailable
    }

    deinit {
        recorder.stop()
    }

    // MARK: View-facing derivations

    var currentSegmentLabel: String {
        isComplete ? "Route complete" : gp.segment(ofBin: Int(displayBin)).fromToLabel
    }

    var nextCheckpoint: String {
        guard reachedCheckpoints < gp.checkpoints.count else { return "Done" }
        return gp.checkpoints[reachedCheckpoints].name
    }

    var activeSegmentPosition: Int { reachedCheckpoints }

    var progressPercentText: String {
        "\(Int((segmentProgress * 100).rounded()))%"
    }

    /// When the posterior says we're likely off-route, the progress display is a
    /// belief about the last consistent position, not a live claim.
    var isProgressStale: Bool {
        isRunning && !isComplete && pOff > FilterParams.offRouteTau
    }

    var limitationCopy: String {
        "Prototype route mode: stand at \(profile.anchors.first?.name ?? "Start"), tap Start/Reset, then walk the surveyed route with the phone in hand. It estimates progress on this route only; it is not arbitrary indoor GPS."
    }

    // MARK: Lifecycle

    func startOrReset() {
        guard deviceMotionAvailable else {
            statusText = "Device motion unavailable"
            return
        }

        runIdentifier += 1
        let activeRunIdentifier = runIdentifier
        isRunning = false
        recorder.stop()
        recorder.onDeviceMotion = { [weak self] motion in
            Task { @MainActor [weak self] in
                self?.handleDeviceMotion(motion, runIdentifier: activeRunIdentifier)
            }
        }

        filter = RouteBeliefFilter(profile: gp)
        totalSampleCount = 0
        detectedSteps = 0
        magneticUpdates = 0
        reachedCheckpoints = 0
        checkpointConsecutive = 0
        isComplete = false
        isRunning = true
        lastAdvanceReason = nil
        pOff = 0
        globalProgress = 0
        segmentProgress = 0
        displayBin = 0
        posteriorStdBins = 0
        lastWindowStatus = "warming up"
        magBuffer.removeAll(keepingCapacity: true)
        stepTimes.removeAll(keepingCapacity: true)
        lastIdleTick = nil
        stepsSinceObservation = .max
        stepDetector.reset()
        resetMotionClassifier()
        statusText = "Starting at \(profile.anchors.first?.name ?? "Start")"

        // Every live run writes a trace (sensors + filter state + events) into the
        // Sessions list — replayable offline and diffable against the JS filter.
        traceWriter?.close()
        traceWriter = try? SessionWriter(setup: RouteSetup(
            venueId: profile.route.venueId,
            routeId: profile.route.routeId,
            floorId: profile.route.floorId ?? "",
            direction: Direction(rawValue: profile.route.direction) ?? .forward,
            devicePose: .hand,
            passType: .live,
            recordGroundTruth: false,
            checkpoints: profile.anchors.map(\.name)
        ))

        recorder.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        let wasRunning = isRunning
        runIdentifier += 1
        isRunning = false
        recorder.stop()
        closeTrace(reason: isComplete ? "complete" : "stopped")
        UIApplication.shared.isIdleTimerDisabled = false
        if wasRunning && !isComplete {
            statusText = "Stopped"
        }
    }

    private func closeTrace(reason: String) {
        guard let writer = traceWriter else { return }
        writer.writeLine([
            "type": "end",
            "t": ProcessInfo.processInfo.systemUptime,
            "reason": reason,
            "reachedCheckpoints": reachedCheckpoints,
            "magUpdates": magneticUpdates,
            "steps": detectedSteps,
        ])
        writer.close()
        traceWriter = nil
    }

    // MARK: Sample handling

    private func handleDeviceMotion(_ motion: CMDeviceMotion, runIdentifier: Int) {
        guard runIdentifier == self.runIdentifier, isRunning, !isComplete else { return }

        let timestamp = motion.timestamp
        let mag = motion.magneticField.field
        let ua = motion.userAcceleration
        let rotation = motion.rotationRate
        let magMagnitude = hypot3(mag.x, mag.y, mag.z)
        let uaMagnitude = hypot3(ua.x, ua.y, ua.z)
        let rotationMagnitude = hypot3(rotation.x, rotation.y, rotation.z)

        totalSampleCount += 1
        magneticMagnitude = magMagnitude
        magneticAccuracy = motion.magneticField.accuracy

        traceWriter?.writeLine([
            "type": "dm",
            "t": jsonRound(timestamp),
            "q": [
                "w": jsonRound(motion.attitude.quaternion.w, 5),
                "x": jsonRound(motion.attitude.quaternion.x, 5),
                "y": jsonRound(motion.attitude.quaternion.y, 5),
                "z": jsonRound(motion.attitude.quaternion.z, 5),
            ],
            "rot": [
                "x": jsonRound(rotation.x),
                "y": jsonRound(rotation.y),
                "z": jsonRound(rotation.z),
            ],
            "ua": [
                "x": jsonRound(ua.x),
                "y": jsonRound(ua.y),
                "z": jsonRound(ua.z),
            ],
            "g": [
                "x": jsonRound(motion.gravity.x),
                "y": jsonRound(motion.gravity.y),
                "z": jsonRound(motion.gravity.z),
            ],
            "mag": [
                "x": jsonRound(mag.x, 3),
                "y": jsonRound(mag.y, 3),
                "z": jsonRound(mag.z, 3),
                "acc": motion.magneticField.accuracy.rawValue,
            ],
        ])

        magBuffer.append((t: timestamp, v: magMagnitude))
        let cutoff = timestamp - magBufferSeconds
        if let firstKept = magBuffer.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            magBuffer.removeFirst(firstKept)
        }

        let didStep = stepDetector.addSample(t: timestamp, magnitude: uaMagnitude)
        updateMotionClassifier(
            timestamp: timestamp,
            userAccelerationMagnitude: uaMagnitude,
            rotationMagnitude: rotationMagnitude,
            magneticMagnitude: magMagnitude,
            didStep: didStep
        )

        if didStep && motionMode == .walking {
            detectedSteps += 1
            stepTimes.append(timestamp)
            filter.predictStep()
            // Freeze magnetic evidence when iOS reports the magnetometer uncalibrated
            // (e.g., right after a MagSafe attach); prediction still runs.
            var observedThisStep = false
            if magneticAccuracy != .uncalibrated {
                if filter.observe(windowForSegment: { [weak self] seg in self?.windowForSegment(seg) }) {
                    magneticUpdates += 1
                    lastWindowStatus = "ok"
                    observedThisStep = true
                }
            } else {
                lastWindowStatus = "uncalibrated"
            }
            if observedThisStep {
                stepsSinceObservation = 0
            } else {
                // Int.max means "never observed yet" and stays that way.
                if stepsSinceObservation != Int.max { stepsSinceObservation += 1 }
                // Motion without magnetic corroboration raises route uncertainty.
                filter.applyUnobservedLeak()
            }
            refreshOutputs(at: timestamp)
        } else if motionMode == .standing {
            if lastIdleTick == nil { lastIdleTick = timestamp }
            if timestamp - (lastIdleTick ?? timestamp) >= 1.0 {
                filter.predictIdle(dt: timestamp - (lastIdleTick ?? timestamp))
                lastIdleTick = timestamp
                refreshOutputs(at: timestamp)
            }
        } else {
            lastIdleTick = timestamp
        }
    }

    private func windowForSegment(_ seg: GlobalRouteProfile.Segment) -> [Double]? {
        guard stepTimes.count >= 2, magBuffer.count >= 2 else {
            lastWindowStatus = "warming up"
            return nil
        }
        let boundaries = Array(stepTimes.suffix(FilterParams.windowSteps + 1))
        let perStep = max(2, Int(seg.binsPerStep.rounded()))
        var out: [Double] = []
        out.reserveCapacity((boundaries.count - 1) * perStep)
        for k in 0..<(boundaries.count - 1) {
            let a = boundaries[k]
            let b = boundaries[k + 1]
            for i in 0..<perStep {
                out.append(magnitudeAt(a + (b - a) * Double(i + 1) / Double(perStep)))
            }
        }
        guard let lo = out.min(), let hi = out.max(), hi - lo >= FilterParams.minWindowRangeUT else {
            lastWindowStatus = "flat field"
            return nil
        }
        return out
    }

    private func magnitudeAt(_ t: TimeInterval) -> Double {
        if t <= magBuffer[0].t { return magBuffer[0].v }
        if t >= magBuffer[magBuffer.count - 1].t { return magBuffer[magBuffer.count - 1].v }
        var lo = 0
        var hi = magBuffer.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if magBuffer[mid].t <= t { lo = mid } else { hi = mid }
        }
        let span = magBuffer[hi].t - magBuffer[lo].t
        let f = span > 0 ? (t - magBuffer[lo].t) / span : 0
        return magBuffer[lo].v + (magBuffer[hi].v - magBuffer[lo].v) * f
    }

    // MARK: Posterior -> UI

    private func refreshOutputs(at timestamp: TimeInterval) {
        let meanBin = filter.meanBin
        pOff = filter.pOff
        posteriorStdBins = filter.beliefStdDev

        traceWriter?.writeLine([
            "type": "filter",
            "t": jsonRound(timestamp),
            "meanBin": jsonRound(meanBin, 1),
            "pOff": jsonRound(pOff, 4),
            "postStd": jsonRound(posteriorStdBins, 1),
            "stepsSinceObs": stepsSinceObservation == Int.max ? -1 : stepsSinceObservation,
            "magUpdates": magneticUpdates,
            "window": lastWindowStatus,
            "motion": motionModeLabel,
            "steps": detectedSteps,
        ])

        // Ordered checkpoint decision: only the next checkpoint can fire, and only
        // with recent magnetic corroboration — dead reckoning alone never fires.
        if reachedCheckpoints < gp.checkpoints.count {
            let cp = gp.checkpoints[reachedCheckpoints]
            let onRoute = max(1 - pOff, 1e-9)
            let fired = stepsSinceObservation <= FilterParams.observationRecencySteps
                && filter.probBeyond(bin: cp.decisionBin) / onRoute > FilterParams.checkpointTau
                && pOff < FilterParams.offRouteTau
            checkpointConsecutive = fired ? checkpointConsecutive + 1 : 0
            if checkpointConsecutive >= 2 {
                checkpointConsecutive = 0
                reachedCheckpoints += 1
                lastAdvanceReason = "Posterior past \(cp.name)"
                traceWriter?.writeLine(["type": "cp_fired", "t": jsonRound(timestamp), "name": cp.name])
                traceWriter?.flush()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if reachedCheckpoints == gp.checkpoints.count {
                    completeRoute()
                    return
                }
            }
        }

        // The timeline ratchets forward when a checkpoint fires (tail probability),
        // but the posterior mean can lag it or even slip backward. The segment card
        // and progress rings must never contradict the timeline, so the displayed
        // bin is floored at the first bin past the last reached checkpoint.
        let floorBin = reachedCheckpoints > 0
            ? Double(min(gp.checkpoints[reachedCheckpoints - 1].bin + 1, gp.bins - 1))
            : 0
        displayBin = max(meanBin, floorBin)
        let seg = gp.segment(ofBin: Int(displayBin))
        globalProgress = displayBin / Double(max(gp.bins - 1, 1))
        segmentProgress = min(1, max(0, (displayBin - Double(seg.startBin)) / Double(max(seg.count - 1, 1))))

        if pOff > FilterParams.offRouteTau {
            statusText = "Off route?"
        } else if motionMode != .walking {
            statusText = pausedMotionStatusText
        } else if reachedCheckpoints < gp.checkpoints.count,
                  filter.probBeyond(bin: gp.checkpoints[reachedCheckpoints].decisionBin) > 0.4 {
            statusText = "Near \(gp.checkpoints[reachedCheckpoints].name)"
        } else if lastWindowStatus == "flat field" {
            statusText = "Low magnetic signal"
        } else {
            statusText = "Walking"
        }
    }

    private func completeRoute() {
        runIdentifier += 1
        isComplete = true
        isRunning = false
        segmentProgress = 1
        globalProgress = 1
        displayBin = Double(gp.bins - 1)
        statusText = "Route complete"
        recorder.stop()
        closeTrace(reason: "complete")
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: Motion classifier (unchanged from the heuristic version)

    private func resetMotionClassifier() {
        motionMode = .starting
        motionModeLabel = motionMode.label
        recentMotionSamples.removeAll(keepingCapacity: true)
        recentStepTimes.removeAll(keepingCapacity: true)
        recentMotionStepCount = 0
        motionMeanUserAcceleration = 0
        motionMeanRotation = 0
        motionMagneticStdDev = 0
    }

    private func updateMotionClassifier(
        timestamp: TimeInterval,
        userAccelerationMagnitude: Double,
        rotationMagnitude: Double,
        magneticMagnitude: Double,
        didStep: Bool
    ) {
        recentMotionSamples.append(MotionClassifierSample(
            t: timestamp,
            userAccelerationMagnitude: userAccelerationMagnitude,
            rotationMagnitude: rotationMagnitude,
            magneticMagnitude: magneticMagnitude
        ))
        if didStep { recentStepTimes.append(timestamp) }

        let cutoff = timestamp - motionWindowDuration
        recentMotionSamples.removeAll { $0.t < cutoff }
        recentStepTimes.removeAll { $0 < cutoff }
        recentMotionStepCount = recentStepTimes.count

        guard recentMotionSamples.count >= 20 else {
            setMotionMode(.starting)
            return
        }

        let sampleCount = Double(recentMotionSamples.count)
        motionMeanUserAcceleration = recentMotionSamples.reduce(0) { $0 + $1.userAccelerationMagnitude } / sampleCount
        motionMeanRotation = recentMotionSamples.reduce(0) { $0 + $1.rotationMagnitude } / sampleCount
        motionMagneticStdDev = standardDeviation(recentMotionSamples.map(\.magneticMagnitude))

        if recentMotionStepCount > 0 {
            setMotionMode(.walking)
        } else if motionMeanUserAcceleration < standingUserAccelerationThreshold
                    && motionMeanRotation < standingRotationThreshold {
            setMotionMode(.standing)
        } else {
            setMotionMode(.phoneMoving)
        }
    }

    private func setMotionMode(_ mode: LiveMotionMode) {
        motionMode = mode
        motionModeLabel = mode.label
    }

    private var pausedMotionStatusText: String {
        switch motionMode {
        case .starting: return "Starting"
        case .standing: return "Standing"
        case .phoneMoving: return "Phone moving"
        case .walking: return "Walking"
        }
    }
}

extension GlobalRouteProfile.Segment {
    var fromToLabel: String { "\(from) → \(to)" }
}

private enum LiveMotionMode {
    case starting
    case standing
    case walking
    case phoneMoving

    var label: String {
        switch self {
        case .starting: return "Starting"
        case .standing: return "Standing"
        case .walking: return "Walking"
        case .phoneMoving: return "Phone moving"
        }
    }
}

private struct MotionClassifierSample {
    let t: TimeInterval
    let userAccelerationMagnitude: Double
    let rotationMagnitude: Double
    let magneticMagnitude: Double
}

private struct LiveStepDetector {
    private struct TimedValue {
        let t: TimeInterval
        let value: Double
    }

    private var raw: [TimedValue] = []
    private var smoothed: [TimedValue] = []
    private var lastStepTime = -Double.infinity

    mutating func reset() {
        raw.removeAll(keepingCapacity: true)
        smoothed.removeAll(keepingCapacity: true)
        lastStepTime = -Double.infinity
    }

    mutating func addSample(t: TimeInterval, magnitude: Double) -> Bool {
        guard magnitude.isFinite else { return false }

        raw.append(TimedValue(t: t, value: magnitude))
        if raw.count > 9 { raw.removeFirst(raw.count - 9) }

        let smoothValue = raw.suffix(7).reduce(0) { $0 + $1.value } / Double(min(raw.count, 7))
        smoothed.append(TimedValue(t: t, value: smoothValue))
        if smoothed.count > 160 { smoothed.removeFirst(smoothed.count - 160) }
        guard smoothed.count >= 5 else { return false }

        let candidateIndex = smoothed.count - 2
        let previous = smoothed[candidateIndex - 1]
        let candidate = smoothed[candidateIndex]
        let next = smoothed[candidateIndex + 1]
        let recentValues = smoothed.suffix(min(120, smoothed.count)).map(\.value)
        let med = median(recentValues)
        let mad = median(recentValues.map { abs($0 - med) })
        let threshold = med + max(0.045, 1.6 * (mad == 0 ? 0.03 : mad))

        let isPeak = candidate.value > previous.value && candidate.value >= next.value && candidate.value > threshold
        let farEnough = candidate.t - lastStepTime >= 0.34
        if isPeak && farEnough {
            lastStepTime = candidate.t
            return true
        }
        return false
    }
}

private func hypot3(_ x: Double, _ y: Double, _ z: Double) -> Double {
    (x * x + y * y + z * z).squareRoot()
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func standardDeviation(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    return variance.squareRoot()
}
