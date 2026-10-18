import Foundation

enum GeminiError: LocalizedError {
    case badResponse
    case apiError(String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The AI returned an unexpected response. Try again."
        case .apiError(let msg): return "Gemini API error: \(msg)"
        case .decodeFailed: return "Could not parse the AI's design. Try rephrasing the prompt."
        }
    }
}

/// Minimal Gemini client. The key lives in the keychain; nothing is logged.
struct GeminiClient {
    let apiKey: String
    private let model = "gemini-2.0-flash"

    func designDevice(prompt: String) async throws -> DeviceDesign {
        let supported = supportedWokwiParts.map(\.id).joined(separator: ", ")
        let system = """
        You are an electronics design assistant. The user describes an ESP32-based device.
        Respond with ONLY a JSON object matching this schema (no markdown fences, no prose):
        {
          "name": "Short device name",
          "mcu": "ESP32-S3",
          "summary": "One paragraph description",
          "components": [
            {"id": "mcu", "name": "ESP32-S3-DevKitC-1", "wokwiPart": "esp32-s3-devkitc-1",
             "widthMm": 52, "heightMm": 12, "depthMm": 28,
             "pins": [], "notes": "Main controller"},
            {"id": "oled1", "name": "0.96in OLED SSD1306", "wokwiPart": "ssd1306",
             "widthMm": 27, "heightMm": 4, "depthMm": 27,
             "pins": ["VCC","GND","SCL","SDA"], "notes": "I2C addr 0x3C"}
          ],
          "pinAssignments": [
            {"componentId": "oled1", "componentPin": "VCC", "gpio": null, "net": "3V3"},
            {"componentId": "oled1", "componentPin": "GND", "gpio": null, "net": "GND"},
            {"componentId": "oled1", "componentPin": "SDA", "gpio": 8, "net": "SDA"},
            {"componentId": "oled1", "componentPin": "SCL", "gpio": 9, "net": "SCL"}
          ],
          "powerNotes": "How the device is powered",
          "buildNotes": "Assembly hints"
        }
        Rules:
        - Always include the MCU as a component with id "mcu" and wokwiPart "esp32-s3-devkitc-1".
        - Peripherals must use only these Wokwi part ids (or null when not simulatable): \(supported).
        - GPIO assignments are integers. NEVER use GPIO 19, 20, 33, 34, 35, 36, 37 (USB / octal flash-PSRAM). Avoid strapping pins 0, 3, 45, 46 unless necessary. Prefer 1,2,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,21,38,39,40,41,42,47,48.
        - I2C default: SDA=GPIO8, SCL=GPIO9. SPI default: MOSI=11, MISO=13, SCK=12, CS=10.
        - Every component pin must appear exactly once in pinAssignments. Power pins use gpio null and net "3V3", "5V" or "GND".
        - widthMm/depthMm are the footprint on the board; heightMm is the part's height.
        - Keep the design hobbyist-buildable (common breakout modules).
        """

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.4],
        ]
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        if let err = decoded.error {
            throw GeminiError.apiError(err.message)
        }
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text else {
            throw GeminiError.badResponse
        }
        let json = stripFences(text)
        guard let jsonData = json.data(using: .utf8),
              let design = try? JSONDecoder().decode(DeviceDesign.self, from: jsonData) else {
            throw GeminiError.decodeFailed
        }
        return design
    }

    private func stripFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "^```[a-zA-Z]*\\n", with: "", options: .regularExpression)
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Gemini wire format (private)

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    struct APIError: Decodable { let message: String }
    let candidates: [Candidate]?
    let error: APIError?
}
