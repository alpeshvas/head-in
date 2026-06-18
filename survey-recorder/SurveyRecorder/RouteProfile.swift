import Foundation

struct RouteProfile: Decodable {
    let schema: Int
    let route: ProfileRoute
    let anchors: [RouteAnchor]
    let segments: [RouteSegment]
    /// Phase-3 turn signature (optional: older profiles predate it).
    let turns: [RouteTurn]?
    /// Per-venue emission calibration fitted by build-profile (optional:
    /// older profiles fall back to the FilterParams constants).
    let calibration: ProfileCalibration?
    /// Bundle resource this profile was loaded from (set after decode, not JSON).
    var sourceResource: String?

    var routeLabel: String {
        [route.venueId, route.routeId, route.direction, route.devicePose]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Bundled route profiles available in this build, in display order.
    static let bundledProfiles: [(label: String, resource: String)] = [
        ("Plumeria", "plumeria-test-forward"),
        ("Plumeria L478", "plumeria-l478-forward"),
        ("Plumeria L478 (pocket)", "plumeria-l478-pocket"),
        ("Office right wing", "office-right-wing-forward"),
        ("Office-Near (LIS)", "office-near-lis-forward"),
        ("Meadows", "meadows-test-forward"),
    ]

    static func loadBundled(resource: String) throws -> RouteProfile {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
            throw RouteProfileError.missingBundledProfile
        }

        let data = try Data(contentsOf: url)
        var profile = try JSONDecoder().decode(RouteProfile.self, from: data)
        guard profile.schema == 1 else { throw RouteProfileError.unsupportedSchema(profile.schema) }
        guard !profile.segments.isEmpty else { throw RouteProfileError.emptyProfile }
        guard profile.segments.contains(where: \.canMatchMagnetically) else { throw RouteProfileError.noMatchingSegments }
        profile.sourceResource = resource
        return profile
    }
}

struct ProfileRoute: Decodable {
    let venueId: String
    let routeId: String
    let direction: String
    let devicePose: String
    let floorId: String?
}

struct RouteAnchor: Decodable, Identifiable {
    let index: Int
    let name: String

    var id: Int { index }
}

struct RouteSegment: Decodable, Identifiable {
    let index: Int
    let from: String
    let to: String
    let kind: String
    let useForMatching: Bool?
    let quality: String
    let duration: ProfileStatistic
    let detectedSteps: ProfileStatistic
    let magneticMagnitude: MagneticMagnitudeProfile?

    var id: Int { index }

    var label: String { "\(from) → \(to)" }

    var nextCheckpoint: String { to }

    var isTransition: Bool {
        kind == "transition" || useForMatching == false
    }

    var canMatchMagnetically: Bool {
        !isTransition && magneticMagnitude?.mean.isEmpty == false
    }

    var medianDuration: Double {
        max(duration.median ?? 0, 0)
    }

    var medianSteps: Double {
        max(detectedSteps.median ?? 0, 0)
    }
}

struct ProfileStatistic: Decodable {
    let median: Double?
}

/// Per-venue emission noise parameters, fitted from the survey passes
/// (Newson-Krumm recipe) by analysis/build-profile.js.
struct ProfileCalibration: Decodable {
    let diffSigmaUT: Double
    let offLogLikPerPoint: Double
}

/// A turn the route reliably contains: signed heading change (degrees,
/// counter-clockwise-from-above positive) at a global profile bin.
struct RouteTurn: Decodable {
    let bin: Int
    let deltaDeg: Double
    let sigmaBins: Double
}

struct MagneticMagnitudeProfile: Decodable {
    let mean: [Double]
    let stddev: [Double]
}

enum RouteProfileError: LocalizedError {
    case missingBundledProfile
    case unsupportedSchema(Int)
    case emptyProfile
    case noMatchingSegments

    var errorDescription: String? {
        switch self {
        case .missingBundledProfile:
            return "The Meadows route profile is missing from this build."
        case .unsupportedSchema(let schema):
            return "Unsupported route profile schema \(schema)."
        case .emptyProfile:
            return "Route profile has no segments."
        case .noMatchingSegments:
            return "Route profile has no magnetic fingerprint segments."
        }
    }
}
