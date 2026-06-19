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

/// On-route / holding(pacing) / off-route, with instrument signal colour.
@MainActor
func routeMapState(_ c: LivePositioningController) -> (color: Color, label: String) {
    if c.pOff > FilterParams.offRouteTau { return (Instrument.coral, "off route") }
    if c.statusText == "Holding position" { return (Instrument.amber, "holding") }
    return (Instrument.phosphor, "on route")
}

/// The floor-plane display — a navigation instrument. Fills its frame so the same
/// view serves the compact card and full screen. Honest by construction: the
/// marker is constrained to the surveyed path (1-D arc-length, not a 2-D fix),
/// shown with an along-path ±2σ glow band.
struct RouteMapCanvas: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    var showBadges = true
    @State private var pulse = false

    var body: some View {
        let st = routeMapState(controller)
        GeometryReader { geo in
            let t = transform(in: geo.size)
            ZStack {
                // instrument backdrop: ink + blueprint grid + vignette
                Instrument.ink
                GridPattern(spacing: 26).stroke(Instrument.grid, lineWidth: 0.5)
                RadialGradient(colors: [.clear, Instrument.ink.opacity(0.7)],
                               center: .center, startRadius: 60, endRadius: max(geo.size.width, geo.size.height))

                // untravelled route
                pathShape(through: 0...(pathData.bins - 1), t: t)
                    .stroke(Instrument.steel, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))

                // travelled portion — glowing phosphor
                if controller.reachedCheckpoints > 0 {
                    let upto = pathData.checkpoints[min(controller.reachedCheckpoints, pathData.checkpoints.count - 1)].bin
                    pathShape(through: 0...max(0, upto), t: t)
                        .stroke(Instrument.phosphor, style: .init(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: Instrument.phosphor.opacity(0.7), radius: 4)
                }

                // along-path ±2σ uncertainty glow band
                let lo = clampBin(controller.displayBin - 2 * controller.posteriorStdBins)
                let hi = clampBin(controller.displayBin + 2 * controller.posteriorStdBins)
                if hi > lo {
                    pathShape(through: lo...hi, t: t)
                        .stroke(st.color.opacity(0.30), style: .init(lineWidth: 11, lineCap: .round, lineJoin: .round))
                        .blur(radius: 1)
                }

                // checkpoint nodes
                if showBadges {
                    ForEach(Array(pathData.checkpoints.enumerated()), id: \.offset) { idx, cp in
                        let reached = idx <= controller.reachedCheckpoints
                        Text("\(idx + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(reached ? Instrument.ink : Instrument.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(reached ? Instrument.phosphor : Instrument.panel))
                            .overlay(Circle().stroke(reached ? Instrument.phosphor : Instrument.hairline, lineWidth: 1.2))
                            .shadow(color: reached ? Instrument.phosphor.opacity(0.6) : .clear, radius: 4)
                            .position(clamped(t(cp.x, cp.z), in: geo.size, inset: 10))
                    }
                }

                // live position marker: haloed, pulsing signal dot
                if controller.isRunning || controller.isComplete {
                    let p = clamped(point(atBin: clampBin(controller.displayBin), t: t), in: geo.size, inset: 10)
                    ZStack {
                        Circle().fill(st.color.opacity(0.22))
                            .frame(width: 34, height: 34)
                            .scaleEffect(pulse ? 1.25 : 0.7).opacity(pulse ? 0.0 : 0.6)
                        Circle().fill(st.color).frame(width: 13, height: 13)
                            .overlay(Circle().stroke(Instrument.ink, lineWidth: 2))
                            .shadow(color: st.color, radius: 6)
                    }
                    .position(p)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) { pulse = true }
        }
    }

    // MARK: geometry
    private func clampBin(_ b: Double) -> Int { min(pathData.bins - 1, max(0, Int(b.rounded()))) }

    private func transform(in size: CGSize) -> (Double, Double) -> CGPoint {
        let pad = 20.0
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(Array(pathData.checkpoints.enumerated()), id: \.offset) { idx, cp in
                let reached = idx <= controller.reachedCheckpoints
                HStack(spacing: 6) {
                    Text("\(idx + 1)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(reached ? Instrument.ink : Instrument.textSecondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(reached ? Instrument.phosphor : Instrument.panel))
                        .overlay(Circle().stroke(reached ? Instrument.phosphor : Instrument.hairline, lineWidth: 1))
                    Text(cp.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(reached ? Instrument.textPrimary : Instrument.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
    }
}

/// DEV map card. Tap (or the expand button) opens a full-screen view.
struct RouteMapView: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    @State private var fullScreen = false

    var body: some View {
        let st = routeMapState(controller)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("FLOOR MAP").monoTag(Instrument.textSecondary)
                Rectangle().fill(Instrument.hairline).frame(height: 1)
                InstrumentChip(text: st.label, color: st.color)
                Button { fullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Instrument.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(Instrument.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Instrument.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            RouteMapCanvas(controller: controller, pathData: pathData)
                .frame(height: 188)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Instrument.hairline, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { fullScreen = true }
            RouteMapLegend(controller: controller, pathData: pathData)
            Text("tap to expand · marker rides surveyed path · band = ±2σ along route")
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(Instrument.textTertiary)
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
        ZStack {
            Instrument.ink.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FLOOR MAP").monoTag()
                        Text(controller.profile.routeLabel)
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .foregroundStyle(Instrument.textPrimary)
                    }
                    Spacer()
                    InstrumentChip(text: routeMapState(controller).label, color: routeMapState(controller).color)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Instrument.textPrimary)
                            .frame(width: 34, height: 34)
                            .background(Instrument.panel, in: Circle())
                            .overlay(Circle().stroke(Instrument.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain).padding(.leading, 4)
                }
                RouteMapCanvas(controller: controller, pathData: pathData)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Instrument.hairline, lineWidth: 1))
                RouteMapLegend(controller: controller, pathData: pathData)
            }
            .padding()
        }
    }
}
