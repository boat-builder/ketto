import Foundation
import CoreGraphics

/// The cursor glyph that was displayed at a given moment. Recorded so the renderer can draw the right shape.
enum CursorType: String, Codable, CaseIterable, Sendable {
    case arrow
    case iBeam = "ibeam"
    case pointingHand = "pointingHand"
    case crosshair
    case resizeLeftRight
    case resizeUpDown
    case openHand
    case closedHand
    case notAllowed

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CursorType(rawValue: raw) ?? .arrow
    }
}

enum MouseButton: String, Codable, Sendable {
    case left, right, other
}

enum ClickPhase: String, Codable, Sendable {
    case down, up
}

/// Cursor position sample. Coordinates are in source-pixel space, `t` is seconds from `recordingStart`.
struct CursorSample: Codable, Equatable, Sendable {
    var t: Double
    var x: Double
    var y: Double
    var type: CursorType

    init(t: Double, x: Double, y: Double, type: CursorType = .arrow) {
        self.t = t
        self.x = x
        self.y = y
        self.type = type
    }

    var position: SIMD2<Double> { SIMD2(x, y) }

    enum CodingKeys: String, CodingKey { case t, x, y, type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        type = c.decode(CursorType.self, forKey: .type, default: .arrow)
    }
}

struct ClickEvent: Codable, Equatable, Sendable {
    var t: Double
    var x: Double
    var y: Double
    var button: MouseButton
    var phase: ClickPhase

    init(t: Double, x: Double, y: Double, button: MouseButton = .left, phase: ClickPhase = .down) {
        self.t = t
        self.x = x
        self.y = y
        self.button = button
        self.phase = phase
    }

    var position: SIMD2<Double> { SIMD2(x, y) }

    enum CodingKeys: String, CodingKey { case t, x, y, button, phase }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        button = c.decode(MouseButton.self, forKey: .button, default: .left)
        phase = c.decode(ClickPhase.self, forKey: .phase, default: .down)
    }
}

/// A key press. `chars` is the display form of the key (`S`, `⏎`, `←`, `F5`); `modifiers` are the lower-case
/// names `cmd`, `shift`, `opt`, `ctrl`, `fn` that were held.
struct KeyEvent: Codable, Equatable, Sendable {
    var t: Double
    var chars: String
    var modifiers: [String]

    init(t: Double, chars: String, modifiers: [String] = []) {
        self.t = t
        self.chars = chars
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case t, chars, modifiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        chars = c.decode(String.self, forKey: .chars, default: "")
        modifiers = c.decode([String].self, forKey: .modifiers, default: [])
    }

    /// Modifier display order and symbols, the way macOS menus show them.
    static let modifierSymbols: [(name: String, symbol: String)] = [
        ("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘"), ("fn", "fn"),
    ]

    /// Keys that read as a shortcut even without a modifier.
    static let specialKeys: Set<String> = ["⏎", "⇥", "⎋", "⌫", "⌦", "←", "→", "↑", "↓", "⇞", "⇟", "↖", "↘", "space"]

    /// `⌘⇧S`-style label: modifiers in canonical order, then the key.
    var label: String {
        let held = Set(modifiers.map { $0.lowercased() })
        let prefix = Self.modifierSymbols.filter { held.contains($0.name) }.map(\.symbol).joined()
        let key = chars == "space" ? "␣" : chars.uppercased()
        return prefix + key
    }

    /// True for key combinations worth showing on screen: anything with ⌘, ⌃, ⌥ or fn, function keys,
    /// and navigation/editing keys. Plain typing (letters, digits, shift-letters) is not a shortcut.
    var isShortcut: Bool {
        let held = Set(modifiers.map { $0.lowercased() })
        if !held.isDisjoint(with: ["cmd", "ctrl", "opt", "fn"]) { return true }
        if Self.specialKeys.contains(chars) { return true }
        if chars.count >= 2, chars.hasPrefix("F"), Int(chars.dropFirst()) != nil { return true }
        return false
    }
}

