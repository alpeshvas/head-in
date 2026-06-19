import Foundation
import Observation

/// A surveyed route's identity + the bits a new pass needs to resume it. The
/// registry is the durable address book of routes: it survives offloading and
/// deleting the raw recordings (a route does not vanish just because its
/// `.jsonl` passes were pulled off the phone). Persisted as `routes.json`.
struct RouteRecord: Codable, Identifiable, Hashable {
    var venueId: String
    var routeId: String
    var floorId: String
    /// Most recent known checkpoint order (predefined tap-through reuses this).
    var checkpoints: [String]
    var lastDirection: String   // Direction.rawValue
    var lastPose: String        // DevicePose.rawValue
    var createdAt: Date
    var updatedAt: Date

    var id: String { "\(venueId)\u{1}\(routeId)" }

    var direction: Direction { Direction(rawValue: lastDirection) ?? .forward }
    var pose: DevicePose { DevicePose(rawValue: lastPose) ?? .hand }
}

/// One recorded pass on disk, parsed cheaply from its filename
/// (`safeVenue_safeRoute_direction_pose_passtype_stamp.jsonl`). Ground truth is
/// the one field not in the name; it's read from the `meta` line on demand.
struct PassFile: Identifiable {
    let url: URL
    let direction: String
    let pose: String
    let passType: String
    let date: Date

    var id: URL { url }
    var fileName: String { url.lastPathComponent }

    var passLabel: String { PassType(rawValue: passType)?.label ?? passType }
    var isNegative: Bool { PassType(rawValue: passType)?.isNegative ?? false }
    var isLive: Bool { passType == PassType.live.rawValue }

    /// Reads `groundTruth` from the file's first (meta) line. Bounded read — the
    /// meta line is the first, small line of an otherwise large stream.
    var hasGroundTruth: Bool {
        (RouteRegistry.meta(of: url)?["groundTruth"] as? Bool) ?? false
    }
}

