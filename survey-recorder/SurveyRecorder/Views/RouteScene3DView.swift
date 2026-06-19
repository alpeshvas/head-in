import SwiftUI
import SceneKit
import simd

/// Isometric 3-D rendering of the REAL surveyed route — same `pathData` the flat
/// map uses, nothing synthetic. No sky, no ground plane: just the ground-truth
/// path as a glowing tube floating on the instrument backdrop, numbered
/// checkpoint posts standing at the surveyed positions, and the live marker
/// riding the path. Travelled segments glow phosphor; the rest is dim steel.
///
/// Honesty is preserved: the marker rides the 1-D arc-length path (displayBin),
/// exactly like the 2-D instrument — the third dimension is only viewing angle.
struct RouteScene3DView: View {
    let controller: LivePositioningController
    let pathData: RoutePathData
    var showBadges = true
    /// When true the scene accepts orbit / tilt / pinch-zoom gestures. Off in the
    /// scrollable card (would fight scrolling); on in the full-screen map.
    var interactive = false

    var body: some View {
        let active = controller.isRunning || controller.isComplete
        // Use the same display names as the legend (survey-bridged when available).
        let names = pathData.checkpoints.indices.map {
            controller.anchorDisplayName($0, fallback: pathData.checkpoints[$0].name)
        }
        RouteSceneRepresentable(
            pathData: pathData,
            names: names,
            markerBin: controller.displayBin,
            reachedCheckpoints: controller.reachedCheckpoints,
            active: active,
            tint: UIColor(routeMapState(controller).color),
            interactive: interactive
        )
    }
}

// MARK: - UIViewRepresentable bridge

struct RouteSceneRepresentable: UIViewRepresentable {
    let pathData: RoutePathData
    var names: [String] = []
    let markerBin: Double
    let reachedCheckpoints: Int
    let active: Bool
    let tint: UIColor
    var interactive = false

    func makeCoordinator() -> SceneCoordinator { SceneCoordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = FittingSCNView()
        view.backgroundColor = UIColor(Instrument.ink)
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        let world = RouteWorld(pathData: pathData, names: names, interactive: interactive)
        view.scene = world.scene
        view.pointOfView = world.cameraNode
        view.fitRadius = world.boundingRadius
        if interactive {
            view.allowsCameraControl = true
            let cc = view.defaultCameraController
            cc.interactionMode = .orbitTurntable
            cc.target = SCNVector3(0, 0.5, 0)
            cc.inertiaEnabled = true
            // Keep it earth-like: never let the camera tip below the route or
            // straight overhead. Angles are degrees above the horizon.
            cc.minimumVerticalAngle = 12
            cc.maximumVerticalAngle = 80
        }
        context.coordinator.world = world
        context.coordinator.apply(self, animated: false)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let sig = RouteWorld.signature(of: pathData) + names.joined(separator: "|")
        if context.coordinator.world?.signature != sig {
            let world = RouteWorld(pathData: pathData, names: names, interactive: interactive)
            view.scene = world.scene
            view.pointOfView = world.cameraNode
            (view as? FittingSCNView)?.fitRadius = world.boundingRadius
            (view as? FittingSCNView)?.didFit = false
            context.coordinator.world = world
        }
        context.coordinator.apply(self, animated: true)
    }
}

/// Fits the orthographic route to the frame once real bounds exist. For an
/// orthographic camera the horizontal half-span is scale·aspect, so a tall
/// portrait frame needs a larger scale to fit a wide route. Fits once, then
/// leaves the camera alone (so interactive pinch-zoom isn't overridden).
final class FittingSCNView: SCNView {
    var fitRadius: Float = 12
    var didFit = false
    override func layoutSubviews() {
        super.layoutSubviews()
        guard !didFit, bounds.width > 1, bounds.height > 1,
              let cam = pointOfView?.camera else { return }
        let aspect = Float(bounds.width / bounds.height)
        cam.orthographicScale = Double(fitRadius / min(1, aspect))
        didFit = true
    }
}

final class SceneCoordinator {
    var world: RouteWorld?
    func apply(_ r: RouteSceneRepresentable, animated: Bool) {
        world?.update(markerBin: r.markerBin, reached: r.reachedCheckpoints,
                      active: r.active, tint: r.tint, animated: animated)
    }
}

// MARK: - The 3-D world (built from the real path)

final class RouteWorld {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let signature: String
    let boundingRadius: Float   // half-diagonal of the scaled route + margin

