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

/// On-route / holding(pacing) / off-route, with display colour.
@MainActor
func routeMapState(_ c: LivePositioningController) -> (color: Color, label: String) {
    if c.pOff > FilterParams.offRouteTau { return (.red, "off route") }
    if c.statusText == "Holding position" { return (.orange, "holding (pacing)") }
    return (.green, "on route")
}

/// The floor-plane drawing only — fills whatever frame it is given so the same
/// view serves the compact card and the full-screen view. Honest by
/// construction: the marker is constrained to the surveyed path (the estimate
/// is 1-D arc-length, not a 2-D fix), shown with an along-path ±2σ band.
struct RouteMapCanvas: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    var showBadges = true

    var body: some View {
        let st = routeMapState(controller)
        GeometryReader { geo in
            let t = transform(in: geo.size)
            ZStack {
                pathShape(through: 0...(pathData.bins - 1), t: t)
                    .stroke(Color(.systemGray3), style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if controller.reachedCheckpoints > 0 {
                    let upto = pathData.checkpoints[min(controller.reachedCheckpoints, pathData.checkpoints.count - 1)].bin
                    pathShape(through: 0...max(0, upto), t: t)
                        .stroke(Color.green.opacity(0.55), style: .init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
                let lo = clampBin(controller.displayBin - 2 * controller.posteriorStdBins)
                let hi = clampBin(controller.displayBin + 2 * controller.posteriorStdBins)
                if hi > lo {
                    pathShape(through: lo...hi, t: t)
                        .stroke(st.color.opacity(0.35), style: .init(lineWidth: 10, lineCap: .round, lineJoin: .round))
                }
                if showBadges {
                    ForEach(Array(pathData.checkpoints.enumerated()), id: \.offset) { idx, cp in
                        let reached = idx <= controller.reachedCheckpoints
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(reached ? Color.green : Color.secondary))
                            .overlay(Circle().stroke(.white, lineWidth: 1))
                            .position(clamped(t(cp.x, cp.z), in: geo.size, inset: 10))
                    }
                }
                if controller.isRunning || controller.isComplete {
                    Circle().fill(st.color)
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .position(clamped(point(atBin: clampBin(controller.displayBin), t: t), in: geo.size, inset: 8))
                }
            }
        }
    }

    // MARK: geometry
    private func clampBin(_ b: Double) -> Int { min(pathData.bins - 1, max(0, Int(b.rounded()))) }

    private func transform(in size: CGSize) -> (Double, Double) -> CGPoint {
        let pad = 18.0
        let spanX = max(pathData.bounds.maxX - pathData.bounds.minX, 0.1)
        let spanZ = max(pathData.bounds.maxZ - pathData.bounds.minZ, 0.1)
        let scale = min((size.width - 2 * pad) / spanX, (size.height - 2 * pad) / spanZ)
        let ox = (size.width - spanX * scale) / 2
        let oy = (size.height - spanZ * scale) / 2
        let minX = pathData.bounds.minX, minZ = pathData.bounds.minZ
        return { x, z in CGPoint(x: ox + (x - minX) * scale, y: oy + (z - minZ) * scale) }
    }
    private func point(atBin bin: Int, t: (Double, Double) -> CGPoint) -> CGPoint {
        let p = pathData.path[min(pathData.path.count - 1, max(0, bin))]; return t(p[0], p[1])
    }
    private func pathShape(through range: ClosedRange<Int>, t: (Double, Double) -> CGPoint) -> Path {
        Path { p in
            let pts = stride(from: range.lowerBound, through: range.upperBound, by: 1).map { point(atBin: $0, t: t) }
            guard let first = pts.first else { return }
            p.move(to: first); for pt in pts.dropFirst() { p.addLine(to: pt) }
        }
    }
    private func clamped(_ p: CGPoint, in size: CGSize, inset: CGFloat) -> CGPoint {
        CGPoint(x: min(max(p.x, inset), size.width - inset), y: min(max(p.y, inset), size.height - inset))
    }
}

/// Wrapping number→name legend; long names truncate per-cell so they never spill.
struct RouteMapLegend: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            ForEach(Array(pathData.checkpoints.enumerated()), id: \.offset) { idx, cp in
                let reached = idx <= controller.reachedCheckpoints
                HStack(spacing: 5) {
                    Text("\(idx + 1)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(reached ? Color.green : Color.secondary))
                    Text(cp.name)
                        .font(.caption2).foregroundStyle(reached ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// DEV/DEBUG map card. Tap (or the expand button) opens a full-screen view.
struct RouteMapView: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    @State private var fullScreen = false

    var body: some View {
        let st = routeMapState(controller)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("MAP (dev)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(st.color).frame(width: 8, height: 8)
                Text(st.label).font(.caption2).foregroundStyle(.secondary)
                Button { fullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption2)
                }
                .buttonStyle(.borderless).padding(.leading, 4)
            }
            RouteMapCanvas(controller: controller, pathData: pathData)
                .frame(height: 170)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
                .onTapGesture { fullScreen = true }
            RouteMapLegend(controller: controller, pathData: pathData)
            Text("Tap to expand · position constrained to surveyed path · band = ±2σ")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .fullScreenCover(isPresented: $fullScreen) {
            RouteMapFullScreen(controller: controller, pathData: pathData)
        }
    }
}

private struct RouteMapFullScreen: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                RouteMapCanvas(controller: controller, pathData: pathData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                RouteMapLegend(controller: controller, pathData: pathData)
            }
            .padding()
            .navigationTitle(controller.profile.routeLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
