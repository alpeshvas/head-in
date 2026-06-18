import XCTest

final class ParticleFilter2DTests: XCTestCase {
    func testPredictStepAppliesHeadingDeltaNoiseStepNoiseAndMotionEquation() {
        var rng = TestRNG(seed: 123)
        let headingNoise = rng.normal(mean: 0, sigma: ParticleFilter2DParams.headingSigmaRadians)
        let step = max(0.2, rng.normal(mean: ParticleFilter2DParams.stepLengthMeters, sigma: ParticleFilter2DParams.stepLengthSigmaMeters))
        let expectedHeading = 0.25 + 0.4 + headingNoise

        let filter = ParticleFilter2D(
            map: Self.openMap,
            heatmapCells: [],
            particles: [Particle2D(x: 2, y: 3, headingRadians: 0.25, weight: 1)],
            seed: 123
        )

        filter.predictStep(gyroDeltaRadians: 0.4)

        let particle = filter.particles[0]
        XCTAssertEqual(particle.headingRadians, expectedHeading, accuracy: 1e-12)
        XCTAssertEqual(particle.x, 2 + step * cos(expectedHeading), accuracy: 1e-12)
        XCTAssertEqual(particle.y, 3 + step * sin(expectedHeading), accuracy: 1e-12)
        XCTAssertEqual(particle.weight, 1, accuracy: 1e-12)
    }

    func testObserveAppliesGaussianMagneticLikelihoodAndNormalizes() {
        let cells = [
            MagneticHeatmapCell(center: MapPoint2D(x: 1, y: 1), cellSizeMeters: 1, sampleCount: 10, passCount: 2, magneticChangeUT: 2),
            MagneticHeatmapCell(center: MapPoint2D(x: 9, y: 1), cellSizeMeters: 1, sampleCount: 10, passCount: 2, magneticChangeUT: 5),
        ]
        let filter = ParticleFilter2D(
            map: Self.openMap,
            heatmapCells: cells,
            particles: [
                Particle2D(x: 1, y: 1, headingRadians: 0, weight: 0.25),
                Particle2D(x: 9, y: 1, headingRadians: 0, weight: 0.75),
            ],
            seed: 123
        )

        filter.observe(magneticChangeUT: 4)

        let sigma2 = ParticleFilter2DParams.magneticSigmaUT * ParticleFilter2DParams.magneticSigmaUT
        let l0 = 0.25 * exp(-0.5 * pow(4 - 2, 2) / sigma2)
        let l1 = 0.75 * exp(-0.5 * pow(4 - 5, 2) / sigma2)
        let total = l0 + l1

        XCTAssertEqual(filter.particles[0].weight, l0 / total, accuracy: 1e-12)
        XCTAssertEqual(filter.particles[1].weight, l1 / total, accuracy: 1e-12)
        XCTAssertEqual(filter.effectiveParticleCount, 1 / (pow(l0 / total, 2) + pow(l1 / total, 2)), accuracy: 1e-12)
    }

    func testPointInPolygonHandlesClockwiseAndCounterClockwisePolygons() {
        let counterClockwise = [
            MapPoint2D(x: 0, y: 0),
            MapPoint2D(x: 4, y: 0),
            MapPoint2D(x: 2, y: 4),
        ]
        let clockwise = counterClockwise.reversed()

        XCTAssertTrue(Geometry2D.pointInPolygon(MapPoint2D(x: 2, y: 2), polygon: Array(clockwise)))
        XCTAssertTrue(Geometry2D.pointInPolygon(MapPoint2D(x: 2, y: 2), polygon: Array(counterClockwise)))
        XCTAssertFalse(Geometry2D.pointInPolygon(MapPoint2D(x: 5, y: 2), polygon: Array(clockwise)))
        XCTAssertFalse(Geometry2D.pointInPolygon(MapPoint2D(x: 5, y: 2), polygon: Array(counterClockwise)))
    }

    private static let openMap = VenueMap2D(
        venueId: "test",
        name: "Test",
        widthMeters: 20,
        heightMeters: 20,
        image: nil,
        walkablePolygons: [],
        walls: [],
        rooms: [],
        entrances: [],
        alignmentPoints: []
    )
}

private struct TestRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x5eed : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func normal(mean: Double, sigma: Double) -> Double {
        let u1 = max(nextUnit(), 1e-12)
        let u2 = nextUnit()
        return mean + sigma * sqrt(-2 * log(u1)) * cos(2 * Double.pi * u2)
    }
}
