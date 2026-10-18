import Foundation

enum PinSeverity {
    case error
    case warning
}

struct PinIssue: Identifiable {
    let id = UUID()
    let severity: PinSeverity
    let message: String
}

/// ESP32-S3 pin rules. Catches reserved pins, strapping pins, ADC2/Wi-Fi
/// conflicts, duplicate assignments, and unassigned component pins.
enum ESP32S3Pins {
    /// USB D-/D+ and octal SPI flash/PSRAM — never usable as GPIO on S3 modules.
    static let forbidden: Set<Int> = [19, 20, 33, 34, 35, 36, 37]
    /// Boot strapping pins — usable with care.
    static let strapping: Set<Int> = [0, 3, 45, 46]
    /// ADC2 channels conflict with Wi-Fi.
    static let adc2: Set<Int> = [11, 12, 13, 14, 15, 16, 17, 18]

    static func validate(_ design: DeviceDesign) -> [PinIssue] {
        var issues: [PinIssue] = []
        var seen: [Int: String] = [:]

        for a in design.pinAssignments {
            guard let g = a.gpio else { continue }
            let label = "\(a.componentId).\(a.componentPin)"
            if forbidden.contains(g) {
                issues.append(PinIssue(severity: .error,
                    message: "GPIO\(g) (\(label)) is reserved (USB or flash/PSRAM) — reassign it."))
            }
            if strapping.contains(g) {
                issues.append(PinIssue(severity: .warning,
                    message: "GPIO\(g) (\(label)) is a strapping pin — verify boot behavior."))
            }
            if adc2.contains(g) {
                issues.append(PinIssue(severity: .warning,
                    message: "GPIO\(g) (\(label)) is ADC2 — analog reads there conflict with Wi-Fi."))
            }
            if let prev = seen[g] {
                issues.append(PinIssue(severity: .error,
                    message: "GPIO\(g) assigned twice: \(prev) and \(label)."))
            } else {
                seen[g] = label
            }
        }

        for c in design.components {
            let assigned = Set(design.pinAssignments
                .filter { $0.componentId == c.id }
                .map(\.componentPin))
            for p in c.pins where !assigned.contains(p) {
                issues.append(PinIssue(severity: .error,
                    message: "Pin \(p) of \(c.name) has no assignment."))
            }
        }
        return issues
    }
}
