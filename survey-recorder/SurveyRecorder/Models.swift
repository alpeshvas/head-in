import Foundation

enum Direction: String, CaseIterable, Identifiable {
    case forward
    case reverse

    var id: String { rawValue }
}

enum DevicePose: String, CaseIterable, Identifiable {
    case hand
    case pocket
    case bag

    var id: String { rawValue }
}

/// What kind of pass this is. `normal` is a clean route walk for fingerprinting;
/// the others are deliberate negative/edge passes used to evaluate route-consistency
/// rejection and off-route detection — the matcher should *fail* these on purpose.
enum PassType: String, CaseIterable, Identifiable {
    case normal
    case pacing      // pacing in place / back-and-forth in one spot
    case offRoute    // walking somewhere the route does not go
    case standing    // standing still for the whole pass
    case live        // trace of a Live-tab tracking run (not a survey pass)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal (clean pass)"
        case .pacing: return "Pacing in place"
        case .offRoute: return "Off-route walk"
        case .standing: return "Standing still"
        case .live: return "Live tracking trace"
        }
    }

    var isNegative: Bool { self != .normal && self != .live }

    /// Pass types a surveyor can pick in the Survey tab; `.live` is written
    /// only by the Live tab's automatic trace logging.
    static var surveyCases: [PassType] { allCases.filter { $0 != .live } }
}

struct RouteSetup {
    var venueId: String
    var routeId: String
    var floorId: String
    var direction: Direction
    var devicePose: DevicePose
    var passType: PassType
    /// Surveyor-only: run ARKit world tracking to log 6-DoF ground-truth pose
    /// alongside the sensor streams. Uses the camera on the surveyor's device;
    /// never part of the shipped runtime experience.
    var recordGroundTruth: Bool
    var checkpoints: [String]
    /// Live runs only: which bundled profile resource the filter ran against
    /// (a hand-vs-pocket profile mix-up is invisible in the trace otherwise).
    var profileResource: String? = nil
}

enum DeviceInfo {
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
