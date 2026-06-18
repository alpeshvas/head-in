import Foundation

final class TwoDSurveyWriter {
    let fileURL: URL

    private let queue = DispatchQueue(label: "two-d-survey-writer")
    private let handle: FileHandle
    private var buffer = Data()
    private static let flushThreshold = 16 * 1024

    init(map: VenueMap2D) throws {
        let dir = SessionWriter.sessionsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let safeVenue = map.venueId.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        fileURL = dir.appendingPathComponent("\(safeVenue)_2d-survey_\(stamp).jsonl")

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)

        writeLine([
            "type": "meta",
            "schema": 1,
            "mode": "2dSurvey",
            "venueId": map.venueId,
            "venueName": map.name,
            "widthMeters": jsonRound(map.widthMeters, 3),
            "heightMeters": jsonRound(map.heightMeters, 3),
            "rooms": map.rooms.map { ["id": $0.id, "name": $0.name] },
            "startedAtUnix": Date().timeIntervalSince1970,
            "deviceModel": DeviceInfo.modelIdentifier,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }

    func writeAlignment(name: String, pair: ARMapAlignmentPair2D) {
        writeLine([
            "type": "alignment",
            "name": name,
            "ar": ["x": jsonRound(pair.ar.x, 4), "z": jsonRound(pair.ar.z, 4)],
            "map": ["x": jsonRound(pair.map.x, 4), "y": jsonRound(pair.map.y, 4)],
        ])
    }

    func writeTransform(_ transform: ARMapTransform2D) {
        writeLine([
            "type": "map_transform",
            "scale": jsonRound(transform.scale, 6),
            "rotationRadians": jsonRound(transform.rotationRadians, 6),
            "translation": ["x": jsonRound(transform.translation.x, 4), "y": jsonRound(transform.translation.y, 4)],
        ])
    }

    func writeSample(_ sample: SurveySample2D) {
        var line: [String: Any] = [
            "type": "sample2d",
            "t": jsonRound(sample.timestamp),
            "ar": ["x": jsonRound(sample.arPoint.x, 4), "z": jsonRound(sample.arPoint.z, 4)],
            "map": ["x": jsonRound(sample.mapPoint.x, 4), "y": jsonRound(sample.mapPoint.y, 4)],
            "mag": [
                "magnitudeUT": jsonRound(sample.magnetic.magnitudeUT, 4),
                "verticalUT": jsonRound(sample.magnetic.verticalUT, 4),
                "acc": sample.magnetic.accuracyRawValue,
            ],
        ]
        if let roomId = sample.roomId { line["roomId"] = roomId }
        writeLine(line)
    }

    func writeEnd(sampleCount: Int) {
        writeLine([
            "type": "end",
            "sampleCount": sampleCount,
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
}
