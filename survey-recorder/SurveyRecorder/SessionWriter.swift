import Foundation

/// Streams JSONL lines to a session file. One JSON object per line, see docs/research-notes.md
/// for the sample schema. Thread-safe: all writes funnel through a serial queue.
final class SessionWriter {
    let fileURL: URL

    private let queue = DispatchQueue(label: "session-writer")
    private let handle: FileHandle
    private var buffer = Data()
    private static let flushThreshold = 16 * 1024

    static var sessionsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Filename-safe form of a venue/route id. Keeps the same character class as
    /// the recorded filenames so the route library can match files back to a
    /// route by `safeName(venue)_safeName(route)_` prefix.
    static func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    init(setup: RouteSetup) throws {
        let dir = Self.sessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())

        let safe = Self.safeName
        let name = "\(safe(setup.venueId))_\(safe(setup.routeId))_\(setup.direction.rawValue)_\(setup.devicePose.rawValue)_\(setup.passType.rawValue)_\(stamp).jsonl"
        fileURL = dir.appendingPathComponent(name)

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)

        // Sensor callbacks report time since boot; this offset maps them back to wall clock.
        let bootToUnixOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
        var meta: [String: Any] = [
            "type": "meta",
            "schema": 2,
            "venueId": setup.venueId,
            "routeId": setup.routeId,
            "floorId": setup.floorId,
            "direction": setup.direction.rawValue,
            "devicePose": setup.devicePose.rawValue,
            "passType": setup.passType.rawValue,
            "groundTruth": setup.recordGroundTruth,
            "checkpoints": setup.checkpoints,
            "deviceModel": DeviceInfo.modelIdentifier,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "startedAtUnix": Date().timeIntervalSince1970,
            "bootToUnixOffset": bootToUnixOffset,
        ]
        if let profileResource = setup.profileResource {
            meta["profileResource"] = profileResource
        }
        writeLine(meta)
    }

    func writeLine(_ object: [String: Any]) {
        queue.async { [self] in
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return }
            buffer.append(data)
            buffer.append(0x0A)
            if buffer.count > Self.flushThreshold {
                flushLocked()
            }
        }
    }

    func flush() {
        queue.async { [self] in flushLocked() }
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
}

/// Rounds to `places` decimals and guards against NaN/Inf, which JSONSerialization rejects.
func jsonRound(_ value: Double, _ places: Int = 4) -> Double {
    guard value.isFinite else { return 0 }
    let p = pow(10.0, Double(places))
    return (value * p).rounded() / p
}
