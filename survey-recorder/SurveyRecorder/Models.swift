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

struct RouteSetup {
    var venueId: String
    var routeId: String
    var floorId: String
    var direction: Direction
    var devicePose: DevicePose
    var checkpoints: [String]
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