    private let pathData: RoutePathData
    private let names: [String]
    private let interactive: Bool
    private let scale: Float
    private let cx: Float, cz: Float
    private let lift: Float = 0.08          // path floats just above y=0
    private let markerNode = SCNNode()
    private let markerHalo = SCNNode()
    private var segments: [(mat: SCNMaterial, endBin: Int)] = []
    private var checkpointDots: [SCNMaterial] = []

    static func signature(of p: RoutePathData) -> String {
        "\(p.bins)-\(p.checkpoints.count)-\(p.bounds.minX)-\(p.bounds.maxX)-\(p.bounds.minZ)-\(p.bounds.maxZ)"
    }

    init(pathData: RoutePathData, names: [String] = [], interactive: Bool = false) {
        self.pathData = pathData
        self.names = names
        self.interactive = interactive
        self.signature = RouteWorld.signature(of: pathData) + names.joined(separator: "|")
        let b = pathData.bounds
        cx = Float((b.minX + b.maxX) / 2)
        cz = Float((b.minZ + b.maxZ) / 2)
        let spanX = Float(b.maxX - b.minX), spanZ = Float(b.maxZ - b.minZ)
        let span = max(spanX, spanZ, 0.5)
        scale = 16 / span                   // normalise longest side to ~16 units
        boundingRadius = 0.5 * (spanX * spanX + spanZ * spanZ).squareRoot() * scale * 1.1 + 0.8

        scene.background.contents = UIColor(Instrument.ink)
        buildGrid()
        buildPath()
        buildCheckpoints()
        buildMarker()
        buildLights()
        buildCamera()
    }

    // MARK: geometry

    private func world(_ x: Double, _ z: Double, y: Float) -> SCNVector3 {
        SCNVector3((Float(x) - cx) * scale, y, (Float(z) - cz) * scale)
    }

    private func point(atBin bin: Double) -> SCNVector3 {
        let n = pathData.path.count
        let i0 = max(0, min(n - 1, Int(bin)))
        let i1 = max(0, min(n - 1, i0 + 1))
        let t = Float(bin - Double(i0))
        let a = pathData.path[i0], c = pathData.path[i1]
        let x = a[0] + Double(t) * (c[0] - a[0])
        let z = a[1] + Double(t) * (c[1] - a[1])
        return world(x, z, y: lift)
    }

    /// Faint blueprint grid on the y=0 plane — a coordinate reference so the
    /// route reads as sitting on a floor, with brighter X/Z axes through origin.
    private func buildGrid() {
        let extent = CGFloat(boundingRadius * 2.6)
        let cell: CGFloat = 1.0
        let plane = SCNPlane(width: extent, height: extent)
        let mat = SCNMaterial()
        mat.diffuse.contents = RouteWorld.gridTexture()
        mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
        let reps = Float(extent / cell)
        mat.diffuse.contentsTransform = SCNMatrix4MakeScale(reps, reps, 1)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        plane.materials = [mat]
        let node = SCNNode(geometry: plane)
        node.eulerAngles.x = -.pi / 2       // lay flat
        node.position.y = 0                 // just under the road (lift = 0.08)
        node.renderingOrder = -10
        scene.rootNode.addChildNode(node)
    }

    /// Build the path as a flat road — short overlapping ribbon segments lying on
    /// the plane (recoloured by progress), rather than a round rod.
    private func buildPath() {
        let n = pathData.path.count
        let stride = max(1, n / 140)        // cap segment count
        var idxs = Array(Swift.stride(from: 0, to: n - 1, by: stride))
        if idxs.last != n - 1 { idxs.append(n - 1) }
        let roadWidth: CGFloat = 0.55
        for k in 0..<(idxs.count - 1) {
            let a = point(atBin: Double(idxs[k]))
            let c = point(atBin: Double(idxs[k + 1]))
            let dx = c.x - a.x, dz = c.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            let mat = Mat.path(travelled: false)
            // flat slab, slightly over-length so corners overlap seamlessly
            let slab = SCNBox(width: roadWidth, height: 0.06,
                              length: CGFloat(max(len, 0.001)) * 1.12, chamferRadius: 0.02)
            slab.materials = [mat]
            let node = SCNNode(geometry: slab)
            node.position = SCNVector3((a.x + c.x) / 2, lift, (a.z + c.z) / 2)
            node.eulerAngles.y = atan2(dx, dz)   // length axis follows the path
            scene.rootNode.addChildNode(node)
            segments.append((mat, idxs[k + 1]))
        }
    }

