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
    static let deltaReciprocalResidualFloor = 0.25
    static let surveyedCellNoPenaltyDistanceMeters = 0.75
    static let surveyedCellDistanceSigmaMeters = 0.75
    static let surveyedCellPenaltyFloor = 0.02
    static let resampleNeffFraction = 0.5
    static let turnRecoveryThresholdRadians = 35.0 * Double.pi / 180.0
    static let turnRecoveryMaxParticleFraction = 0.18
    static let turnRecoveryPositionJitterMeters = 0.45
    static let turnRecoveryHeadingSigmaRadians = 35.0 * Double.pi / 180.0
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
    private(set) var lastTurnYawRadians = 0.0
    private(set) var lastTurnRecoveryParticleCount = 0

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
        lastTurnYawRadians = gyroDeltaRadians
        lastTurnRecoveryParticleCount = 0
        let previousEstimate = estimate.point
        let previousHeading = weightedMeanHeading()
        let headingSigma = predictionHeadingSigma(for: gyroDeltaRadians)
        for i in particles.indices {
            let old = particles[i]
            let heading = old.headingRadians + gyroDeltaRadians + rng.normal(mean: 0, sigma: headingSigma)
            let step = max(0.2, rng.normal(mean: ParticleFilter2DParams.stepLengthMeters, sigma: ParticleFilter2DParams.stepLengthSigmaMeters))
            let nx = old.x + step * cos(heading)
            let ny = old.y + step * sin(heading)
            var weight = old.weight
            if !isWalkable(MapPoint2D(x: nx, y: ny)) { weight *= ParticleFilter2DParams.outsidePenalty }
            if crossesWall(from: MapPoint2D(x: old.x, y: old.y), to: MapPoint2D(x: nx, y: ny)) { weight *= ParticleFilter2DParams.wallPenalty }
            particles[i] = Particle2D(x: nx, y: ny, headingRadians: heading, weight: weight, previousX: old.x, previousY: old.y)
        }
        injectTurnRecoveryParticles(from: previousEstimate, previousHeading: previousHeading, gyroDeltaRadians: gyroDeltaRadians)
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
            let dm = feature.magnitudeUT - previous.magnitudeUT
            let dv = feature.verticalUT - previous.verticalUT
            let dh = feature.horizontalUT - previous.horizontalUT
            observe(magneticChangeUT: sqrt(dm * dm + dv * dv + dh * dh))
        }
    }

    private func observeAbsolute(magnetic feature: MagneticFeature2D, sigma floorSigma: Double, shouldNormalize: Bool = true) {
        guard heatmapCells.contains(where: hasRuntimeFingerprint) else { return }
        for i in particles.indices {
            guard let cell = nearestCell(to: MapPoint2D(x: particles[i].x, y: particles[i].y)),
                  let expectedMagnitude = cell.meanMagnitudeUT,
                  let expectedVertical = cell.meanVerticalUT,
                  let expectedHorizontal = cell.meanHorizontalUT else {
                particles[i].weight *= ParticleFilter2DParams.surveyedCellPenaltyFloor
                continue
            }
            let sigmaMagnitude = magneticSigma(for: cell.stddevMagnitudeUT, floor: floorSigma)
            let sigmaVertical = magneticSigma(for: cell.stddevVerticalUT, floor: floorSigma)
            let sigmaHorizontal = magneticSigma(for: cell.stddevHorizontalUT, floor: floorSigma)
            let magnitudeResidual = (feature.magnitudeUT - expectedMagnitude) / sigmaMagnitude
            let verticalResidual = (feature.verticalUT - expectedVertical) / sigmaVertical
            let horizontalResidual = (feature.horizontalUT - expectedHorizontal) / sigmaHorizontal
            particles[i].weight *= exp(-0.5 * (magnitudeResidual * magnitudeResidual + verticalResidual * verticalResidual + horizontalResidual * horizontalResidual))
        }
        guard shouldNormalize else { return }
        normalize()
        if effectiveParticleCount < Double(particles.count) * ParticleFilter2DParams.resampleNeffFraction { resample() }
    }

    private func observeDelta(current: MagneticFeature2D, previous: MagneticFeature2D, shouldNormalize: Bool = true) {
        guard heatmapCells.contains(where: hasRuntimeFingerprint) else { return }
        let observedMagnitudeDelta = current.magnitudeUT - previous.magnitudeUT
        let observedVerticalDelta = current.verticalUT - previous.verticalUT
        let observedHorizontalDelta = current.horizontalUT - previous.horizontalUT
        let sigma2 = ParticleFilter2DParams.deltaMagneticSigmaUT * ParticleFilter2DParams.deltaMagneticSigmaUT
        for i in particles.indices {
            guard let previousX = particles[i].previousX,
                  let previousY = particles[i].previousY,
                  let previousCell = nearestCell(to: MapPoint2D(x: previousX, y: previousY)),
                  let currentCell = nearestCell(to: MapPoint2D(x: particles[i].x, y: particles[i].y)),
                  let previousMagnitude = previousCell.meanMagnitudeUT,
                  let previousVertical = previousCell.meanVerticalUT,
                  let previousHorizontal = previousCell.meanHorizontalUT,
                  let currentMagnitude = currentCell.meanMagnitudeUT,
                  let currentVertical = currentCell.meanVerticalUT,
                  let currentHorizontal = currentCell.meanHorizontalUT else {
                particles[i].weight *= ParticleFilter2DParams.surveyedCellPenaltyFloor
                continue
            }
            let residualMagnitude = observedMagnitudeDelta - (currentMagnitude - previousMagnitude)
            let residualVertical = observedVerticalDelta - (currentVertical - previousVertical)
            let residualHorizontal = observedHorizontalDelta - (currentHorizontal - previousHorizontal)
            let normalizedResidual = sqrt((residualMagnitude * residualMagnitude + residualVertical * residualVertical + residualHorizontal * residualHorizontal) / (3 * sigma2))
            particles[i].weight *= 1.0 / max(ParticleFilter2DParams.deltaReciprocalResidualFloor, normalizedResidual)
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
              let vertical = cell.meanVerticalUT,
              let horizontal = cell.meanHorizontalUT else { return nil }
        return MagneticFeature2D(magnitudeUT: magnitude, verticalUT: vertical, horizontalUT: horizontal, accuracyRawValue: 0)
    }

    func nearestHeatmapCellDistanceMeters(to point: MapPoint2D) -> Double? {
        guard let cell = nearestCell(to: point) else { return nil }
        return sqrt(distanceSquared(cell.center, point)) + max(0, cell.supportDistanceMeters ?? 0)
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

    private func hasRuntimeFingerprint(_ cell: MagneticHeatmapCell) -> Bool {
        cell.meanMagnitudeUT != nil && cell.meanVerticalUT != nil && cell.meanHorizontalUT != nil
    }

    private func predictionHeadingSigma(for gyroDeltaRadians: Double) -> Double {
        guard abs(gyroDeltaRadians) >= ParticleFilter2DParams.turnRecoveryThresholdRadians else {
            return ParticleFilter2DParams.headingSigmaRadians
        }
        return min(
            ParticleFilter2DParams.turnRecoveryHeadingSigmaRadians,
            ParticleFilter2DParams.headingSigmaRadians + 0.45 * abs(gyroDeltaRadians)
        )
    }

    private func injectTurnRecoveryParticles(from previousEstimate: MapPoint2D, previousHeading: Double, gyroDeltaRadians: Double) {
        let turnAmount = abs(gyroDeltaRadians)
        guard turnAmount >= ParticleFilter2DParams.turnRecoveryThresholdRadians, !particles.isEmpty else { return }
        let fraction = min(
            ParticleFilter2DParams.turnRecoveryMaxParticleFraction,
            0.05 + 0.18 * turnAmount / Double.pi
        )
        let count = max(1, Int((Double(particles.count) * fraction).rounded()))
        let replacementIndices = particles.indices.sorted { particles[$0].weight < particles[$1].weight }.prefix(count)
        var injected = 0
        for index in replacementIndices {
            let turnProgress = 0.35 + 0.9 * rng.nextUnit()
            let heading = previousHeading + gyroDeltaRadians * turnProgress + rng.normal(mean: 0, sigma: ParticleFilter2DParams.turnRecoveryHeadingSigmaRadians)
            let step = max(0.2, rng.normal(mean: ParticleFilter2DParams.stepLengthMeters, sigma: ParticleFilter2DParams.stepLengthSigmaMeters))
            let lateral = rng.normal(mean: 0, sigma: ParticleFilter2DParams.turnRecoveryPositionJitterMeters)
            let point = MapPoint2D(
                x: previousEstimate.x + step * cos(heading) - lateral * sin(heading),
                y: previousEstimate.y + step * sin(heading) + lateral * cos(heading)
            )
            var weight = 1.0 / Double(particles.count)
            if !isWalkable(point) { weight *= ParticleFilter2DParams.outsidePenalty }
            if crossesWall(from: previousEstimate, to: point) { weight *= ParticleFilter2DParams.wallPenalty }
            particles[index] = Particle2D(
                x: point.x,
                y: point.y,
                headingRadians: heading,
                weight: weight,
                previousX: previousEstimate.x,
                previousY: previousEstimate.y
            )
            injected += 1
        }
        lastTurnRecoveryParticleCount = injected
    }

    private func weightedMeanHeading() -> Double {
        let x = particles.reduce(0) { $0 + cos($1.headingRadians) * $1.weight }
        let y = particles.reduce(0) { $0 + sin($1.headingRadians) * $1.weight }
        guard x != 0 || y != 0 else { return 0 }
        return atan2(y, x)
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
