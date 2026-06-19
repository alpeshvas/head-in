import Foundation

/// Converts AR-aligned 2D survey samples into the heatmap cells rendered by the
/// Map tab. `magneticChangeUT` is local magnetic texture: high values mean the
/// region should be more useful for particle-filter observations than a flat field.
struct HeatmapAccumulator2D {
    var cellSizeMeters: Double
    var passSeparationSeconds: TimeInterval

    init(cellSizeMeters: Double = 0.5, passSeparationSeconds: TimeInterval = 8) {
        self.cellSizeMeters = cellSizeMeters
        self.passSeparationSeconds = passSeparationSeconds
    }

    func buildCells(from samples: [SurveySample2D], in map: VenueMap2D) -> [MagneticHeatmapCell] {
        var buckets: [CellKey: [SurveySample2D]] = [:]
        for sample in samples where isWalkable(sample.mapPoint, in: map) {
            buckets[CellKey(point: sample.mapPoint, cellSizeMeters: cellSizeMeters), default: []].append(sample)
        }

        return buckets.map { key, bucket in
            let sorted = bucket.sorted { $0.timestamp < $1.timestamp }
            return MagneticHeatmapCell(
                center: key.center(cellSizeMeters: cellSizeMeters),
                cellSizeMeters: cellSizeMeters,
                sampleCount: sorted.count,
                passCount: estimatedPassCount(sorted),
                magneticChangeUT: magneticChangeScore(samples: sorted),
                meanMagnitudeUT: mean(sorted.map { $0.magnetic.magnitudeUT }),
                stddevMagnitudeUT: stddev(sorted.map { $0.magnetic.magnitudeUT }),
                meanVerticalUT: mean(sorted.map { $0.magnetic.verticalUT }),
                stddevVerticalUT: stddev(sorted.map { $0.magnetic.verticalUT })
            )
        }
        .sorted { lhs, rhs in
            lhs.center.y == rhs.center.y ? lhs.center.x < rhs.center.x : lhs.center.y < rhs.center.y
        }
    }

    private func isWalkable(_ point: MapPoint2D, in map: VenueMap2D) -> Bool {
        Geometry2D.isWalkable(point, in: map)
    }

    private func estimatedPassCount(_ sortedSamples: [SurveySample2D]) -> Int {
        guard let first = sortedSamples.first else { return 0 }
        var passes = 1
        var lastT = first.timestamp
        for sample in sortedSamples.dropFirst() {
            if sample.timestamp - lastT >= passSeparationSeconds { passes += 1 }
            lastT = sample.timestamp
        }
        return passes
    }

    private func magneticChangeScore(samples: [SurveySample2D]) -> Double {
        guard samples.count >= 2 else { return 0 }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var deltas: [Double] = []
        deltas.reserveCapacity(sorted.count - 1)
        for i in 1..<sorted.count {
            let dm = sorted[i].magnetic.magnitudeUT - sorted[i - 1].magnetic.magnitudeUT
            let dv = sorted[i].magnetic.verticalUT - sorted[i - 1].magnetic.verticalUT
            deltas.append(hypot(dm, dv))
        }
        return percentile(deltas, p: 0.75)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func stddev(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    private struct CellKey: Hashable {
        var ix: Int
        var iy: Int

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
