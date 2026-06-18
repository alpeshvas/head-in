import ARKit
import AVFoundation
import Foundation

/// Surveyor-only ground-truth recorder. Runs an ARKit world-tracking session and
/// forwards the camera's 6-DoF pose (position + euler orientation) plus tracking
/// state at frame rate. ARKit pose is visual-inertial — it requires the camera, so
/// this only ever runs on the surveyor's device, never in the shipped tour runtime.
///
/// ARFrame.timestamp shares the same system-uptime clock as CMDeviceMotion.timestamp,
/// so poses align with the sensor streams without extra bookkeeping.
final class ARPoseRecorder: NSObject, ARSessionDelegate {
    struct Pose {
        let t: TimeInterval
        let x: Double
        let y: Double
        let z: Double
        let pitch: Double
        let yaw: Double
        let roll: Double
        let tracking: String
    }

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var onPose: ((Pose) -> Void)?
    /// Fired once if ground truth cannot start (camera denied, unsupported, etc.).
    var onUnavailable: ((String) -> Void)?

    private let session = ARSession()
    private let delegateQueue = DispatchQueue(label: "ar-pose-recorder")
    private var started = false

    func start() {
        guard Self.isSupported else {
            onUnavailable?("AR world tracking not supported on this device")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.run()
                } else {
                    self.onUnavailable?("Camera access denied")
                }
            }
        case .denied, .restricted:
            onUnavailable?("Camera access denied")
        @unknown default:
            onUnavailable?("Camera access unavailable")
        }
    }

    func stop() {
        guard started else { return }
        started = false
        session.pause()
        session.delegate = nil
        onPose = nil
        onUnavailable = nil
    }

    private func run() {
        started = true
        session.delegate = self
        session.delegateQueue = delegateQueue
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let camera = frame.camera
        let translation = camera.transform.columns.3
        let euler = camera.eulerAngles
        onPose?(Pose(
            t: frame.timestamp,
            x: Double(translation.x),
            y: Double(translation.y),
            z: Double(translation.z),
            pitch: Double(euler.x),
            yaw: Double(euler.y),
            roll: Double(euler.z),
            tracking: Self.label(for: camera.trackingState)
        ))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onUnavailable?(error.localizedDescription)
    }

    static func label(for state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "normal"
        case .notAvailable:
            return "notAvailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited:initializing"
            case .excessiveMotion: return "limited:excessiveMotion"
            case .insufficientFeatures: return "limited:insufficientFeatures"
            case .relocalizing: return "limited:relocalizing"
            @unknown default: return "limited:unknown"
            }
        }
    }
}
