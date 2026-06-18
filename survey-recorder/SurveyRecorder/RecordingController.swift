import CoreMotion
import Foundation
import Observation
import UIKit

/// Owns one recording session: wires SensorRecorder output into the SessionWriter
/// and exposes throttled live stats for the record screen.
@Observable
final class RecordingController {
    let setup: RouteSetup
    let fileURL: URL
    let startedAt = Date()

    private(set) var deviceMotionCount = 0
    private(set) var rawMagCount = 0
    private(set) var steps = 0
    private(set) var magneticMagnitude = 0.0
    private(set) var magneticAccuracy = CMMagneticFieldCalibrationAccuracy.uncalibrated
    private(set) var nextAnchorIndex = 0
    private(set) var anchorCount = 0
    /// Names actually anchored, in order. In predefined mode this tracks the
    /// setup list; in ad-hoc mode (empty setup list) it grows as you drop.
    private(set) var recordedCheckpoints: [String]
    let deviceMotionAvailable: Bool

    /// No checkpoints listed at setup → name them while surveying.
    var isAdHoc: Bool { setup.checkpoints.isEmpty }

    // Ground-truth (ARKit) state — only meaningful when groundTruthEnabled.
    let groundTruthEnabled: Bool
    private(set) var arPoseCount = 0
    private(set) var arTrackingLabel = "starting"
    private(set) var groundTruthStatus: String

    private let writer: SessionWriter
    private let recorder = SensorRecorder()
    private let poseRecorder = ARPoseRecorder()
    private var stopped = false

