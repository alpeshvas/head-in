import SwiftUI

/// 2D floor-plane path baked from the survey's ARKit poses, aligned to the
/// filter's bin grid (path[bin] is the (x,z) for that global bin). Loaded from
/// "<profileResource>-path.json" in the bundle; absent for routes surveyed
/// without ARKit ground truth (the map simply doesn't appear).
struct RoutePathData: Decodable {
    struct Checkpoint: Decodable { let name: String; let bin: Int; let x: Double; let z: Double }
    struct Bounds: Decodable { let minX: Double; let maxX: Double; let minZ: Double; let maxZ: Double }
    let bins: Int
    let bounds: Bounds
    let path: [[Double]]      // [[x, z], …] one per bin
    let checkpoints: [Checkpoint]

    static func load(resource: String) -> RoutePathData? {
        guard let url = Bundle.main.url(forResource: "\(resource)-path", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RoutePathData.self, from: data),
              decoded.path.count >= 2 else { return nil }
        return decoded
    }
}

/// DEV/DEBUG map. Honest by construction: the marker is constrained to the
/// surveyed path (the estimate is 1-D arc-length, not a 2-D fix), shown with an
/// along-path uncertainty band. Not an end-user "blue dot".
struct RouteMapView: View {
    let controller: LivePositioningController
    let pathData: RoutePathData

    private var state: (color: Color, label: String) {
        if controller.pOff > FilterParams.offRouteTau { return (.red, "off route") }
        if controller.statusText == "Holding position" { return (.orange, "holding (pacing)") }
        return (.green, "on route")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MAP (dev)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(state.color).frame(width: 8, height: 8)
                Text(state.label).font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let t = transform(in: geo.size)
                ZStack {
                    // full surveyed path
                    pathShape(through: 0...(pathData.bins - 1), t: t)
                        .stroke(Color(.systemGray3), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    // travelled portion (up to last reached checkpoint)
                    if controller.reachedCheckpoints > 0 {
                        let upto = pathData.checkpoints[min(controller.reachedCheckpoints, pathData.checkpoints.count - 1)].bin
                        pathShape(through: 0...max(0, upto), t: t)
                            .stroke(Color.green.opacity(0.55), style: .init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                    // along-path uncertainty band around the current estimate
                    let lo = clampBin(controller.displayBin - 2 * controller.posteriorStdBins)
                    let hi = clampBin(controller.displayBin + 2 * controller.posteriorStdBins)
                    if hi > lo {
                        pathShape(through: lo...hi, t: t)
                            .stroke(state.color.opacity(0.35), style: .init(lineWidth: 9, lineCap: .round, lineJoin: .round))
                    }
                    // checkpoints
                    ForEach(Array(pathData.checkpoints.enumerated()), id: \.offset) { idx, cp in
                        let reached = idx <= controller.reachedCheckpoints
                        Circle()
                            .fill(reached ? Color.green : Color(.systemBackground))
                            .overlay(Circle().stroke(reached ? Color.green : Color.secondary, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .position(t(cp.x, cp.z))
                    }
                    // current position marker (only while running)
                    if controller.isRunning || controller.isComplete {
                        let p = point(atBin: clampBin(controller.displayBin), t: t)
                        Circle().fill(state.color)
                            .frame(width: 13, height: 13)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .position(p)
                    }
                }
            }
            .frame(height: 170)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Position constrained to surveyed path · band = ±2σ along route")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: geometry

    private func clampBin(_ b: Double) -> Int {
        min(pathData.bins - 1, max(0, Int(b.rounded())))
    }

    /// Aspect-preserving map from floor-plane (x,z) metres to the view rect.
    private func transform(in size: CGSize) -> (Double, Double) -> CGPoint {
        let pad = 16.0
        let spanX = max(pathData.bounds.maxX - pathData.bounds.minX, 0.1)
        let spanZ = max(pathData.bounds.maxZ - pathData.bounds.minZ, 0.1)
        let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanZ)
        let ox = (size.width - spanX * scale) / 2
        let oy = (size.height - spanZ * scale) / 2
        let minX = pathData.bounds.minX, minZ = pathData.bounds.minZ
        return { x, z in CGPoint(x: ox + (x - minX) * scale, y: oy + (z - minZ) * scale) }
    }

    private func point(atBin bin: Int, t: (Double, Double) -> CGPoint) -> CGPoint {
        let p = pathData.path[min(pathData.path.count - 1, max(0, bin))]
        return t(p[0], p[1])
    }

    private func pathShape(through range: ClosedRange<Int>, t: (Double, Double) -> CGPoint) -> Path {
        Path { p in
            let pts = stride(from: range.lowerBound, through: range.upperBound, by: 1)
                .map { point(atBin: $0, t: t) }
            guard let first = pts.first else { return }
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }
}
