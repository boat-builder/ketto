import Foundation

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

    static let `default` = CursorSpec(scale: 1.6, smoothing: 0.8, hideWhenIdle: true, clickHighlight: true)

    init(scale: Double, smoothing: Double, hideWhenIdle: Bool, clickHighlight: Bool) {
        self.scale = scale
        self.smoothing = smoothing
        self.hideWhenIdle = hideWhenIdle
        self.clickHighlight = clickHighlight
    }

    enum CodingKeys: String, CodingKey { case scale, smoothing, hideWhenIdle, clickHighlight }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scale = c.decode(Double.self, forKey: .scale, default: CursorSpec.default.scale)
        smoothing = c.decode(Double.self, forKey: .smoothing, default: CursorSpec.default.smoothing)
        hideWhenIdle = c.decode(Bool.self, forKey: .hideWhenIdle, default: CursorSpec.default.hideWhenIdle)
        clickHighlight = c.decode(Bool.self, forKey: .clickHighlight, default: CursorSpec.default.clickHighlight)
    }
}

struct CanvasSpec: Codable, Equatable, Sendable {
    var aspect: String
    var width: Int
    var height: Int

    static let `default` = CanvasSpec(aspect: "16:9", width: 1920, height: 1080)

    init(aspect: String, width: Int, height: Int) {
        self.aspect = aspect
        self.width = width
        self.height = height
    }

    enum CodingKeys: String, CodingKey { case aspect, width, height }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aspect = c.decode(String.self, forKey: .aspect, default: CanvasSpec.default.aspect)
        width = max(16, c.decode(Int.self, forKey: .width, default: CanvasSpec.default.width))
        height = max(16, c.decode(Int.self, forKey: .height, default: CanvasSpec.default.height))
    }

    var aspectRatio: Double { Double(width) / Double(height) }
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

struct Cut: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
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
    static let currentVersion = 1

    var version: Int
    var canvas: CanvasSpec
    var style: StyleSpec
    var cursor: CursorSpec
    var zooms: [Zoom]
    var cuts: [Cut]
    var captions: CaptionTrack?
    var autoZoom: AutoZoomSpec
    var effects: EffectsSpec

    init(
        version: Int = EditDocument.currentVersion,
        canvas: CanvasSpec = .default,
        style: StyleSpec = .default,
        cursor: CursorSpec = .default,
        zooms: [Zoom] = [],
        cuts: [Cut] = [],
        captions: CaptionTrack? = nil,
        autoZoom: AutoZoomSpec = .default,
        effects: EffectsSpec = .default
    ) {
        self.version = version
        self.canvas = canvas
        self.style = style
        self.cursor = cursor
        self.zooms = zooms
        self.cuts = cuts
        self.captions = captions
        self.autoZoom = autoZoom
        self.effects = effects
    }

    static let `default` = EditDocument()

    enum CodingKeys: String, CodingKey { case version, canvas, style, cursor, zooms, cuts, captions, autoZoom, effects }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(Int.self, forKey: .version, default: EditDocument.currentVersion)
        canvas = c.decode(CanvasSpec.self, forKey: .canvas, default: .default)
        style = c.decode(StyleSpec.self, forKey: .style, default: .default)
        cursor = c.decode(CursorSpec.self, forKey: .cursor, default: .default)
        zooms = c.decode([Zoom].self, forKey: .zooms, default: [])
        cuts = c.decode([Cut].self, forKey: .cuts, default: [])
        captions = c.decode(CaptionTrack?.self, forKey: .captions, default: nil)
        autoZoom = c.decode(AutoZoomSpec.self, forKey: .autoZoom, default: .default)
        effects = c.decode(EffectsSpec.self, forKey: .effects, default: .default)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(style, forKey: .style)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(zooms, forKey: .zooms)
        try c.encode(cuts, forKey: .cuts)
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
