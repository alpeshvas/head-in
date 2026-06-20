import CoreMotion
import Foundation

final class TwoDRuntimeDebugWriter {
    let fileURL: URL

    private let queue = DispatchQueue(label: "two-d-runtime-debug-writer")
    private let handle: FileHandle
    private var buffer = Data()
    private static let flushThreshold = 32 * 1024

    init(bundle: VenueMapBundle2D, observationMode: ParticleObservationMode2D, entrance: Entrance2D?) throws {
        let dir = SessionWriter.sessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let safeVenue = bundle.map.venueId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        fileURL = dir.appendingPathComponent("\(safeVenue)_2d-runtime-debug_\(stamp).jsonl")

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)

        var meta: [String: Any] = [
            "type": "meta",
            "schema": 1,
            "mode": "2dRuntimeDebug",
            "venueId": bundle.map.venueId,
            "venueName": bundle.map.name,
            "observationMode": observationMode.rawValue,
            "heatmapCellCount": bundle.heatmapCells.count,
            "startedAtUnix": Date().timeIntervalSince1970,
            "bootToUnixOffset": Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime,
            "deviceModel": DeviceInfo.modelIdentifier,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "params": particleFilterParamsObject(),
        ]
        if let entrance {
            meta["startEntrance"] = entranceObject(entrance)
        }
        if let mapPackage = encodableObject(bundle) {
            meta["mapPackage"] = mapPackage
        }
        writeLine(meta)
    }

    func writeAlignment(name: String, pair: ARMapAlignmentPair2D) {
        writeLine([
            "type": "alignment",
            "name": name,
            "ar": arObject(pair.ar),
            "map": pointObject(pair.map),
        ])
    }

    func writeTransform(_ transform: ARMapTransform2D) {
        writeLine([
            "type": "map_transform",
            "scale": jsonRound(transform.scale, 6),
            "rotationRadians": jsonRound(transform.rotationRadians, 6),
            "translation": pointObject(transform.translation),
        ])
    }

    func writeStartAnchor(timestamp: TimeInterval, entrance: Entrance2D, ar: ARPoint2D, rawMap: MapPoint2D, residualMeters: Double) {
        writeLine([
            "type": "start_anchor",
            "t": jsonRound(timestamp),
            "entrance": entranceObject(entrance),
            "map": pointObject(entrance.point),
            "ar": arObject(ar),
            "rawMap": pointObject(rawMap),
            "rawAlignmentResidualMeters": jsonRound(residualMeters, 4),
        ])
    }

    func writeTruth(pose: ARPoseRecorder.Pose, rawMap: MapPoint2D?, anchoredMap: MapPoint2D?) {
        var line: [String: Any] = [
            "type": "truth",
            "t": jsonRound(pose.t),
            "tracking": pose.tracking,
            "ar": [
                "x": jsonRound(pose.x, 4),
                "y": jsonRound(pose.y, 4),
                "z": jsonRound(pose.z, 4),
                "pitch": jsonRound(pose.pitch, 5),
                "yaw": jsonRound(pose.yaw, 5),
                "roll": jsonRound(pose.roll, 5),
            ],
        ]
        if let rawMap { line["rawMap"] = pointObject(rawMap) }
        if let anchoredMap { line["map"] = pointObject(anchoredMap) }
        writeLine(line)
    }

    func writeMotion(_ motion: CMDeviceMotion, feature: MagneticFeature2D?) {
        let ua = motion.userAcceleration
        let gravity = motion.gravity
        let rotation = motion.rotationRate
        let mag = motion.magneticField.field
        var magObject: [String: Any] = [
            "x": jsonRound(mag.x, 4),
            "y": jsonRound(mag.y, 4),
            "z": jsonRound(mag.z, 4),
            "accuracy": Int(motion.magneticField.accuracy.rawValue),
        ]
        if let feature {
            magObject["magnitudeUT"] = jsonRound(feature.magnitudeUT, 4)
            magObject["verticalUT"] = jsonRound(feature.verticalUT, 4)
            magObject["horizontalUT"] = jsonRound(feature.horizontalUT, 4)
        }
        writeLine([
            "type": "motion",
            "t": jsonRound(motion.timestamp),
            "ua": vectorObject(x: ua.x, y: ua.y, z: ua.z),
            "gravity": vectorObject(x: gravity.x, y: gravity.y, z: gravity.z),
            "rotation": vectorObject(x: rotation.x, y: rotation.y, z: rotation.z),
            "mag": magObject,
        ])
    }

    func writePedometer(_ data: CMPedometerData, detectedSteps: Int) {
        writeLine([
            "type": "pedometer",
            "t": jsonRound(ProcessInfo.processInfo.systemUptime),
            "appleSteps": max(0, data.numberOfSteps.intValue),
            "detectedSteps": detectedSteps,
        ])
    }

    func writeStep(index: Int, timestamp: TimeInterval, yawDeltaRadians: Double, appleSteps: Int, rejectedPeaks: Int, stepIntervalSec: Double = 0, medianStepIntervalSec: Double = 0) {
        var line: [String: Any] = [
            "type": "step",
            "t": jsonRound(timestamp),
            "index": index,
            "yawDeltaDeg": jsonRound(yawDeltaRadians * 180 / .pi, 3),
            "appleSteps": appleSteps,
            "rejectedPeaks": rejectedPeaks,
        ]
        if stepIntervalSec > 0 { line["stepIntervalSec"] = jsonRound(stepIntervalSec, 4) }
        if medianStepIntervalSec > 0 { line["medianStepIntervalSec"] = jsonRound(medianStepIntervalSec, 4) }
        writeLine(line)
    }

    func writeRejectedPeak(timestamp: TimeInterval, rejectedPeaks: Int) {
        writeLine([
            "type": "rejected_peak",
            "t": jsonRound(timestamp),
            "rejectedPeaks": rejectedPeaks,
        ])
    }

    func writeFilter(
        timestamp: TimeInterval,
        phase: String,
        estimate: ParticleEstimate2D,
        nearestCellDistance: Double?,
        meanParticleCellDistance: Double?,
        farParticlePercent: Double?,
        magneticResidualUT: Double?,
        turnRecoveryParticleCount: Int,
        particles: [Particle2D]
    ) {
        var line: [String: Any] = [
            "type": "filter",
            "t": jsonRound(timestamp),
            "phase": phase,
            "estimate": [
                "x": jsonRound(estimate.point.x, 4),
                "y": jsonRound(estimate.point.y, 4),
                "radius": jsonRound(estimate.confidenceRadiusMeters, 4),
                "neff": jsonRound(estimate.effectiveParticleCount, 3),
            ],
            "turnRecoveryParticleCount": turnRecoveryParticleCount,
            "particles": sampledParticlesObject(particles),
        ]
        if let roomId = estimate.roomId { line["roomId"] = roomId }
        if let nearestCellDistance { line["nearestCellDistance"] = jsonRound(nearestCellDistance, 4) }
        if let meanParticleCellDistance { line["meanParticleCellDistance"] = jsonRound(meanParticleCellDistance, 4) }
        if let farParticlePercent { line["farParticlePercent"] = jsonRound(farParticlePercent, 3) }
        if let magneticResidualUT { line["magneticResidualUT"] = jsonRound(magneticResidualUT, 4) }
        writeLine(line)
    }

    func writeEnd(reason: String, sampleCount: Int, detectedSteps: Int) {
        writeLine([
            "type": "end",
            "reason": reason,
            "sampleCount": sampleCount,
            "detectedSteps": detectedSteps,
            "endedAtUnix": Date().timeIntervalSince1970,
        ])
    }

    func writeLine(_ object: [String: Any]) {
        queue.async { [self] in
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            buffer.append(data)
            buffer.append(0x0A)
            if buffer.count > Self.flushThreshold { flushLocked() }
        }
    }

    func close() {
        queue.sync { [self] in
            flushLocked()
            try? handle.close()
        }
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func pointObject(_ point: MapPoint2D) -> [String: Any] {
        ["x": jsonRound(point.x, 4), "y": jsonRound(point.y, 4)]
    }

    private func arObject(_ point: ARPoint2D) -> [String: Any] {
        ["x": jsonRound(point.x, 4), "z": jsonRound(point.z, 4)]
    }

    private func vectorObject(x: Double, y: Double, z: Double) -> [String: Any] {
        ["x": jsonRound(x, 6), "y": jsonRound(y, 6), "z": jsonRound(z, 6)]
    }

    private func entranceObject(_ entrance: Entrance2D) -> [String: Any] {
        ["id": entrance.id, "name": entrance.name, "point": pointObject(entrance.point)]
    }

    private func sampledParticlesObject(_ particles: [Particle2D]) -> [[String: Any]] {
        guard !particles.isEmpty else { return [] }
        let stride = max(1, particles.count / 250)
        return particles.enumerated().compactMap { index, particle in
            guard index.isMultiple(of: stride) else { return nil }
            return [
                "x": jsonRound(particle.x, 4),
                "y": jsonRound(particle.y, 4),
                "heading": jsonRound(particle.headingRadians, 5),
                "weight": jsonRound(particle.weight, 8),
            ]
        }
    }

    private func particleFilterParamsObject() -> [String: Any] {
        [
            "particleCount": ParticleFilter2DParams.particleCount,
            "initialRadiusMeters": ParticleFilter2DParams.initialRadiusMeters,
            "stepLengthMeters": ParticleFilter2DParams.stepLengthMeters,
            "stepLengthSigmaMeters": ParticleFilter2DParams.stepLengthSigmaMeters,
            "headingSigmaRadians": ParticleFilter2DParams.headingSigmaRadians,
            "wallPenalty": ParticleFilter2DParams.wallPenalty,
            "outsidePenalty": ParticleFilter2DParams.outsidePenalty,
            "absoluteMagneticSigmaUT": ParticleFilter2DParams.absoluteMagneticSigmaUT,
            "deltaMagneticSigmaUT": ParticleFilter2DParams.deltaMagneticSigmaUT,
            "surveyedCellNoPenaltyDistanceMeters": ParticleFilter2DParams.surveyedCellNoPenaltyDistanceMeters,
            "surveyedCellDistanceSigmaMeters": ParticleFilter2DParams.surveyedCellDistanceSigmaMeters,
            "surveyedCellPenaltyFloor": ParticleFilter2DParams.surveyedCellPenaltyFloor,
            "stepLengthCadenceClampMin": ParticleFilter2DParams.stepLengthCadenceClampMin,
            "stepLengthCadenceClampMax": ParticleFilter2DParams.stepLengthCadenceClampMax,
            "stepLengthTurnShrinkK": ParticleFilter2DParams.stepLengthTurnShrinkK,
            "stepLengthTurnShrinkFloor": ParticleFilter2DParams.stepLengthTurnShrinkFloor,
            "recentStepIntervalWindow": ParticleFilter2DParams.recentStepIntervalWindow,
            "referenceStepIntervalSeconds": ParticleFilter2DParams.referenceStepIntervalSeconds,
            "sessionCadenceClampMin": ParticleFilter2DParams.sessionCadenceClampMin,
            "sessionCadenceClampMax": ParticleFilter2DParams.sessionCadenceClampMax,
            "headingSigmaTurnK": ParticleFilter2DParams.headingSigmaTurnK,
        ]
    }

    private func encodableObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
