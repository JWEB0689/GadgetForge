import Foundation

// MARK: - Parametric enclosure (tray + lid), sized from the design's parts

struct EnclosureSpec {
    /// Tray outer dimensions (mm)
    var trayW: Double
    var trayD: Double
    var trayWallH: Double
    var wall: Double = 2.0
    var base: Double = 2.5
    var lidT: Double = 2.0
    /// Virtual PCB the parts sit on (mm)
    var pcbW: Double
    var pcbD: Double
}

/// Lays parts out in a row (plus the S3 devkit) and sizes a tray + lid around them.
func planEnclosure(for design: DeviceDesign) -> EnclosureSpec {
    let gap = 6.0
    var x = 0.0
    var maxD = 0.0
    var maxH = 0.0
    for c in design.components where c.id != "mcu" {
        x += c.widthMm + gap
        maxD = max(maxD, c.depthMm)
        maxH = max(maxH, c.heightMm)
    }
    // ESP32-S3-DevKitC-1 footprint when present (or assumed if the AI omitted dims)
    x += 52 + gap
    maxD = max(maxD, 28)
    maxH = max(maxH, 12)

    let pcbW = x + 8
    let pcbD = maxD + 8
    return EnclosureSpec(
        trayW: pcbW + 8,
        trayD: pcbD + 8,
        trayWallH: maxH + 14,
        pcbW: pcbW,
        pcbD: pcbD
    )
}

/// (component, x-center, z-center) layout in mm, origin at tray corner.
func componentLayout(for design: DeviceDesign, spec: EnclosureSpec) -> [(GadgetComponent, Double, Double)] {
    let gap = 6.0
    var x = 4.0 + 26.0 // start past half the devkit width
    var out: [(GadgetComponent, Double, Double)] = []
    let mcu = GadgetComponent(id: "mcu", name: "ESP32-S3-DevKitC-1", wokwiPart: "esp32-s3-devkitc-1",
                              widthMm: 52, heightMm: 12, depthMm: 28, pins: [], notes: nil)
    out.append((mcu, 4.0 + 26.0, spec.trayD / 2))
    x += 26.0
    for c in design.components where c.id != "mcu" {
        x += gap + c.widthMm / 2
        out.append((c, x, spec.trayD / 2))
        x += c.widthMm / 2
    }
    return out
}

// MARK: - Binary STL writer

private struct Vec { var x, y, z: Float }

private final class STLBuilder {
    private var tris: [(n: Vec, a: Vec, b: Vec, c: Vec)] = []

    private func tri(_ n: Vec, _ a: (Double, Double, Double), _ b: (Double, Double, Double), _ c: (Double, Double, Double)) {
        tris.append((n, Vec(x: Float(a.0), y: Float(a.1), z: Float(a.2)),
                         Vec(x: Float(b.0), y: Float(b.1), z: Float(b.2)),
                         Vec(x: Float(c.0), y: Float(c.1), z: Float(c.2))))
    }

    private func quad(_ n: Vec, _ a: (Double, Double, Double), _ b: (Double, Double, Double),
                      _ c: (Double, Double, Double), _ d: (Double, Double, Double)) {
        tri(n, a, b, c)
        tri(n, a, c, d)
    }

    /// Axis-aligned box. Winding is outward-facing; slicers also repair if needed.
    func addBox(min: (Double, Double, Double), size: (Double, Double, Double)) {
        let (x0, y0, z0) = min
        let (sx, sy, sz) = size
        let x1 = x0 + sx, y1 = y0 + sy, z1 = z0 + sz
        quad(Vec(x: 0, y: 0, z: 1),  (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1))
        quad(Vec(x: 0, y: 0, z: -1), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (x1, y0, z0))
        quad(Vec(x: 1, y: 0, z: 0),  (x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (x1, y0, z1))
        quad(Vec(x: -1, y: 0, z: 0), (x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0))
        quad(Vec(x: 0, y: 1, z: 0),  (x0, y1, z0), (x0, y1, z1), (x1, y1, z1), (x1, y1, z0))
        quad(Vec(x: 0, y: -1, z: 0), (x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1))
    }

    /// Vertical cylinder (for mounting posts).
    func addCylinder(center: (Double, Double), z0: Double, z1: Double, radius: Double, segments: Int = 20) {
        let (cx, cy) = center
        var ring: [(Double, Double)] = []
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            ring.append((cx + radius * cos(a), cy + radius * sin(a)))
        }
        for i in 0..<segments {
            let j = (i + 1) % segments
            let (x0, y0) = ring[i], (x1, y1) = ring[j]
            let nx = cos(Double(i) / Double(segments) * 2 * .pi)
            let ny = sin(Double(i) / Double(segments) * 2 * .pi)
            let n = Vec(x: Float(nx), y: Float(ny), z: 0)
            tri(n, (x0, y0, z0), (x1, y1, z0), (x1, y1, z1))
            tri(n, (x0, y0, z0), (x1, y1, z1), (x0, y0, z1))
            // caps (fan around center)
            tri(Vec(x: 0, y: 0, z: 1), (cx, cy, z1), (x0, y0, z1), (x1, y1, z1))
            tri(Vec(x: 0, y: 0, z: -1), (cx, cy, z0), (x1, y1, z0), (x0, y0, z0))
        }
    }

    func data() -> Data {
        var out = Data(count: 84)
        var count = UInt32(tris.count).littleEndian
        out.append(Data(bytes: &count, count: 4))
        for t in tris {
            for v in [t.n, t.a, t.b, t.c] {
                var x = v.x, y = v.y, z = v.z
                out.append(Data(bytes: &x, count: 4))
                out.append(Data(bytes: &y, count: 4))
                out.append(Data(bytes: &z, count: 4))
            }
            var attr: UInt16 = 0
            out.append(Data(bytes: &attr, count: 2))
        }
        return out
    }
}

/// Builds tray + lid STL (lid offset beside the tray). Units: mm.
func stlData(for spec: EnclosureSpec) -> Data {
    let b = STLBuilder()
    let W = spec.trayW, D = spec.trayD, H = spec.trayWallH
    let t = spec.wall, base = spec.base

    // Tray: bottom plate
    b.addBox(min: (0, 0, 0), size: (W, D, base))
    // Tray: four walls
    b.addBox(min: (0, 0, base), size: (W, t, H))            // front
    b.addBox(min: (0, D - t, base), size: (W, t, H))        // back
    b.addBox(min: (0, 0, base), size: (t, D, H))            // left
    b.addBox(min: (W - t, 0, base), size: (t, D, H))        // right
    // Corner mounting posts
    let pr = 3.0
    for (cx, cy) in [(t + pr, t + pr), (W - t - pr, t + pr), (t + pr, D - t - pr), (W - t - pr, D - t - pr)] {
        b.addCylinder(center: (cx, cy), z0: base, z1: base + H, radius: pr)
    }

    // Lid: flat plate beside the tray
    let lx = W + 15.0
    b.addBox(min: (lx, 0, 0), size: (W, D, spec.lidT))
    // Lid lip
    b.addBox(min: (lx + t, t, spec.lidT), size: (W - 2 * t, D - 2 * t, 1.5))

    return b.data()
}
