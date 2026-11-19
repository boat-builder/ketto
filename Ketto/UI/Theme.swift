import SwiftUI
import AppKit

/// Ketto's palette and the handful of shared controls every surface of the app is built from.
///
/// The look is calm and quiet but not grey: warm white surfaces, near-black ink, one ultramarine accent for
/// anything that is on, selected or in progress, lime as a small "done" pop, and red only while recording.
/// Lines are hairlines (`KettoTheme.line`, 1pt) throughout. Every colour has a dark counterpart, so the app
/// still follows the system appearance; the asset catalogue's AccentColor matches `accent` for system controls.
enum KettoTheme {
    // MARK: Surfaces

    /// Page and card background.
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x1A191E)
    /// The warm off-white behind pages: sidebars, the editor stage, the share page.
    static let surface = dynamic(light: 0xFBF6F4, dark: 0x211F25)
    /// Quiet fills: segment tracks, chips, empty thumbnails, hover and press.
    static let fill = dynamic(light: 0xF2EBE6, dark: 0x2D2B32)
    /// 1pt separators and card outlines.
    static let hairline = dynamic(light: 0xECE4DE, dark: 0x34313A)
    /// 1pt outlines of secondary buttons and fields.
    static let outline = dynamic(light: 0xD9D0C9, dark: 0x48454E)
    /// Unfilled part of sliders, progress bars and meters.
    static let track = dynamic(light: 0xE8E1DB, dark: 0x3A373F)

    // MARK: Text

    static let ink = dynamic(light: 0x1D1D1D, dark: 0xF4F1EE)
    static let secondaryInk = dynamic(light: 0x5C5D6B, dark: 0xA7A8B6)
    /// Text and icons on an `ink` fill (the primary pill flips to light in dark appearance).
    static let onInk = dynamic(light: 0xFFFFFF, dark: 0x1D1D1D)

    // MARK: Accent

    /// Ultramarine: selection, on-states, progress, and the Export / Share / Done actions. White text on it.
    static let accent = dynamic(light: 0x343CED, dark: 0x5D63F1)
    /// Accent-coloured text and icons on `accentTint` (and on plain surfaces, for links).
    static let accentInk = dynamic(light: 0x2A31D4, dark: 0xAAAEF8)
    /// The fill of something that is on: a toggled input, a selected sidebar row or segment.
    static let accentTint = dynamic(light: 0xE2E3FB, dark: 0x2B2E66)
    /// A barely-there accent wash behind a selected card.
    static let accentWash = dynamic(light: 0xF3F3FE, dark: 0x22244C)
    /// Outline of accent-tinted things: automatic zoom blocks, selected cards.
    static let accentLine = dynamic(light: 0xBABDF8, dark: 0x4C51BA)

    // MARK: Pops

    /// Lime, used sparingly: done badges and blur masks. Always with dark text on it.
    static let lime = Color(hex: 0xD8FD49)
    /// Text on `lime`.
    static let onLime = Color(hex: 0x1D1D1D)
    /// Olive text and outlines that sit with lime (the highlight mask).
    static let olive = dynamic(light: 0x3F4D00, dark: 0xC9E25A)
    static let oliveLine = dynamic(light: 0xA2BA25, dark: 0x8FA51E)
    /// Something is wrong or needs a permission: a status dot, a small badge.
    static let warning = dynamic(light: 0xF07A3E, dark: 0xFF935F)
    /// Something is fine: a status dot.
    static let positive = dynamic(light: 0x7E9A12, dark: 0xA2BA25)
    /// Error text: readable on white (unlike `record`, which is a dot colour, not a text colour).
    static let danger = dynamic(light: 0xC8321F, dark: 0xFF7A66)

    // MARK: Recording

    /// The recording dot: on Record, in the HUD, on the timeline's playhead marker. Never a button fill.
    static let record = dynamic(light: 0xFF4F36, dark: 0xFF5F48)

    // MARK: Lines and media

    /// Every line in the app: separators, outlines, selection rings.
    static let line: CGFloat = 1

    /// Background presets and placeholder art: vivid, never pastel.
    static let sunrise = LinearGradient(colors: [Color(hex: 0xFF935F), Color(hex: 0xE16BFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cobalt = LinearGradient(colors: [Color(hex: 0x3CCBF4), Color(hex: 0x343CED)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let violet = LinearGradient(colors: [Color(hex: 0xD59BFF), Color(hex: 0x5D63F1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let limeWash = LinearGradient(colors: [Color(hex: 0xD8FD49), Color(hex: 0x3CCBF4)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let midnight = LinearGradient(colors: [Color(hex: 0x300876), Color(hex: 0x0A0227)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The editor stage behind the canvas: the same warm surface as the rest of the window.
    static let stage = surface
    static let stageEdge = hairline

    // MARK: Timeline blocks

    /// Automatic zooms: a canvas block with an accent outline and accent text.
    static let automaticZoom = accentLine
    /// Zooms the user placed or changed: solid accent.
    static let manualZoom = accent
    static let blurMask = lime
    static let highlightMask = oliveLine

    /// A colour that follows the window's appearance.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    /// `0xRRGGBB` in sRGB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    /// `0xRRGGBB` in sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Liquid glass

/// A glass surface: Liquid Glass on macOS 26, a material with a hairline on earlier systems.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let material: Material

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(material, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
        }
    }
}

extension View {
    /// Glass behind a floating surface: the capture bar, the HUD, popovers over the desktop.
    func glassSurface<S: Shape>(_ shape: S, material: Material = .regularMaterial) -> some View {
        modifier(GlassSurface(shape: shape, material: material))
    }

    /// Glass behind a rounded rectangle.
    func glassSurface(cornerRadius: CGFloat, material: Material = .regularMaterial) -> some View {
        glassSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), material: material)
    }

    /// A card: canvas fill inside a 1pt hairline.
    func card(cornerRadius: CGFloat = 14, fill: Color = KettoTheme.canvas, stroke: Color = KettoTheme.hairline) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(fill, in: shape)
            .overlay(shape.strokeBorder(stroke, lineWidth: KettoTheme.line))
    }
}

/// An AppKit visual effect view for window-level materials.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
    }
}

// MARK: - Buttons

/// The ink capsule: the one primary action of a surface. Record on the bar (its label carries the red dot),
/// Stop on the HUD, New Recording in the library, Play in the editor.
struct RecordButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(KettoTheme.onInk)
            .padding(.leading, height > 30 ? 14 : 11)
            .padding(.trailing, height > 30 ? 16 : 12)
            .frame(height: height)
            .background(KettoTheme.ink.opacity(configuration.isPressed ? 0.78 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// The accent capsule: Export, Share Link, Done — the action that finishes a task.
struct ProminentPillButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(KettoTheme.accent.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// A quiet outlined capsule: Cancel, Pause, Copy Link, secondary toolbar actions. `emphasized` is the
/// on-state of a pill that toggles: accent tint, accent text, no outline.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 30
    var emphasized = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: emphasized ? .semibold : .medium))
            .foregroundStyle(emphasized ? KettoTheme.accentInk : KettoTheme.ink)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(background(isPressed: configuration.isPressed), in: Capsule())
            .overlay(Capsule().strokeBorder(emphasized ? Color.clear : KettoTheme.outline, lineWidth: KettoTheme.line))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }

    private func background(isPressed: Bool) -> Color {
        if emphasized { return KettoTheme.accentTint.opacity(isPressed ? 0.7 : 1) }
        return isPressed ? KettoTheme.fill : Color.clear
    }
}

/// A square icon button with a rounded press fill, for toolbars and the bar.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .frame(width: size, height: size)
            .background(
                configuration.isPressed ? KettoTheme.fill : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Shows a subtle fill under a view while the pointer is over it. Used with `IconButtonStyle`.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 7
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? KettoTheme.fill.opacity(0.8) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 7) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

// MARK: - Small pieces

/// Ketto's wordmark: the red recording dot and the name in lowercase.
struct Wordmark: View {
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 0.55) {
            Circle()
                .fill(KettoTheme.record)
                .frame(width: size * 0.53, height: size * 0.53)
            Text("ketto")
                .font(.system(size: size, weight: .semibold))
                .tracking(-0.15)
                .foregroundStyle(KettoTheme.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ketto")
    }
}

/// A 1pt separator in the hairline colour.
struct Hairline: View {
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(KettoTheme.hairline)
            .frame(width: axis == .vertical ? KettoTheme.line : nil, height: axis == .horizontal ? KettoTheme.line : nil)
    }
}

/// A round lime badge with a check: something finished.
struct DoneBadge: View {
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(KettoTheme.onLime)
            .frame(width: size, height: size)
            .background(KettoTheme.lime, in: Circle())
            .accessibilityHidden(true)
    }
}

/// A thin 2pt progress bar: the export, an upload, a link's remaining life.
struct ThinProgressBar: View {
    var fraction: Double
    var tint: Color = KettoTheme.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(KettoTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(fraction.isFinite ? fraction : 0, 0), 1))
            }
        }
        .frame(height: 2)
    }
}

