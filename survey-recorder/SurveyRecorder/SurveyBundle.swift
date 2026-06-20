import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// A self-contained `.survey-bundle.jsonl` archive that carries everything needed
/// to restore survey state on another device/install: the venue-map bundle (with
/// heatmap cells), the floor-plan image asset, the route registry, and every
/// recorded session file — all in one JSONL stream.
///
/// Format (`bundleSchema: 1`), one JSON object per line:
///  1. `bundle_meta`   — `{type, bundleSchema, exportedAtUnix, deviceModel,
///                       systemVersion, sessionCount, mapIncluded, mapImageIncluded,
///                       routesIncluded, venueId?}`
///  2. `bundle_map`    — `{type, mapSchema, bundle: {schema, map, heatmapCells}}`
///                       (only if a map is available)
///  3. `bundle_map_image` — `{type, fileName, mediaType, dataBase64}`
///                       (only if a floor-plan image asset exists)
///  4. `bundle_routes` — `{type, routes: [RouteRecord, ...]}` (only if routes.json
///                       exists)
///  5. For each session, in order:
///     `bundle_session_begin` — `{type, filename, byteSize}`
///     ... original session lines, copied verbatim ...
///     `bundle_session_end`   — `{type, filename, lineCount}`
///  6. `bundle_end`    — `{type, sessionCount, totalLines, endedAtUnix}`
///
/// Session lines are copied byte-for-byte so existing analysis tooling keeps
/// working and a re-import round-trips losslessly. `bundle_session_begin`/`end`
/// bracket each session because session lines carry heterogeneous `type` values
/// (`meta`, `sample2d`, `motion`, `filter`, ...) and cannot be self-delimiting.
enum SurveyBundle {
    static let bundleSchema = 1
    static let fileExtension = "survey-bundle.jsonl"

