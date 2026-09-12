import SwiftUI
import AppKit

/// Brand colours and the handful of shared controls every surface of the app is built from. The accent
/// (violet) comes from the asset catalogue through `Color.accentColor`; only the record coral and the editor
/// stage are fixed here, because they must read the same in light and dark appearance.
enum KettoTheme {
    /// The record button, the recording dot and the stop button: the coral of the app icon.
    static let record = Color(red: 1.0, green: 0.384, blue: 0.373)
    static let recordPressed = Color(red: 0.86, green: 0.30, blue: 0.29)
    /// The editor stage stays dark whatever the appearance, so the canvas reads like a video.
    static let stage = Color(red: 0.086, green: 0.086, blue: 0.106)
    static let stageEdge = Color(red: 0.13, green: 0.13, blue: 0.16)
    /// Colours of the timeline blocks.
    static let automaticZoom = Color(red: 0.24, green: 0.52, blue: 0.98)
    static let manualZoom = Color(red: 0.62, green: 0.36, blue: 0.95)
    static let blurMask = Color.teal
    static let highlightMask = Color.yellow
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
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
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
}

/// An AppKit visual effect view for window-level materials (the sidebar, toolbars).
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

/// The coral capsule: Record on the bar, Stop on the HUD, New Recording in the library.
struct RecordButtonStyle: ButtonStyle {
    var height: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: height > 30 ? 13 : 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, height > 30 ? 16 : 12)
            .frame(height: height)
            .background(configuration.isPressed ? KettoTheme.recordPressed : KettoTheme.record, in: Capsule())
            .shadow(color: KettoTheme.record.opacity(configuration.isPressed ? 0.15 : 0.35), radius: 8, y: 3)
            .contentShape(Capsule())
    }
}

/// The accent capsule: Share Link, and the one primary action on a page.
struct ProminentPillButtonStyle: ButtonStyle {
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}

/// A quiet capsule on a translucent fill: Cancel, Pause, secondary toolbar actions.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.16 : (emphasized ? 0.1 : 0.06)),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
    }
}

/// A square icon button with a rounded hover/press fill, for toolbars and the bar.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : 0),
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
                Color.primary.opacity(isHovering ? 0.07 : 0),
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

/// A key cap, the way System Settings draws shortcuts.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// A coloured status dot with a label: permission state, backend state.
struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
    }
}

/// The page header used by every page of the app window: a title, a subtitle, and trailing actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            actions
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
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
            path.lineWidth = 2.6
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
