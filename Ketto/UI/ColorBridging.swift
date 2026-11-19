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

/// Backgrounds offered as one-click presets in the inspector: the vivid media gradients of Ketto's palette
/// (`KettoTheme.sunrise` and friends), two solids, and Indigo, which is what a new recording starts with
/// (`BackgroundSpec.default`). A preset only copies its colours into edit.json, so changing this list never
/// changes an existing project.
struct GradientPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let background: BackgroundSpec

    static let all: [GradientPreset] = [
        GradientPreset(id: "sunrise", name: "Sunrise", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#FF935F")!, RGBAColor(hex: "#E16BFF")!], angle: 135)),
        GradientPreset(id: "cobalt", name: "Cobalt", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#3CCBF4")!, RGBAColor(hex: "#343CED")!], angle: 135)),
        GradientPreset(id: "violet", name: "Violet", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#D59BFF")!, RGBAColor(hex: "#5D63F1")!], angle: 135)),
        GradientPreset(id: "lime", name: "Lime", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#D8FD49")!, RGBAColor(hex: "#3CCBF4")!], angle: 135)),
        GradientPreset(id: "midnight", name: "Midnight", background: BackgroundSpec(type: .gradient, colors: [RGBAColor(hex: "#300876")!, RGBAColor(hex: "#0A0227")!], angle: 135)),
        GradientPreset(id: "indigo", name: "Indigo", background: .default),
        GradientPreset(id: "ink", name: "Ink", background: BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#1D1D1D")!])),
        GradientPreset(id: "paper", name: "Paper", background: BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#FBF6F4")!])),
    ]

    var swatch: LinearGradient {
        let colors = background.type == .gradient ? background.colors.map(\.color) : [background.primaryColor.color, background.primaryColor.color]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
