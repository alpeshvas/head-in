import SwiftUI
import SceneKit
import simd

struct LivePositioningView: View {
    @State private var bundle = VenueMap2DStore.loadSavedOrBundled()
    @State private var controller: TwoDRuntimeController?
    @State private var loadError: String?
    @State private var showMagneticFieldOverlay = false
    @State private var scrollToTopToken = 0
    @State private var checkpointAudioPlayer = CheckpointAudioPlayer()

    private var map: VenueMap2D { bundle.map }
    private var cells: [MagneticHeatmapCell] { bundle.heatmapCells }
    private var cellsHaveRuntimeFingerprint: Bool {
        cells.contains { $0.meanMagnitudeUT != nil && $0.meanVerticalUT != nil && $0.meanHorizontalUT != nil }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Color.clear
                        .frame(height: 18)
                        .id("liveTop")
                    checkpointStoryPanel
                        .id("checkpointPanel")
                    mapCard
                    controlsCard
                    diagnosticsCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .onChange(of: scrollToTopToken) { _, _ in
                withAnimation(.easeInOut(duration: 0.45)) {
                    proxy.scrollTo("checkpointPanel", anchor: .top)
                }
            }
            .onChange(of: controller?.activeCheckpoint?.id) { _, id in
                guard id != nil else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo("checkpointPanel", anchor: .top)
                }
            }
        }
        .background(Color.black)
        .navigationTitle("Live")
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.black, for: .navigationBar)
        .onAppear(perform: reloadBundleIfIdle)
        .onDisappear { controller?.stop() }
        .onChange(of: controller?.activeCheckpoint?.id) { _, _ in
            guard let checkpoint = controller?.activeCheckpoint else {
                checkpointAudioPlayer.resetCheckpointGate()
                return
            }
            checkpointAudioPlayer.play(checkpoint: checkpoint)
        }
        .alert("Live unavailable", isPresented: Binding(
            get: { loadError != nil },
            set: { if !$0 { loadError = nil } }
        )) {
            Button("OK", role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "Unknown error")
        }
    }

    private var checkpointStoryPanel: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let checkpoint = controller?.activeCheckpoint {
                VStack(alignment: .leading, spacing: 9) {
                    Text("YOU ARE NEAR")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(.orange.opacity(0.9))
                    Text(checkpoint.name)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    if !checkpoint.message.isEmpty {
                        Text(checkpoint.message)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [.white.opacity(0.13), .white.opacity(0.045)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .orange.opacity(0.20), radius: 24, y: 8)
                .transition(.opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minHeight: 128, alignment: .center)
        .animation(.easeInOut(duration: 0.35), value: controller?.activeCheckpoint?.id)
    }

    private var mapCard: some View {
        IsometricLiveMapView(
            map: map,
            cells: cells,
            checkpoints: map.checkpoints,
            estimate: controller?.estimate,
            activeCheckpoint: controller?.activeCheckpoint,
            showMagneticFieldOverlay: showMagneticFieldOverlay
        )
        .frame(height: 470)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.7), radius: 20, y: 12)
    }

    private var controlsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button(controller?.isRunning == true ? "Restart" : "Start") {
                        startRuntime()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartRuntime)

                    Button("Stop") {
                        controller?.stop()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller?.isRunning != true)
                }

                Label("Live uses Combo matching for the demo runtime.", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.54))

                Toggle("Show magnetic field overlay", isOn: $showMagneticFieldOverlay)
                    .font(.caption.weight(.semibold))
                    .tint(.cyan)

                if !canStartRuntime {
                    Text(runtimeUnavailableText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Diagnostics")
                    .font(.headline)
                if let controller {
                    diagnosticRow("Steps", "\(controller.detectedSteps)")
                    diagnosticRow("Apple steps", "\(controller.applePedometerSteps)")
                    diagnosticRow("Mag obs", "\(controller.magneticUpdates)")
                    diagnosticRow("Room", currentRoomName)
                    diagnosticRow("Radius", controller.estimate.map { String(format: "%.1fm", $0.confidenceRadiusMeters) } ?? "-")
                    diagnosticRow("Nearest cell", controller.nearestHeatmapCellDistanceMeters.map { String(format: "%.1fm", $0) } ?? "-")
                    diagnosticRow("Residual", controller.magneticResidualUT.map { String(format: "%.1fµT", $0) } ?? "-")
                    diagnosticRow("Particles", "\(controller.particleSnapshot.count)")
                } else {
                    Text("Runtime diagnostics will appear after Start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var canStartRuntime: Bool {
        !map.entrances.isEmpty && !cells.isEmpty && cellsHaveRuntimeFingerprint
    }

    private var currentRoomName: String {
        guard let roomId = controller?.estimate?.roomId else { return "-" }
        return map.rooms.first { $0.id == roomId }?.name ?? roomId
    }

    private var runtimeUnavailableText: String {
        if map.entrances.isEmpty { return "Add an entrance before runtime tracking." }
        if cells.isEmpty { return "Generate/import heatmap cells before runtime tracking." }
        return "Heatmap cells need magnitude, vertical, and horizontal means. Resurvey in-app or import a rebuilt map."
    }

    private func reloadBundleIfIdle() {
        guard controller?.isRunning != true else { return }
        bundle = VenueMap2DStore.loadSavedOrBundled()
    }

    private func startRuntime() {
        guard let entrance = map.entrances.first else {
            loadError = "This map has no entrance. Add one to the map JSON before live tracking."
            return
        }
        guard cellsHaveRuntimeFingerprint else {
            loadError = runtimeUnavailableText
            return
        }
        controller?.stop()
        let next = TwoDRuntimeController(map: map, heatmapCells: cells, observationMode: .combo)
        controller = next
        next.start(at: entrance)
        scrollToTopToken += 1
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.trailing)
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct IsometricLiveMapView: View {
    let map: VenueMap2D
    let cells: [MagneticHeatmapCell]
    let checkpoints: [Checkpoint2D]
    let estimate: ParticleEstimate2D?
    let activeCheckpoint: Checkpoint2D?
    let showMagneticFieldOverlay: Bool

    var body: some View {
        ZStack {
            VenueScene3DRepresentable(
                map: map,
                cells: cells,
                checkpoints: checkpoints,
                estimate: estimate,
                activeCheckpointID: activeCheckpoint?.id,
                showMagneticFieldOverlay: showMagneticFieldOverlay,
                interactive: true
            )

            LinearGradient(
                colors: [.black.opacity(0.96), .black.opacity(0.32), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)

            LinearGradient(
                colors: [.clear, .black.opacity(0.10), .black.opacity(0.94)],
                startPoint: .center,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }
}

private struct VenueScene3DRepresentable: UIViewRepresentable {
    let map: VenueMap2D
    let cells: [MagneticHeatmapCell]
    let checkpoints: [Checkpoint2D]
    let estimate: ParticleEstimate2D?
    let activeCheckpointID: String?
    let showMagneticFieldOverlay: Bool
    var interactive = false

    func makeCoordinator() -> VenueScene3DCoordinator { VenueScene3DCoordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = VenueFittingSCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        view.allowsCameraControl = interactive
        view.rendersContinuously = false
        view.isPlaying = true
        view.scene = SCNScene()

        let world = VenueWorld3D(map: map, cells: cells, checkpoints: checkpoints, showMagneticFieldOverlay: showMagneticFieldOverlay, interactive: interactive)
        view.scene = world.scene
        view.pointOfView = world.cameraNode
        view.fitRadius = world.boundingRadius
        configureCameraControl(for: view, world: world)
        context.coordinator.world = world
        context.coordinator.apply(estimate: estimate, activeCheckpointID: activeCheckpointID, animated: false)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let signature = VenueWorld3D.signature(map: map, checkpoints: checkpoints, cellCount: cells.count, showMagneticFieldOverlay: showMagneticFieldOverlay)
        if context.coordinator.world?.signature != signature {
            let world = VenueWorld3D(map: map, cells: cells, checkpoints: checkpoints, showMagneticFieldOverlay: showMagneticFieldOverlay, interactive: interactive)
            view.scene = world.scene
            view.pointOfView = world.cameraNode
            if let fitting = view as? VenueFittingSCNView {
                fitting.fitRadius = world.boundingRadius
                fitting.didFit = false
            }
            configureCameraControl(for: view, world: world)
            context.coordinator.world = world
        }
        context.coordinator.apply(estimate: estimate, activeCheckpointID: activeCheckpointID, animated: true)
    }

    private func configureCameraControl(for view: SCNView, world: VenueWorld3D) {
        view.allowsCameraControl = interactive
        guard interactive else { return }
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.target = SCNVector3(0, 0.35, 0)
        controller.inertiaEnabled = true
        controller.minimumVerticalAngle = 12
        controller.maximumVerticalAngle = 80
        // Touching the map should feel like inspecting the live scene, not scrolling.
        view.gestureRecognizers?.forEach { $0.cancelsTouchesInView = true }
    }
}

private final class VenueFittingSCNView: SCNView {
    var fitRadius: Float = 12
    var didFit = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didFit, bounds.width > 1, bounds.height > 1,
              let camera = pointOfView?.camera else { return }
        let aspect = Float(bounds.width / bounds.height)
        camera.orthographicScale = Double(fitRadius / min(1, aspect))
        didFit = true
    }
}

private final class VenueScene3DCoordinator {
    var world: VenueWorld3D?

    func apply(estimate: ParticleEstimate2D?, activeCheckpointID: String?, animated: Bool) {
        world?.update(estimate: estimate, activeCheckpointID: activeCheckpointID, animated: animated)
    }
}

private final class VenueWorld3D {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let signature: String
    let boundingRadius: Float
    let interactive: Bool

    private let map: VenueMap2D
    private let checkpoints: [Checkpoint2D]
    private let showMagneticFieldOverlay: Bool
    private let bounds: MapBounds2D
    private let scale: Float
    private let cx: Float
    private let cy: Float
    private let floorY: Float = 0
    private let liftY: Float = 0.06
    private let markerNode = SCNNode()
    private let markerHaloNode = SCNNode()
    private let confidenceNode = SCNNode()
    private var checkpointMaterials: [String: (pin: SCNMaterial, disk: SCNMaterial)] = [:]

    static func signature(map: VenueMap2D, checkpoints: [Checkpoint2D], cellCount: Int, showMagneticFieldOverlay: Bool) -> String {
        let entranceSignature = map.entrances
            .map { "\($0.id):\($0.point.x.rounded()):\($0.point.y.rounded()):\($0.name)" }
            .joined(separator: "|")
        let checkpointSignature = checkpoints
            .map { "\($0.id):\($0.point.x.rounded()):\($0.point.y.rounded()):\($0.name)" }
            .joined(separator: "|")
        return [
            map.venueId,
            String(map.widthMeters),
            String(map.heightMeters),
            String(map.rooms.count),
            String(map.walls.count),
            String(map.walkablePolygons.count),
            String(cellCount),
            String(showMagneticFieldOverlay),
            entranceSignature,
            checkpointSignature,
        ].joined(separator: "-")
    }

    init(map: VenueMap2D, cells: [MagneticHeatmapCell], checkpoints: [Checkpoint2D], showMagneticFieldOverlay: Bool, interactive: Bool = false) {
        self.map = map
        self.checkpoints = checkpoints
        self.showMagneticFieldOverlay = showMagneticFieldOverlay
        self.interactive = interactive
        self.signature = Self.signature(map: map, checkpoints: checkpoints, cellCount: cells.count, showMagneticFieldOverlay: showMagneticFieldOverlay)
        self.bounds = MapContentBounds.bounds(map: map, cells: cells, checkpoints: checkpoints, paddingMeters: 2.5)
        self.cx = Float((bounds.minX + bounds.maxX) / 2)
        self.cy = Float((bounds.minY + bounds.maxY) / 2)
        let span = Float(max(bounds.width, bounds.height, 0.5))
        self.scale = 16 / span
        let sx = Float(bounds.width) * scale
        let sy = Float(bounds.height) * scale
        self.boundingRadius = 0.5 * sqrt(sx * sx + sy * sy) * 1.18 + 1.2

        scene.background.contents = UIColor.black
        buildGrid()
        buildFloorGeometry()
        buildMagneticFieldOverlay(cells: cells)
        buildWalls()
        buildStartPoint()
        buildCheckpoints()
        buildMarker()
        buildLights()
        buildCamera()
    }

    private func world(_ point: MapPoint2D, y: Float = 0) -> SCNVector3 {
        SCNVector3((Float(point.x) - cx) * scale, y, (Float(point.y) - cy) * scale)
    }

    private func buildGrid() {
        let extent = CGFloat(boundingRadius * 2.8)
        let plane = SCNPlane(width: extent, height: extent)
        let material = SCNMaterial()
        material.diffuse.contents = Self.gridTexture()
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        let repeats = Float(extent / 1.0)
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
        material.lightingModel = .constant
        material.isDoubleSided = true
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2
        node.position.y = floorY - 0.02
        node.renderingOrder = -20
        scene.rootNode.addChildNode(node)
    }

    private func buildFloorGeometry() {
        let walkableMaterial = Venue3DMaterial.floor(UIColor(red: 0.12, green: 0.18, blue: 0.20, alpha: 0.55))
        for polygon in map.walkablePolygons where polygon.count >= 3 {
            let node = SCNNode(geometry: polygonGeometry(points: polygon, y: floorY, material: walkableMaterial))
            node.renderingOrder = -5
            scene.rootNode.addChildNode(node)
        }

        let palette = [
            UIColor(red: 0.23, green: 0.27, blue: 0.46, alpha: 0.62),
            UIColor(red: 0.16, green: 0.35, blue: 0.34, alpha: 0.58),
            UIColor(red: 0.28, green: 0.22, blue: 0.40, alpha: 0.58),
            UIColor(red: 0.18, green: 0.28, blue: 0.40, alpha: 0.58),
        ]
        for (index, room) in map.rooms.enumerated() where room.polygon.count >= 3 {
            let material = Venue3DMaterial.floor(palette[index % palette.count])
            let node = SCNNode(geometry: polygonGeometry(points: room.polygon, y: floorY + 0.01, material: material))
            scene.rootNode.addChildNode(node)
        }
    }

    private func buildMagneticFieldOverlay(cells: [MagneticHeatmapCell]) {
        guard showMagneticFieldOverlay else { return }
        let values = cells.compactMap(\.meanMagnitudeUT)
        guard let minValue = values.min(), let maxValue = values.max(), maxValue > minValue else { return }

        for cell in cells {
            guard Geometry2D.isWalkable(cell.center, in: map), let value = cell.meanMagnitudeUT else { continue }
            let score = min(1, max(0, (value - minValue) / (maxValue - minValue)))
            let side = CGFloat(cell.cellSizeMeters * Double(scale) * 1.02)
            let plane = SCNPlane(width: side, height: side)
            plane.cornerRadius = side * 0.08
            plane.materials = [Venue3DMaterial.magneticOverlay(Self.magneticFieldColor(score))]
            let node = SCNNode(geometry: plane)
            let p = world(cell.center, y: floorY + 0.035)
            node.position = p
            node.eulerAngles.x = -.pi / 2
            node.renderingOrder = -2
            scene.rootNode.addChildNode(node)
        }
    }

    private func polygonGeometry(points: [MapPoint2D], y: Float, material: SCNMaterial) -> SCNGeometry {
        let centroid = points.reduce(MapPoint2D(x: 0, y: 0)) { partial, point in
            MapPoint2D(x: partial.x + point.x, y: partial.y + point.y)
        }
        let center = MapPoint2D(x: centroid.x / Double(points.count), y: centroid.y / Double(points.count))
        var vertices = [world(center, y: y)]
        vertices.append(contentsOf: points.map { world($0, y: y) })

        var indices: [UInt32] = []
        for i in 1...points.count {
            let next = i == points.count ? 1 : i + 1
            indices.append(0)
            indices.append(UInt32(i))
            indices.append(UInt32(next))
        }
        let source = SCNGeometrySource(vertices: vertices)
        let data = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: MemoryLayout<UInt32>.size)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    private func buildWalls() {
        let material = Venue3DMaterial.wall()
        for wall in map.walls where wall.points.count >= 2 {
            for index in 1..<wall.points.count {
                let a = world(wall.points[index - 1], y: liftY + 0.10)
                let b = world(wall.points[index], y: liftY + 0.10)
                let node = Self.cylinder(from: a, to: b, radius: 0.035, material: material)
                scene.rootNode.addChildNode(node)
            }
        }
    }

    private func buildCheckpoints() {
        for checkpoint in checkpoints {
            let base = world(checkpoint.point, y: liftY)
            let color = UIColor(red: 1.0, green: 0.36, blue: 0.64, alpha: 1)
            let pinMaterial = Venue3DMaterial.emissive(color, strength: 0.35)
            let diskMaterial = Venue3DMaterial.disk(color.withAlphaComponent(0.12))
            checkpointMaterials[checkpoint.id] = (pinMaterial, diskMaterial)

            let disk = SCNCylinder(radius: CGFloat(3.0 * Double(scale)), height: 0.018)
            disk.radialSegmentCount = 64
            disk.materials = [diskMaterial]
            let diskNode = SCNNode(geometry: disk)
            diskNode.position = SCNVector3(base.x, floorY + 0.025, base.z)
            scene.rootNode.addChildNode(diskNode)

            let stem = SCNCylinder(radius: 0.035, height: 0.74)
            stem.radialSegmentCount = 10
            stem.materials = [Venue3DMaterial.post()]
            let stemNode = SCNNode(geometry: stem)
            stemNode.position = SCNVector3(base.x, liftY + 0.37, base.z)
            scene.rootNode.addChildNode(stemNode)

            let head = SCNSphere(radius: 0.16)
            head.segmentCount = 18
            head.materials = [pinMaterial]
            let headNode = SCNNode(geometry: head)
            headNode.position = SCNVector3(base.x, liftY + 0.78, base.z)
            scene.rootNode.addChildNode(headNode)
        }
    }

    private func buildStartPoint() {
        guard let entrance = map.entrances.first else { return }
        let base = world(entrance.point, y: liftY)
        let color = UIColor(red: 0.08, green: 0.86, blue: 1.0, alpha: 1)

        let disk = SCNCylinder(radius: CGFloat(max(0.30, 0.72 * Double(scale))), height: 0.018)
        disk.radialSegmentCount = 64
        disk.materials = [Venue3DMaterial.disk(color.withAlphaComponent(0.18))]
        let diskNode = SCNNode(geometry: disk)
        diskNode.position = SCNVector3(base.x, floorY + 0.03, base.z)
        scene.rootNode.addChildNode(diskNode)

        let stem = SCNCylinder(radius: 0.03, height: 0.54)
        stem.radialSegmentCount = 10
        stem.materials = [Venue3DMaterial.post()]
        let stemNode = SCNNode(geometry: stem)
        stemNode.position = SCNVector3(base.x, liftY + 0.27, base.z)
        scene.rootNode.addChildNode(stemNode)

        let head = SCNSphere(radius: 0.14)
        head.segmentCount = 18
        head.materials = [Venue3DMaterial.emissive(color, strength: 0.64)]
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(base.x, liftY + 0.57, base.z)
        scene.rootNode.addChildNode(headNode)

        let text = SCNText(string: "START", extrusionDepth: 0.01)
        text.font = UIFont.systemFont(ofSize: 16, weight: .heavy)
        text.flatness = 0.2
        text.materials = [Venue3DMaterial.emissive(color, strength: 0.48)]
        let labelNode = SCNNode(geometry: text)
        let bounds = text.boundingBox
        labelNode.pivot = SCNMatrix4MakeTranslation((bounds.min.x + bounds.max.x) / 2, bounds.min.y, 0)
        labelNode.scale = SCNVector3(0.018, 0.018, 0.018)
        labelNode.position = SCNVector3(base.x, liftY + 0.78, base.z)
        labelNode.constraints = [SCNBillboardConstraint()]
        scene.rootNode.addChildNode(labelNode)
    }

    private func buildMarker() {
        let disk = SCNCylinder(radius: 1, height: 0.018)
        disk.radialSegmentCount = 48
        disk.materials = [Venue3DMaterial.disk(UIColor.systemMint.withAlphaComponent(0.16))]
        confidenceNode.geometry = disk
        confidenceNode.opacity = 0
        scene.rootNode.addChildNode(confidenceNode)

        let core = SCNSphere(radius: 0.22)
        core.segmentCount = 20
        core.materials = [Venue3DMaterial.emissive(.systemMint, strength: 0.75)]
        markerNode.geometry = core
        markerNode.opacity = 0

        let halo = SCNSphere(radius: 0.40)
        halo.segmentCount = 20
        halo.materials = [Venue3DMaterial.halo(.systemMint)]
        markerHaloNode.geometry = halo
        markerNode.addChildNode(markerHaloNode)
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.22, duration: 0.9),
            SCNAction.scale(to: 0.86, duration: 0.9),
        ])
        pulse.timingMode = .easeInEaseOut
        markerHaloNode.runAction(.repeatForever(pulse))
        scene.rootNode.addChildNode(markerNode)
    }

    private func buildLights() {
        let key = SCNLight()
        key.type = .directional
        key.intensity = 720
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        scene.rootNode.addChildNode(keyNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 420
        ambient.color = UIColor(white: 0.52, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 12
        camera.zNear = 0.1
        camera.zFar = 220
        camera.wantsHDR = false
        camera.bloomIntensity = 0.35
        camera.bloomThreshold = 0.78
        camera.bloomBlurRadius = 7
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(13, 10.7, 13)
        scene.rootNode.addChildNode(cameraNode)
        if interactive {
            cameraNode.look(at: SCNVector3(0, 0.35, 0))
        } else {
            let target = SCNNode()
            target.position = SCNVector3(0, 0.35, 0)
            scene.rootNode.addChildNode(target)
            cameraNode.constraints = [SCNLookAtConstraint(target: target)]
        }
    }

    func update(estimate: ParticleEstimate2D?, activeCheckpointID: String?, animated: Bool) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.45 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        if let estimate {
            let p = world(estimate.point, y: liftY + 0.26)
            markerNode.position = p
            markerNode.opacity = 1
            confidenceNode.position = SCNVector3(p.x, floorY + 0.035, p.z)
            let radius = max(0.18, Float(estimate.confidenceRadiusMeters) * scale)
            confidenceNode.scale = SCNVector3(radius, 1, radius)
            confidenceNode.opacity = 1
        } else {
            markerNode.opacity = 0
            confidenceNode.opacity = 0
        }

        for (id, materials) in checkpointMaterials {
            let active = id == activeCheckpointID
            let color = active
                ? UIColor(red: 1.0, green: 0.58, blue: 0.20, alpha: 1)
                : UIColor(red: 1.0, green: 0.36, blue: 0.64, alpha: 1)
            materials.pin.diffuse.contents = color
            materials.pin.emission.contents = Self.dim(color, active ? 0.62 : 0.34)
            materials.disk.diffuse.contents = color.withAlphaComponent(active ? 0.24 : 0.10)
            materials.disk.emission.contents = color.withAlphaComponent(active ? 0.08 : 0.02)
        }
        SCNTransaction.commit()
    }

    static func gridTexture() -> UIImage {
        let size: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.12).cgColor)
            cg.setLineWidth(1)
            cg.move(to: CGPoint(x: 0, y: 0))
            cg.addLine(to: CGPoint(x: size, y: 0))
            cg.move(to: CGPoint(x: 0, y: 0))
            cg.addLine(to: CGPoint(x: 0, y: size))
            cg.strokePath()
        }
    }

    static func dim(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }

    static func magneticFieldColor(_ score: Double) -> UIColor {
        if score < 0.2 { return UIColor(red: 0.10, green: 0.42, blue: 1.0, alpha: 0.24) }
        if score < 0.4 { return UIColor(red: 0.0, green: 0.86, blue: 1.0, alpha: 0.25) }
        if score < 0.6 { return UIColor(red: 0.0, green: 0.92, blue: 0.55, alpha: 0.23) }
        if score < 0.8 { return UIColor(red: 1.0, green: 0.86, blue: 0.12, alpha: 0.24) }
        return UIColor(red: 1.0, green: 0.23, blue: 0.15, alpha: 0.25)
    }

    static func cylinder(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let va = SIMD3<Float>(a.x, a.y, a.z)
        let vb = SIMD3<Float>(b.x, b.y, b.z)
        let d = vb - va
        let height = simd_length(d)
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(max(height, 0.001)))
        cylinder.radialSegmentCount = 8
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        if height > 1e-5 {
            let direction = d / height
            let up = SIMD3<Float>(0, 1, 0)
            let dot = simd_dot(up, direction)
            if dot < -0.9999 {
                node.eulerAngles = SCNVector3(Float.pi, 0, 0)
            } else if dot < 0.9999 {
                let axis = simd_normalize(simd_cross(up, direction))
                node.rotation = SCNVector4(axis.x, axis.y, axis.z, acos(dot))
            }
        }
        return node
    }
}

private enum Venue3DMaterial {
    static func floor(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.04)
        material.lightingModel = .lambert
        material.isDoubleSided = true
        material.blendMode = .alpha
        return material
    }

    static func wall() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.58)
        material.emission.contents = UIColor.white.withAlphaComponent(0.08)
        material.lightingModel = .lambert
        return material
    }

    static func post() -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.62)
        material.lightingModel = .lambert
        return material
    }

    static func disk(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.20)
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    static func magneticOverlay(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.16)
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.isDoubleSided = true
        return material
    }

    static func emissive(_ color: UIColor, strength: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = VenueWorld3D.dim(color, strength)
        material.lightingModel = .constant
        return material
    }

    static func halo(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.clear
        material.emission.contents = color.withAlphaComponent(0.25)
        material.lightingModel = .constant
        material.blendMode = .add
        material.writesToDepthBuffer = false
        return material
    }
}
