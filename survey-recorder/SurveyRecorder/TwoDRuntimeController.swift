import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class TwoDRuntimeController {
    let map: VenueMap2D
    let heatmapCells: [MagneticHeatmapCell]
    var observationMode: ParticleObservationMode2D

    private(set) var isRunning = false
    private(set) var statusText = "Ready"
    private(set) var detectedSteps = 0
    private(set) var magneticUpdates = 0
    private(set) var estimate: ParticleEstimate2D?
    private(set) var particleSnapshot: [MapPoint2D] = []
    private(set) var observedMagnitudeUT: Double?
    private(set) var observedVerticalUT: Double?
    private(set) var observedHorizontalUT: Double?
    private(set) var expectedMagnitudeUT: Double?
    private(set) var expectedVerticalUT: Double?
    private(set) var expectedHorizontalUT: Double?
    private(set) var magneticResidualUT: Double?
    private(set) var nearestHeatmapCellDistanceMeters: Double?
    private(set) var meanParticleCellDistanceMeters: Double?
    private(set) var farParticlePercent: Double?
    private(set) var lastStepYawDeltaDegrees: Double?
    private(set) var turnRecoveryParticleCount = 0
    private(set) var applePedometerSteps = 0
    private(set) var stepCountDifference = 0
    private(set) var rejectedStepCandidateCount = 0

    @ObservationIgnored private let sensorRecorder = SensorRecorder()
    @ObservationIgnored private var stepDetector = StepDetector2D()
    @ObservationIgnored private var filter: ParticleFilter2D?
    @ObservationIgnored private var previousMotionTimestamp: TimeInterval?
    @ObservationIgnored private var pendingYawDelta = 0.0
    @ObservationIgnored private var latestStepFeature: MagneticFeature2D?
    @ObservationIgnored private var latestStepFeatureIsUsable = false
    @ObservationIgnored private var lastStepFeature: MagneticFeature2D?
    @ObservationIgnored private let debugWriter: TwoDRuntimeDebugWriter?

    init(
        map: VenueMap2D,
        heatmapCells: [MagneticHeatmapCell],
        observationMode: ParticleObservationMode2D = .absolute,
        debugWriter: TwoDRuntimeDebugWriter? = nil
    ) {
        self.map = map
        self.heatmapCells = heatmapCells
        self.observationMode = observationMode
        self.debugWriter = debugWriter
    }

    func start(at entrance: Entrance2D) {
        guard !isRunning else { return }
        guard !heatmapCells.isEmpty else {
            statusText = "No magnetic heatmap cells"
            return
        }
        guard heatmapCells.contains(where: { $0.meanMagnitudeUT != nil && $0.meanVerticalUT != nil && $0.meanHorizontalUT != nil }) else {
            statusText = "Heatmap needs horizontal magnetic means · resurvey or rebuild"
            return
        }
        filter = ParticleFilter2D(map: map, heatmapCells: heatmapCells, start: entrance.point)
        estimate = filter?.estimate
        detectedSteps = 0
        magneticUpdates = 0
        particleSnapshot = []
        observedMagnitudeUT = nil
        observedVerticalUT = nil
        observedHorizontalUT = nil
        expectedMagnitudeUT = nil
        expectedVerticalUT = nil
        expectedHorizontalUT = nil
        magneticResidualUT = nil
        nearestHeatmapCellDistanceMeters = nil
        meanParticleCellDistanceMeters = nil
        farParticlePercent = nil
        lastStepYawDeltaDegrees = nil
        turnRecoveryParticleCount = 0
        applePedometerSteps = 0
        stepCountDifference = 0
        rejectedStepCandidateCount = 0
        pendingYawDelta = 0
        previousMotionTimestamp = nil
        latestStepFeature = nil
        latestStepFeatureIsUsable = false
        lastStepFeature = nil
        stepDetector.reset()
        if let filter { updateRuntimeDiagnostics(filter: filter) }
        if let filter, let estimate {
            debugWriter?.writeFilter(
                timestamp: ProcessInfo.processInfo.systemUptime,
                phase: "initial",
                estimate: estimate,
                nearestCellDistance: nearestHeatmapCellDistanceMeters,
                meanParticleCellDistance: meanParticleCellDistanceMeters,
                farParticlePercent: farParticlePercent,
                magneticResidualUT: magneticResidualUT,
                turnRecoveryParticleCount: turnRecoveryParticleCount,
                particles: filter.particles
            )
        }
        isRunning = true
        statusText = "Tracking from \(entrance.name)"

        sensorRecorder.onDeviceMotion = { [weak self] motion in
            Task { @MainActor [weak self] in
                self?.handleMotion(motion)
            }
        }
        sensorRecorder.onPedometer = { [weak self] data in
            Task { @MainActor [weak self] in
                self?.handlePedometer(data)
            }
        }
        sensorRecorder.start(includeMagnetometer: false, includePedometer: true, includeAltimeter: false)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sensorRecorder.stop()
        statusText = "Stopped"
    }

    private func handleMotion(_ motion: CMDeviceMotion) {
        guard isRunning, let filter else { return }
        let timestamp = motion.timestamp
        let ua = motion.userAcceleration
        let uaMagnitude = hypot3(ua.x, ua.y, ua.z)

        let rotation = motion.rotationRate
        let gravity = motion.gravity
        let gravityMagnitude = hypot3(gravity.x, gravity.y, gravity.z)
        if gravityMagnitude > 0, let previousMotionTimestamp {
            let dt = max(0, min(0.1, timestamp - previousMotionTimestamp))
            let yawRate = -(rotation.x * gravity.x + rotation.y * gravity.y + rotation.z * gravity.z) / gravityMagnitude
            pendingYawDelta += yawRate * dt
        }
        previousMotionTimestamp = timestamp

        let mag = motion.magneticField.field
        let feature = MagneticFeature2D.from(
            magneticVector: Vector3D(x: mag.x, y: mag.y, z: mag.z),
            gravityVector: Vector3D(x: gravity.x, y: gravity.y, z: gravity.z),
            accuracyRawValue: Int(motion.magneticField.accuracy.rawValue)
        )
        latestStepFeature = feature
        latestStepFeatureIsUsable = feature != nil && motion.magneticField.accuracy != .uncalibrated
        debugWriter?.writeMotion(motion, feature: feature)

        switch stepDetector.addSample(t: timestamp, magnitude: uaMagnitude) {
        case .accepted:
            acceptStep(filter: filter)
        case .rejected:
            rejectedStepCandidateCount += 1
            debugWriter?.writeRejectedPeak(timestamp: timestamp, rejectedPeaks: rejectedStepCandidateCount)
        case .none:
            break
        }
    }

    private func handlePedometer(_ data: CMPedometerData) {
        guard isRunning else { return }
        applePedometerSteps = max(0, data.numberOfSteps.intValue)
        updateStepDifference()
        debugWriter?.writePedometer(data, detectedSteps: detectedSteps)
    }

    private func acceptStep(filter: ParticleFilter2D) {
        detectedSteps += 1
        updateStepDifference()
        let stepYawDelta = pendingYawDelta
        debugWriter?.writeStep(
            index: detectedSteps,
            timestamp: previousMotionTimestamp ?? ProcessInfo.processInfo.systemUptime,
            yawDeltaRadians: stepYawDelta,
            appleSteps: applePedometerSteps,
            rejectedPeaks: rejectedStepCandidateCount
        )
        filter.predictStep(gyroDeltaRadians: stepYawDelta)
        lastStepYawDeltaDegrees = stepYawDelta * 180 / .pi
        turnRecoveryParticleCount = filter.lastTurnRecoveryParticleCount
        pendingYawDelta = 0
        estimate = filter.estimate
        updateRuntimeDiagnostics(filter: filter)
        if let estimate {
            debugWriter?.writeFilter(
                timestamp: previousMotionTimestamp ?? ProcessInfo.processInfo.systemUptime,
                phase: "afterPredict",
                estimate: estimate,
                nearestCellDistance: nearestHeatmapCellDistanceMeters,
                meanParticleCellDistance: meanParticleCellDistanceMeters,
                farParticlePercent: farParticlePercent,
                magneticResidualUT: magneticResidualUT,
                turnRecoveryParticleCount: turnRecoveryParticleCount,
                particles: filter.particles
            )
        }

        if let feature = latestStepFeature, latestStepFeatureIsUsable {
            filter.observe(magnetic: feature, previous: lastStepFeature, mode: observationMode)
            if observationMode != .coverageOnly { magneticUpdates += 1 }
            observedMagnitudeUT = feature.magnitudeUT
            observedVerticalUT = feature.verticalUT
            observedHorizontalUT = feature.horizontalUT
            lastStepFeature = feature
        }
        estimate = filter.estimate
        updateRuntimeDiagnostics(filter: filter)
        if let estimate {
            debugWriter?.writeFilter(
                timestamp: previousMotionTimestamp ?? ProcessInfo.processInfo.systemUptime,
                phase: "afterObserve",
                estimate: estimate,
                nearestCellDistance: nearestHeatmapCellDistanceMeters,
                meanParticleCellDistance: meanParticleCellDistanceMeters,
                farParticlePercent: farParticlePercent,
                magneticResidualUT: magneticResidualUT,
                turnRecoveryParticleCount: turnRecoveryParticleCount,
                particles: filter.particles
            )
        }
        updateStatus()
    }

    private func updateStepDifference() {
        stepCountDifference = applePedometerSteps - detectedSteps
    }

    private func updateRuntimeDiagnostics(filter: ParticleFilter2D) {
        guard let estimate else { return }
        let expected = filter.expectedMagneticFeature(at: estimate.point)
        expectedMagnitudeUT = expected?.magnitudeUT
        expectedVerticalUT = expected?.verticalUT
        expectedHorizontalUT = expected?.horizontalUT
        nearestHeatmapCellDistanceMeters = filter.nearestHeatmapCellDistanceMeters(to: estimate.point)
        if let observedMagnitudeUT, let observedVerticalUT, let observedHorizontalUT, let expectedMagnitudeUT, let expectedVerticalUT, let expectedHorizontalUT {
            let dm = observedMagnitudeUT - expectedMagnitudeUT
            let dv = observedVerticalUT - expectedVerticalUT
            let dh = observedHorizontalUT - expectedHorizontalUT
            magneticResidualUT = sqrt(dm * dm + dv * dv + dh * dh)
        } else {
            magneticResidualUT = nil
        }

        let stride = max(1, filter.particles.count / 250)
        var distanceSum = 0.0
        var distanceCount = 0
        var farCount = 0
        particleSnapshot = filter.particles.enumerated().compactMap { index, particle in
            if let distance = filter.nearestHeatmapCellDistanceMeters(to: MapPoint2D(x: particle.x, y: particle.y)) {
                distanceSum += distance
                distanceCount += 1
                if distance > ParticleFilter2DParams.surveyedCellNoPenaltyDistanceMeters { farCount += 1 }
            }
            guard index.isMultiple(of: stride) else { return nil }
            return MapPoint2D(x: particle.x, y: particle.y)
        }
        meanParticleCellDistanceMeters = distanceCount > 0 ? distanceSum / Double(distanceCount) : nil
        farParticlePercent = distanceCount > 0 ? 100 * Double(farCount) / Double(distanceCount) : nil
    }

    private func updateStatus() {
        guard let estimate else { return }
        let room = estimate.roomId.flatMap { id in map.rooms.first { $0.id == id }?.name } ?? "unknown room"
        if estimate.confidenceRadiusMeters <= 2.5 {
            statusText = "High confidence · \(room)"
        } else if estimate.confidenceRadiusMeters <= 5.0 {
            statusText = "Medium confidence · \(room)"
        } else {
            statusText = "Locating · \(room)"
        }
    }
}

