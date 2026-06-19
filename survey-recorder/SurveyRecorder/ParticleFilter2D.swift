import Foundation

struct Particle2D: Hashable {
    var x: Double
    var y: Double
    var headingRadians: Double
    var weight: Double
    var previousX: Double? = nil
    var previousY: Double? = nil
}

struct ParticleEstimate2D: Hashable {
    var point: MapPoint2D
    var confidenceRadiusMeters: Double
    var roomId: String?
    var effectiveParticleCount: Double
}

enum ParticleFilter2DParams {
    static let particleCount = 1_500
    static let initialRadiusMeters = 1.8
    static let stepLengthMeters = 0.74
    static let stepLengthSigmaMeters = 0.22
    static let headingSigmaRadians = 12.0 * Double.pi / 180.0
    static let wallPenalty = 0.001
    static let outsidePenalty = 0.0001
    static let magneticSigmaUT = 3.0
    static let absoluteMagneticSigmaUT = 5.0
    static let deltaMagneticSigmaUT = 3.0
    static let comboAbsoluteMagneticSigmaUT = 8.0
    static let surveyedCellNoPenaltyDistanceMeters = 0.75
    static let surveyedCellDistanceSigmaMeters = 0.75
    static let surveyedCellPenaltyFloor = 0.02
    static let resampleNeffFraction = 0.5
}

enum ParticleObservationMode2D: String, CaseIterable, Identifiable {
    case absolute
    case delta
    case combo
    case coverageOnly
    case legacyChange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .absolute: return "Absolute"
        case .delta: return "Delta"
        case .combo: return "Combo"
        case .coverageOnly: return "Coverage"
        case .legacyChange: return "Legacy"
        }
    }
}

/// Minimal 2D particle filter core for the floor-plan runtime. It is intentionally
/// independent from CoreMotion/UI so it can be replay-tested offline.
final class ParticleFilter2D {
    private(set) var particles: [Particle2D]
    let map: VenueMap2D
    let heatmapCells: [MagneticHeatmapCell]
    private var rng: SeededRandomNumberGenerator

    init(map: VenueMap2D, heatmapCells: [MagneticHeatmapCell], start: MapPoint2D, seed: UInt64 = 0x5eed) {
        self.map = map
        self.heatmapCells = heatmapCells
        rng = SeededRandomNumberGenerator(seed: seed)
        particles = []
        particles.reserveCapacity(ParticleFilter2DParams.particleCount)
        for _ in 0..<ParticleFilter2DParams.particleCount {
            let r = ParticleFilter2DParams.initialRadiusMeters * sqrt(rng.nextUnit())
            let theta = 2 * Double.pi * rng.nextUnit()
            particles.append(Particle2D(
                x: start.x + r * cos(theta),
                y: start.y + r * sin(theta),
                headingRadians: 2 * Double.pi * rng.nextUnit(),
                weight: 1.0 / Double(ParticleFilter2DParams.particleCount),
                previousX: start.x,
                previousY: start.y
            ))
        }
        normalize()
    }

    init(map: VenueMap2D, heatmapCells: [MagneticHeatmapCell], particles: [Particle2D], seed: UInt64 = 0x5eed) {
        self.map = map
        self.heatmapCells = heatmapCells
        self.rng = SeededRandomNumberGenerator(seed: seed)
        self.particles = particles
        normalize()
    }

    func predictStep(gyroDeltaRadians: Double) {
        for i in particles.indices {
            let old = particles[i]
            let heading = old.headingRadians + gyroDeltaRadians + rng.normal(mean: 0, sigma: ParticleFilter2DParams.headingSigmaRadians)
            let step = max(0.2, rng.normal(mean: ParticleFilter2DParams.stepLengthMeters, sigma: ParticleFilter2DParams.stepLengthSigmaMeters))
            let nx = old.x + step * cos(heading)
            let ny = old.y + step * sin(heading)
            var weight = old.weight
            if !isWalkable(MapPoint2D(x: nx, y: ny)) { weight *= ParticleFilter2DParams.outsidePenalty }
            if crossesWall(from: MapPoint2D(x: old.x, y: old.y), to: MapPoint2D(x: nx, y: ny)) { weight *= ParticleFilter2DParams.wallPenalty }
            particles[i] = Particle2D(x: nx, y: ny, headingRadians: heading, weight: weight, previousX: old.x, previousY: old.y)
        }
        applySurveyedCellPrior()
        normalize()
        if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
    }

