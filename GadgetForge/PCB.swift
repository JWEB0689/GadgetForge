import Foundation

// MARK: - PCB data model
// A simple 2-layer auto-router for module-style ESP32 designs.
// Footprints are parametric (2.54 mm pin rows); routing is Manhattan A* on a
// 0.5 mm grid with vias. Intended for low-speed carrier boards.

struct PCBPad {
    var name: String
    var cx, cy: Double   // mm, board coords (absolute after placement)
    var w = 1.8, h = 1.8 // mm
    var net: String
}

struct PCBFootprint {
    var ref: String      // U1, J2, ...
    var name: String
    var x, y, w, d: Double // body rect, mm (x/y set at placement)
    var pads: [PCBPad]
}

struct PCBTrace {
    var net: String
    var layer: Int       // 0 = top, 1 = bottom
    var points: [(Double, Double)]
}

struct PCBVia {
    var x, y: Double
    var net: String
}

struct PCBBoard {
    var width, height: Double
    var footprints: [PCBFootprint]
    var traces: [PCBTrace]
    var vias: [PCBVia]
    var unrouted: [String]
    var drcIssues: [String]
    var routedNetCount: Int
    var totalNetCount: Int
}

// MARK: - Footprint generation

private let pinPitch = 2.54

/// Builds unplaced footprints and the net list from the design.
private func buildFootprints(for design: DeviceDesign)
    -> (footprints: [PCBFootprint], nets: [String: [(ref: String, pad: String)]])
{
    var pinNet: [String: String] = [:]
    for a in design.pinAssignments {
        pinNet["\(a.componentId).\(a.componentPin)"] = a.net
    }
    var nets: [String: [(ref: String, pad: String)]] = [:]
    var footprints: [PCBFootprint] = []
    var nextJ = 2

    func make(ref: String, name: String, bodyW: Double, bodyD: Double,
              padNames: [String], padNets: [String]) -> PCBFootprint {
        let perSide = max(1, (padNames.count + 1) / 2)
        let d = max(bodyD, Double(perSide) * pinPitch + 3.0)
        let w = max(bodyW, 8.0)
        var pads: [PCBPad] = []
        for (i, pn) in padNames.enumerated() {
            let side = i % 2
            let k = i / 2
            let py = Double(k) * pinPitch + pinPitch / 2 + 1.5
            let px = side == 0 ? -1.2 : w + 1.2
            let net = padNets[i]
            pads.append(PCBPad(name: pn, cx: px, cy: py, net: net))
            nets[net, default: []].append((ref: ref, pad: pn))
        }
        return PCBFootprint(ref: ref, name: name, x: 0, y: 0, w: w, d: d, pads: pads)
    }

    // MCU: one pad per net used in the design.
    var mcuNets: [String] = []
    var seenNets = Set<String>()
    for a in design.pinAssignments where !seenNets.contains(a.net) {
        seenNets.insert(a.net)
        mcuNets.append(a.net)
    }
    mcuNets.sort()
    footprints.append(make(ref: "U1", name: "ESP32-S3-DevKitC-1",
                           bodyW: 52, bodyD: 28, padNames: mcuNets, padNets: mcuNets))

    for c in design.components where c.id != "mcu" {
        let ref = "J\(nextJ)"; nextJ += 1
        let pnets = c.pins.map { pinNet["\(c.id).\($0)"] ?? "?" }
        footprints.append(make(ref: ref, name: c.name, bodyW: c.widthMm, bodyD: c.depthMm,
                               padNames: c.pins, padNets: pnets))
    }
    return (footprints, nets)
}

// MARK: - Grid A* router

private struct Cell: Hashable { var x, y, l: Int }

private struct Heap {
    var items: [(Double, Cell)] = []
    var isEmpty: Bool { items.isEmpty }
    mutating func push(_ p: Double, _ c: Cell) {
        items.append((p, c))
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if items[parent].0 <= items[i].0 { break }
            items.swapAt(parent, i); i = parent
        }
    }
    mutating func pop() -> (Double, Cell)? {
        guard !items.isEmpty else { return nil }
        let top = items[0]
        items[0] = items[items.count - 1]
        items.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = 2 * i + 2
            var m = i
            if l < items.count && items[l].0 < items[m].0 { m = l }
            if r < items.count && items[r].0 < items[m].0 { m = r }
            if m == i { break }
            items.swapAt(i, m); i = m
        }
        return top
    }
}

