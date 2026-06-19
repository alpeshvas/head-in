import CoreMotion
import Foundation

/// Drives Core Motion sampling and forwards readings to callbacks.
/// Callbacks fire on a background OperationQueue, not the main thread.
final class SensorRecorder {
    static let sampleRateHz = 100.0

    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private let altimeter = CMAltimeter()
    private let sensorQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "sensor-recorder"
        return q
    }()

    var onDeviceMotion: ((CMDeviceMotion) -> Void)?
    var onMagnetometer: ((CMMagnetometerData) -> Void)?
    var onPedometer: ((CMPedometerData) -> Void)?
    var onAltimeter: ((CMAltitudeData) -> Void)?

    var isDeviceMotionAvailable: Bool { motion.isDeviceMotionAvailable }

    func start(
        sampleRateHz: Double = SensorRecorder.sampleRateHz,
        includeMagnetometer: Bool = true,
        includePedometer: Bool = true,
        includeAltimeter: Bool = true
    ) {
        let interval = 1.0 / max(1.0, sampleRateHz)

        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = interval
            // Magnetic-north frame so deviceMotion.magneticField carries the calibrated reading.
            motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: sensorQueue) { [weak self] data, _ in
                guard let data else { return }
                self?.onDeviceMotion?(data)
            }
        }

        if includeMagnetometer, motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = interval
            motion.startMagnetometerUpdates(to: sensorQueue) { [weak self] data, _ in
                guard let data else { return }
                self?.onMagnetometer?(data)
            }
        }

        if includePedometer, CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data else { return }
                self?.onPedometer?(data)
            }
        }

        // Barometer is recorded for future use only; floor detection is out of scope (see docs).
        if includeAltimeter, CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: sensorQueue) { [weak self] data, _ in
                guard let data else { return }
                self?.onAltimeter?(data)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        motion.stopMagnetometerUpdates()
        pedometer.stopUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        onDeviceMotion = nil
        onMagnetometer = nil
        onPedometer = nil
        onAltimeter = nil
    }
}