    func observe(magneticChangeUT: Double) {
        guard !heatmapCells.isEmpty else { return }
        let sigma2 = ParticleFilter2DParams.magneticSigmaUT * ParticleFilter2DParams.magneticSigmaUT
        for i in particles.indices {
            let expected = expectedMagneticChangeUT(at: MapPoint2D(x: particles[i].x, y: particles[i].y)) ?? 0
            let residual = magneticChangeUT - expected
            particles[i].weight *= exp(-0.5 * residual * residual / sigma2)
        }
        normalize()
        if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
    }

    func observe(magnetic feature: MagneticFeature2D, previous: MagneticFeature2D?, mode: ParticleObservationMode2D) {
        switch mode {
        case .absolute:
            observeAbsolute(magnetic: feature, sigma: ParticleFilter2DParams.absoluteMagneticSigmaUT)
        case .delta:
            if let previous { observeDelta(current: feature, previous: previous) }
        case .combo:
            observeAbsolute(magnetic: feature, sigma: ParticleFilter2DParams.comboAbsoluteMagneticSigmaUT, shouldNormalize: false)
            if let previous { observeDelta(current: feature, previous: previous, shouldNormalize: false) }
            normalize()
            if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
        case .coverageOnly:
            return
        case .legacyChange:
            guard let previous else { return }
            observe(magneticChangeUT: hypot(feature.magnitudeUT - previous.magnitudeUT, feature.verticalUT - previous.verticalUT))
        }
    }

    private func observeAbsolute(magnetic feature: MagneticFeature2D, sigma floorSigma: Double, shouldNormalize: Bool = true) {
        guard heatmapCells.contains(where: { $0.meanMagnitudeUT != nil && $0.meanVerticalUT != nil }) else { return }
        for i in particles.indices {
            guard let cell = nearestCell(to: MapPoint2D(x: particles[i].x, y: particles[i].y)),
                  let expectedMagnitude = cell.meanMagnitudeUT,
                  let expectedVertical = cell.meanVerticalUT else {
                particles[i].weight *= ParticleFilter2DParams.surveyedCellPenaltyFloor
                continue
            }
            let sigmaMagnitude = magneticSigma(for: cell.stddevMagnitudeUT, floor: floorSigma)
            let sigmaVertical = magneticSigma(for: cell.stddevVerticalUT, floor: floorSigma)
            let magnitudeResidual = (feature.magnitudeUT - expectedMagnitude) / sigmaMagnitude
            let verticalResidual = (feature.verticalUT - expectedVertical) / sigmaVertical
            particles[i].weight *= exp(-0.5 * (magnitudeResidual * magnitudeResidual + verticalResidual * verticalResidual))
        }
        guard shouldNormalize else { return }
        normalize()
        if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
    }

    private func observeDelta(current: MagneticFeature2D, previous: MagneticFeature2D, shouldNormalize: Bool = true) {
        guard heatmapCells.contains(where: { $0.meanMagnitudeUT != nil && $0.meanVerticalUT != nil }) else { return }
        let observedMagnitudeDelta = current.magnitudeUT - previous.magnitudeUT
        let observedVerticalDelta = current.verticalUT - previous.verticalUT
        let sigma2 = ParticleFilter2DParams.deltaMagneticSigmaUT * ParticleFilter2DParams.deltaMagneticSigmaUT
        for i in particles.indices {
            guard let previousX = particles[i].previousX,
                  let previousY = particles[i].previousY,
                  let previousCell = nearestCell(to: MapPoint2D(x: previousX, y: previousY)),
                  let currentCell = nearestCell(to: MapPoint2D(x: particles[i].x, y: particles[i].y)),
                  let previousMagnitude = previousCell.meanMagnitudeUT,
                  let previousVertical = previousCell.meanVerticalUT,
                  let currentMagnitude = currentCell.meanMagnitudeUT,
                  let currentVertical = currentCell.meanVerticalUT else {
                particles[i].weight *= ParticleFilter2DParams.surveyedCellPenaltyFloor
                continue
            }
            let residualMagnitude = observedMagnitudeDelta - (currentMagnitude - previousMagnitude)
            let residualVertical = observedVerticalDelta - (currentVertical - previousVertical)
            particles[i].weight *= exp(-0.5 * (residualMagnitude * residualMagnitude + residualVertical * residualVertical) / sigma2)
        }
        guard shouldNormalize else { return }
        normalize()
        if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
    }

    func expectedMagneticChangeUT(at point: MapPoint2D) -> Double? {
        nearestCell(to: point)?.magneticChangeUT
    }

    func expectedMagneticFeature(at point: MapPoint2D) -> MagneticFeature2D? {
        guard let cell = nearestCell(to: point),
              let magnitude = cell.meanMagnitudeUT,
              let vertical = cell.meanVerticalUT else { return nil }
        return MagneticFeature2D(magnitudeUT: magnitude, verticalUT: vertical, accuracyRawValue: 0)
    }

