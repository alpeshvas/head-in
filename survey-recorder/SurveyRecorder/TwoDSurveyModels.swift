import Foundation

struct Vector3D: Codable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    var magnitude: Double { sqrt(x * x + y * y + z * z) }

    func dot(_ other: Vector3D) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    var unit: Vector3D? {
        let m = magnitude
        guard m > 1e-9 else { return nil }
        return Vector3D(x: x / m, y: y / m, z: z / m)
    }
}

struct ARPoint2D: Codable, Hashable {
    /// ARKit local X in meters.
    var x: Double
    /// ARKit local Z in meters, flattened into the venue-map plane.
    var z: Double
}

struct ARMapAlignmentPair2D: Codable, Hashable {
    var ar: ARPoint2D
    var map: MapPoint2D
}

/// Similarity transform from ARKit's local x/z plane into floor-plan meters.
/// ARKit survey is camera-based, but runtime can remain camera-free.
struct ARMapTransform2D: Codable, Hashable {
    var scale: Double
    var rotationRadians: Double
    var translation: MapPoint2D

    static func fromTwoPointAlignment(_ a: ARMapAlignmentPair2D, _ b: ARMapAlignmentPair2D) throws -> ARMapTransform2D {
        let arDx = b.ar.x - a.ar.x
        let arDy = b.ar.z - a.ar.z
        let mapDx = b.map.x - a.map.x
        let mapDy = b.map.y - a.map.y
        let arDistance = hypot(arDx, arDy)
        let mapDistance = hypot(mapDx, mapDy)
        guard arDistance > 0.25, mapDistance > 0.25 else { throw ARMapTransformError.degenerateAlignment }

        let scale = mapDistance / arDistance
        let rotation = atan2(mapDy, mapDx) - atan2(arDy, arDx)
        let transformedA = rotateAndScale(a.ar, scale: scale, rotation: rotation)
        let translation = MapPoint2D(x: a.map.x - transformedA.x, y: a.map.y - transformedA.y)
        return ARMapTransform2D(scale: scale, rotationRadians: rotation, translation: translation)
    }

    func mapPoint(for ar: ARPoint2D) -> MapPoint2D {
        let p = Self.rotateAndScale(ar, scale: scale, rotation: rotationRadians)
        return MapPoint2D(x: p.x + translation.x, y: p.y + translation.y)
    }

    private static func rotateAndScale(_ ar: ARPoint2D, scale: Double, rotation: Double) -> MapPoint2D {
        let c = cos(rotation)
        let s = sin(rotation)
        return MapPoint2D(
            x: scale * (ar.x * c - ar.z * s),
            y: scale * (ar.x * s + ar.z * c)
        )
    }
}

enum ARMapTransformError: LocalizedError {
    case degenerateAlignment

    var errorDescription: String? {
        switch self {
        case .degenerateAlignment:
            return "AR/map alignment points must be at least 0.25 m apart."
        }
    }
}

struct MagneticFeature2D: Codable, Hashable {
    var magnitudeUT: Double
    var verticalUT: Double
    var accuracyRawValue: Int

    static func from(magneticVector: Vector3D, gravityVector: Vector3D, accuracyRawValue: Int) -> MagneticFeature2D? {
        guard let gravityUnit = gravityVector.unit else { return nil }
        return MagneticFeature2D(
            magnitudeUT: magneticVector.magnitude,
            verticalUT: magneticVector.dot(gravityUnit),
            accuracyRawValue: accuracyRawValue
        )
    }
}

struct SurveySample2D: Codable, Hashable {
    var timestamp: TimeInterval
    var arPoint: ARPoint2D
    var mapPoint: MapPoint2D
    var roomId: String?
    var magnetic: MagneticFeature2D
}

enum Geometry2D {
    static func roomId(containing point: MapPoint2D, in map: VenueMap2D) -> String? {
        map.rooms.first { pointInPolygon(point, polygon: $0.polygon) }?.id
    }

    static func pointInPolygon(_ point: MapPoint2D, polygon: [MapPoint2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if ((pi.y > point.y) != (pj.y > point.y)) &&
                (point.x < (pj.x - pi.x) * (point.y - pi.y) / max(pj.y - pi.y, 1e-9) + pi.x) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
