import SwiftUI
import AppKit

enum Step: String, CaseIterable, Identifiable {
    case prompt, design, enclosure, simulate, pcb, export, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prompt: return "1 · Prompt"
        case .design: return "2 · Design"
        case .enclosure: return "3 · Enclosure"
        case .simulate: return "4 · Simulate"
        case .pcb: return "5 · PCB"
        case .export: return "6 · Build files"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .prompt: return "text.bubble"
        case .design: return "cpu"
        case .enclosure: return "cube"
        case .simulate: return "play.circle"
        case .pcb: return "circuit.board"
        case .export: return "square.and.arrow.up"
        case .settings: return "gear"
        }
    }
}

struct ContentView: View {
    @StateObject private var store = DesignStore()
    @State private var step: Step = .prompt

    var body: some View {
        NavigationSplitView {
            List(Step.allCases, selection: $step) { s in
                Label(s.title, systemImage: s.icon)
            }
            .navigationTitle("GadgetForge")
        } detail: {
            switch step {
            case .prompt: PromptView(store: store)
            case .design: DesignView(store: store)
            case .enclosure: EnclosureView(store: store)
            case .simulate: SimulateView(store: store)
            case .pcb: PCBView(store: store)
            case .export: ExportView(store: store)
            case .settings: SettingsView(store: store)
            }
        }
    }
}

// MARK: - 1 · Prompt

struct PromptView: View {
    @ObservedObject var store: DesignStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Describe the device you want to build")
                .font(.title2).bold()
            Text("Example: “Battery-powered ESP32-S3 temperature logger with an OLED display, two buttons, and a buzzer alarm.”")
                .foregroundStyle(.secondary)
            TextEditor(text: $store.prompt)
                .font(.body)
                .border(.quaternary)
                .frame(minHeight: 160)
            HStack {
                if store.isGenerating { ProgressView().scaleEffect(0.8) }
                Button(store.isGenerating ? "Designing…" : "Generate design") {
                    Task { await store.generate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isGenerating)
            }
            if let err = store.errorMessage {
                Text(err).foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Prompt")
    }
}

// MARK: - 2 · Design

struct DesignView: View {
    @ObservedObject var store: DesignStore

