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

    @ObservationIgnored private let sensorRecorder = SensorRecorder()
    @ObservationIgnored private var filter: ParticleFilter2D?
    @ObservationIgnored private var previousMotionTimestamp: TimeInterval?
    @ObservationIgnored private var pendingYawDelta = 0.0
    @ObservationIgnored private var lastPedometerStepCount: Int?
    @ObservationIgnored private var latestStepFeature: MagneticFeature2D?
    @ObservationIgnored private var latestStepFeatureIsUsable = false
    @ObservationIgnored private var lastStepFeature: MagneticFeature2D?

    init(map: VenueMap2D, heatmapCells: [MagneticHeatmapCell], observationMode: ParticleObservationMode2D = .absolute) {
        self.map = map
        self.heatmapCells = heatmapCells
        self.observationMode = observationMode
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
        pendingYawDelta = 0
        previousMotionTimestamp = nil
        lastPedometerStepCount = nil
        latestStepFeature = nil
        latestStepFeatureIsUsable = false
        lastStepFeature = nil
        if let filter { updateRuntimeDiagnostics(filter: filter) }
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
        guard isRunning else { return }
        let timestamp = motion.timestamp

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
    }

    private func handlePedometer(_ data: CMPedometerData) {
        guard isRunning, let filter else { return }
        let stepCount = data.numberOfSteps.intValue
        let previousCount = lastPedometerStepCount ?? 0
        lastPedometerStepCount = stepCount
        let stepDelta = stepCount - previousCount
        guard stepDelta > 0 else { return }

        detectedSteps += stepDelta
        let yawPerStep = pendingYawDelta / Double(stepDelta)
        var injectedCount = 0
        for _ in 0..<stepDelta {
            filter.predictStep(gyroDeltaRadians: yawPerStep)
            injectedCount += filter.lastTurnRecoveryParticleCount
        }
        lastStepYawDeltaDegrees = yawPerStep * 180 / .pi
        turnRecoveryParticleCount = injectedCount
        pendingYawDelta = 0

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
        updateStatus()
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

private func hypot3(_ x: Double, _ y: Double, _ z: Double) -> Double {
    (x * x + y * y + z * z).squareRoot()
}