private enum StepDetector2DResult {
    case none
    case accepted
    case rejected
}

private struct StepDetector2D {
    private struct TimedValue {
        let t: TimeInterval
        let value: Double
    }

    private static let minStepIntervalSeconds = 0.34

    private var raw: [TimedValue] = []
    private var smoothed: [TimedValue] = []
    private var lastAcceptedStepTime = -Double.infinity

    mutating func reset() {
        raw.removeAll(keepingCapacity: true)
        smoothed.removeAll(keepingCapacity: true)
        lastAcceptedStepTime = -Double.infinity
    }

    mutating func addSample(t: TimeInterval, magnitude: Double) -> StepDetector2DResult {
        guard magnitude.isFinite else { return .none }
        raw.append(TimedValue(t: t, value: magnitude))
        if raw.count > 9 { raw.removeFirst(raw.count - 9) }
        let smoothValue = raw.suffix(7).reduce(0) { $0 + $1.value } / Double(min(raw.count, 7))
        smoothed.append(TimedValue(t: t, value: smoothValue))
        if smoothed.count > 160 { smoothed.removeFirst(smoothed.count - 160) }
        guard smoothed.count >= 5 else { return .none }

        let candidateIndex = smoothed.count - 2
        let previous = smoothed[candidateIndex - 1]
        let candidate = smoothed[candidateIndex]
        let next = smoothed[candidateIndex + 1]
        let recentValues = smoothed.suffix(min(120, smoothed.count)).map(\.value)
        let med = median(recentValues)
        let mad = median(recentValues.map { abs($0 - med) })
        let threshold = med + max(0.045, 1.6 * (mad == 0 ? 0.03 : mad))
        let isPeak = candidate.value > previous.value && candidate.value >= next.value && candidate.value > threshold
        guard isPeak else { return .none }

        guard candidate.t - lastAcceptedStepTime >= Self.minStepIntervalSeconds else {
            return .rejected
        }
        lastAcceptedStepTime = candidate.t
        return .accepted
    }
}

private func hypot3(_ x: Double, _ y: Double, _ z: Double) -> Double {
    (x * x + y * y + z * z).squareRoot()
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
    return sorted[middle]
}
