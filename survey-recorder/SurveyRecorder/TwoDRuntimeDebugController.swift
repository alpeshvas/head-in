import Foundation
import Observation

@MainActor
@Observable
final class TwoDRuntimeDebugController {
    let bundle: VenueMapBundle2D
    let observationMode: ParticleObservationMode2D
    let entrance: Entrance2D

    private(set) var isRunning = false
    private(set) var isRuntimeStarted = false
    private(set) var statusText = "Ready"
    private(set) var trackingStatus = "off"
    private(set) var latestRawTruthMapPoint: MapPoint2D?
    private(set) var latestTruthMapPoint: MapPoint2D?
    private(set) var latestDebugFileURL: URL?
    private(set) var alignmentPairs: [ARMapAlignmentPair2D] = []
    private(set) var transform: ARMapTransform2D?
    private(set) var runtimeEstimate: ParticleEstimate2D?
    private(set) var runtimeParticles: [MapPoint2D] = []
    private(set) var detectedSteps = 0
    private(set) var applePedometerSteps = 0
    private(set) var rejectedStepCandidateCount = 0

    @ObservationIgnored private let arRecorder = ARPoseRecorder()
    @ObservationIgnored private var latestARPoint: ARPoint2D?
    @ObservationIgnored private var latestARTimestamp: TimeInterval?
    @ObservationIgnored private var startAnchorAR: ARPoint2D?
    @ObservationIgnored private var writer: TwoDRuntimeDebugWriter?
    @ObservationIgnored private var runtimeController: TwoDRuntimeController?
    @ObservationIgnored private var truthSampleCount = 0

    init(bundle: VenueMapBundle2D, observationMode: ParticleObservationMode2D, entrance: Entrance2D) {
        self.bundle = bundle
        self.observationMode = observationMode
        self.entrance = entrance
    }

    var map: VenueMap2D { bundle.map }
    var heatmapCells: [MagneticHeatmapCell] { bundle.heatmapCells }
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
        guard !heatmapCells.isEmpty else {
            statusText = "No magnetic heatmap cells"
            return
        }
        guard heatmapCells.contains(where: { $0.meanMagnitudeUT != nil && $0.meanVerticalUT != nil && $0.meanHorizontalUT != nil }) else {
            statusText = "Heatmap needs horizontal magnetic means"
            return
        }

        isRunning = true
        isRuntimeStarted = false
        statusText = "Debug AR starting · capture alignment points"
        trackingStatus = "starting"
        latestRawTruthMapPoint = nil
        latestTruthMapPoint = nil
        latestDebugFileURL = nil
        alignmentPairs.removeAll(keepingCapacity: true)
        transform = nil
        latestARPoint = nil
        latestARTimestamp = nil
        startAnchorAR = nil
        truthSampleCount = 0
        runtimeEstimate = nil
        runtimeParticles = []
        detectedSteps = 0
        applePedometerSteps = 0
        rejectedStepCandidateCount = 0
        runtimeController = nil

        do {
            let debugWriter = try TwoDRuntimeDebugWriter(bundle: bundle, observationMode: observationMode, entrance: entrance)
            writer = debugWriter
            latestDebugFileURL = debugWriter.fileURL
        } catch {
            isRunning = false
            statusText = "Could not create debug log: \(error.localizedDescription)"
            return
        }

        arRecorder.onPose = { [weak self] pose in
            Task { @MainActor [weak self] in
                self?.handlePose(pose)
            }
        }
        arRecorder.onUnavailable = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.statusText = reason
                self?.trackingStatus = "unavailable"
                self?.stop(reason: "ar_unavailable")
            }
        }
        arRecorder.start()
    }

    func stop(reason: String = "stopped") {
        guard isRunning else { return }
        let finalDetectedSteps = detectedSteps
        runtimeController?.stop()
        runtimeController = nil
        arRecorder.stop()
        writer?.writeEnd(reason: reason, sampleCount: truthSampleCount, detectedSteps: finalDetectedSteps)
        writer?.close()
        writer = nil
        isRunning = false
        isRuntimeStarted = false
        trackingStatus = "off"
        statusText = "Stopped debug run · \(latestDebugFileURL?.lastPathComponent ?? "saved")"
    }

    func captureNextAlignmentPoint() {
        guard isRunning else { return }
        guard let ar = latestARPoint else {
            statusText = "No AR pose yet"
            return
        }
        guard let alignmentPoint = nextAlignmentPoint else {
            statusText = "All alignment points captured"
            return
        }

        let pair = ARMapAlignmentPair2D(ar: ar, map: alignmentPoint.point)
        alignmentPairs.append(pair)
        writer?.writeAlignment(name: alignmentPoint.name, pair: pair)
        if alignmentPairs.count >= 2, transform == nil {
            do {
                let t = try ARMapTransform2D.fromTwoPointAlignment(alignmentPairs[0], alignmentPairs[1])
                transform = t
                writer?.writeTransform(t)
                statusText = "Aligned · walk to \(entrance.name), then anchor start"
            } catch {
                statusText = error.localizedDescription
            }
        } else {
            statusText = "Captured \(alignmentPoint.name)"
        }
    }

    func anchorAndStartRuntime() {
        guard isRunning, !isRuntimeStarted else { return }
        guard let transform else {
            statusText = "Capture alignment points first"
            return
        }
        guard let ar = latestARPoint else {
            statusText = "No AR pose yet"
            return
        }

        startAnchorAR = ar
        let rawMap = transform.mapPoint(for: ar)
        let residual = hypot(rawMap.x - entrance.point.x, rawMap.y - entrance.point.y)
        latestRawTruthMapPoint = rawMap
        latestTruthMapPoint = entrance.point
        writer?.writeStartAnchor(
            timestamp: latestARTimestamp ?? ProcessInfo.processInfo.systemUptime,
            entrance: entrance,
            ar: ar,
            rawMap: rawMap,
            residualMeters: residual
        )

        let runtime = TwoDRuntimeController(
            map: map,
            heatmapCells: heatmapCells,
            observationMode: observationMode,
            debugWriter: writer
        )
        runtimeController = runtime
        runtime.start(at: entrance)
        isRuntimeStarted = runtime.isRunning
        syncRuntimeState()
        statusText = runtime.isRunning
            ? "Debug runtime tracking from \(entrance.name)"
            : runtime.statusText
    }

    private func handlePose(_ pose: ARPoseRecorder.Pose) {
        latestARPoint = ARPoint2D(x: pose.x, z: pose.z)
        latestARTimestamp = pose.t
        trackingStatus = pose.tracking

        let rawMap = transform?.mapPoint(for: ARPoint2D(x: pose.x, z: pose.z))
        let anchoredMap: MapPoint2D?
        if let transform, let startAnchorAR {
            anchoredMap = transform.anchoredMapPoint(
                for: ARPoint2D(x: pose.x, z: pose.z),
                anchorAR: startAnchorAR,
                anchorMap: entrance.point
            )
        } else {
            anchoredMap = nil
        }
        latestRawTruthMapPoint = rawMap
        latestTruthMapPoint = anchoredMap
        syncRuntimeState()
        truthSampleCount += 1
        writer?.writeTruth(pose: pose, rawMap: rawMap, anchoredMap: anchoredMap)
    }

    private func syncRuntimeState() {
        guard let runtimeController else { return }
        runtimeEstimate = runtimeController.estimate
        runtimeParticles = runtimeController.particleSnapshot
        detectedSteps = runtimeController.detectedSteps
        applePedometerSteps = runtimeController.applePedometerSteps
        rejectedStepCandidateCount = runtimeController.rejectedStepCandidateCount
    }
}
