import SwiftUI
import AppKit

/// `RGBAColor` (edit.json) ↔ SwiftUI `Color` for the inspector's colour pickers.
extension RGBAColor {
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    init(color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        self.init(
            red: Double(resolved.redComponent),
            green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent),
            alpha: Double(resolved.alphaComponent)
        )
    }
}

/// Backgrounds offered as one-click presets in the inspector.
struct GradientPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let background: BackgroundSpec

    static let all: [GradientPreset] = [
        GradientPreset(id: "indigo", name: "Indigo", background: .default),
        GradientPreset(id: "sunset", name: "Sunset", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#f97316")!, RGBAColor(hex: "#db2777")!], angle: 135)),
        GradientPreset(id: "ocean", name: "Ocean", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#0ea5e9")!, RGBAColor(hex: "#1e40af")!], angle: 160)),
        GradientPreset(id: "forest", name: "Forest", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#10b981")!, RGBAColor(hex: "#0f766e")!], angle: 135)),
        GradientPreset(id: "graphite", name: "Graphite", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#374151")!, RGBAColor(hex: "#111827")!], angle: 180)),
        GradientPreset(id: "cream", name: "Cream", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#fde68a")!, RGBAColor(hex: "#fca5a5")!], angle: 120)),
        GradientPreset(id: "midnight", name: "Midnight", background: BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#0b1020")!])),
        GradientPreset(id: "paper", name: "Paper", background: BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#f3f4f6")!])),
    ]

    var swatch: LinearGradient {
        let colors = background.type == .gradient ? background.colors.map(\.color) : [background.primaryColor.color, background.primaryColor.color]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
