import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct MapHeatmapView: View {
    @State private var mode = HeatmapMode2D.surveyStrength
    @State private var bundle = VenueMap2DStore.loadSavedOrBundled()
    @State private var importingMap = false
    @State private var importingImage = false
    @State private var importError: String?
    @State private var surveyController: TwoDSurveyController?
    @State private var runtimeController: TwoDRuntimeController?

    private var map: VenueMap2D { bundle.map }
    private var cells: [MagneticHeatmapCell] {
        if let liveCells = surveyController?.heatmapCells, !liveCells.isEmpty { return liveCells }
        return bundle.heatmapCells
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerCard
                Picker("Heatmap", selection: $mode) {
                    ForEach(HeatmapMode2D.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                FloorPlanHeatmapCanvas(
                    map: map,
                    cells: cells,
                    mode: mode,
                    currentPoint: surveyController?.latestMapPoint,
                    runtimeEstimate: runtimeController?.estimate
                )
                    .frame(height: 430)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                    )

                surveyCard
                runtimeCard
                legendCard
                implementationCard
            }
            .padding()
        }
        .background(Color.mapGroupedBackground)
        .navigationTitle("Map")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        importingMap = true
                    } label: {
                        Label("Import map JSON", systemImage: "doc.badge.plus")
                    }
                    Button {
                        importingImage = true
                    } label: {
                        Label("Import floor-plan image", systemImage: "photo")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
            }
        }
        .fileImporter(isPresented: $importingMap, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    bundle = try VenueMap2DStore.saveImportedMap(from: url)
                    importError = nil
                    surveyController?.stop()
                    surveyController = nil
                    runtimeController?.stop()
                    runtimeController = nil
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Could not import map", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown error")
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                do {
                    let fileName = try VenueMap2DStore.copyImportedAsset(from: url)
                    var updated = bundle
                    let size = imagePixelSize(at: VenueMap2DStore.venueMapsDirectory.appendingPathComponent(fileName))
                    updated.map.image = VenueMapImage2D(
                        fileName: fileName,
                        widthPixels: size?.width ?? 0,
                        heightPixels: size?.height ?? 0
                    )
                    try VenueMap2DStore.save(updated)
                    bundle = updated
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
    }

    private var headerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("2D floor-plan heatmaps")
                    .font(.title2.bold())
                Text("\(map.name) · \(map.widthMeters.formatted(.number.precision(.fractionLength(0...1)))) × \(map.heightMeters.formatted(.number.precision(.fractionLength(0...1)))) m")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(mode.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legendCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mode semantics")
                    .font(.headline)
                Label("Survey strength combines sample count and repeated passes per cell.", systemImage: "checkmark.circle")
                Label("Magnetic change visualizes local field texture, not absolute field strength.", systemImage: "waveform.path.ecg")
                Label("Rooms are first-class geometry so the runtime can report room confidence, not only x/y.", systemImage: "square.split.2x2")
                Label("Walls, entrances, and AR alignment points now come from venue-map JSON.", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var surveyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2D survey")
                            .font(.headline)
                        Text(surveyController?.statusText ?? "Start AR survey, capture alignment points, then walk coverage.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(surveyController?.isRunning == true ? "Stop" : "Start") {
                        toggleSurvey()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if let controller = surveyController {
                    HStack(spacing: 14) {
                        stat("Tracking", controller.trackingStatus)
                        stat("Samples", "\(controller.sampleCount)")
                        stat("Room", controller.latestRoomName ?? "-")
                    }

                    Button {
                        controller.captureNextAlignmentPoint()
                    } label: {
                        Label(alignmentButtonTitle(controller), systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRunning || controller.nextAlignmentPoint == nil)
                }
            }
        }
    }

    private var runtimeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("2D runtime")
                            .font(.headline)
                        Text(runtimeController?.statusText ?? "Start from an entrance to run the particle filter over this map.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(runtimeController?.isRunning == true ? "Stop" : "Start") {
                        toggleRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(map.entrances.isEmpty || cells.isEmpty)
                }

                if let controller = runtimeController {
                    HStack(spacing: 14) {
                        stat("Steps", "\(controller.detectedSteps)")
                        stat("Mag obs", "\(controller.magneticUpdates)")
                        stat("Radius", controller.estimate.map { String(format: "%.1fm", $0.confidenceRadiusMeters) } ?? "-")
                    }
                } else if map.entrances.isEmpty || cells.isEmpty {
                    Text(map.entrances.isEmpty ? "Add an entrance before runtime tracking." : "Generate/import heatmap cells before runtime tracking.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var implementationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Next build steps")
                    .font(.headline)
                Text("The view is reading the same JSON package the web editor exports. Next: generate heatmap cells from live AR-aligned survey samples instead of a static fixture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Imported maps are persisted to Documents/venue-maps/current-2d-venue-map.json.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mapSecondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func toggleSurvey() {
        if surveyController?.isRunning == true {
            surveyController?.stop()
            return
        }
        let controller = TwoDSurveyController(map: map, existingCells: cells)
        surveyController = controller
        controller.start()
    }

    private func toggleRuntime() {
        if runtimeController?.isRunning == true {
            runtimeController?.stop()
            return
        }
        guard let entrance = map.entrances.first else { return }
        surveyController?.stop()
        let controller = TwoDRuntimeController(map: map, heatmapCells: cells)
        runtimeController = controller
        controller.start(at: entrance)
    }

    private func alignmentButtonTitle(_ controller: TwoDSurveyController) -> String {
        if let next = controller.nextAlignmentPoint {
            return "Capture \(next.name)"
        }
        return controller.alignmentReady ? "Alignment complete" : "No alignment points"
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imagePixelSize(at url: URL) -> CGSize? {
        #if canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return image.size
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.size
        #else
        return nil
        #endif
    }
}

struct FloorPlanHeatmapCanvas: View {
    let map: VenueMap2D
    let cells: [MagneticHeatmapCell]
    let mode: HeatmapMode2D
    var currentPoint: MapPoint2D? = nil
    var runtimeEstimate: ParticleEstimate2D? = nil

    var body: some View {
        GeometryReader { proxy in
            let transform = MapTransform(map: map, size: proxy.size)
            ZStack(alignment: .topLeading) {
                if let image = floorPlanImage() {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: map.widthMeters * transform.scale, height: map.heightMeters * transform.scale)
                        .clipped()
                        .offset(x: transform.xOffset, y: transform.yOffset)
                        .opacity(0.72)
                }
                Canvas { context, size in
                    drawBackground(in: &context, size: size, hasImage: floorPlanImage() != nil)
                    drawWalkableAreas(in: &context, transform: transform)
                    drawHeatmap(in: &context, transform: transform)
                    drawRooms(in: &context, transform: transform)
                    drawWalls(in: &context, transform: transform)
                    drawEntrances(in: &context, transform: transform)
                    drawAlignmentPoints(in: &context, transform: transform)
                    drawRuntimeEstimate(in: &context, transform: transform)
                    drawCurrentPoint(in: &context, transform: transform)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("venue-map JSON · \(cells.count) heatmap cells")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
                    .padding(10)
            }
            .accessibilityLabel("2D floor plan heatmap")
        }
    }

    private func drawBackground(in context: inout GraphicsContext, size: CGSize, hasImage: Bool) {
        let rect = CGRect(origin: .zero, size: size)
        context.fill(Path(rect), with: .color(hasImage ? .clear : Color.mapSecondaryGroupedBackground))
    }

    private func floorPlanImage() -> Image? {
        guard let fileName = map.image?.fileName else { return nil }
        let docsURL = VenueMap2DStore.venueMapsDirectory.appendingPathComponent(fileName)
        #if canImport(UIKit)
        if let uiImage = UIImage(contentsOfFile: docsURL.path) { return Image(uiImage: uiImage) }
        if let uiImage = UIImage(named: fileName) { return Image(uiImage: uiImage) }
        if let url = Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: (fileName as NSString).pathExtension),
           let uiImage = UIImage(contentsOfFile: url.path) { return Image(uiImage: uiImage) }
        #elseif canImport(AppKit)
        if let nsImage = NSImage(contentsOf: docsURL) { return Image(nsImage: nsImage) }
        if let nsImage = NSImage(named: fileName) { return Image(nsImage: nsImage) }
        if let url = Bundle.main.url(forResource: (fileName as NSString).deletingPathExtension, withExtension: (fileName as NSString).pathExtension),
           let nsImage = NSImage(contentsOf: url) { return Image(nsImage: nsImage) }
        #endif
        return nil
    }

    private func drawHeatmap(in context: inout GraphicsContext, transform: MapTransform) {
        let maxSamples = max(cells.map(\.sampleCount).max() ?? 1, 1)
        let maxChange = max(cells.map(\.magneticChangeUT).max() ?? 1, 1)

        for cell in cells {
            let rect = transform.rect(center: cell.center, meters: cell.cellSizeMeters)
            let color: Color
            switch mode {
            case .surveyStrength:
                let sampleScore = min(1, Double(cell.sampleCount) / Double(maxSamples))
                let passScore = min(1, Double(cell.passCount) / 4.0)
                let score = 0.65 * sampleScore + 0.35 * passScore
                color = surveyStrengthColor(score)
            case .magneticFieldChange:
                color = magneticChangeColor(min(1, cell.magneticChangeUT / maxChange))
            }
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
        }
    }

    private func drawWalkableAreas(in context: inout GraphicsContext, transform: MapTransform) {
        for polygon in map.walkablePolygons {
            guard polygon.count >= 3 else { continue }
            var path = Path()
            path.move(to: transform.point(polygon[0]))
            for point in polygon.dropFirst() { path.addLine(to: transform.point(point)) }
            path.closeSubpath()
            context.fill(path, with: .color(.green.opacity(0.06)))
            context.stroke(path, with: .color(.green.opacity(0.35)), lineWidth: 1)
        }
    }

    private func drawRooms(in context: inout GraphicsContext, transform: MapTransform) {
        for room in map.rooms {
            var path = Path()
            guard let first = room.polygon.first else { continue }
            path.move(to: transform.point(first))
            for point in room.polygon.dropFirst() {
                path.addLine(to: transform.point(point))
            }
            path.closeSubpath()
            context.stroke(path, with: .color(.primary.opacity(0.65)), lineWidth: 1.4)

            if let centroid = centroid(room.polygon) {
                let resolved = context.resolve(Text(room.name).font(.caption.bold()).foregroundStyle(.primary))
                context.draw(resolved, at: transform.point(centroid), anchor: .center)
            }
        }
    }

    private func drawEntrances(in context: inout GraphicsContext, transform: MapTransform) {
        for entrance in map.entrances {
            let p = transform.point(entrance.point)
            let marker = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            context.fill(Path(ellipseIn: marker), with: .color(.blue))
            context.stroke(Path(ellipseIn: marker.insetBy(dx: -2, dy: -2)), with: .color(.white), lineWidth: 2)

            let label = context.resolve(Text(entrance.name).font(.caption2.weight(.semibold)).foregroundStyle(.blue))
            context.draw(label, at: CGPoint(x: p.x + 8, y: p.y), anchor: .leading)
        }
    }

    private func drawWalls(in context: inout GraphicsContext, transform: MapTransform) {
        for wall in map.walls where wall.points.count >= 2 {
            var path = Path()
            path.move(to: transform.point(wall.points[0]))
            for point in wall.points.dropFirst() { path.addLine(to: transform.point(point)) }
            context.stroke(path, with: .color(.primary.opacity(0.78)), lineWidth: 2.4)
        }
    }

    private func drawAlignmentPoints(in context: inout GraphicsContext, transform: MapTransform) {
        for alignment in map.alignmentPoints {
            let p = transform.point(alignment.point)
            var cross = Path()
            cross.move(to: CGPoint(x: p.x - 6, y: p.y))
            cross.addLine(to: CGPoint(x: p.x + 6, y: p.y))
            cross.move(to: CGPoint(x: p.x, y: p.y - 6))
            cross.addLine(to: CGPoint(x: p.x, y: p.y + 6))
            context.stroke(cross, with: .color(.purple), lineWidth: 2)

            let label = context.resolve(Text(alignment.name).font(.caption2.weight(.semibold)).foregroundStyle(.purple))
            context.draw(label, at: CGPoint(x: p.x + 8, y: p.y + 8), anchor: .leading)
        }
    }

    private func drawCurrentPoint(in context: inout GraphicsContext, transform: MapTransform) {
        guard let currentPoint else { return }
        let p = transform.point(currentPoint)
        let outer = CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)
        let inner = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: outer), with: .color(.blue.opacity(0.18)))
        context.stroke(Path(ellipseIn: outer), with: .color(.blue), lineWidth: 2)
        context.fill(Path(ellipseIn: inner), with: .color(.blue))
    }

    private func drawRuntimeEstimate(in context: inout GraphicsContext, transform: MapTransform) {
        guard let runtimeEstimate else { return }
        let p = transform.point(runtimeEstimate.point)
        let r = max(6, runtimeEstimate.confidenceRadiusMeters * transform.scale)
        let circle = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let dot = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: circle), with: .color(.indigo.opacity(0.12)))
        context.stroke(Path(ellipseIn: circle), with: .color(.indigo.opacity(0.75)), lineWidth: 2)
        context.fill(Path(ellipseIn: dot), with: .color(.indigo))
    }

    private func surveyStrengthColor(_ score: Double) -> Color {
        if score < 0.25 { return Color.gray.opacity(0.22) }
        if score < 0.5 { return Color.yellow.opacity(0.42) }
        if score < 0.75 { return Color.green.opacity(0.48) }
        return Color.green.opacity(0.74)
    }

    private func magneticChangeColor(_ score: Double) -> Color {
        if score < 0.2 { return Color.blue.opacity(0.24) }
        if score < 0.45 { return Color.cyan.opacity(0.34) }
        if score < 0.7 { return Color.orange.opacity(0.48) }
        return Color.red.opacity(0.66)
    }

    private func centroid(_ polygon: [MapPoint2D]) -> MapPoint2D? {
        guard !polygon.isEmpty else { return nil }
        let sum = polygon.reduce(MapPoint2D(x: 0, y: 0)) { partial, point in
            MapPoint2D(x: partial.x + point.x, y: partial.y + point.y)
        }
        return MapPoint2D(x: sum.x / Double(polygon.count), y: sum.y / Double(polygon.count))
    }
}

private struct MapTransform {
    let map: VenueMap2D
    let scale: Double
    let xOffset: Double
    let yOffset: Double

    init(map: VenueMap2D, size: CGSize) {
        self.map = map
        let sx = size.width / max(map.widthMeters, 1)
        let sy = size.height / max(map.heightMeters, 1)
        scale = min(sx, sy)
        xOffset = (size.width - map.widthMeters * scale) / 2
        yOffset = (size.height - map.heightMeters * scale) / 2
    }

    func point(_ p: MapPoint2D) -> CGPoint {
        CGPoint(x: xOffset + p.x * scale, y: yOffset + p.y * scale)
    }

    func rect(center: MapPoint2D, meters: Double) -> CGRect {
        let side = meters * scale
        let p = point(center)
        return CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side).insetBy(dx: 0.5, dy: 0.5)
    }
}

private extension Color {
    static var mapGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.gray.opacity(0.08)
        #endif
    }

    static var mapSecondaryGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .underPageBackgroundColor)
        #else
        Color.gray.opacity(0.14)
        #endif
    }
}