    /// Filename-safe form of a venue id, matching `SessionWriter.safeName`.
    static func safeName(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    /// Builds a bundle file in a temporary directory and returns its URL.
    /// The caller owns the returned URL (typically handed to a share sheet).
    static func exportBundle() throws -> URL {
        let bundle = VenueMap2DStore.loadSavedOrBundled()
        let sessionsDir = SessionWriter.sessionsDirectory
        let sessionURLs = ((try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let venueTag = safeName(bundle.map.venueId)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(venueTag)_bundle_\(stamp).\(fileExtension)")

        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        let writer = LineWriter(handle: handle)

        // 1. bundle_meta
        var meta: [String: Any] = [
            "type": "bundle_meta",
            "bundleSchema": bundleSchema,
            "exportedAtUnix": Date().timeIntervalSince1970,
            "deviceModel": DeviceInfo.modelIdentifier,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "sessionCount": sessionURLs.count,
            "mapIncluded": true,
            "mapImageIncluded": false,
            "routesIncluded": routeRegistryURLExists(),
        ]
        meta["venueId"] = bundle.map.venueId
        writer.write(jsonObject: meta)

        // 2. bundle_map
        if let mapObject = encodableObject(bundle) {
            writer.write(jsonObject: [
                "type": "bundle_map",
                "mapSchema": bundle.schema,
                "bundle": mapObject,
            ])
        }

        // 3. bundle_map_image (embed the referenced floor-plan image, if present)
        if let imageRef = bundle.map.image,
           let imageBytes = try? Data(contentsOf: VenueMap2DStore.venueMapsDirectory.appendingPathComponent(imageRef.fileName)),
           !imageBytes.isEmpty {
            writer.write(jsonObject: [
                "type": "bundle_map_image",
                "fileName": imageRef.fileName,
                "mediaType": imageMediaType(for: imageRef.fileName),
                "dataBase64": imageBytes.base64EncodedString(),
            ])
        }

        // 4. bundle_routes
        if let routesURL = currentRouteRegistryURL(),
           let routesData = try? Data(contentsOf: routesURL),
           let routesObject = try? JSONSerialization.jsonObject(with: routesData) {
            writer.write(jsonObject: [
                "type": "bundle_routes",
                "routes": routesObject,
            ])
        }

        // 5. sessions, verbatim
        var totalLines = 0
        for sessionURL in sessionURLs {
            let byteSize = (try? sessionURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            writer.write(jsonObject: [
                "type": "bundle_session_begin",
                "filename": sessionURL.lastPathComponent,
                "byteSize": byteSize,
            ])
            let lineCount = copyLinesVerbatim(from: sessionURL, to: writer)
            writer.write(jsonObject: [
                "type": "bundle_session_end",
                "filename": sessionURL.lastPathComponent,
                "lineCount": lineCount,
            ])
            totalLines += lineCount
        }

        // 6. bundle_end
        writer.write(jsonObject: [
            "type": "bundle_end",
            "sessionCount": sessionURLs.count,
            "totalLines": totalLines,
            "endedAtUnix": Date().timeIntervalSince1970,
        ])

        try writer.flush()
        return tempURL
    }

    /// Restores a bundle from a (possibly security-scoped) URL into Documents.
    /// Overwrites the current venue map, image, and route registry; sessions are
    /// written alongside existing ones with collision-safe names.
    static func importBundle(from sourceURL: URL) throws -> SurveyBundleSummary {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { sourceURL.stopAccessingSecurityScopedResource() }
        }

        guard let handle = try? FileHandle(forReadingFrom: sourceURL) else {
            throw SurveyBundleError.couldNotRead(sourceURL.lastPathComponent)
        }
        defer { try? handle.close() }

        var summary = SurveyBundleSummary()
        var sawMeta = false
        var pendingMap: VenueMapBundle2D?
        var sessionWriter: LineWriter?
        var currentSessionFilename: String?
        var currentSessionLineCount = 0
        let sessionsDir = SessionWriter.sessionsDirectory
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        var lineIterator = LineIterator(handle: handle)
        while let line = lineIterator.next() {
            // Preserve the raw bytes for verbatim re-emission to session files.
            guard let rawString = String(data: line, encoding: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = json["type"] as? String else {
                // Not one of our envelope lines → belongs to the open session.
                if let writer = sessionWriter {
                    writer.writeRaw(rawString + "\n")
                    currentSessionLineCount += 1
                }
                continue
            }

            switch type {
            case "bundle_meta":
                sawMeta = true
                let schema = json["bundleSchema"] as? Int ?? 0
                guard schema == bundleSchema else {
                    throw SurveyBundleError.unsupportedBundleSchema(schema)
                }

            case "bundle_map":
                if let bundleObject = json["bundle"] {
                    let data = try JSONSerialization.data(withJSONObject: bundleObject)
                    pendingMap = try JSONDecoder().decode(VenueMapBundle2D.self, from: data)
                }

            case "bundle_map_image":
                if let fileName = json["fileName"] as? String,
                   let base64 = json["dataBase64"] as? String,
                   let imageBytes = Data(base64Encoded: base64) {
                    try FileManager.default.createDirectory(
                        at: VenueMap2DStore.venueMapsDirectory, withIntermediateDirectories: true)
                    let dest = VenueMap2DStore.venueMapsDirectory.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try imageBytes.write(to: dest, options: .atomic)
                    summary.imageRestored = true
                    summary.imageFileName = fileName
                }

            case "bundle_routes":
                if let routesObject = json["routes"] {
                    try restoreRoutes(routesObject)
                    summary.routesRestored = true
                }

            case "bundle_session_begin":
                if let writer = sessionWriter {
                    try writer.flush()
                    sessionWriter = nil
                }
                let filename = json["filename"] as? String ?? "restored_\(Date().timeIntervalSince1970).jsonl"
                let dest = uniqueSessionURL(for: filename, in: sessionsDir)
                currentSessionFilename = dest.lastPathComponent
                currentSessionLineCount = 0
                FileManager.default.createFile(atPath: dest.path, contents: nil)
                sessionWriter = LineWriter(handle: try FileHandle(forWritingTo: dest))

            case "bundle_session_end":
                if let writer = sessionWriter {
                    try writer.flush()
                    sessionWriter = nil
                }
                if currentSessionFilename != nil {
                    summary.sessionsRestored += 1
                    summary.sessionLineCount += currentSessionLineCount
                }
                currentSessionFilename = nil
                currentSessionLineCount = 0

            case "bundle_end":
                if let writer = sessionWriter { try writer.flush(); sessionWriter = nil }

            default:
                // An original session line: re-emit verbatim to the open session file.
                if let writer = sessionWriter {
                    writer.writeRaw(rawString + "\n")
                    currentSessionLineCount += 1
                }
            }
        }

        if let writer = sessionWriter { try writer.flush(); sessionWriter = nil }

        guard sawMeta else { throw SurveyBundleError.notABundle }
        if let pendingMap {
            // Patch the image reference to whatever we restored (or kept).
            var restored = pendingMap
            if summary.imageRestored, let fileName = summary.imageFileName {
                let size = imageSize(at: VenueMap2DStore.venueMapsDirectory.appendingPathComponent(fileName))
                restored.map.image = VenueMapImage2D(
                    fileName: fileName,
                    widthPixels: Double(size?.width ?? pendingMap.map.image?.widthPixels ?? 0),
                    heightPixels: Double(size?.height ?? pendingMap.map.image?.heightPixels ?? 0)
                )
            }
            try VenueMap2DStore.save(restored)
            summary.mapRestored = true
            summary.venueId = restored.map.venueId
        }

        return summary
    }

    // MARK: - helpers

    private static func copyLinesVerbatim(from sourceURL: URL, to writer: LineWriter) -> Int {
        guard let readHandle = try? FileHandle(forReadingFrom: sourceURL) else { return 0 }
        defer { try? readHandle.close() }
        var count = 0
        var iterator = LineIterator(handle: readHandle)
        while let line = iterator.next() {
            if let raw = String(data: line, encoding: .utf8) {
                writer.writeRaw(raw + "\n")
                count += 1
            }
        }
        return count
    }

    /// Returns a non-colliding URL in `sessionsDir` for `filename`. If a file with
    /// the same name exists, inserts `_<n>` before the extension.
    private static func uniqueSessionURL(for filename: String, in sessionsDir: URL) -> URL {
        let proposed = sessionsDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: proposed.path) else { return proposed }
        let nsName = filename as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty
                ? "\(stem)_\(n)"
                : "\(stem)_\(n).\(ext)"
            let url = sessionsDir.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private static func restoreRoutes(_ routesObject: Any) throws {
        let incomingData = try JSONSerialization.data(withJSONObject: routesObject)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming = (try? decoder.decode([RouteRecord].self, from: incomingData)) ?? []

        let existingURL = currentRouteRegistryURL()
        var merged: [RouteRecord] = []
        if let url = existingURL,
           let existingData = try? Data(contentsOf: url),
           let existing = try? decoder.decode([RouteRecord].self, from: existingData) {
            merged = existing
        }

        var byID = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        for record in incoming {
            if let existing = byID[record.id] {
                // Keep the union; newer updatedAt wins, earliest createdAt wins.
                var combined = record
                combined.createdAt = min(existing.createdAt, record.createdAt)
                combined.updatedAt = max(existing.updatedAt, record.updatedAt)
                if combined.checkpoints.isEmpty { combined.checkpoints = existing.checkpoints }
                byID[record.id] = combined
            } else {
                byID[record.id] = record
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let out = try encoder.encode(Array(byID.values))
        try out.write(to: routeRegistryURL(), options: .atomic)
    }

    private static func routeRegistryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("routes.json")
    }

    private static func currentRouteRegistryURL() -> URL? {
        let url = routeRegistryURL()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func routeRegistryURLExists() -> Bool {
        currentRouteRegistryURL() != nil
    }

    private static func imageMediaType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }

    private static func imageSize(at url: URL) -> CGSize? {
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image.size
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.size
        #else
        return nil
        #endif
    }

    private static func encodableObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

struct SurveyBundleSummary {
    var mapRestored = false
    var imageRestored = false
    var imageFileName: String?
    var routesRestored = false
    var sessionsRestored = 0
    var sessionLineCount = 0
    var venueId: String?

    var description: String {
        var parts: [String] = []
        if mapRestored { parts.append("map\(venueId.map { " (\($0))" } ?? "")") }
        if imageRestored { parts.append("floor-plan image") }
        if routesRestored { parts.append("routes") }
        if sessionsRestored > 0 {
            parts.append("\(sessionsRestored) session\(sessionsRestored == 1 ? "" : "s") (\(sessionLineCount) lines)")
        }
        if parts.isEmpty { return "Bundle was empty." }
        return "Restored " + parts.joined(separator: ", ") + "."
    }
}

enum SurveyBundleError: LocalizedError {
    case notABundle
    case unsupportedBundleSchema(Int)
    case couldNotRead(String)

    var errorDescription: String? {
        switch self {
        case .notABundle:
            return "This file is not a survey bundle (missing bundle_meta)."
        case .unsupportedBundleSchema(let schema):
            return "Unsupported survey bundle schema \(schema). Update the app."
        case .couldNotRead(let name):
            return "Could not read bundle file \(name)."
        }
    }
}

/// Serializes envelope lines as compact JSON and writes raw strings verbatim,
/// buffering through a FileHandle.
private final class LineWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private static let flushThreshold = 16 * 1024

    init(handle: FileHandle) { self.handle = handle }

    func write(jsonObject object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        buffer.append(data)
        buffer.append(0x0A)
        if buffer.count > Self.flushThreshold { flushLocked() }
    }

    /// Writes `raw` exactly, without re-serializing. Used for verbatim session
    /// line copies (preserves key ordering and number formatting of the source).
    func writeRaw(_ raw: String) {
        guard let data = raw.data(using: .utf8) else { return }
        buffer.append(data)
        if buffer.count > Self.flushThreshold { flushLocked() }
    }

    func flush() throws {
        flushLocked()
    }

    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Iterates JSONL lines from a FileHandle as `Data` chunks (one per line, without
/// the trailing newline), streaming so large session files don't load in full.
private struct LineIterator: IteratorProtocol {
    private let handle: FileHandle
    private var buffer = Data()
    private var atEOF = false

    init(handle: FileHandle) { self.handle = handle }

    mutating func next() -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer = buffer.subdata(in: buffer.index(after: nl)..<buffer.endIndex)
                return line
            }
            if atEOF {
                if buffer.isEmpty { return nil }
                let rest = buffer
                buffer = Data()
                return rest
            }
            let chunk = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if chunk.isEmpty { atEOF = true } else { buffer.append(chunk) }
        }
    }
}