    func nearestHeatmapCellDistanceMeters(to point: MapPoint2D) -> Double? {
        guard let cell = nearestCell(to: point) else { return nil }
        return sqrt(distanceSquared(cell.center, point))
    }

    var estimate: ParticleEstimate2D {
        let total = particles.reduce(0) { $0 + $1.weight }
        guard total > 0 else {
            return ParticleEstimate2D(point: MapPoint2D(x: 0, y: 0), confidenceRadiusMeters: .infinity, roomId: nil, effectiveParticleCount: 0)
        }
        let mx = particles.reduce(0) { $0 + $1.x * $1.weight } / total
        let my = particles.reduce(0) { $0 + $1.y * $1.weight } / total
        let variance = particles.reduce(0) { acc, p in
            acc + p.weight * ((p.x - mx) * (p.x - mx) + (p.y - my) * (p.y - my))
        } / total
        let point = MapPoint2D(x: mx, y: my)
        return ParticleEstimate2D(
            point: point,
            confidenceRadiusMeters: sqrt(max(0, variance)),
            roomId: Geometry2D.roomId(containing: point, in: map),
            effectiveParticleCount: effectiveParticleCount
        )
    }

    var effectiveParticleCount: Double {
        let sumSq = particles.reduce(0) { $0 + $1.weight * $1.weight }
        return sumSq > 0 ? 1.0 / sumSq : 0
    }

    private func normalize() {
        let sum = particles.reduce(0) { $0 + $1.weight }
        if sum <= 0 || !sum.isFinite {
            let uniform = 1.0 / Double(max(particles.count, 1))
            for i in particles.indices { particles[i].weight = uniform }
            return
        }
        for i in particles.indices { particles[i].weight /= sum }
    }

    private func resample() {
        normalize()
        var cumulative: [Double] = []
        cumulative.reserveCapacity(particles.count)
        var acc = 0.0
        for particle in particles {
            acc += particle.weight
            cumulative.append(acc)
        }
        let n = particles.count
        let step = 1.0 / Double(n)
        var u = rng.nextUnit() * step
        var j = 0
        var next: [Particle2D] = []
        next.reserveCapacity(n)
        for _ in 0..<n {
            while j < cumulative.count - 1 && cumulative[j] < u { j += 1 }
            var p = particles[j]
            p.weight = step
            next.append(p)
            u += step
        }
        particles = next
    }

    private func isWalkable(_ point: MapPoint2D) -> Bool {
        Geometry2D.isWalkable(point, in: map)
    }

    private func nearestCell(to point: MapPoint2D) -> MagneticHeatmapCell? {
        heatmapCells.min { a, b in
            distanceSquared(a.center, point) < distanceSquared(b.center, point)
        }
    }

    private func magneticSigma(for cellStddev: Double?, floor: Double) -> Double {
        let stddev = cellStddev ?? 0
        return sqrt(floor * floor + stddev * stddev)
    }

    private func applySurveyedCellPrior() {
        guard !heatmapCells.isEmpty else { return }
        for i in particles.indices {
            let point = MapPoint2D(x: particles[i].x, y: particles[i].y)
            guard let distance = nearestHeatmapCellDistanceMeters(to: point) else { continue }
            let excess = max(0, distance - ParticleFilter2DParams.surveyedCellNoPenaltyDistanceMeters)
            guard excess > 0 else { continue }
            let z = excess / ParticleFilter2DParams.surveyedCellDistanceSigmaMeters
            let penalty = max(ParticleFilter2DParams.surveyedCellPenaltyFloor, exp(-0.5 * z * z))
            particles[i].weight *= penalty
        }
    }

    private func distanceSquared(_ a: MapPoint2D, _ b: MapPoint2D) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func crossesWall(from: MapPoint2D, to: MapPoint2D) -> Bool {
        for wall in map.walls where wall.points.count >= 2 {
            for i in 1..<wall.points.count {
                if segmentsIntersect(from, to, wall.points[i - 1], wall.points[i]) { return true }
            }
        }
        return false
    }

    private func segmentsIntersect(_ a: MapPoint2D, _ b: MapPoint2D, _ c: MapPoint2D, _ d: MapPoint2D) -> Bool {
        func orient(_ p: MapPoint2D, _ q: MapPoint2D, _ r: MapPoint2D) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let o1 = orient(a, b, c)
        let o2 = orient(a, b, d)
        let o3 = orient(c, d, a)
        let o4 = orient(c, d, b)
        return (o1 * o2 < 0) && (o3 * o4 < 0)
    }
}

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
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