    init(setup: RouteSetup) throws {
        self.setup = setup
        recordedCheckpoints = setup.checkpoints
        writer = try SessionWriter(setup: setup)
        fileURL = writer.fileURL
        deviceMotionAvailable = recorder.isDeviceMotionAvailable
        groundTruthEnabled = setup.recordGroundTruth && ARPoseRecorder.isSupported
        groundTruthStatus = setup.recordGroundTruth
            ? (ARPoseRecorder.isSupported ? "starting" : "unsupported")
            : "off"

        recorder.onDeviceMotion = { [weak self] dm in
            guard let self else { return }
            let mag = dm.magneticField
            writer.writeLine([
                "type": "dm",
                "t": jsonRound(dm.timestamp),
                "q": [
                    "w": jsonRound(dm.attitude.quaternion.w, 5),
                    "x": jsonRound(dm.attitude.quaternion.x, 5),
                    "y": jsonRound(dm.attitude.quaternion.y, 5),
                    "z": jsonRound(dm.attitude.quaternion.z, 5),
                ],
                "rot": [
                    "x": jsonRound(dm.rotationRate.x),
                    "y": jsonRound(dm.rotationRate.y),
                    "z": jsonRound(dm.rotationRate.z),
                ],
                "ua": [
                    "x": jsonRound(dm.userAcceleration.x),
                    "y": jsonRound(dm.userAcceleration.y),
                    "z": jsonRound(dm.userAcceleration.z),
                ],
                "g": [
                    "x": jsonRound(dm.gravity.x),
                    "y": jsonRound(dm.gravity.y),
                    "z": jsonRound(dm.gravity.z),
                ],
                "mag": [
                    "x": jsonRound(mag.field.x, 3),
                    "y": jsonRound(mag.field.y, 3),
                    "z": jsonRound(mag.field.z, 3),
                    "acc": mag.accuracy.rawValue,
                ],
            ])

            // Throttle UI updates to ~10Hz; writing happens at full rate above.
            let count = self.deviceMotionCount + 1
            if count % 10 == 0 {
                let magnitude = (mag.field.x * mag.field.x + mag.field.y * mag.field.y + mag.field.z * mag.field.z).squareRoot()
                Task { @MainActor in
                    self.deviceMotionCount = count
                    self.magneticMagnitude = magnitude
                    self.magneticAccuracy = mag.accuracy
                }
            } else {
                Task { @MainActor in self.deviceMotionCount = count }
            }
        }

        recorder.onMagnetometer = { [weak self] data in
            guard let self else { return }
            writer.writeLine([
                "type": "mag",
                "t": jsonRound(data.timestamp),
                "x": jsonRound(data.magneticField.x, 3),
                "y": jsonRound(data.magneticField.y, 3),
                "z": jsonRound(data.magneticField.z, 3),
            ])
            let count = self.rawMagCount + 1
            Task { @MainActor in self.rawMagCount = count }
        }

        recorder.onPedometer = { [weak self] data in
            guard let self else { return }
            var line: [String: Any] = [
                "type": "step",
                "t": ProcessInfo.processInfo.systemUptime,
                "steps": data.numberOfSteps.intValue,
            ]
            if let distance = data.distance { line["distance"] = jsonRound(distance.doubleValue, 2) }
            if let cadence = data.currentCadence { line["cadence"] = jsonRound(cadence.doubleValue, 2) }
            writer.writeLine(line)
            let steps = data.numberOfSteps.intValue
            Task { @MainActor in self.steps = steps }
        }

        recorder.onAltimeter = { [weak self] data in
            self?.writer.writeLine([
                "type": "baro",
                "t": jsonRound(data.timestamp),
                "relAlt": jsonRound(data.relativeAltitude.doubleValue, 3),
                "pressure": jsonRound(data.pressure.doubleValue, 4),
            ])
        }

        if groundTruthEnabled {
            poseRecorder.onPose = { [weak self] pose in
                guard let self else { return }
                writer.writeLine([
                    "type": "arpose",
                    "t": jsonRound(pose.t),
                    "p": [
                        "x": jsonRound(pose.x, 4),
                        "y": jsonRound(pose.y, 4),
                        "z": jsonRound(pose.z, 4),
                    ],
                    "e": [
                        "pitch": jsonRound(pose.pitch, 4),
                        "yaw": jsonRound(pose.yaw, 4),
                        "roll": jsonRound(pose.roll, 4),
                    ],
                    "track": pose.tracking,
                ])
                let count = self.arPoseCount + 1
                let tracking = pose.tracking
                Task { @MainActor in
                    self.arPoseCount = count
                    self.arTrackingLabel = tracking
                    self.groundTruthStatus = tracking == "normal" ? "tracking" : tracking
                }
            }
            poseRecorder.onUnavailable = { [weak self] reason in
                guard let self else { return }
                writer.writeLine(["type": "arpose_unavailable", "reason": reason])
                Task { @MainActor in self.groundTruthStatus = reason }
            }
            poseRecorder.start()
        }

        recorder.start()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var nextCheckpointName: String? {
        guard nextAnchorIndex < setup.checkpoints.count else { return nil }
        return setup.checkpoints[nextAnchorIndex]
    }

    func tapAnchor() {
        guard let name = nextCheckpointName else { return }
        writeAnchor(name: name)
    }

    /// Ad-hoc mode: drop a checkpoint at the current instant. `pendingName` is
    /// typed while walking up to the spot, so the tap is the precise arrival
    /// time; empty falls back to an auto name that can be renamed offline.
    func dropCheckpoint(pendingName: String) {
        let trimmed = pendingName.trimmingCharacters(in: .whitespaces)
        writeAnchor(name: trimmed.isEmpty ? "Checkpoint \(anchorCount + 1)" : trimmed)
    }

    private func writeAnchor(name: String) {
        writer.writeLine([
            "type": "anchor",
            "t": ProcessInfo.processInfo.systemUptime,
            "index": nextAnchorIndex,
            "name": name,
        ])
        writer.flush()
        if isAdHoc { recordedCheckpoints.append(name) }
        anchorCount += 1
        nextAnchorIndex += 1
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    func undoAnchor() {
        guard nextAnchorIndex > 0 else { return }
        nextAnchorIndex -= 1
        anchorCount -= 1
        if isAdHoc, !recordedCheckpoints.isEmpty { recordedCheckpoints.removeLast() }
        // Append-only log: downstream tooling drops the matching anchor on undo.
        writer.writeLine([
            "type": "anchor_undo",
            "t": ProcessInfo.processInfo.systemUptime,
            "index": nextAnchorIndex,
        ])
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        recorder.stop()
        poseRecorder.stop()
        writer.writeLine([
            "type": "end",
            "t": ProcessInfo.processInfo.systemUptime,
            "deviceMotionSamples": deviceMotionCount,
            "rawMagSamples": rawMagCount,
            "arPoseSamples": arPoseCount,
            "anchors": anchorCount,
            "steps": steps,
            "checkpoints": recordedCheckpoints,
        ])
        writer.close()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