/// Routes the board. Returns the finished board with DRC notes.
func routePCB(for design: DeviceDesign) -> PCBBoard {
    let gcell = 0.5
    let traceW = 0.35
    let inflate = 0.45 // obstacle inflation (clearance), mm

    var (fps, nets) = buildFootprints(for: design)

    // Board size from layout
    var needX = 10.0
    var maxD = 0.0
    for f in fps { needX += f.w + 8; maxD = max(maxD, f.d) }
    let W = max(needX + 10, 40)
    let H = maxD + 16

    // Place footprints in a row
    var x = 10.0
    for i in fps.indices {
        fps[i].x = x
        fps[i].y = (H - fps[i].d) / 2
        for j in fps[i].pads.indices {
            fps[i].pads[j].cx += x
            fps[i].pads[j].cy += fps[i].y
        }
        x += fps[i].w + 8
    }

    let cols = Int(ceil(W / gcell)) + 2
    let rows = Int(ceil(H / gcell)) + 2
    func gx(_ mm: Double) -> Int { Int((mm / gcell).rounded()) + 1 }
    func gy(_ mm: Double) -> Int { Int((mm / gcell).rounded()) + 1 }
    func mmX(_ g: Int) -> Double { (Double(g) - 1) * gcell }
    func mmY(_ g: Int) -> Double { (Double(g) - 1) * gcell }
    func idx(_ x: Int, _ y: Int, _ l: Int) -> Int { (l * rows + y) * cols + x }
    func idx2(_ x: Int, _ y: Int) -> Int { y * cols + x }

    // 0 = free, 1 = blocked, 10+netId = occupied by net
    var occ = [Int](repeating: 0, count: cols * rows * 2)
    func blockRect(x0: Double, y0: Double, x1: Double, y1: Double) {
        for yy in gy(y0)...gy(y1) {
            for xx in gx(x0)...gx(x1) {
                guard xx >= 0, yy >= 0, xx < cols, yy < rows else { continue }
                occ[idx(xx, yy, 0)] = 1
                occ[idx(xx, yy, 1)] = 1
            }
        }
    }

    // Obstacles: bodies, pads, mounting holes
    for f in fps {
        blockRect(x0: f.x - inflate, y0: f.y - inflate, x1: f.x + f.w + inflate, y1: f.y + f.d + inflate)
        for p in f.pads {
            blockRect(x0: p.cx - p.w / 2 - inflate, y0: p.cy - p.h / 2 - inflate,
                      x1: p.cx + p.w / 2 + inflate, y1: p.cy + p.h / 2 + inflate)
        }
    }
    let holeR = 2.2
    let holes = [(4.0, 4.0), (W - 4.0, 4.0), (4.0, H - 4.0), (W - 4.0, H - 4.0)]
    for (hx, hy) in holes {
        blockRect(x0: hx - holeR, y0: hy - holeR, x1: hx + holeR, y1: hy + holeR)
    }

    // Net ids and their pad cells (2D)
    let netNames = nets.keys.filter { (nets[$0]?.count ?? 0) >= 2 }.sorted()
    var netId: [String: Int] = [:]
    for (i, n) in netNames.enumerated() { netId[n] = i }
    var padCells: [Int: Set<Int>] = [:] // netId -> 2D cell set
    var padByNet: [Int: [(Double, Double)]] = [:]
    for f in fps {
        for p in f.pads {
            guard let id = netId[p.net] else { continue }
            for yy in gy(p.cy - p.h / 2)...gy(p.cy + p.h / 2) {
                for xx in gx(p.cx - p.w / 2)...gx(p.cx + p.w / 2) {
                    guard xx >= 0, yy >= 0, xx < cols, yy < rows else { continue }
                    padCells[id, default: []].insert(idx2(xx, yy))
                }
            }
            padByNet[id, default: []].append((p.cx, p.cy))
        }
    }

    func passable(_ x: Int, _ y: Int, _ l: Int, _ id: Int) -> Bool {
        guard x >= 1, y >= 1, x < cols - 1, y < rows - 1 else { return false }
        let v = occ[idx(x, y, l)]
        if v == 0 { return true }
        if v == 1 { return padCells[id]?.contains(idx2(x, y)) ?? false }
        return v == 10 + id
    }

    func astar(from startCells: Set<Cell>, goalCells: Set<Cell>, id: Int) -> [Cell]? {
        // Heuristic target points (2D)
        let goals2D = Set(goalCells.map { idx2($0.x, $0.y) })
        var goalPts: [(Int, Int)] = []
        for g in goals2D { goalPts.append((g % cols, g / cols)) }
        func h(_ c: Cell) -> Double {
            var best = Double.greatestFiniteMagnitude
            for (gx_, gy_) in goalPts {
                let d = Double(abs(c.x - gx_) + abs(c.y - gy_))
                if d < best { best = d }
            }
            return best
        }
        var open = Heap()
        var gScore: [Cell: Double] = [:]
        var came: [Cell: Cell] = [:]
        var closed = Set<Cell>()
        for s in startCells { gScore[s] = 0; open.push(h(s), s) }
        let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        while let (_, cur) = open.pop() {
            if closed.contains(cur) { continue }
            closed.insert(cur)
            if goalCells.contains(cur) {
                var path = [cur]
                var c = cur
                while let p = came[c] { path.append(p); c = p }
                return path.reversed()
            }
            let g = gScore[cur] ?? Double.greatestFiniteMagnitude
            for (dx, dy) in dirs {
                let n = Cell(x: cur.x + dx, y: cur.y + dy, l: cur.l)
                if !passable(n.x, n.y, n.l, id) || closed.contains(n) { continue }
                let ng = g + 1
                if ng < (gScore[n] ?? Double.greatestFiniteMagnitude) {
                    gScore[n] = ng; came[n] = cur
                    open.push(ng + h(n), n)
                }
            }
            // Via to other layer
            let nl = 1 - cur.l
            let n = Cell(x: cur.x, y: cur.y, l: nl)
            if passable(n.x, n.y, n.l, id) && !closed.contains(n) {
                let ng = g + 10
                if ng < (gScore[n] ?? Double.greatestFiniteMagnitude) {
                    gScore[n] = ng; came[n] = cur
                    open.push(ng + h(n), n)
                }
            }
        }
        return nil
    }

    var traces: [PCBTrace] = []
    var vias: [PCBVia] = []
    var unrouted: [String] = []

    // Route shortest nets first (fewer pads first is a decent heuristic)
    let order = netNames.sorted { (nets[$0]?.count ?? 0) < (nets[$1]?.count ?? 0) }

    for name in order {
        guard let id = netId[name], let pads = padByNet[id], pads.count >= 2 else { continue }
        // Order pads left-to-right for chaining
        let sortedPads = pads.sorted { $0.0 < $1.0 }
        var ok = true

        for pi in 1..<sortedPads.count {
            // Start: previous pad's cells (or its routed trace); goal: this pad's cells
            let (sxmm, symm) = sortedPads[pi - 1]
            let (gxmm, gymm) = sortedPads[pi]
            var start = Set<Cell>()
            var goal = Set<Cell>()
            if pi == 1 {
                // first hop: pad cells of pad 0
                for yy in gy(symm - 1)...gy(symm + 1) {
                    for xx in gx(sxmm - 1)...gx(sxmm + 1) {
                        if padCells[id]?.contains(idx2(xx, yy)) ?? false {
                            start.insert(Cell(x: xx, y: yy, l: 0))
                            start.insert(Cell(x: xx, y: yy, l: 1))
                        }
                    }
                }
            } else {
                // subsequent hops may start from any cell already owned by this net
                // (approximated: previous pad cells — chaining keeps it simple and correct)
                for yy in gy(symm - 1)...gy(symm + 1) {
                    for xx in gx(sxmm - 1)...gx(sxmm + 1) {
                        let v0 = occ[idx(xx, yy, 0)], v1 = occ[idx(xx, yy, 1)]
                        if v0 == 10 + id { start.insert(Cell(x: xx, y: yy, l: 0)) }
                        if v1 == 10 + id { start.insert(Cell(x: xx, y: yy, l: 1)) }
                    }
                }
                if start.isEmpty {
                    for yy in gy(symm - 1)...gy(symm + 1) {
                        for xx in gx(sxmm - 1)...gx(sxmm + 1) {
                            if padCells[id]?.contains(idx2(xx, yy)) ?? false {
                                start.insert(Cell(x: xx, y: yy, l: 0))
                                start.insert(Cell(x: xx, y: yy, l: 1))
                            }
                        }
                    }
                }
            }
            for yy in gy(gymm - 1)...gy(gymm + 1) {
                for xx in gx(gxmm - 1)...gx(gxmm + 1) {
                    if padCells[id]?.contains(idx2(xx, yy)) ?? false {
                        goal.insert(Cell(x: xx, y: yy, l: 0))
                        goal.insert(Cell(x: xx, y: yy, l: 1))
                    }
                }
            }
            guard !start.isEmpty, !goal.isEmpty,
                  let path = astar(from: start, goalCells: goal, id: id), path.count > 1 else {
                ok = false
                break
            }
            // Commit: mark cells, record vias, build per-layer polylines
            var run: [(Double, Double)] = []
            var runLayer = path[0].l
            func flush() {
                if run.count >= 2 {
                    traces.append(PCBTrace(net: name, layer: runLayer, points: run))
                } else if run.count == 1 {
                    traces.append(PCBTrace(net: name, layer: runLayer, points: [run[0], run[0]]))
                }
            }
            var prevDir: (Int, Int)? = nil
            for (i, c) in path.enumerated() {
                occ[idx(c.x, c.y, c.l)] = 10 + id
                if i > 0 && path[i - 1].l != c.l {
                    // via at this cell
                    occ[idx(c.x, c.y, 0)] = 10 + id
                    occ[idx(c.x, c.y, 1)] = 10 + id
                    vias.append(PCBVia(x: mmX(c.x), y: mmY(c.y), net: name))
                    flush()
                    run = [(mmX(c.x), mmY(c.y))]
                    runLayer = c.l
                    prevDir = nil
                    continue
                }
                let pt = (mmX(c.x), mmY(c.y))
                if i == 0 {
                    run = [pt]
                } else {
                    let p = path[i - 1]
                    let dir = (c.x - p.x, c.y - p.y)
                    if prevDir == nil || prevDir! != dir {
                        run.append(pt)
                    } else {
                        run[run.count - 1] = pt
                    }
                    prevDir = dir
                }
            }
            flush()
        }
        if !ok { unrouted.append(name) }
    }

    // MARK: - DRC: foreign-pad clearance spot check
    var drcIssues: [String] = []
    let minClear = 0.25
    func pointSegDist(_ px: Double, _ py: Double,
                      _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
        t = max(0, min(1, t))
        let cx = ax + t * dx - px, cy = ay + t * dy - py
        return (cx * cx + cy * cy).squareRoot()
    }
    for t in traces {
        for i in 0..<(t.points.count - 1) {
            let (ax, ay) = t.points[i], (bx, by) = t.points[i + 1]
            // sample along segment
            let segLen = hypot(bx - ax, by - ay)
            let steps = max(1, Int(ceil(segLen / 0.25)))
            for f in fps {
                for p in f.pads where p.net != t.net {
                    var bad = false
                    for s in 0...steps {
                        let px = ax + (bx - ax) * Double(s) / Double(steps)
                        let py = ay + (by - ay) * Double(s) / Double(steps)
                        let dx = abs(px - p.cx) - p.w / 2
                        let dy = abs(py - p.cy) - p.h / 2
                        let outside = hypot(max(0, dx), max(0, dy))
                        if outside < minClear + traceW / 2 { bad = true; break }
                    }
                    if bad {
                        drcIssues.append("Clearance: \(t.net) trace near \(f.ref).\(p.name) pad")
                        break
                    }
                }
                if !drcIssues.isEmpty, drcIssues.last!.hasPrefix("Clearance: \(t.net)") { break }
            }
        }
    }
    // De-duplicate
    drcIssues = Array(Set(drcIssues)).sorted()

    let routed = netNames.count - unrouted.count
    return PCBBoard(width: W, height: H, footprints: fps, traces: traces, vias: vias,
                    unrouted: unrouted.sorted(), drcIssues: drcIssues,
                    routedNetCount: routed, totalNetCount: netNames.count)
}
