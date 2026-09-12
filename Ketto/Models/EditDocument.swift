import Foundation
import CoreGraphics

enum BackgroundType: String, Codable, Sendable {
    case solid, gradient
}

struct BackgroundSpec: Codable, Equatable, Sendable {
    var type: BackgroundType
    var colors: [RGBAColor]
    /// Gradient angle in degrees, CSS convention: 0° points up, 90° points right, 135° = top-left to bottom-right.
    var angle: Double

    static let `default` = BackgroundSpec(
        type: .gradient,
        colors: [RGBAColor(hex: "#1e3a8a")!, RGBAColor(hex: "#9333ea")!],
        angle: 135
    )

    init(type: BackgroundType, colors: [RGBAColor], angle: Double = 135) {
        self.type = type
        self.colors = colors
        self.angle = angle
    }

    enum CodingKeys: String, CodingKey { case type, colors, angle }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.decode(BackgroundType.self, forKey: .type, default: BackgroundSpec.default.type)
        let decodedColors = c.decode([RGBAColor].self, forKey: .colors, default: BackgroundSpec.default.colors)
        colors = decodedColors.isEmpty ? BackgroundSpec.default.colors : decodedColors
        angle = c.decode(Double.self, forKey: .angle, default: BackgroundSpec.default.angle)
    }

    var primaryColor: RGBAColor { colors.first ?? .black }
    var secondaryColor: RGBAColor { colors.count > 1 ? colors[1] : primaryColor }
}

struct ShadowSpec: Codable, Equatable, Sendable {
    /// Blur radius in canvas pixels.
    var radius: Double
    var opacity: Double
    /// Vertical offset in canvas pixels (positive is down).
    var y: Double

    static let `default` = ShadowSpec(radius: 40, opacity: 0.35, y: 20)

    init(radius: Double, opacity: Double, y: Double) {
        self.radius = radius
        self.opacity = opacity
        self.y = y
    }

    enum CodingKeys: String, CodingKey { case radius, opacity, y }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        radius = c.decode(Double.self, forKey: .radius, default: ShadowSpec.default.radius)
        opacity = c.decode(Double.self, forKey: .opacity, default: ShadowSpec.default.opacity)
        y = c.decode(Double.self, forKey: .y, default: ShadowSpec.default.y)
    }
}

struct StyleSpec: Codable, Equatable, Sendable {
    var background: BackgroundSpec
    /// Padding around the screen frame in canvas pixels.
    var padding: Double
    /// Corner radius of the screen frame in canvas pixels.
    var cornerRadius: Double
    var shadow: ShadowSpec

    static let `default` = StyleSpec(background: .default, padding: 64, cornerRadius: 12, shadow: .default)

    init(background: BackgroundSpec, padding: Double, cornerRadius: Double, shadow: ShadowSpec) {
        self.background = background
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
    }

    enum CodingKeys: String, CodingKey { case background, padding, cornerRadius, shadow }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = c.decode(BackgroundSpec.self, forKey: .background, default: .default)
        padding = c.decode(Double.self, forKey: .padding, default: StyleSpec.default.padding)
        cornerRadius = c.decode(Double.self, forKey: .cornerRadius, default: StyleSpec.default.cornerRadius)
        shadow = c.decode(ShadowSpec.self, forKey: .shadow, default: .default)
    }
}

struct CursorSpec: Codable, Equatable, Sendable {
    var scale: Double
    /// 0 = raw positions, 1 = heavy smoothing.
    var smoothing: Double
    var hideWhenIdle: Bool
    var clickHighlight: Bool
    /// Glide the cursor back to its starting position over the last `CursorSpec.loopBlend` seconds so a
    /// looping export is seamless.
    var loop: Bool

    /// Seconds over which the loop-cursor glide happens at the end of the edit.
    static let loopBlend = 0.75

    static let `default` = CursorSpec(scale: 1.6, smoothing: 0.8, hideWhenIdle: true, clickHighlight: true)

    init(scale: Double, smoothing: Double, hideWhenIdle: Bool, clickHighlight: Bool, loop: Bool = false) {
        self.scale = scale
        self.smoothing = smoothing
        self.hideWhenIdle = hideWhenIdle
        self.clickHighlight = clickHighlight
        self.loop = loop
    }

