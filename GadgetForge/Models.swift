import Foundation

// MARK: - Device design model (produced by the AI from the user's prompt)

struct GadgetComponent: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// Wokwi part id (without the "wokwi-" prefix), or nil when not simulatable.
    var wokwiPart: String?
    var widthMm: Double
    var heightMm: Double
    var depthMm: Double
    /// Pin names on the part, e.g. ["VCC","GND","SDA","SCL"]
    var pins: [String]
    var notes: String?
}

struct PinAssignment: Codable, Hashable {
    var componentId: String
    var componentPin: String
    /// ESP32 GPIO number, or nil for power rails.
    var gpio: Int?
    /// Net name, e.g. "3V3", "GND", "SDA"
    var net: String
}

struct DeviceDesign: Codable {
    var name: String
    var mcu: String
    var summary: String
    var components: [GadgetComponent]
    var pinAssignments: [PinAssignment]
    var powerNotes: String
    var buildNotes: String
}

// MARK: - Wokwi part library known to the app

struct WokwiPartInfo: Hashable {
    let id: String
    let label: String
}

/// Peripheral parts the simulator exporter understands.
let supportedWokwiParts: [WokwiPartInfo] = [
    WokwiPartInfo(id: "ssd1306", label: "OLED SSD1306 128x64 (I2C)"),
    WokwiPartInfo(id: "dht22", label: "DHT22 temp/humidity"),
    WokwiPartInfo(id: "pushbutton", label: "Pushbutton"),
    WokwiPartInfo(id: "led", label: "LED"),
    WokwiPartInfo(id: "buzzer", label: "Buzzer"),
    WokwiPartInfo(id: "potentiometer", label: "Potentiometer"),
    WokwiPartInfo(id: "servo", label: "Servo"),
    WokwiPartInfo(id: "neopixel", label: "NeoPixel (single)"),
    WokwiPartInfo(id: "hc-sr04", label: "HC-SR04 ultrasonic"),
    WokwiPartInfo(id: "ds1307", label: "DS1307 RTC (I2C)"),
]

// MARK: - Shared app state

final class DesignStore: ObservableObject {
    @Published var prompt: String = ""
    @Published var design: DeviceDesign?
    @Published var issues: [PinIssue] = []
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published var apiKey: String = KeychainHelper.load() ?? ""

    var enclosureSpec: EnclosureSpec? {
        guard let design else { return nil }
        return planEnclosure(for: design)
    }

    @MainActor
    func generate() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "Add your Gemini API key in Settings first."
            return
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Describe the device you want to build."
            return
        }
        isGenerating = true
        errorMessage = nil
        defer { isGenerating = false }
        do {
            let client = GeminiClient(apiKey: key)
            let design = try await client.designDevice(prompt: prompt)
            self.design = design
            self.issues = ESP32S3Pins.validate(design)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
