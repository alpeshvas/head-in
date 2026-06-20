import Foundation

struct MapPoint2D: Codable, Hashable {
    var x: Double
    var y: Double
}

struct Room2D: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var polygon: [MapPoint2D]
}

struct Wall2D: Codable, Identifiable, Hashable {
    var id: String
    var points: [MapPoint2D]
}

struct AlignmentPoint2D: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var point: MapPoint2D
}

struct VenueMapImage2D: Codable, Hashable {
    var fileName: String
    var widthPixels: Double
    var heightPixels: Double
}

struct Entrance2D: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var point: MapPoint2D
}

struct Checkpoint2D: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var message: String
    var point: MapPoint2D
    var roomId: String?
    var audioFileName: String? = nil
}

struct VenueMap2D: Codable, Hashable {
    var venueId: String
    var name: String
    var widthMeters: Double
    var heightMeters: Double
    var image: VenueMapImage2D?
    var walkablePolygons: [[MapPoint2D]]
    var walls: [Wall2D]
    var rooms: [Room2D]
    var entrances: [Entrance2D]
    var alignmentPoints: [AlignmentPoint2D]
    var checkpoints: [Checkpoint2D]

    init(
        venueId: String,
        name: String,
        widthMeters: Double,
        heightMeters: Double,
        image: VenueMapImage2D?,
        walkablePolygons: [[MapPoint2D]],
        walls: [Wall2D],
        rooms: [Room2D],
        entrances: [Entrance2D],
        alignmentPoints: [AlignmentPoint2D],
        checkpoints: [Checkpoint2D] = []
    ) {
        self.venueId = venueId
        self.name = name
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.image = image
        self.walkablePolygons = walkablePolygons
        self.walls = walls
        self.rooms = rooms
        self.entrances = entrances
        self.alignmentPoints = alignmentPoints
        self.checkpoints = checkpoints
    }

    private enum CodingKeys: String, CodingKey {
        case venueId
        case name
        case widthMeters
        case heightMeters
        case image
        case walkablePolygons
        case walls
        case rooms
        case entrances
        case alignmentPoints
        case checkpoints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        venueId = try container.decode(String.self, forKey: .venueId)
        name = try container.decode(String.self, forKey: .name)
        widthMeters = try container.decode(Double.self, forKey: .widthMeters)
        heightMeters = try container.decode(Double.self, forKey: .heightMeters)
        image = try container.decodeIfPresent(VenueMapImage2D.self, forKey: .image)
        walkablePolygons = try container.decode([[MapPoint2D]].self, forKey: .walkablePolygons)
        walls = try container.decode([Wall2D].self, forKey: .walls)
        rooms = try container.decode([Room2D].self, forKey: .rooms)
        entrances = try container.decode([Entrance2D].self, forKey: .entrances)
        alignmentPoints = try container.decode([AlignmentPoint2D].self, forKey: .alignmentPoints)
        checkpoints = try container.decodeIfPresent([Checkpoint2D].self, forKey: .checkpoints) ?? []
    }
}

struct VenueMapBundle2D: Codable, Hashable {
    var schema: Int
    var map: VenueMap2D
    var heatmapCells: [MagneticHeatmapCell]
}

struct MagneticHeatmapCell: Codable, Identifiable, Hashable {
    var id: String { "\(center.x),\(center.y),\(cellSizeMeters)" }
    var center: MapPoint2D
    var cellSizeMeters: Double
    var sampleCount: Int
    var passCount: Int
    /// Local magnetic texture in microtesla. Higher means a more useful fingerprint region.
    var magneticChangeUT: Double
    /// Absolute magnetic fingerprint used by the 2D runtime. Optional so older
    /// bundled/imported heatmap JSON still loads, but new surveys should fill it.
    var meanMagnitudeUT: Double? = nil
    var stddevMagnitudeUT: Double? = nil
    var meanVerticalUT: Double? = nil
    var stddevVerticalUT: Double? = nil
    var meanHorizontalUT: Double? = nil
    var stddevHorizontalUT: Double? = nil
    /// Distance from this cell center to the nearest real survey bucket. Interpolated
    /// cells keep this non-zero so runtime priors still know support is weaker.
    var supportDistanceMeters: Double? = nil
}