    enum CodingKeys: String, CodingKey { case scale, smoothing, hideWhenIdle, clickHighlight, loop }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = c.decode(Double.self, forKey: .scale, default: CursorSpec.default.scale)
        smoothing = c.decode(Double.self, forKey: .smoothing, default: CursorSpec.default.smoothing)
        hideWhenIdle = c.decode(Bool.self, forKey: .hideWhenIdle, default: CursorSpec.default.hideWhenIdle)
        clickHighlight = c.decode(Bool.self, forKey: .clickHighlight, default: CursorSpec.default.clickHighlight)
        loop = c.decode(Bool.self, forKey: .loop, default: false)
    }
}

/// How the recording is placed on a canvas whose aspect differs from the source.
enum FramingMode: String, Codable, Sendable {
    /// The whole (cropped) recording is visible, letterboxed inside the padding. The v1 behaviour.
    case fit
    /// The screen frame fills the padded canvas; the visible slice of the recording follows the action.
    case fill
}

struct CanvasSpec: Codable, Equatable, Sendable {
    var aspect: String
    var width: Int
    var height: Int
    var framing: FramingMode

    static let `default` = CanvasSpec(aspect: "16:9", width: 1920, height: 1080)

    /// The aspect presets offered in the inspector, in display order.
    static let presetNames = ["16:9", "9:16", "1:1", "4:5"]

    init(aspect: String, width: Int, height: Int, framing: FramingMode = .fit) {
        self.aspect = aspect
        self.width = width
        self.height = height
        self.framing = framing
    }

    /// A named preset. Vertical, square and portrait presets default to `fill` framing so the recording fills
    /// the frame instead of shrinking to a letterboxed strip.
    static func preset(_ name: String) -> CanvasSpec? {
        switch name {
        case "16:9": return CanvasSpec(aspect: "16:9", width: 1920, height: 1080, framing: .fit)
        case "9:16": return CanvasSpec(aspect: "9:16", width: 1080, height: 1920, framing: .fill)
        case "1:1": return CanvasSpec(aspect: "1:1", width: 1080, height: 1080, framing: .fill)
        case "4:5": return CanvasSpec(aspect: "4:5", width: 1080, height: 1350, framing: .fill)
        default: return nil
        }
    }

    enum CodingKeys: String, CodingKey { case aspect, width, height, framing }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = c.decode(String.self, forKey: .aspect, default: CanvasSpec.default.aspect)
        width = max(16, c.decode(Int.self, forKey: .width, default: CanvasSpec.default.width))
        height = max(16, c.decode(Int.self, forKey: .height, default: CanvasSpec.default.height))
        framing = c.decode(FramingMode.self, forKey: .framing, default: .fit)
    }

    var aspectRatio: Double { Double(width) / Double(height) }
}

/// A sub-rectangle of the recording, normalised (0–1) in source space. Everything outside it is discarded.
struct CropSpec: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let full = CropSpec(x: 0, y: 0, width: 1, height: 1)
    static let minimumSide = 0.05

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self = sanitized()
    }

    init(rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    enum CodingKeys: String, CodingKey { case x, y, width, height }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: c.decode(Double.self, forKey: .x, default: 0),
            y: c.decode(Double.self, forKey: .y, default: 0),
            width: c.decode(Double.self, forKey: .width, default: 1),
            height: c.decode(Double.self, forKey: .height, default: 1)
        )
    }

    /// Clamped into the unit square with a minimum size, so a bad value can never blank the frame.
    func sanitized() -> CropSpec {
        var c = self
        if !c.width.isFinite { c.width = 1 }
        if !c.height.isFinite { c.height = 1 }
        if !c.x.isFinite { c.x = 0 }
        if !c.y.isFinite { c.y = 0 }
        c.width = min(max(c.width, Self.minimumSide), 1)
        c.height = min(max(c.height, Self.minimumSide), 1)
        c.x = min(max(c.x, 0), 1 - c.width)
        c.y = min(max(c.y, 0), 1 - c.height)
        return c
    }

    var isFull: Bool { self == .full }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var viewport: Viewport { Viewport(origin: SIMD2(x, y), size: SIMD2(width, height)) }
}