@Observable
final class RouteRegistry {
    private(set) var records: [RouteRecord] = []

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("routes.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? Self.decoder.decode([RouteRecord].self, from: data) {
            records = decoded
        } else {
            // First launch after the registry shipped: bootstrap from whatever
            // recordings are already on the phone, then persist. After this the
            // registry is authoritative — deletes stick, files vanishing don't
            // re-add routes.
            records = Self.seedFromSessions()
            save()
        }
        sortRecords()
    }

    // MARK: venues grouping

    /// Routes grouped by venue, both alpha-sorted, for the library list.
    var venues: [(venue: String, routes: [RouteRecord])] {
        Dictionary(grouping: records, by: \.venueId)
            .map { (venue: $0.key, routes: $0.value.sorted { $0.routeId < $1.routeId }) }
            .sorted { $0.venue.localizedCaseInsensitiveCompare($1.venue) == .orderedAscending }
    }

    var venueNames: [String] {
        Array(Set(records.map(\.venueId))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    func record(venueId: String, routeId: String) -> RouteRecord? {
        records.first { $0.venueId == venueId && $0.routeId == routeId }
    }

    /// Pass counts for every route from a single directory scan (the library
    /// list would otherwise re-scan once per row on every render).
    func passCounts() -> [RouteRecord.ID: Int] {
        let names = ((try? FileManager.default.contentsOfDirectory(
            at: SessionWriter.sessionsDirectory, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .map(\.lastPathComponent)
        var counts: [RouteRecord.ID: Int] = [:]
        for record in records {
            let prefix = "\(SessionWriter.safeName(record.venueId))_\(SessionWriter.safeName(record.routeId))_"
            counts[record.id] = names.filter { $0.hasPrefix(prefix) }.count
        }
        return counts
    }

    // MARK: mutations

    /// Create or refresh the route for this setup at recording start. Called
    /// before any sensor data is written, so the route is persisted even if the
    /// pass is abandoned. Empty checkpoints (ad-hoc) don't clobber a known list.
    func upsert(from setup: RouteSetup) {
        let now = Date()
        if let i = records.firstIndex(where: {
            $0.venueId == setup.venueId && $0.routeId == setup.routeId
        }) {
            if !setup.checkpoints.isEmpty { records[i].checkpoints = setup.checkpoints }
            if !setup.floorId.isEmpty { records[i].floorId = setup.floorId }
            records[i].lastDirection = setup.direction.rawValue
            records[i].lastPose = setup.devicePose.rawValue
            records[i].updatedAt = now
        } else {
            records.append(RouteRecord(
                venueId: setup.venueId,
                routeId: setup.routeId,
                floorId: setup.floorId,
                checkpoints: setup.checkpoints,
                lastDirection: setup.direction.rawValue,
                lastPose: setup.devicePose.rawValue,
                createdAt: now,
                updatedAt: now
            ))
        }
        sortRecords()
        save()
    }

    /// After an ad-hoc pass, store the names dropped during the walk so later
    /// passes of this route get the fast predefined tap-through.
    func setCheckpoints(_ names: [String], venueId: String, routeId: String) {
        guard names.count >= 2,
              let i = records.firstIndex(where: {
                  $0.venueId == venueId && $0.routeId == routeId
              }) else { return }
        records[i].checkpoints = names
        records[i].updatedAt = Date()
        save()
    }

    func delete(_ record: RouteRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    // MARK: pass files on disk

    /// Recordings belonging to a route, newest first. Matched by the same
    /// filename prefix the writer produces.
    func passes(for record: RouteRecord) -> [PassFile] {
        let prefix = "\(SessionWriter.safeName(record.venueId))_\(SessionWriter.safeName(record.routeId))_"
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: SessionWriter.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix(prefix) }
            .compactMap { Self.parsePass(url: $0, prefix: prefix) }
            .sorted { $0.date > $1.date }
    }

    // MARK: persistence

    private func sortRecords() {
        records.sort { $0.updatedAt > $1.updatedAt }
    }

    private func save() {
        guard let data = try? Self.encoder.encode(records) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: seeding / parsing

    /// One-time bootstrap: read every recording's meta line and fold it into
    /// route records. Newest pass wins for checkpoints/pose/direction.
    static func seedFromSessions() -> [RouteRecord] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: SessionWriter.sessionsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var byKey: [String: RouteRecord] = [:]
        for url in urls where url.pathExtension == "jsonl" {
            guard let meta = meta(of: url),
                  let venueId = meta["venueId"] as? String, !venueId.isEmpty,
                  let routeId = meta["routeId"] as? String, !routeId.isEmpty
            else { continue }
            let started = (meta["startedAtUnix"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let checkpoints = meta["checkpoints"] as? [String] ?? []
            let direction = meta["direction"] as? String ?? Direction.forward.rawValue
            let pose = meta["devicePose"] as? String ?? DevicePose.hand.rawValue
            let floorId = meta["floorId"] as? String ?? ""
            let key = "\(venueId)\u{1}\(routeId)"

            if var existing = byKey[key] {
                existing.createdAt = min(existing.createdAt, started)
                if started >= existing.updatedAt {
                    existing.updatedAt = started
                    if !checkpoints.isEmpty { existing.checkpoints = checkpoints }
                    existing.lastDirection = direction
                    existing.lastPose = pose
                    if !floorId.isEmpty { existing.floorId = floorId }
                }
                byKey[key] = existing
            } else {
                byKey[key] = RouteRecord(
                    venueId: venueId, routeId: routeId, floorId: floorId,
                    checkpoints: checkpoints, lastDirection: direction, lastPose: pose,
                    createdAt: started, updatedAt: started
                )
            }
        }
        return Array(byKey.values)
    }

    /// Splits the fixed `direction_pose_passtype_stamp` tail off a filename whose
    /// route prefix is already known. The tail tokens come from closed enums and
    /// a no-underscore timestamp, so a 4-way split is unambiguous.
    private static func parsePass(url: URL, prefix: String) -> PassFile? {
        let base = url.deletingPathExtension().lastPathComponent
        guard base.hasPrefix(prefix) else { return nil }
        let tail = String(base.dropFirst(prefix.count)).split(separator: "_").map(String.init)
        guard tail.count == 4 else { return nil }
        let date = stampFormatter.date(from: tail[3])
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
        return PassFile(url: url, direction: tail[0], pose: tail[1], passType: tail[2], date: date)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Reads and parses just the first line (the `meta` object) of a session
    /// file without loading the whole stream.
    static func meta(of url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 16 * 1024),
              let newline = chunk.firstIndex(of: 0x0A) else { return nil }
        let lineData = chunk.subdata(in: chunk.startIndex..<newline)
        return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
    }
}