enum HeatmapMode2D: String, CaseIterable, Identifiable {
    case surveyStrength
    case magneticMeanMagnitude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .surveyStrength: return "Survey strength"
        case .magneticMeanMagnitude: return "Mag avg"
        }
    }

    var caption: String {
        switch self {
        case .surveyStrength:
            return "Coverage from sample count and repeated passes. Green means this area has enough survey data."
        case .magneticMeanMagnitude:
            return "Average total magnetic-field magnitude per cell (µT). This is the primary fingerprint the runtime matches against."
        }
    }
}

enum VenueMap2DStore {
    static let defaultResource = "demo-2d-venue-map"
    static let importedFileName = "current-2d-venue-map.json"

    static var venueMapsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("venue-maps", isDirectory: true)
    }

    static var importedMapURL: URL {
        venueMapsDirectory.appendingPathComponent(importedFileName)
    }

    static var checkpointAudioDirectory: URL {
        venueMapsDirectory.appendingPathComponent("checkpoint-audio", isDirectory: true)
    }

    static func checkpointAudioURL(fileName: String) -> URL {
        checkpointAudioDirectory.appendingPathComponent(fileName)
    }

    static func removeCheckpointAudio(fileName: String) {
        try? FileManager.default.removeItem(at: checkpointAudioURL(fileName: fileName))
    }

    static func loadSavedOrBundled(resource: String = defaultResource) -> VenueMapBundle2D {
        if let imported = try? load(from: importedMapURL) { return imported }
        if let bundled = try? loadBundled(resource: resource), bundled.hasRuntimeFingerprint {
            return bundled
        }
        return demoBundle
    }

    static func loadBundled(resource: String) throws -> VenueMapBundle2D {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw VenueMap2DStoreError.missingResource(resource)
        }
        let data = try Data(contentsOf: url)
        let bundle = try JSONDecoder().decode(VenueMapBundle2D.self, from: data)
        guard bundle.schema == 1 else { throw VenueMap2DStoreError.unsupportedSchema(bundle.schema) }
        return bundle
    }

    static func load(from url: URL) throws -> VenueMapBundle2D {
        let data = try Data(contentsOf: url)
        let bundle = try JSONDecoder().decode(VenueMapBundle2D.self, from: data)
        guard bundle.schema == 1 else { throw VenueMap2DStoreError.unsupportedSchema(bundle.schema) }
        return bundle
    }

    static func saveImportedMap(from sourceURL: URL) throws -> VenueMapBundle2D {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let bundle = try load(from: sourceURL)
        try FileManager.default.createDirectory(at: venueMapsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyPrinted.encode(bundle)
        try data.write(to: importedMapURL, options: .atomic)
        return bundle
    }

    static func save(_ bundle: VenueMapBundle2D) throws {
        try FileManager.default.createDirectory(at: venueMapsDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyPrinted.encode(bundle)
        try data.write(to: importedMapURL, options: .atomic)
    }

    static func copyImportedAsset(from sourceURL: URL) throws -> String {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try FileManager.default.createDirectory(at: venueMapsDirectory, withIntermediateDirectories: true)
        let destination = venueMapsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination.lastPathComponent
    }

    static var demoBundle: VenueMapBundle2D {
        VenueMapBundle2D(schema: 1, map: DemoVenueMap2D.map, heatmapCells: DemoVenueMap2D.cells)
    }
}

private extension VenueMapBundle2D {
    var hasRuntimeFingerprint: Bool {
        heatmapCells.contains { cell in
            cell.meanMagnitudeUT != nil && cell.meanVerticalUT != nil && cell.meanHorizontalUT != nil
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum VenueMap2DStoreError: LocalizedError {
    case missingResource(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .missingResource(let resource): return "Missing 2D venue map resource: \(resource).json"
        case .unsupportedSchema(let schema): return "Unsupported 2D venue map schema: \(schema)"
        }
    }
}

enum DemoVenueMap2D {
    static let map = VenueMap2D(
        venueId: "demo-gallery",
        name: "Demo Gallery",
        widthMeters: 24,
        heightMeters: 16,
        image: nil,
        walkablePolygons: [
            [
                MapPoint2D(x: 1, y: 1), MapPoint2D(x: 23, y: 1),
                MapPoint2D(x: 23, y: 15), MapPoint2D(x: 1, y: 15),
            ],
        ],
        walls: [
            Wall2D(id: "wall-lobby-east", points: [MapPoint2D(x: 8.5, y: 1), MapPoint2D(x: 8.5, y: 7)]),
            Wall2D(id: "wall-north-south", points: [MapPoint2D(x: 1, y: 7.5), MapPoint2D(x: 23, y: 7.5)]),
        ],
        rooms: [
            Room2D(
                id: "lobby",
                name: "Lobby",
                polygon: [
                    MapPoint2D(x: 1, y: 1), MapPoint2D(x: 8, y: 1),
                    MapPoint2D(x: 8, y: 7), MapPoint2D(x: 1, y: 7),
                ]
            ),
            Room2D(
                id: "east-gallery",
                name: "East Gallery",
                polygon: [
                    MapPoint2D(x: 9, y: 1), MapPoint2D(x: 23, y: 1),
                    MapPoint2D(x: 23, y: 7), MapPoint2D(x: 9, y: 7),
                ]
            ),
            Room2D(
                id: "south-gallery",
                name: "South Gallery",
                polygon: [
                    MapPoint2D(x: 1, y: 8), MapPoint2D(x: 23, y: 8),
                    MapPoint2D(x: 23, y: 15), MapPoint2D(x: 1, y: 15),
                ]
            ),
        ],
        entrances: [
            Entrance2D(id: "main", name: "Main Entrance", point: MapPoint2D(x: 2, y: 4)),
        ],
        alignmentPoints: [
            AlignmentPoint2D(id: "align-main", name: "Main Entrance", point: MapPoint2D(x: 2, y: 4)),
            AlignmentPoint2D(id: "align-east", name: "East Gallery Corner", point: MapPoint2D(x: 22, y: 6)),
        ]
    )

    static let cells: [MagneticHeatmapCell] = {
        var out: [MagneticHeatmapCell] = []
        let cellSize = 1.0
        for y in stride(from: 1.5, through: 14.5, by: cellSize) {
            for x in stride(from: 1.5, through: 22.5, by: cellSize) {
                let inWalkable = map.rooms.contains { room in pointInPolygon(MapPoint2D(x: x, y: y), room.polygon) }
                guard inWalkable else { continue }
                let passCount = x < 8 ? 4 : (y > 8 ? 3 : 2)
                let sampleCount = Int((Double(passCount) * 18) + ((x + y).truncatingRemainder(dividingBy: 5) * 4))
                let steelAnomaly = 7.5 * exp(-0.5 * (pow((x - 19) / 2.2, 2) + pow((y - 4) / 1.4, 2)))
                let doorwayChange = 3.2 * exp(-0.5 * pow((x - 8.5) / 0.8, 2))
                let baseTexture = 0.9 + 0.35 * sin(x * 0.8) + 0.25 * cos(y * 1.1)
                let meanMagnitude = 49.0 + steelAnomaly - 2.0 * cos(y * 0.6)
                let meanVertical = -18.0 + steelAnomaly * 0.6 + 6.0 * sin(x * 0.5)
                let meanHorizontal = sqrt(max(0, meanMagnitude * meanMagnitude - meanVertical * meanVertical))
                out.append(MagneticHeatmapCell(
                    center: MapPoint2D(x: x, y: y),
                    cellSizeMeters: cellSize,
                    sampleCount: sampleCount,
                    passCount: passCount,
                    magneticChangeUT: max(0, baseTexture + steelAnomaly + doorwayChange),
                    meanMagnitudeUT: meanMagnitude,
                    meanVerticalUT: meanVertical,
                    meanHorizontalUT: meanHorizontal,
                    supportDistanceMeters: 0
                ))
            }
        }
        return out
    }()

    private static func pointInPolygon(_ point: MapPoint2D, _ polygon: [MapPoint2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let dy = pj.y - pi.y
            if abs(dy) > 1e-9,
               ((pi.y > point.y) != (pj.y > point.y)),
               point.x < (pj.x - pi.x) * (point.y - pi.y) / dy + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
