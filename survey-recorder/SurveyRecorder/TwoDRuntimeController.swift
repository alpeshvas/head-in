import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class TwoDRuntimeController {
    let map: VenueMap2D
    let heatmapCells: [MagneticHeatmapCell]

    private(set) var isRunning = false
    private(set) var statusText = "Ready"
    private(set) var detectedSteps = 0
    private(set) var magneticUpdates = 0
    private(set) var estimate: ParticleEstimate2D?
    private(set) var particleSnapshot: [MapPoint2D] = []
    private(set) var lastMagneticChangeUT: Double?
    private(set) var expectedMagneticChangeUT: Double?
    private(set) var magneticResidualUT: Double?
    private(set) var nearestHeatmapCellDistanceMeters: Double?

    @ObservationIgnored private let sensorRecorder = SensorRecorder()
    @ObservationIgnored private var stepDetector = StepDetector2D()
    @ObservationIgnored private var filter: ParticleFilter2D?
    @ObservationIgnored private var previousMotionTimestamp: TimeInterval?
    @ObservationIgnored private var pendingYawDelta = 0.0
    @ObservationIgnored private var lastStepFeature: MagneticFeature2D?

    init(map: VenueMap2D, heatmapCells: [MagneticHeatmapCell]) {
        self.map = map
        self.heatmapCells = heatmapCells
    }

    func start(at entrance: Entrance2D) {
        guard !isRunning else { return }
        guard !heatmapCells.isEmpty else {
            statusText = "No magnetic heatmap cells"
            return
        }
        filter = ParticleFilter2D(map: map, heatmapCells: heatmapCells, start: entrance.point)
        estimate = filter?.estimate
        detectedSteps = 0
        magneticUpdates = 0
        particleSnapshot = []
        lastMagneticChangeUT = nil
        expectedMagneticChangeUT = nil
        magneticResidualUT = nil
        nearestHeatmapCellDistanceMeters = nil
        pendingYawDelta = 0
        previousMotionTimestamp = nil
        lastStepFeature = nil
        stepDetector.reset()
        if let filter { updateRuntimeDiagnostics(filter: filter) }
        isRunning = true
        statusText = "Tracking from \(entrance.name)"

        sensorRecorder.onDeviceMotion = { [weak self] motion in
            Task { @MainActor [weak self] in
                self?.handleMotion(motion)
            }
        }
        sensorRecorder.start()
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

        guard stepDetector.addSample(t: timestamp, magnitude: uaMagnitude) else { return }
        detectedSteps += 1
        filter.predictStep(gyroDeltaRadians: pendingYawDelta)
        pendingYawDelta = 0

        if let feature, let previous = lastStepFeature, motion.magneticField.accuracy != .uncalibrated {
            let magneticChange = hypot(feature.magnitudeUT - previous.magnitudeUT, feature.verticalUT - previous.verticalUT)
            filter.observe(magneticChangeUT: magneticChange)
            magneticUpdates += 1
            lastMagneticChangeUT = magneticChange
        }
        if let feature { lastStepFeature = feature }
        estimate = filter.estimate
        updateRuntimeDiagnostics(filter: filter)
        updateStatus()
    }

    private func updateRuntimeDiagnostics(filter: ParticleFilter2D) {
        guard let estimate else { return }
        expectedMagneticChangeUT = filter.expectedMagneticChangeUT(at: estimate.point)
        nearestHeatmapCellDistanceMeters = filter.nearestHeatmapCellDistanceMeters(to: estimate.point)
        if let lastMagneticChangeUT, let expectedMagneticChangeUT {
            magneticResidualUT = lastMagneticChangeUT - expectedMagneticChangeUT
        } else {
            magneticResidualUT = nil
        }

        let stride = max(1, filter.particles.count / 250)
        particleSnapshot = filter.particles.enumerated().compactMap { index, particle in
            guard index.isMultiple(of: stride) else { return nil }
            return MapPoint2D(x: particle.x, y: particle.y)
        }
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

private struct StepDetector2D {
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
    if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
    return sorted[middle]
}
