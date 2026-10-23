import SwiftUI

enum GradientPreset: String, CaseIterable, Identifiable, Sendable {
    case aurora = "Aurora (Default)"
    case oceanTeal = "Ocean Teal"
    case sunsetGlow = "Sunset Glow"
    case midnightPurple = "Midnight Purple"
    case cyberpunk = "Cyberpunk Neon"
    case deepSpace = "Deep Space"
    case custom = "Custom"

    var id: String { rawValue }

    var colors: [Color] {
        switch self {
        case .aurora:
            return [
                Color(red: 0.31, green: 0.74, blue: 0.34),
                Color(red: 0.18, green: 0.58, blue: 0.44),
                Color(red: 0.10, green: 0.36, blue: 0.42),
                Color(red: 0.06, green: 0.16, blue: 0.22)
            ]
        case .oceanTeal:
            return [
                Color(red: 0.08, green: 0.65, blue: 0.82),
                Color(red: 0.06, green: 0.38, blue: 0.56),
                Color(red: 0.05, green: 0.18, blue: 0.32)
            ]
        case .sunsetGlow:
            return [
                Color(red: 0.95, green: 0.42, blue: 0.32),
                Color(red: 0.68, green: 0.22, blue: 0.45),
                Color(red: 0.22, green: 0.08, blue: 0.25)
            ]
        case .midnightPurple:
            return [
                Color(red: 0.45, green: 0.32, blue: 0.88),
                Color(red: 0.24, green: 0.15, blue: 0.52),
                Color(red: 0.09, green: 0.07, blue: 0.22)
            ]
        case .cyberpunk:
            return [
                Color(red: 0.00, green: 0.92, blue: 0.65),
                Color(red: 0.08, green: 0.45, blue: 0.68),
                Color(red: 0.06, green: 0.10, blue: 0.32)
            ]
        case .deepSpace:
            return [
                Color(red: 0.22, green: 0.24, blue: 0.28),
                Color(red: 0.14, green: 0.15, blue: 0.18),
                Color(red: 0.07, green: 0.08, blue: 0.10)
            ]
        case .custom:
            return [
                Color(red: 0.31, green: 0.74, blue: 0.34),
                Color(red: 0.06, green: 0.16, blue: 0.22)
            ]
        }
    }
}

struct GradientTheme {
    static let defaultTopHex = "#4FBC57"
    static let defaultBottomHex = "#0F2938"

    static func activeColors(presetRaw: String, customTopHex: String, customBottomHex: String) -> [Color] {
        guard let preset = GradientPreset(rawValue: presetRaw) else {
            return GradientPreset.aurora.colors
        }

        if preset == .custom {
            let top = Color(hex: customTopHex) ?? Color(hex: defaultTopHex) ?? .green
            let bottom = Color(hex: customBottomHex) ?? Color(hex: defaultBottomHex) ?? .black
            return [top, bottom]
        }
        return preset.colors
    }
}

extension Color {
    init?(hex: String) {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanHex.hasPrefix("#") {
            cleanHex.removeFirst()
        }

        guard cleanHex.count == 6 || cleanHex.count == 8 else { return nil }

        var intVal: UInt64 = 0
        guard Scanner(string: cleanHex).scanHexInt64(&intVal) else { return nil }

        let r, g, b, a: Double
        if cleanHex.count == 6 {
            r = Double((intVal >> 16) & 0xFF) / 255.0
            g = Double((intVal >> 8) & 0xFF) / 255.0
            b = Double(intVal & 0xFF) / 255.0
            a = 1.0
        } else {
            r = Double((intVal >> 24) & 0xFF) / 255.0
            g = Double((intVal >> 16) & 0xFF) / 255.0
            b = Double((intVal >> 8) & 0xFF) / 255.0
            a = Double(intVal & 0xFF) / 255.0
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else {
            return "#4FBC57"
        }
        let r = Int(components.redComponent * 255.0)
        let g = Int(components.greenComponent * 255.0)
        let b = Int(components.blueComponent * 255.0)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