/// A key cap, the way System Settings draws shortcuts.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(KettoTheme.ink)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(KettoTheme.canvas, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(KettoTheme.outline, lineWidth: KettoTheme.line))
    }
}

/// A coloured status dot with a label: permission state, backend state.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

/// The page header used by every page of the app window: a title, a subtitle, and trailing actions. A short
/// subtitle (a count) sits on the title's baseline; a sentence goes underneath.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    var inline = false
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: inline ? .center : .firstTextBaseline, spacing: 16) {
            if inline {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    titleText
                    subtitleText
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    titleText
                    subtitleText
                }
            }
            Spacer(minLength: 0)
            actions
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            .tracking(-0.2)
            .foregroundStyle(KettoTheme.ink)
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(KettoTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, inline: Bool = false) {
        self.init(title: title, subtitle: subtitle, inline: inline) { EmptyView() }
    }
}

/// `mm:ss`, the way durations read on cards and in the menu bar.
func shortTimecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
    return String(format: "%d:%02d", minutes, secs)
}

/// The Ketto mark as a template image for the menu bar: a ring with a gap, like the app icon's loop.
enum KettoMark {
    @MainActor
    static let statusItemImage: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2.5, dy: 2.5)
            let path = NSBezierPath()
            path.appendArc(withCenter: NSPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2, startAngle: 300, endAngle: 240, clockwise: false)
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            let dot = NSBezierPath(ovalIn: NSRect(x: inset.midX - 2, y: inset.midY - 2, width: 4, height: 4))
            NSColor.black.setFill()
            dot.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
