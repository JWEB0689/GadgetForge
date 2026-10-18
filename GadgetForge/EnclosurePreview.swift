import SwiftUI
import SceneKit

/// SceneKit preview of the tray + lid with the parts placed inside.
struct EnclosurePreview: NSViewRepresentable {
    var spec: EnclosureSpec
    var design: DeviceDesign

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        let scene = SCNScene()
        let s: Double = 0.1 // mm -> scene units

        func box(_ w: Double, _ h: Double, _ d: Double, color: NSColor, opacity: Double = 1) -> SCNNode {
            let geo = SCNBox(width: w * s, height: h * s, length: d * s, chamferRadius: 0.02)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.transparency = opacity
            geo.materials = [mat]
            return SCNNode(geometry: geo)
        }

        // Tray walls (translucent) + base
        let tray = SCNNode()
        let wallMat: (SCNNode) -> Void = { _ in }
        _ = wallMat
        let base = box(spec.trayW, spec.base, spec.trayD, color: .systemGray, opacity: 0.35)
        base.position = SCNVector3(Float(spec.trayW / 2 * s), Float(spec.base / 2 * s), Float(spec.trayD / 2 * s))
        tray.addChildNode(base)
        let wallH = spec.trayWallH
        let walls: [(Double, Double, Double, Double, Double, Double)] = [
            (spec.trayW, wallH, spec.wall, spec.trayW / 2, spec.base + wallH / 2, spec.wall / 2),
            (spec.trayW, wallH, spec.wall, spec.trayW / 2, spec.base + wallH / 2, spec.trayD - spec.wall / 2),
            (spec.wall, wallH, spec.trayD, spec.wall / 2, spec.base + wallH / 2, spec.trayD / 2),
            (spec.wall, wallH, spec.trayD, spec.trayW - spec.wall / 2, spec.base + wallH / 2, spec.trayD / 2),
        ]
        for (w, h, d, x, y, z) in walls {
            let n = box(w, h, d, color: .systemBlue, opacity: 0.25)
            n.position = SCNVector3(Float(x * s), Float(y * s), Float(z * s))
            tray.addChildNode(n)
        }
        // Lid beside the tray
        let lid = box(spec.trayW, spec.lidT, spec.trayD, color: .systemTeal, opacity: 0.3)
        lid.position = SCNVector3(Float((spec.trayW * 1.5 + 15) * s), Float(spec.lidT / 2 * s), Float(spec.trayD / 2 * s))
        tray.addChildNode(lid)
        scene.rootNode.addChildNode(tray)

        // Parts
        let palette: [NSColor] = [.systemGreen, .systemOrange, .systemPurple, .systemPink, .systemYellow, .systemRed]
        for (i, (comp, x, z)) in componentLayout(for: design, spec: spec).enumerated() {
            let n = box(comp.widthMm, comp.heightMm, comp.depthMm,
                        color: palette[i % palette.count])
            n.position = SCNVector3(Float(x * s),
                                    Float((spec.base + comp.heightMm / 2) * s),
                                    Float(z * s))
            scene.rootNode.addChildNode(n)
        }

        // Camera
        let cam = SCNCamera()
        cam.zFar = 1000
        let camNode = SCNNode()
        camNode.camera = cam
        let cx = Float(spec.trayW * 0.75 * s)
        camNode.position = SCNVector3(cx + 12, 14, Float(spec.trayD * s) + 14)
        camNode.look(at: SCNVector3(cx, 2, Float(spec.trayD / 2 * s)))
        scene.rootNode.addChildNode(camNode)

        view.scene = scene
        view.pointOfView = camNode
    }
}
