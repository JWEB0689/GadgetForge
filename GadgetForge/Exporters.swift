import Foundation
import AppKit
import UniformTypeIdentifiers

/// File exporters: Wokwi simulation, BOM, firmware stub, PCBWay notes.
enum Exporter {

    // MARK: - Save panel

    static func save(data: Data, suggestedName: String, fileExtension: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }

    static func save(text: String, suggestedName: String, fileExtension: String) {
        save(data: Data(text.utf8), suggestedName: suggestedName, fileExtension: fileExtension)
    }

    // MARK: - Wokwi simulation

    /// Generates a Wokwi diagram.json. Open at wokwi.com → New Project → ESP32-S3 →
    /// paste into diagram.json. GPIO n maps to the S3-DevKitC-1 pin "Dn".
    static func wokwiDiagram(for design: DeviceDesign) -> Data {
        var parts: [[String: Any]] = [
            ["type": "wokwi-esp32-s3-devkitc-1", "id": "mcu", "top": 0, "left": 0,
             "attrs": ["env": "arduino"]]
        ]
        var connections: [[Any]] = []
        var left = 260.0

        for c in design.components where c.id != "mcu" {
            guard let wp = c.wokwiPart else { continue }
            parts.append(["type": "wokwi-\(wp)", "id": c.id, "top": 80, "left": left, "attrs": [:] as [String: Any]])
            left += 220
        }

        for a in design.pinAssignments {
            let mcuPin: String
            if let g = a.gpio {
                mcuPin = "mcu:D\(g)"
            } else {
                mcuPin = "mcu:\(a.net)"
            }
            connections.append([mcuPin, "\(a.componentId):\(a.componentPin)", wireColor(for: a.net)])
        }

        let doc: [String: Any] = [
            "version": 1,
            "author": "GadgetForge",
            "editor": "wokwi",
            "parts": parts,
            "connections": connections,
        ]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    private static func wireColor(for net: String) -> String {
        let n = net.uppercased()
        if n.contains("GND") { return "black" }
        if n.contains("3V3") || n.contains("5V") || n.contains("VCC") || n.contains("VIN") { return "red" }
        if n.contains("SDA") || n.contains("SCL") { return "blue" }
        return "green"
    }

    static func wokwiHowTo(design: DeviceDesign) -> String {
        """
        Simulate "\(design.name)" in Wokwi (free, runs in your browser):

        1. Go to https://wokwi.com and start a new ESP32-S3 project.
        2. Open diagram.json in the Wokwi editor and paste the exported file's contents.
        3. Press Play. The wiring from your design is already connected.

        Parts without a Wokwi equivalent are listed in the design notes —
        simulate those pins with buttons/LEDs, or leave them unconnected.
        """
    }

    // MARK: - Gerber ZIP (PCBWay-ready)

    /// Writes Gerber + drill files to a temp dir, zips them with /usr/bin/zip,
    /// and asks where to save the archive.
    static func saveGerbers(board: PCBBoard, designName: String) {
        let stripped = designName.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let base = stripped.isEmpty ? "gadget" : stripped
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gadgetforge-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let files = [
            ("\(base).GTL", Gerber.topCopper(board)),
            ("\(base).GBL", Gerber.bottomCopper(board)),
            ("\(base).GTO", Gerber.topSilk(board)),
            ("\(base).GKO", Gerber.outline(board)),
            ("\(base).TXT", Gerber.drills(board)),
        ]
        var paths: [String] = []
        for (name, content) in files {
            let url = tmp.appendingPathComponent(name)
            try? content.write(to: url, atomically: true, encoding: .utf8)
            paths.append(url.path)
        }
        let zipPath = tmp.appendingPathComponent("\(base)-gerbers.zip").path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-j", "-q", zipPath] + paths
        try? proc.run()
        proc.waitUntilExit()
        guard FileManager.default.fileExists(atPath: zipPath) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(base)-gerbers.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: zipPath), to: dest)
    }

    // MARK: - BOM

    static func bomCSV(for design: DeviceDesign) -> String {
        var rows = ["Designator,Part,Footprint (mm),Pins,Notes"]
        for (i, c) in design.components.enumerated() {
            let ref = c.id == "mcu" ? "U1" : "J\(i)"
            let notes = (c.notes ?? "").replacingOccurrences(of: ",", with: ";")
            rows.append("\(ref),\"\(c.name)\",\(Int(c.widthMm))x\(Int(c.depthMm)),\"\(c.pins.joined(separator: " "))\",\"\(notes)\"")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    // MARK: - Firmware stub (Arduino)

    static func firmwareStub(for design: DeviceDesign) -> String {
        var lines: [String] = []
        lines.append("// \(design.name) — generated by GadgetForge")
        lines.append("// Target: ESP32-S3 (Arduino framework)")
        lines.append("")
        for a in design.pinAssignments {
            guard let g = a.gpio else { continue }
            let sym = "PIN_\(a.componentId.uppercased())_\(a.componentPin.uppercased())"
                .replacingOccurrences(of: "-", with: "_")
            lines.append("#define \(sym) \(g)  // \(a.net)")
        }
        lines.append("")
        lines.append("void setup() {")
        lines.append("  Serial.begin(115200);")
        for c in design.components where c.id != "mcu" {
            lines.append("  // TODO: init \(c.name) (\(c.notes ?? "see datasheet"))")
        }
        lines.append("}")
        lines.append("")
        lines.append("void loop() {")
        lines.append("  // TODO: your application logic")
        lines.append("  delay(100);")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - PCBWay package notes

    static func pcbNotes(for design: DeviceDesign, spec: EnclosureSpec) -> String {
        let bom = design.components.map { "- \($0.name) (\($0.id))" }.joined(separator: "\n")
        return """
        # PCB fabrication notes — \(design.name)

        Generated by GadgetForge. This is a starter package: import the BOM into
        KiCad (or EasyEDA), place the footprints, route, then export Gerbers for PCBWay.

        ## Board
        - Suggested board size: \(Int(spec.pcbW)) x \(Int(spec.pcbD)) mm, 2 layers, 1.6 mm FR-4
        - Mounting holes: 3.2 mm at the tray corner posts (see enclosure STL)

        ## BOM
        \(bom)

        ## Pin map
        \(design.pinAssignments.map { "- \($0.componentId).\($0.componentPin) -> \($0.gpio.map { "GPIO\($0)" } ?? $0.net) (\($0.net))" }.joined(separator: "\n"))

        ## Power
        \(design.powerNotes)

        ## Ordering from PCBWay
        1. Finish routing in KiCad, run DRC, plot Gerbers (JLC/PCBWay preset).
        2. Upload the Gerber zip at pcbway.com → "PCB Instant Quote".
        3. 2-layer, 1.6 mm, HASL or ENIG, green mask is the cheapest reliable combo.
        """
    }
}