/// A zoom block. `target` is normalised (0–1) in source space so it survives resolution changes.
struct Zoom: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var start: Double
    var duration: Double
    var target: SIMD2<Double>
    var scale: Double
    var easing: Easing
    /// Set when the user edits the block; regeneration preserves such zooms.
    var userModified: Bool

    init(id: String, start: Double, duration: Double, target: SIMD2<Double>, scale: Double = 2, easing: Easing = .easeInOutCubic, userModified: Bool = false) {
        self.id = id
        self.start = start
        self.duration = duration
        self.target = target
        self.scale = scale
        self.easing = easing
        self.userModified = userModified
    }

    var end: Double { start + duration }

    enum CodingKeys: String, CodingKey { case id, start, duration, target, scale, easing, userModified }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(String.self, forKey: .id, default: UUID().uuidString)
        start = c.decode(Double.self, forKey: .start, default: 0)
        duration = max(0, c.decode(Double.self, forKey: .duration, default: 0))
        let targetValues = c.decode([Double].self, forKey: .target, default: [0.5, 0.5])
        target = targetValues.count >= 2 ? SIMD2(targetValues[0], targetValues[1]) : SIMD2(0.5, 0.5)
        scale = max(1, c.decode(Double.self, forKey: .scale, default: 2))
        easing = c.decode(Easing.self, forKey: .easing, default: .easeInOutCubic)
        userModified = c.decode(Bool.self, forKey: .userModified, default: false)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(start, forKey: .start)
        try c.encode(duration, forKey: .duration)
        try c.encode([target.x, target.y], forKey: .target)
        try c.encode(scale, forKey: .scale)
        try c.encode(easing, forKey: .easing)
        if userModified { try c.encode(userModified, forKey: .userModified) }
    }
}

/// A removed range of the recording, in source seconds. Read for compatibility with v1 documents; the editor
/// writes `clips` instead, which win whenever they are present.
struct Cut: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
}

/// One piece of the main track: a range of the recording played at `speed`. Clips are laid end to end on
/// the output timeline in order; a gap between two clips' source ranges is a cut.
struct Clip: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var sourceStart: Double
    var sourceEnd: Double
    /// Playback rate multiplier: 2 plays the range twice as fast, 0.5 at half speed.
    var speed: Double

    static let speedRange = 0.25...4.0
    static let minimumDuration = 0.05

    init(id: String, sourceStart: Double, sourceEnd: Double, speed: Double = 1) {
        self.id = id
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.speed = Clip.clampedSpeed(speed)
    }

    static func clampedSpeed(_ speed: Double) -> Double {
        guard speed.isFinite else { return 1 }
        return min(max(speed, speedRange.lowerBound), speedRange.upperBound)
    }

    var sourceDuration: Double { max(0, sourceEnd - sourceStart) }
    var outputDuration: Double { sourceDuration / speed }

    enum CodingKeys: String, CodingKey { case id, sourceStart, sourceEnd, speed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: c.decode(String.self, forKey: .id, default: UUID().uuidString),
            sourceStart: max(0, c.decode(Double.self, forKey: .sourceStart, default: 0)),
            sourceEnd: max(0, c.decode(Double.self, forKey: .sourceEnd, default: 0)),
            speed: c.decode(Double.self, forKey: .speed, default: 1)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourceStart, forKey: .sourceStart)
        try c.encode(sourceEnd, forKey: .sourceEnd)
        try c.encode(speed, forKey: .speed)
    }
}

enum CameraShape: String, Codable, Sendable {
    case circle
    case roundedRect
}

struct BorderSpec: Codable, Equatable, Sendable {
    /// Width in canvas pixels.
    var width: Double
    var color: RGBAColor

    static let `default` = BorderSpec(width: 4, color: .white)

    init(width: Double, color: RGBAColor) {
        self.width = width
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case width, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = max(0, c.decode(Double.self, forKey: .width, default: BorderSpec.default.width))
        color = c.decode(RGBAColor.self, forKey: .color, default: BorderSpec.default.color)
    }
}

/// The webcam overlay drawn from `camera.mov`.
struct CameraOverlaySpec: Codable, Equatable, Sendable {
    var enabled: Bool
    var shape: CameraShape
    /// Width / height of the overlay box. 1 for a circle or square bubble.
    var aspect: Double
    /// Corner radius in canvas pixels, for `roundedRect`.
    var cornerRadius: Double
    /// Height of the overlay as a fraction of the canvas height.
    var size: Double
    /// Centre of the overlay, normalised in canvas space (0–1 on both axes).
    var position: SIMD2<Double>
    var border: BorderSpec
    var shadow: Bool
    var mirrored: Bool
    /// Slide to the opposite side of the canvas while the cursor is over the overlay.
    var dodgeCursor: Bool