    var body: some View {
        Group {
            if let d = store.design {
                List {
                    Section("Summary") { Text(d.summary) }
                    if !store.issues.isEmpty {
                        Section("Pin check") {
                            ForEach(store.issues) { issue in
                                Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                            }
                        }
                    }
                    Section("Components") {
                        ForEach(d.components) { c in
                            VStack(alignment: .leading) {
                                Text(c.name).bold()
                                Text("\(Int(c.widthMm))×\(Int(c.depthMm)) mm, pins: \(c.pins.joined(separator: ", "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let n = c.notes { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    Section("Pin assignments") {
                        ForEach(d.pinAssignments, id: \.self) { a in
                            HStack {
                                Text("\(a.componentId).\(a.componentPin)")
                                Spacer()
                                Text(a.gpio.map { "GPIO\($0)" } ?? a.net)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Power") { Text(d.powerNotes) }
                    Section("Build notes") { Text(d.buildNotes) }
                }
            } else {
                ContentUnavailableView("No design yet", systemImage: "cpu",
                    description: Text("Generate a design from a prompt first."))
            }
        }
        .navigationTitle("Design")
    }
}

// MARK: - 3 · Enclosure

struct EnclosureView: View {
    @ObservedObject var store: DesignStore

    var body: some View {
        Group {
            if let d = store.design, let spec = store.enclosureSpec {
                let dims = String(format: "Tray: %.0f × %.0f × %.0f mm (walls %.0f mm). Lid included in the STL, offset beside the tray.",
                                  spec.trayW, spec.trayD, spec.trayWallH, spec.wall)
                VStack(alignment: .leading, spacing: 12) {
                    EnclosurePreview(spec: spec, design: d)
                        .frame(minHeight: 380)
                        .border(.quaternary)
                    Text(dims)
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Export enclosure STL (3D-printable)") {
                        Exporter.save(data: stlData(for: spec),
                                      suggestedName: "\(d.name)-enclosure.stl",
                                      fileExtension: "stl")
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(24)
            } else {
                ContentUnavailableView("No design yet", systemImage: "cube",
                    description: Text("Generate a design from a prompt first."))
            }
        }
        .navigationTitle("Enclosure")
    }
}

// MARK: - 4 · Simulate

struct SimulateView: View {
    @ObservedObject var store: DesignStore

    var body: some View {
        Group {
            if let d = store.design {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Wokwi simulation").font(.title2).bold()
                    Text(Exporter.wokwiHowTo(design: d))
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack {
                        Button("Export diagram.json") {
                            Exporter.save(data: Exporter.wokwiDiagram(for: d),
                                          suggestedName: "\(d.name)-wokwi-diagram.json",
                                          fileExtension: "json")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Open wokwi.com") {
                            if let url = URL(string: "https://wokwi.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    Spacer()
                }
                .padding(24)
            } else {
                ContentUnavailableView("No design yet", systemImage: "play.circle",
                    description: Text("Generate a design from a prompt first."))
            }
        }
        .navigationTitle("Simulate")
    }
}

// MARK: - 5 · Build files

struct ExportView: View {
    @ObservedObject var store: DesignStore

    var body: some View {
        Group {
            if let d = store.design, let spec = store.enclosureSpec {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Fabrication package").font(.title2).bold()
                    Text("Import the BOM into KiCad or EasyEDA, place footprints, route, then export Gerbers for PCBWay. The notes file walks through ordering.")
                        .foregroundStyle(.secondary)
                    ExportRow(title: "BOM (CSV)", detail: "Parts list for KiCad / PCBWay") {
                        Exporter.save(text: Exporter.bomCSV(for: d),
                                      suggestedName: "\(d.name)-bom.csv", fileExtension: "csv")
                    }
                    ExportRow(title: "Firmware stub (.ino)", detail: "Arduino sketch with your pin defines") {
                        Exporter.save(text: Exporter.firmwareStub(for: d),
                                      suggestedName: "\(d.name)-firmware.ino", fileExtension: "ino")
                    }
                    ExportRow(title: "PCBWay notes (.md)", detail: "Board size, pin map, ordering steps") {
                        Exporter.save(text: Exporter.pcbNotes(for: d, spec: spec),
                                      suggestedName: "\(d.name)-pcbway-notes.md", fileExtension: "md")
                    }
                    Spacer()
                }
                .padding(24)
            } else {
                ContentUnavailableView("No design yet", systemImage: "square.and.arrow.up",
                    description: Text("Generate a design from a prompt first."))
            }
        }
        .navigationTitle("Build files")
    }
}

struct ExportRow: View {
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export", action: action).buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 5 · PCB (auto-route + Gerbers)

struct PCBView: View {
    @ObservedObject var store: DesignStore
    @State private var board: PCBBoard?
    @State private var routing = false

    var body: some View {
        Group {
            if let d = store.design {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Auto-routed PCB").font(.title2).bold()
                    Text("2-layer carrier board, 0.35 mm traces, ~0.2 mm clearance. The router is a simple Manhattan maze router — right for low-speed module boards like these. Review the Gerbers in a viewer before ordering.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    HStack {
                        Button(routing ? "Routing…" : "Auto-route PCB") {
                            routing = true
                            board = nil
                            Task.detached(priority: .userInitiated) {
                                let b = routePCB(for: d)
                                await MainActor.run {
                                    board = b
                                    routing = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(routing)
                        if routing { ProgressView().scaleEffect(0.8) }
                    }
                    if let b = board {
                        Text("Board \(Int(b.width)) × \(Int(b.height)) mm · \(b.traces.count) traces · \(b.vias.count) vias · \(b.routedNetCount)/\(b.totalNetCount) nets routed")
                            .font(.callout)
                        if !b.unrouted.isEmpty {
                            Label("Unrouted nets: \(b.unrouted.joined(separator: ", "))",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                        ForEach(b.drcIssues, id: \.self) { issue in
                            Label(issue, systemImage: "xmark.octagon")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                        Button("Export Gerber ZIP (PCBWay-ready)") {
                            Exporter.saveGerbers(board: b, designName: d.name)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!b.unrouted.isEmpty || !b.drcIssues.isEmpty)
                        if !b.unrouted.isEmpty || !b.drcIssues.isEmpty {
                            Text("Fix routing issues before exporting — or export the BOM and finish in KiCad.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Tip: open the ZIP in a Gerber viewer (e.g. gerblook.org) before sending it to PCBWay.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(24)
            } else {
                ContentUnavailableView("No design yet", systemImage: "circuit.board",
                    description: Text("Generate a design from a prompt first."))
            }
        }
        .navigationTitle("PCB")
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: DesignStore
    @State private var saved = false

    var body: some View {
        Form {
            Section("Gemini API key") {
                SecureField("Paste key", text: $store.apiKey)
                Text("Stored only in your login keychain. Get a free key at aistudio.google.com.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save") {
                        saved = KeychainHelper.save(store.apiKey)
                    }
                    Button("Remove") {
                        _ = KeychainHelper.delete()
                        store.apiKey = ""
                        saved = false
                    }
                    if saved { Text("Saved").foregroundStyle(.green).font(.caption) }
                }
            }
            Section("About") {
                Text("GadgetForge turns a plain-language prompt into an ESP32 device design: validated pinout, Wokwi simulation, 3D-printable enclosure, and PCBWay-ready build files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .navigationTitle("Settings")
    }
}
