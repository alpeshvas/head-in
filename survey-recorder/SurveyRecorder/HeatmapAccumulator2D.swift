import Foundation

/// Converts AR-aligned 2D survey samples into the heatmap cells rendered by the
/// Map tab. `magneticChangeUT` is local magnetic texture: high values mean the
/// region should be more useful for particle-filter observations than a flat field.
struct HeatmapAccumulator2D {
    var cellSizeMeters: Double
    var passSeparationSeconds: TimeInterval
    var interpolationRadiusMeters: Double
    var interpolationSigmaMeters: Double

    private var buckets: [CellKey: CellState] = [:]

    init(
        cellSizeMeters: Double = 0.5,
        passSeparationSeconds: TimeInterval = 8,
        interpolationRadiusMeters: Double = 1.0,
        interpolationSigmaMeters: Double = 0.65
    ) {
        self.cellSizeMeters = cellSizeMeters
        self.passSeparationSeconds = passSeparationSeconds
        self.interpolationRadiusMeters = interpolationRadiusMeters
        self.interpolationSigmaMeters = interpolationSigmaMeters
    }

    mutating func reset() {
        buckets.removeAll(keepingCapacity: true)
    }

    mutating func add(_ sample: SurveySample2D, in map: VenueMap2D) {
        guard Geometry2D.isWalkable(sample.mapPoint, in: map) else { return }
        let key = CellKey(point: sample.mapPoint, cellSizeMeters: cellSizeMeters)
        var state = buckets[key] ?? CellState()
        state.add(sample, passSeparationSeconds: passSeparationSeconds)
        buckets[key] = state
    }

    func cells(in map: VenueMap2D) -> [MagneticHeatmapCell] {
        guard !buckets.isEmpty else { return [] }
        let radiusCells = max(0, Int(ceil(interpolationRadiusMeters / cellSizeMeters)))
        var candidateKeys: Set<CellKey> = []
        for key in buckets.keys {
            for dx in -radiusCells...radiusCells {
                for dy in -radiusCells...radiusCells {
                    let candidate = CellKey(ix: key.ix + dx, iy: key.iy + dy)
                    guard Geometry2D.isWalkable(candidate.center(cellSizeMeters: cellSizeMeters), in: map) else { continue }
                    candidateKeys.insert(candidate)
                }
            }
        }

        return candidateKeys.compactMap { key in
            interpolatedCell(key: key, radiusCells: radiusCells)
        }
        .sorted { lhs, rhs in
            lhs.center.y == rhs.center.y ? lhs.center.x < rhs.center.x : lhs.center.y < rhs.center.y
        }
    }

    private func interpolatedCell(key: CellKey, radiusCells: Int) -> MagneticHeatmapCell? {
        let center = key.center(cellSizeMeters: cellSizeMeters)
        var neighbors: [(stats: CellStats, weight: Double)] = []
        var supportDistance = Double.greatestFiniteMagnitude

        for dx in -radiusCells...radiusCells {
            for dy in -radiusCells...radiusCells {
                let neighborKey = CellKey(ix: key.ix + dx, iy: key.iy + dy)
                guard let state = buckets[neighborKey] else { continue }
                let neighborCenter = neighborKey.center(cellSizeMeters: cellSizeMeters)
                let distance = hypot(center.x - neighborCenter.x, center.y - neighborCenter.y)
                guard distance <= interpolationRadiusMeters + 1e-9 else { continue }
                supportDistance = min(supportDistance, distance)
                let z = distance / max(interpolationSigmaMeters, 1e-6)
                neighbors.append((state.stats, exp(-0.5 * z * z)))
            }
        }

        let weightSum = neighbors.reduce(0) { $0 + $1.weight }
        guard weightSum > 0, supportDistance.isFinite else { return nil }
        let meanMag = neighbors.reduce(0) { $0 + $1.stats.meanMagnitudeUT * $1.weight } / weightSum
        let meanVert = neighbors.reduce(0) { $0 + $1.stats.meanVerticalUT * $1.weight } / weightSum
        let meanHoriz = neighbors.reduce(0) { $0 + $1.stats.meanHorizontalUT * $1.weight } / weightSum
        let magneticChange = neighbors.reduce(0) { $0 + $1.stats.magneticChangeUT * $1.weight } / weightSum
        let stdMag = interpolatedStddev(neighbors: neighbors, keyPath: \.meanMagnitudeUT, stddevKeyPath: \.stddevMagnitudeUT, mean: meanMag, weightSum: weightSum)
        let stdVert = interpolatedStddev(neighbors: neighbors, keyPath: \.meanVerticalUT, stddevKeyPath: \.stddevVerticalUT, mean: meanVert, weightSum: weightSum)
        let stdHoriz = interpolatedStddev(neighbors: neighbors, keyPath: \.meanHorizontalUT, stddevKeyPath: \.stddevHorizontalUT, mean: meanHoriz, weightSum: weightSum)
        let rawStats = buckets[key]?.stats
        return MagneticHeatmapCell(
            center: center,
            cellSizeMeters: cellSizeMeters,
            sampleCount: rawStats?.sampleCount ?? 0,
            passCount: rawStats?.passCount ?? 0,
            magneticChangeUT: magneticChange,
            meanMagnitudeUT: meanMag,
            stddevMagnitudeUT: stdMag,
            meanVerticalUT: meanVert,
            stddevVerticalUT: stdVert,
            meanHorizontalUT: meanHoriz,
            stddevHorizontalUT: stdHoriz,
            supportDistanceMeters: supportDistance
        )
    }