    static let `default` = CameraOverlaySpec(
        enabled: true, shape: .circle, aspect: 1, cornerRadius: 24, size: 0.26,
        position: SIMD2(0.86, 0.82), border: .default, shadow: true, mirrored: false, dodgeCursor: true
    )

    init(enabled: Bool, shape: CameraShape, aspect: Double, cornerRadius: Double, size: Double, position: SIMD2<Double>, border: BorderSpec, shadow: Bool, mirrored: Bool, dodgeCursor: Bool) {
        self.enabled = enabled
        self.shape = shape
        self.aspect = aspect
        self.cornerRadius = cornerRadius
        self.size = size
        self.position = position
        self.border = border
        self.shadow = shadow
        self.mirrored = mirrored
        self.dodgeCursor = dodgeCursor
    }

    enum CodingKeys: String, CodingKey { case enabled, shape, aspect, cornerRadius, size, position, border, shadow, mirrored, dodgeCursor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CameraOverlaySpec.default
        enabled = c.decode(Bool.self, forKey: .enabled, default: d.enabled)
        shape = c.decode(CameraShape.self, forKey: .shape, default: d.shape)
        aspect = min(max(c.decode(Double.self, forKey: .aspect, default: d.aspect), 0.25), 4)
        cornerRadius = max(0, c.decode(Double.self, forKey: .cornerRadius, default: d.cornerRadius))
        size = min(max(c.decode(Double.self, forKey: .size, default: d.size), 0.05), 1)
        let positionValues = c.decode([Double].self, forKey: .position, default: [d.position.x, d.position.y])
        position = positionValues.count >= 2 ? SIMD2(min(max(positionValues[0], 0), 1), min(max(positionValues[1], 0), 1)) : d.position
        border = c.decode(BorderSpec.self, forKey: .border, default: d.border)
        shadow = c.decode(Bool.self, forKey: .shadow, default: d.shadow)
        mirrored = c.decode(Bool.self, forKey: .mirrored, default: d.mirrored)
        dodgeCursor = c.decode(Bool.self, forKey: .dodgeCursor, default: d.dodgeCursor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(shape, forKey: .shape)
        try c.encode(aspect, forKey: .aspect)
        try c.encode(cornerRadius, forKey: .cornerRadius)
        try c.encode(size, forKey: .size)
        try c.encode([position.x, position.y], forKey: .position)
        try c.encode(border, forKey: .border)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(mirrored, forKey: .mirrored)
        try c.encode(dodgeCursor, forKey: .dodgeCursor)
    }
}

enum MaskKind: String, Codable, Sendable {
    /// Blurs the region — for passwords, names, anything sensitive.
    case blur
    /// Dims everything except the region — for emphasis.
    case highlight
}

/// A rectangular region of the recording, normalised (0–1) in source space so it follows zooms and crops.
/// Active from `start` to `end` in source seconds; a nil `end` means until the end of the recording.
struct Mask: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: MaskKind
    var rect: CGRect
    var start: Double
    var end: Double?
    /// Blur amount or highlight dimming, 0–1.
    var strength: Double
    /// Corner radius of the region in canvas pixels.
    var cornerRadius: Double

    init(id: String, kind: MaskKind, rect: CGRect, start: Double = 0, end: Double? = nil, strength: Double = 1, cornerRadius: Double = 8) {
        let clampedStart = max(0, start.isFinite ? start : 0)
        self.id = id
        self.kind = kind
        self.rect = Mask.sanitized(rect)
        self.start = clampedStart
        self.end = end.map { max($0.isFinite ? $0 : clampedStart, clampedStart) }
        self.strength = min(max(strength.isFinite ? strength : 1, 0), 1)
        self.cornerRadius = max(0, cornerRadius.isFinite ? cornerRadius : 0)
    }

    static func sanitized(_ rect: CGRect) -> CGRect {
        var r = rect.standardized
        if !r.origin.x.isFinite || !r.origin.y.isFinite || !r.width.isFinite || !r.height.isFinite { return CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2) }
        r.size.width = min(max(r.width, 0.01), 1)
        r.size.height = min(max(r.height, 0.01), 1)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

    /// True when the mask applies at source time `t`.
    func isActive(at t: Double) -> Bool {
        guard t >= start else { return false }
        if let end { return t < end }
        return true
    }