    private func buildCheckpoints() {
        let outDist: Float = 0.32       // pin stands just beside the road
        let pinH: Float = 0.95          // how tall the pin rises
        for (i, cp) in pathData.checkpoints.enumerated() {
            let onRoute = point(atBin: Double(cp.bin))
            // small outward perpendicular offset so the pin stands beside the
            // road (outside the loop), not on the line.
            let pa = point(atBin: Double(max(0, cp.bin - 1)))
            let pc = point(atBin: Double(min(pathData.bins - 1, cp.bin + 1)))
            var nx = -(pc.z - pa.z), nz = (pc.x - pa.x)
            let len = (nx * nx + nz * nz).squareRoot()
            if len > 1e-5 { nx /= len; nz /= len } else { nx = 1; nz = 0 }
            let outward: Float = (onRoute.x * nx + onRoute.z * nz) >= 0 ? 1 : -1
            let bx = onRoute.x + nx * outward * outDist
            let bz = onRoute.z + nz * outward * outDist
            // vertical pin stem rising from the plane
            let stem = SCNCylinder(radius: 0.03, height: CGFloat(pinH))
            stem.materials = [Mat.post()]
            let stemN = SCNNode(geometry: stem)
            stemN.position = SCNVector3(bx, lift + pinH / 2, bz)
            scene.rootNode.addChildNode(stemN)
            // pin head on top
            let dotMat = Mat.emissive(UIColor(Instrument.steel))
            checkpointDots.append(dotMat)
            let head = SCNSphere(radius: 0.13); head.materials = [dotMat]
            let headN = SCNNode(geometry: head)
            headN.position = SCNVector3(bx, lift + pinH, bz)
            scene.rootNode.addChildNode(headN)
            // name label, billboarded, just above the pin head
            let name = i < names.count ? names[i] : cp.name
            let img = RouteWorld.label("\(i + 1)  \(name)")
            let lm = SCNMaterial()
            lm.diffuse.contents = img; lm.isDoubleSided = true
            lm.lightingModel = .constant; lm.writesToDepthBuffer = false
            let h: CGFloat = 0.40
            let plane = SCNPlane(width: h * img.size.width / img.size.height, height: h)
            plane.materials = [lm]
            let labelN = SCNNode(geometry: plane)
            labelN.position = SCNVector3(bx, lift + pinH + 0.36, bz)
            labelN.constraints = [SCNBillboardConstraint()]
            scene.rootNode.addChildNode(labelN)
        }
    }