    private func interpolatedStddev(
        neighbors: [(stats: CellStats, weight: Double)],
        keyPath: KeyPath<CellStats, Double>,
        stddevKeyPath: KeyPath<CellStats, Double>,
        mean: Double,
        weightSum: Double
    ) -> Double {
        let variance = neighbors.reduce(0) { acc, neighbor in
            let neighborMean = neighbor.stats[keyPath: keyPath]
            let neighborStddev = neighbor.stats[keyPath: stddevKeyPath]
            let spread = neighborMean - mean
            return acc + neighbor.weight * (neighborStddev * neighborStddev + spread * spread)
        } / weightSum
        return sqrt(max(0, variance))
    }

    private struct CellStats {
        var sampleCount: Int
        var passCount: Int
        var magneticChangeUT: Double
        var meanMagnitudeUT: Double
        var stddevMagnitudeUT: Double
        var meanVerticalUT: Double
        var stddevVerticalUT: Double
        var meanHorizontalUT: Double
        var stddevHorizontalUT: Double
    }

    private struct CellState {
        var sampleCount = 0
        var passCount = 0
        var lastTimestamp: TimeInterval?
        var lastMagnitudeUT: Double = 0
        var lastVerticalUT: Double = 0
        var lastHorizontalUT: Double = 0
        var sumMagnitudeUT: Double = 0
        var sumSqMagnitudeUT: Double = 0
        var sumVerticalUT: Double = 0
        var sumSqVerticalUT: Double = 0
        var sumHorizontalUT: Double = 0
        var sumSqHorizontalUT: Double = 0
        var deltas: [Double] = []

        mutating func add(_ sample: SurveySample2D, passSeparationSeconds: TimeInterval) {
            let mag = sample.magnetic.magnitudeUT
            let vert = sample.magnetic.verticalUT
            let horiz = sample.magnetic.horizontalUT
            if let lastT = lastTimestamp {
                let dt = sample.timestamp - lastT
                if dt >= passSeparationSeconds { passCount += 1 }
                let dm = mag - lastMagnitudeUT
                let dv = vert - lastVerticalUT
                let dh = horiz - lastHorizontalUT
                deltas.append(sqrt(dm * dm + dv * dv + dh * dh))
            } else {
                passCount = 1
            }
            sampleCount += 1
            lastTimestamp = sample.timestamp
            lastMagnitudeUT = mag
            lastVerticalUT = vert
            lastHorizontalUT = horiz
            sumMagnitudeUT += mag
            sumSqMagnitudeUT += mag * mag
            sumVerticalUT += vert
            sumSqVerticalUT += vert * vert
            sumHorizontalUT += horiz
            sumSqHorizontalUT += horiz * horiz
        }

        var stats: CellStats {
            let n = max(sampleCount, 1)
            let meanMag = sumMagnitudeUT / Double(n)
            let meanVert = sumVerticalUT / Double(n)
            let meanHoriz = sumHorizontalUT / Double(n)
            return CellStats(
                sampleCount: sampleCount,
                passCount: passCount,
                magneticChangeUT: percentile(deltas, p: 0.75),
                meanMagnitudeUT: meanMag,
                stddevMagnitudeUT: stddev(sum: sumMagnitudeUT, sumSq: sumSqMagnitudeUT, n: sampleCount, mean: meanMag),
                meanVerticalUT: meanVert,
                stddevVerticalUT: stddev(sum: sumVerticalUT, sumSq: sumSqVerticalUT, n: sampleCount, mean: meanVert),
                meanHorizontalUT: meanHoriz,
                stddevHorizontalUT: stddev(sum: sumHorizontalUT, sumSq: sumSqHorizontalUT, n: sampleCount, mean: meanHoriz)
            )
        }

        private func percentile(_ values: [Double], p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
            return sorted[idx]
        }

        private func stddev(sum: Double, sumSq: Double, n: Int, mean: Double) -> Double {
            guard n >= 2 else { return 0 }
            let variance = (sumSq - Double(n) * mean * mean) / Double(n - 1)
            return sqrt(max(0, variance))
        }
    }

    private struct CellKey: Hashable {
        var ix: Int
        var iy: Int

        init(ix: Int, iy: Int) {
            self.ix = ix
            self.iy = iy
        }

        init(point: MapPoint2D, cellSizeMeters: Double) {
            ix = Int(floor(point.x / cellSizeMeters))
            iy = Int(floor(point.y / cellSizeMeters))
        }

        func center(cellSizeMeters: Double) -> MapPoint2D {
            MapPoint2D(
                x: (Double(ix) + 0.5) * cellSizeMeters,
                y: (Double(iy) + 0.5) * cellSizeMeters
            )
        }
    }
}