    /// The end used for drawing, given the recording's duration.
    func resolvedEnd(duration: Double) -> Double { end ?? max(duration, start) }

    enum CodingKeys: String, CodingKey { case id, type, rect, start, end, strength, cornerRadius }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let values = c.decode([Double].self, forKey: .rect, default: [0.4, 0.4, 0.2, 0.2])
        let rect = values.count >= 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        self.init(
            id: c.decode(String.self, forKey: .id, default: UUID().uuidString),
            kind: c.decode(MaskKind.self, forKey: .type, default: .blur),
            rect: rect,
            start: c.decode(Double.self, forKey: .start, default: 0),
            end: c.decode(Double?.self, forKey: .end, default: nil),
            strength: c.decode(Double.self, forKey: .strength, default: 1),
            cornerRadius: c.decode(Double.self, forKey: .cornerRadius, default: 8)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .type)
        try c.encode([rect.minX, rect.minY, rect.width, rect.height], forKey: .rect)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end) // `null` when open-ended
        try c.encode(strength, forKey: .strength)
        try c.encode(cornerRadius, forKey: .cornerRadius)
    }
}

enum OverlayEdge: String, Codable, Sendable {
    case top, bottom
}

/// On-screen display of captured keystrokes.
struct KeystrokeSpec: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Show only combinations with a modifier or a special key, not plain typing.
    var shortcutsOnly: Bool
    var position: OverlayEdge
    var scale: Double

    static let `default` = KeystrokeSpec(enabled: true, shortcutsOnly: true, position: .bottom, scale: 1)

    init(enabled: Bool, shortcutsOnly: Bool, position: OverlayEdge, scale: Double) {
        self.enabled = enabled
        self.shortcutsOnly = shortcutsOnly
        self.position = position
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey { case enabled, shortcutsOnly, position, scale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decode(Bool.self, forKey: .enabled, default: true)
        shortcutsOnly = c.decode(Bool.self, forKey: .shortcutsOnly, default: true)
        position = c.decode(OverlayEdge.self, forKey: .position, default: .bottom)
        scale = min(max(c.decode(Double.self, forKey: .scale, default: 1), 0.5), 2)
    }
}

/// Audio decisions. The mic and system tracks stay separate on disk; these apply at playback and export.
struct AudioSpec: Codable, Equatable, Sendable {
    /// Bring the voice track to a consistent level (measured once, applied as gain).
    var normalize: Bool
    /// Spectral-gate background noise out of the voice track.
    var noiseRemoval: Bool
    var micVolume: Double
    var systemVolume: Double

    static let `default` = AudioSpec(normalize: false, noiseRemoval: false, micVolume: 1, systemVolume: 1)

    init(normalize: Bool, noiseRemoval: Bool, micVolume: Double, systemVolume: Double) {
        self.normalize = normalize
        self.noiseRemoval = noiseRemoval
        self.micVolume = micVolume
        self.systemVolume = systemVolume
    }

    enum CodingKeys: String, CodingKey { case normalize, noiseRemoval, micVolume, systemVolume }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        normalize = c.decode(Bool.self, forKey: .normalize, default: false)
        noiseRemoval = c.decode(Bool.self, forKey: .noiseRemoval, default: false)
        micVolume = min(max(c.decode(Double.self, forKey: .micVolume, default: 1), 0), 2)
        systemVolume = min(max(c.decode(Double.self, forKey: .systemVolume, default: 1), 0), 2)
    }
}

/// Placeholder for v4. Kept in the schema so `captions: null` round-trips.
struct CaptionTrack: Codable, Equatable, Sendable {
    var lines: [CaptionLine]

    struct CaptionLine: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }
}

struct AutoZoomSpec: Codable, Equatable, Sendable {
    var enabled: Bool
    /// Multiplies the zoom strength: 1.0 = default 2× zoom.
    var intensity: Double

    static let `default` = AutoZoomSpec(enabled: true, intensity: 1)

    init(enabled: Bool, intensity: Double) {
        self.enabled = enabled
        self.intensity = intensity
    }

    enum CodingKeys: String, CodingKey { case enabled, intensity }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.decode(Bool.self, forKey: .enabled, default: true)
        intensity = c.decode(Double.self, forKey: .intensity, default: 1)
    }
}

struct EffectsSpec: Codable, Equatable, Sendable {
    var motionBlur: Bool