/// A change of the frontmost application / window. `frame` is `[x, y, width, height]` in source pixels.
struct FocusEvent: Codable, Equatable, Sendable {
    var t: Double
    var bundleId: String
    var frame: [Double]?

    init(t: Double, bundleId: String, frame: CGRect? = nil) {
        self.t = t
        self.bundleId = bundleId
        self.frame = frame.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
    }

    var rect: CGRect? {
        guard let frame, frame.count == 4, frame[2] > 0, frame[3] > 0 else { return nil }
        return CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
    }

    enum CodingKeys: String, CodingKey { case t, bundleId, frame }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        bundleId = c.decode(String.self, forKey: .bundleId, default: "")
        frame = c.decode([Double]?.self, forKey: .frame, default: nil)
    }
}

struct DisplayInfo: Codable, Equatable, Sendable {
    /// `CGDirectDisplayID` of the captured display.
    var id: UInt32
    /// Captured size in pixels.
    var width: Int
    var height: Int
    /// Pixels per point.
    var scale: Double

    init(id: UInt32, width: Int, height: Int, scale: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.scale = scale
    }

    enum CodingKeys: String, CodingKey { case id, width, height, scale }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decode(UInt32.self, forKey: .id, default: 0)
        width = c.decode(Int.self, forKey: .width, default: 1920)
        height = c.decode(Int.self, forKey: .height, default: 1080)
        scale = c.decode(Double.self, forKey: .scale, default: 1)
    }

    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

/// `events.json` — the event track captured alongside the pixels. Auto-zoom derives from this, never from frames.
struct EventsDocument: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    /// Unix epoch seconds of the first captured frame.
    var recordingStart: Double
    /// Recording length in seconds (seconds from `recordingStart` to the last frame).
    var duration: Double
    var display: DisplayInfo
    var cursor: [CursorSample]
    var clicks: [ClickEvent]
    var keys: [KeyEvent]
    var focus: [FocusEvent]

    init(
        version: Int = EventsDocument.currentVersion,
        recordingStart: Double,
        duration: Double,
        display: DisplayInfo,
        cursor: [CursorSample] = [],
        clicks: [ClickEvent] = [],
        keys: [KeyEvent] = [],
        focus: [FocusEvent] = []
    ) {
        self.version = version
        self.recordingStart = recordingStart
        self.duration = duration
        self.display = display
        self.cursor = cursor
        self.clicks = clicks
        self.keys = keys
        self.focus = focus
    }

    enum CodingKeys: String, CodingKey { case version, recordingStart, duration, display, cursor, clicks, keys, focus }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.decode(Int.self, forKey: .version, default: EventsDocument.currentVersion)
        recordingStart = c.decode(Double.self, forKey: .recordingStart, default: 0)
        display = c.decode(DisplayInfo.self, forKey: .display, default: DisplayInfo(id: 0, width: 1920, height: 1080, scale: 1))
        cursor = c.decode([CursorSample].self, forKey: .cursor, default: [])
        clicks = c.decode([ClickEvent].self, forKey: .clicks, default: [])
        keys = c.decode([KeyEvent].self, forKey: .keys, default: [])
        focus = c.decode([FocusEvent].self, forKey: .focus, default: [])
        let lastEvent = max(cursor.last?.t ?? 0, clicks.last?.t ?? 0, keys.last?.t ?? 0, focus.last?.t ?? 0)
        duration = c.decode(Double.self, forKey: .duration, default: lastEvent)
    }

    func encodedData() throws -> Data {
        try DocumentJSON.encoder(pretty: false).encode(self)
    }

    static func decode(_ data: Data) throws -> EventsDocument {
        try DocumentJSON.decoder.decode(EventsDocument.self, from: data)
    }

    /// The focus record in effect at time `t`.
    func focus(at t: Double) -> FocusEvent? {
        var result: FocusEvent?
        for event in focus {
            if event.t <= t { result = event } else { break }
        }
        return result
    }

    /// Source pixel size as a vector.
    var sourceSize: SIMD2<Double> { SIMD2(Double(max(display.width, 1)), Double(max(display.height, 1))) }
}
