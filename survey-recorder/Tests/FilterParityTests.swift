import XCTest

/// JS↔Swift filter parity: drives RouteBeliefFilter through the exact op
/// sequence recorded by analysis/make-parity-fixture.js from the reference
/// implementation (analysis/grid-filter.js) and asserts the posterior matches
/// after every op. The two filters are maintained by hand in parallel; this
/// test is what makes that safe. Regenerate fixtures whenever filter math or
/// params change on either side.
final class FilterParityTests: XCTestCase {
    struct Fixture: Decodable {
        let profileFile: String
        let sessionFile: String
        let probeBins: [Int]
        let ops: [Op]
    }

    struct Op: Decodable {
        let op: String
        let deltaDeg: Double?
        let dt: Double?
        let windows: [String: [Double]?]?
        let expect: Expect
    }

    struct Expect: Decodable {
        let meanBin: Double
        let pOff: Double
        let probBeyond: [Double]
        let belief: [Double]?
        // Direction-latch state (optional: older fixtures predate it).
        let reversalActive: Bool?
    }

    // Cross-libm drift only: the op order is identical in both implementations,
    // so disagreement beyond these bounds is a real divergence.
    private let meanBinTolerance = 0.05
    private let probTolerance = 1e-4
    private let beliefTolerance = 1e-6

    func testPacingTraceParity() throws {
        try runFixture(named: "parity-fixture")
    }

    func testCleanWalkTraceParity() throws {
        try runFixture(named: "parity-fixture-clean")
    }

    func testL478PacingTraceParity() throws {
        try runFixture(named: "parity-fixture-l478-pacing")
    }

    func testRaviPlaceTraceParity() throws {
        try runFixture(named: "parity-fixture-ravi")
    }

    func testRaviPlacePacingTraceParity() throws {
        try runFixture(named: "parity-fixture-ravi-pacing")
    }

    /// Round-trip (out-and-back) trace: exercises the U-turn / reversal path and
    /// the direction-latch wiring in reversalActive (bidirectional-route-tracking.md
    /// §8). On this weak-field venue the `returning` latch does not itself flip
    /// (belief never reaches the terminus), but the reversalActive parity guards
    /// the JS<->Swift toggle wiring; a strong-field round-trip would also exercise
    /// the flip.
    func testLISRoundTripTraceParity() throws {
        try runFixture(named: "parity-fixture-lis-roundtrip")
    }

    private func runFixture(named name: String) throws {
        let bundle = Bundle(for: FilterParityTests.self)
        let fixtureURL = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "missing fixture \(name)")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))

        let profileName = (fixture.profileFile as NSString).deletingPathExtension
        let profileURL = try XCTUnwrap(bundle.url(forResource: profileName, withExtension: "json"), "missing profile \(profileName)")
        let profile = try JSONDecoder().decode(RouteProfile.self, from: Data(contentsOf: profileURL))
        let gp = try GlobalRouteProfile(profile: profile)
        let filter = RouteBeliefFilter(profile: gp)

        for (index, op) in fixture.ops.enumerated() {
            switch op.op {
            case "predictStep":
                filter.predictStep()
            case "observe":
                let windows = op.windows ?? [:]
                _ = filter.observe { seg in windows[String(seg.index)] ?? nil }
            case "applyUnobservedLeak":
                filter.applyUnobservedLeak()
            case "observeTurn":
                filter.observeTurn(deltaDeg: try XCTUnwrap(op.deltaDeg))
            case "predictIdle":
                filter.predictIdle(dt: try XCTUnwrap(op.dt))
            default:
                XCTFail("unknown op \(op.op)")
            }

            let label = "\(name) op \(index) (\(op.op))"
            XCTAssertEqual(filter.meanBin, op.expect.meanBin, accuracy: meanBinTolerance, "\(label) meanBin")
            XCTAssertEqual(filter.pOff, op.expect.pOff, accuracy: probTolerance, "\(label) pOff")
            for (k, bin) in fixture.probeBins.enumerated() {
                XCTAssertEqual(filter.probBeyond(bin: bin), op.expect.probBeyond[k], accuracy: probTolerance, "\(label) probBeyond(\(bin))")
            }
            if let expectedReversal = op.expect.reversalActive {
                XCTAssertEqual(filter.reversalActive, expectedReversal, "\(label) reversalActive (direction latch)")
            }
            if let expected = op.expect.belief {
                XCTAssertEqual(expected.count, filter.belief.count, "\(label) belief length")
                var worst = 0.0
                var worstBin = -1
                for i in expected.indices {
                    let d = abs(filter.belief[i] - expected[i])
                    if d > worst { worst = d; worstBin = i }
                }
                XCTAssertLessThanOrEqual(worst, beliefTolerance, "\(label) belief diverges at bin \(worstBin)")
            }
        }
    }
}