    static let `default` = EffectsSpec(motionBlur: true)

    init(motionBlur: Bool) {
        self.motionBlur = motionBlur
    }

    enum CodingKeys: String, CodingKey { case motionBlur }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        motionBlur = c.decode(Bool.self, forKey: .motionBlur, default: true)
    }
}

/// `edit.json` — every non-destructive editing decision. Every field has a sane default.
struct EditDocument: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int
    var canvas: CanvasSpec
    var crop: CropSpec
    var style: StyleSpec
    var cursor: CursorSpec
    var zooms: [Zoom]
    /// v1 representation of removed ranges. Only consulted when `clips` is empty.
    var cuts: [Cut]
    /// The main track. Empty means the whole recording at 1×.
    var clips: [Clip]
    var camera: CameraOverlaySpec
    var masks: [Mask]
    var keystrokes: KeystrokeSpec
    var audio: AudioSpec
    var captions: CaptionTrack?
    var autoZoom: AutoZoomSpec
    var effects: EffectsSpec

    init(
        version: Int = EditDocument.currentVersion,
        canvas: CanvasSpec = .default,
        crop: CropSpec = .full,
        style: StyleSpec = .default,
        cursor: CursorSpec = .default,
        zooms: [Zoom] = [],
        cuts: [Cut] = [],
        clips: [Clip] = [],
        camera: CameraOverlaySpec = .default,
        masks: [Mask] = [],
        keystrokes: KeystrokeSpec = .default,
        audio: AudioSpec = .default,
        captions: CaptionTrack? = nil,
        autoZoom: AutoZoomSpec = .default,
        effects: EffectsSpec = .default
    ) {
        self.version = version
        self.canvas = canvas
        self.crop = crop
        self.style = style
        self.cursor = cursor
        self.zooms = zooms
        self.cuts = cuts
        self.clips = clips
        self.camera = camera
        self.masks = masks
        self.keystrokes = keystrokes
        self.audio = audio
        self.captions = captions
        self.autoZoom = autoZoom
        self.effects = effects
    }

    static let `default` = EditDocument()

    enum CodingKeys: String, CodingKey {
        case version, canvas, crop, style, cursor, zooms, cuts, clips, camera, masks, keystrokes, audio, captions, autoZoom, effects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(Int.self, forKey: .version, default: EditDocument.currentVersion)
        canvas = c.decode(CanvasSpec.self, forKey: .canvas, default: .default)
        crop = c.decode(CropSpec.self, forKey: .crop, default: .full)
        style = c.decode(StyleSpec.self, forKey: .style, default: .default)
        cursor = c.decode(CursorSpec.self, forKey: .cursor, default: .default)
        zooms = c.decode([Zoom].self, forKey: .zooms, default: [])
        cuts = c.decode([Cut].self, forKey: .cuts, default: [])
        clips = c.decode([Clip].self, forKey: .clips, default: [])
        camera = c.decode(CameraOverlaySpec.self, forKey: .camera, default: .default)
        masks = c.decode([Mask].self, forKey: .masks, default: [])
        keystrokes = c.decode(KeystrokeSpec.self, forKey: .keystrokes, default: .default)
        audio = c.decode(AudioSpec.self, forKey: .audio, default: .default)
        captions = c.decode(CaptionTrack?.self, forKey: .captions, default: nil)
        autoZoom = c.decode(AutoZoomSpec.self, forKey: .autoZoom, default: .default)
        effects = c.decode(EffectsSpec.self, forKey: .effects, default: .default)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(crop, forKey: .crop)
        try c.encode(style, forKey: .style)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(zooms, forKey: .zooms)
        try c.encode(cuts, forKey: .cuts)
        try c.encode(clips, forKey: .clips)
        try c.encode(camera, forKey: .camera)
        try c.encode(masks, forKey: .masks)
        try c.encode(keystrokes, forKey: .keystrokes)
        try c.encode(audio, forKey: .audio)
        try c.encode(captions, forKey: .captions) // encodes `null` when nil
        try c.encode(autoZoom, forKey: .autoZoom)
        try c.encode(effects, forKey: .effects)
    }

    func encodedData() throws -> Data {
        try DocumentJSON.encoder(pretty: true).encode(self)
    }

    static func decode(_ data: Data) throws -> EditDocument {
        try DocumentJSON.decoder.decode(EditDocument.self, from: data)
    }
}
