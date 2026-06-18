import CoreMotion
import Foundation
import Observation

@MainActor
@Observable
final class TwoDSurveyController {
    let map: VenueMap2D

    private(set) var isRunning = false
    private(set) var statusText = "Ready"
    private(set) var trackingStatus = "off"
    private(set) var latestMapPoint: MapPoint2D?
    private(set) var latestRoomName: String?
    private(set) var sampleCount = 0
    private(set) var heatmapCells: [MagneticHeatmapCell]
    private(set) var alignmentPairs: [ARMapAlignmentPair2D] = []
    private(set) var transform: ARMapTransform2D?

    @ObservationIgnored private let sensorRecorder = SensorRecorder()
    @ObservationIgnored private let arRecorder = ARPoseRecorder()
    @ObservationIgnored private let accumulator = HeatmapAccumulator2D(cellSizeMeters: 0.5)
    @ObservationIgnored private var latestARPoint: ARPoint2D?
    @ObservationIgnored private var samples: [SurveySample2D] = []
    @ObservationIgnored private var updateCounter = 0
    @ObservationIgnored private var writer: TwoDSurveyWriter?

    init(map: VenueMap2D, existingCells: [MagneticHeatmapCell] = []) {
        self.map = map
        heatmapCells = existingCells
    }

    var alignmentReady: Bool { transform != nil }

    var nextAlignmentPoint: AlignmentPoint2D? {
        guard alignmentPairs.count < map.alignmentPoints.count else { return nil }
        return map.alignmentPoints[alignmentPairs.count]
    }

    func start() {
        guard !isRunning else { return }
        guard ARPoseRecorder.isSupported else {
            statusText = "ARKit world tracking unsupported"
            return
        }

        isRunning = true
        statusText = "Starting AR survey"
        trackingStatus = "starting"
        latestMapPoint = nil
        latestRoomName = nil
        sampleCount = 0
        samples.removeAll(keepingCapacity: true)
        // Reset+add: every fresh survey starts from an empty heatmap rather than
        // building on the previously saved cells.
        heatmapCells = []
        alignmentPairs.removeAll(keepingCapacity: true)
        transform = nil
        latestARPoint = nil
        writer = try? TwoDSurveyWriter(map: map)

        arRecorder.onPose = { [weak self] pose in
            Task { @MainActor [weak self] in
                self?.handlePose(pose)
            }
        }
        arRecorder.onUnavailable = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.statusText = reason
                self?.trackingStatus = "unavailable"
                self?.stop()
            }
        }

        sensorRecorder.onDeviceMotion = { [weak self] motion in
            Task { @MainActor [weak self] in
                self?.handleMotion(motion)
            }
        }

        arRecorder.start()
        sensorRecorder.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        arRecorder.stop()
        sensorRecorder.stop()
        writer?.writeEnd(sampleCount: sampleCount)
        writer?.close()
        writer = nil
        statusText = "Stopped · \(sampleCount) samples"
    }

    func captureNextAlignmentPoint() {
        guard let ar = latestARPoint else {
            statusText = "No AR pose yet"
            return
        }
        guard let alignmentPoint = nextAlignmentPoint else {
            statusText = "All alignment points captured"
            return
        }

        alignmentPairs.append(ARMapAlignmentPair2D(ar: ar, map: alignmentPoint.point))
        writer?.writeAlignment(name: alignmentPoint.name, pair: alignmentPairs[alignmentPairs.count - 1])
        if alignmentPairs.count >= 2, transform == nil {
            do {
                transform = try ARMapTransform2D.fromTwoPointAlignment(alignmentPairs[0], alignmentPairs[1])
                writer?.writeTransform(transform!)
                statusText = "Aligned · walk survey coverage"
            } catch {
                statusText = error.localizedDescription
            }
        } else {
            statusText = "Captured \(alignmentPoint.name)"
        }
    }

    private func handlePose(_ pose: ARPoseRecorder.Pose) {
        trackingStatus = pose.tracking
        latestARPoint = ARPoint2D(x: pose.x, z: pose.z)
        if let transform {
            let mapPoint = transform.mapPoint(for: ARPoint2D(x: pose.x, z: pose.z))
            latestMapPoint = mapPoint
            latestRoomName = roomName(containing: mapPoint)
        }
    }

    private func handleMotion(_ motion: CMDeviceMotion) {
        guard isRunning, let transform, let ar = latestARPoint else { return }
        let mag = motion.magneticField.field
        let gravity = motion.gravity
        guard let feature = MagneticFeature2D.from(
            magneticVector: Vector3D(x: mag.x, y: mag.y, z: mag.z),
            gravityVector: Vector3D(x: gravity.x, y: gravity.y, z: gravity.z),
            accuracyRawValue: Int(motion.magneticField.accuracy.rawValue)
        ) else { return }

        let mapPoint = transform.mapPoint(for: ar)
        guard Geometry2D.roomId(containing: mapPoint, in: map) != nil || map.walkablePolygons.isEmpty else { return }

        let sample = SurveySample2D(
            timestamp: motion.timestamp,
            arPoint: ar,
            mapPoint: mapPoint,
            roomId: Geometry2D.roomId(containing: mapPoint, in: map),
            magnetic: feature
        )
        samples.append(sample)
        writer?.writeSample(sample)
        sampleCount = samples.count
        latestMapPoint = mapPoint
        latestRoomName = roomName(containing: mapPoint)

        updateCounter += 1
        if updateCounter >= 25 {
            updateCounter = 0
            heatmapCells = accumulator.buildCells(from: samples, in: map)
        }
    }

    private func roomName(containing point: MapPoint2D) -> String? {
        guard let roomId = Geometry2D.roomId(containing: point, in: map) else { return nil }
        return map.rooms.first { $0.id == roomId }?.name
    }
}
