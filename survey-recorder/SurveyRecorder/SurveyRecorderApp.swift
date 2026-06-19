import SwiftUI

@main
struct SurveyRecorderApp: App {
    @State private var registry = RouteRegistry()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-scene3dpreview") {
                Scene3DPreviewHarness()
            } else {
                mainTabs
            }
            #else
            mainTabs
            #endif
        }
    }

    private var mainTabs: some View {
        WindowGroupBody(registry: registry)
    }
}

/// TEMP debug harness — `-scene3dpreview` launch arg only, DEBUG only.
/// Feeds the 3-D view a representative loop path so the look can be screenshotted.
private struct Scene3DPreviewHarness: View {
    @State private var progress = 0.45
    private let data = Scene3DPreviewHarness.sampleLoop()
    var body: some View {
        ZStack(alignment: .bottom) {
            Color(Instrument.ink).ignoresSafeArea()
            RouteSceneRepresentable(
                pathData: data,
                markerBin: progress * Double(data.bins - 1),
                reachedCheckpoints: Int(progress * Double(data.checkpoints.count - 1) + 0.5),
                active: true,
                tint: UIColor(Instrument.phosphor)
            )
            .ignoresSafeArea()
            Slider(value: $progress).padding()
        }
    }

    static func sampleLoop() -> RoutePathData {
        // a meandering open loop, ~ office-scale, with 8 checkpoints
        var pts: [[Double]] = []
        let n = 120
        for i in 0..<n {
            let t = Double(i) / Double(n - 1) * 2 * .pi
            let x = 6 * cos(t) + 1.5 * cos(3 * t)
            let z = 5 * sin(t) + 1.0 * sin(2 * t)
            pts.append([x, z])
        }
        let cps = (0..<8).map { k -> RoutePathData.Checkpoint in
            let bin = k * (n - 1) / 7
            return .init(name: "CP\(k + 1)", bin: bin, x: pts[bin][0], z: pts[bin][1])
        }
        let xs = pts.map { $0[0] }, zs = pts.map { $0[1] }
        return RoutePathData(
            bins: n,
            bounds: .init(minX: xs.min()!, maxX: xs.max()!, minZ: zs.min()!, maxZ: zs.max()!),
            path: pts, checkpoints: cps)
    }
}

private struct WindowGroupBody: View {
    let registry: RouteRegistry
    var body: some View {
        TabView {
                NavigationStack { RouteLibraryView() }
                    .tabItem { Label("Survey", systemImage: "map") }
                NavigationStack { LivePositioningView() }
                    .tabItem { Label("Live", systemImage: "location.north.circle") }
                NavigationStack { SessionsView() }
                    .tabItem { Label("Sessions", systemImage: "tray.full") }
            }
            .environment(registry)
    }
}