    private func buildMarker() {
        let core = SCNSphere(radius: 0.34)
        core.materials = [Mat.emissive(UIColor(Instrument.phosphor))]
        markerNode.geometry = core
        let halo = SCNSphere(radius: 0.6)
        let hm = SCNMaterial()
        hm.diffuse.contents = UIColor.clear
        hm.emission.contents = UIColor(Instrument.phosphor).withAlphaComponent(0.3)
        hm.blendMode = .add; hm.writesToDepthBuffer = false; hm.lightingModel = .constant
        halo.materials = [hm]
        markerHalo.geometry = halo
        markerNode.addChildNode(markerHalo)
        // gentle pulse
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.25, duration: 0.9),
            SCNAction.scale(to: 0.85, duration: 0.9)])
        pulse.timingMode = .easeInEaseOut
        markerHalo.runAction(.repeatForever(pulse))
        scene.rootNode.addChildNode(markerNode)
    }

    private func buildLights() {
        let key = SCNLight(); key.type = .directional; key.intensity = 700
        let keyN = SCNNode(); keyN.light = key
        keyN.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0)
        scene.rootNode.addChildNode(keyN)
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 500
        amb.color = UIColor(Instrument.steel)
        let ambN = SCNNode(); ambN.light = amb
        scene.rootNode.addChildNode(ambN)
    }

    private func buildCamera() {
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = 11
        cam.zNear = 0.1; cam.zFar = 200
        cam.bloomIntensity = 0.4
        cam.bloomThreshold = 0.7
        cam.bloomBlurRadius = 8
        cam.wantsHDR = false        // keep the instrument-ink background truly dark
        cameraNode.camera = cam
        // classic isometric vantage
        cameraNode.position = SCNVector3(14, 11.5, 14)   // ~35° true isometric
        scene.rootNode.addChildNode(cameraNode)
        if interactive {
            // let the camera controller own orientation from here
            cameraNode.look(at: SCNVector3(0, 0.5, 0))
        } else {
            let target = SCNNode(); target.position = SCNVector3(0, 0.5, 0)
            scene.rootNode.addChildNode(target)
            cameraNode.constraints = [SCNLookAtConstraint(target: target)]
        }
    }

    // MARK: live update

    func update(markerBin: Double, reached: Int, active: Bool, tint: UIColor, animated: Bool) {
        let upto = Int(markerBin.rounded())
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.4 : 0
        // recolour travelled segments — muted emission so it reads as a soft
        // glow, not neon
        for (mat, endBin) in segments {
            let travelled = endBin <= upto
            mat.diffuse.contents = travelled ? tint : UIColor(Instrument.steel)
            mat.emission.contents = travelled ? RouteWorld.dim(tint, 0.4) : UIColor.black
        }
        // checkpoint dots glow softly when reached
        for (i, mat) in checkpointDots.enumerated() {
            let on = i < reached
            mat.diffuse.contents = on ? tint : UIColor(Instrument.steel)
            mat.emission.contents = on ? RouteWorld.dim(tint, 0.45) : RouteWorld.dim(UIColor(Instrument.steel), 0.5)
        }
        // marker
        markerNode.position = point(atBin: max(0, min(Double(pathData.bins - 1), markerBin)))
        markerNode.position.y = lift + 0.45
        markerNode.opacity = active ? 1 : 0.5
        if let core = markerNode.geometry?.materials.first {
            core.emission.contents = RouteWorld.dim(tint, 0.75)
        }
        if let h = markerHalo.geometry?.materials.first {
            h.emission.contents = tint.withAlphaComponent(0.3)
        }
        SCNTransaction.commit()
    }

    // MARK: helpers

    /// One grid cell: transparent with thin lines on two edges so it tiles into
    /// graph paper. Drawn in the instrument grid colour.
    static func gridTexture() -> UIImage {
        let s: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: s, height: s)).image { ctx in
            let cg = ctx.cgContext
            cg.setStrokeColor(UIColor(Instrument.grid).withAlphaComponent(0.9).cgColor)
            cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: 0, y: 0)); cg.addLine(to: CGPoint(x: s, y: 0))
            cg.move(to: CGPoint(x: 0, y: 0)); cg.addLine(to: CGPoint(x: 0, y: s))
            cg.strokePath()
        }
    }

    /// Darken a colour toward black by a factor (1 = unchanged, 0 = black).
    static func dim(_ c: UIColor, _ f: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * f, green: g * f, blue: b * f, alpha: a)
    }

    static func cylinder(from a: SCNVector3, to b: SCNVector3, radius: CGFloat, material: SCNMaterial) -> SCNNode {
        let va = SIMD3<Float>(a.x, a.y, a.z), vb = SIMD3<Float>(b.x, b.y, b.z)
        let d = vb - va
        let h = simd_length(d)
        let cyl = SCNCylinder(radius: radius, height: CGFloat(max(h, 0.001)))
        cyl.radialSegmentCount = 8
        cyl.materials = [material]
        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        if h > 1e-5 {
            let dir = d / h
            let up = SIMD3<Float>(0, 1, 0)
            let dot = simd_dot(up, dir)
            if dot < -0.9999 {
                node.eulerAngles = SCNVector3(Float.pi, 0, 0)
            } else if dot < 0.9999 {
                let axis = simd_normalize(simd_cross(up, dir))
                node.rotation = SCNVector4(axis.x, axis.y, axis.z, acos(dot))
            }
        }
        return node
    }

    /// Small floating text label (transparent background, subtle shadow for
    /// legibility over any colour). Rendered once per checkpoint.
    static func label(_ text: String) -> UIImage {
        let font = UIFont.monospacedSystemFont(ofSize: 40, weight: .semibold)
        let s = text as NSString
        let pad: CGFloat = 16
        let textSize = s.size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + pad * 2, height: ceil(textSize.height) + pad)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let shadow = NSShadow()
            shadow.shadowColor = UIColor(Instrument.ink).withAlphaComponent(0.9)
            shadow.shadowBlurRadius = 6; shadow.shadowOffset = .zero
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor(Instrument.textPrimary),
                .shadow: shadow]
            s.draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: attrs)
        }
    }
}

// MARK: - Materials

private enum Mat {
    static func path(travelled: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(Instrument.steel)
        m.lightingModel = .lambert
        return m
    }
    static func post() -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(Instrument.hairline)
        m.lightingModel = .lambert
        return m
    }
    static func emissive(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.emission.contents = color
        m.lightingModel = .constant
        return m
    }
}
