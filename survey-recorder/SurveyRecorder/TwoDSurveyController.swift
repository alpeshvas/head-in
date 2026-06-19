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
    private(set) var latestMagneticFeature: MagneticFeature2D?
    private(set) var sampleCount = 0
    private(set) var rejectedOutsideWalkableCount = 0
    private(set) var heatmapCells: [MagneticHeatmapCell]
    private(set) var alignmentPairs: [ARMapAlignmentPair2D] = []
    private(set) var transform: ARMapTransform2D?

    @ObservationIgnored private let sensorRecorder = SensorRecorder()
    @ObservationIgnored private let arRecorder = ARPoseRecorder()
    @ObservationIgnored private var accumulator = HeatmapAccumulator2D(cellSizeMeters: 0.5)
    @ObservationIgnored private var latestARPoint: ARPoint2D?
    @ObservationIgnored private var writer: TwoDSurveyWriter?
    @ObservationIgnored private var pendingTrackingStatus = "off"
    @ObservationIgnored private var pendingMapPoint: MapPoint2D?
    @ObservationIgnored private var pendingRoomName: String?
    @ObservationIgnored private var pendingMagneticFeature: MagneticFeature2D?
    @ObservationIgnored private var pendingSampleCount = 0
    @ObservationIgnored private var pendingRejectedCount = 0
    @ObservationIgnored private var lastPublishT = -Double.infinity

    private let publishIntervalSeconds = 0.3

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
        pendingTrackingStatus = "starting"
        latestMapPoint = nil
        latestRoomName = nil
        latestMagneticFeature = nil
        sampleCount = 0
        rejectedOutsideWalkableCount = 0
        pendingMapPoint = nil
        pendingRoomName = nil
        pendingMagneticFeature = nil
        pendingSampleCount = 0
        pendingRejectedCount = 0
        accumulator.reset()
        heatmapCells = []
        alignmentPairs.removeAll(keepingCapacity: true)
        transform = nil
        latestARPoint = nil
        lastPublishT = -Double.infinity
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
                self?.pendingTrackingStatus = "unavailable"
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
        publishState(timestamp: ProcessInfo.processInfo.systemUptime)
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
        latestARPoint = ARPoint2D(x: pose.x, z: pose.z)
        pendingTrackingStatus = pose.tracking
        if let transform {
            let mapPoint = transform.mapPoint(for: ARPoint2D(x: pose.x, z: pose.z))
            pendingMapPoint = mapPoint
            pendingRoomName = roomName(containing: mapPoint)
        }
        touch(timestamp: pose.t)
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
        pendingMagneticFeature = feature

        let mapPoint = transform.mapPoint(for: ar)
        pendingMapPoint = mapPoint
        pendingRoomName = roomName(containing: mapPoint)
        guard Geometry2D.isWalkable(mapPoint, in: map) else {
            pendingRejectedCount += 1
            if pendingRejectedCount.isMultiple(of: 25) {
                statusText = "Outside walkable area · adjust map/alignment"
            }
            touch(timestamp: motion.timestamp)
            return
        }

        let sample = SurveySample2D(
            timestamp: motion.timestamp,
            arPoint: ar,
            mapPoint: mapPoint,
            roomId: Geometry2D.roomId(containing: mapPoint, in: map),
            magnetic: feature
        )
        accumulator.add(sample, in: map)
        writer?.writeSample(sample)
        pendingSampleCount += 1
        if pendingSampleCount == 1 || statusText.hasPrefix("Outside walkable area") {
            statusText = "Surveying · heatmap forming"
        }

        touch(timestamp: motion.timestamp)
    }

    private func touch(timestamp: TimeInterval) {
        guard timestamp - lastPublishT >= publishIntervalSeconds else { return }
        publishState(timestamp: timestamp)
    }

    private func publishState(timestamp: TimeInterval) {
        trackingStatus = pendingTrackingStatus
        latestMapPoint = pendingMapPoint
        latestRoomName = pendingRoomName
        latestMagneticFeature = pendingMagneticFeature
        sampleCount = pendingSampleCount
        rejectedOutsideWalkableCount = pendingRejectedCount
        heatmapCells = accumulator.cells(in: map)
        lastPublishT = timestamp
    }

    private func roomName(containing point: MapPoint2D) -> String? {
        guard let roomId = Geometry2D.roomId(containing: point, in: map) else { return nil }
        return map.rooms.first { $0.id == roomId }?.name
    }
}
