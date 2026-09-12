import Foundation
import CoreGraphics

struct SourceInfo: Equatable, Sendable {
    var width: Int
    var height: Int
    /// Pixels per point of the recorded display.
    var scale: Double

    init(width: Int, height: Int, scale: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        self.scale = max(scale, 0.01)
    }

    init(display: DisplayInfo) {
        self.init(width: display.width, height: display.height, scale: display.scale)
    }

    var aspect: Double { Double(width) / Double(height) }
    var size: SIMD2<Double> { SIMD2(Double(width), Double(height)) }
}

/// Canvas geometry: where the screen frame sits on the canvas.
struct CanvasLayout: Equatable, Sendable {
    var canvasSize: SIMD2<Double>
    var contentRect: CGRect
    var style: StyleSpec

    /// Fits a frame of aspect `sourceAspect` (width / height) inside the padded canvas, centred.
    static func compute(canvas: CanvasSpec, style: StyleSpec, sourceAspect: Double) -> CanvasLayout {
        let w = Double(canvas.width), h = Double(canvas.height)
        let padding = Self.clampedPadding(style.padding, width: w, height: h)
        let availableWidth = max(w - 2 * padding, 8)
        let availableHeight = max(h - 2 * padding, 8)
        var contentWidth = availableWidth
        var contentHeight = contentWidth / sourceAspect
        if contentHeight > availableHeight {
            contentHeight = availableHeight
            contentWidth = contentHeight * sourceAspect
        }
        let rect = CGRect(x: (w - contentWidth) / 2, y: (h - contentHeight) / 2, width: contentWidth, height: contentHeight)
        return CanvasLayout(canvasSize: SIMD2(w, h), contentRect: rect, style: style)
    }

    static func clampedPadding(_ padding: Double, width: Double, height: Double) -> Double {
        min(max(padding, 0), min(width, height) / 2 - 8)
    }

    /// Aspect (width / height) of the area inside the padding — what a `fill` frame takes on.
    static func paddedAspect(canvas: CanvasSpec, style: StyleSpec) -> Double {
        let w = Double(canvas.width), h = Double(canvas.height)
        let padding = clampedPadding(style.padding, width: w, height: h)
        return max(w - 2 * padding, 8) / max(h - 2 * padding, 8)
    }
}

struct CursorState: Equatable, Sendable {
    /// Hotspot position in canvas pixels.
    var position: SIMD2<Double>
    /// Size of the glyph design box in canvas pixels.
    var size: SIMD2<Double>
    var type: CursorType
    var opacity: Double
}

struct RippleState: Equatable, Sendable {
    var center: SIMD2<Double>
    var radius: Double
    var thickness: Double
    var alpha: Double
}

/// A mask region for one frame, in canvas pixels.
struct MaskState: Equatable, Sendable {
    var rect: CGRect
    var kind: MaskKind
    var strength: Double
    var cornerRadius: Double
}

/// The webcam overlay for one frame, in canvas pixels.
struct CameraOverlayState: Equatable, Sendable {
    var rect: CGRect
    var shape: CameraShape
    var cornerRadius: Double
    var borderWidth: Double
    var borderColor: RGBAColor
    var mirrored: Bool
    var opacity: Double
    var shadow: Bool
}

/// The keystroke label for one frame. The renderer measures the text; the composer only places it.
struct KeystrokeLabelState: Equatable, Sendable {
    var text: String
    /// Centre of the label in canvas pixels.
    var anchor: SIMD2<Double>
    /// Font size in canvas pixels.
    var fontSize: Double
    var opacity: Double
}

/// Everything the renderer needs to draw one frame. Pure data: preview and export render the same state.
struct FrameState: Equatable, Sendable {
    var layout: CanvasLayout
    var viewport: Viewport
    var previousViewport: Viewport
    var cursor: CursorState?
    var ripples: [RippleState]
    var motionBlur: Bool
    var masks: [MaskState] = []
    var camera: CameraOverlayState? = nil
    var keystroke: KeystrokeLabelState? = nil
    /// The recording time this frame shows.
    var sourceTime: Double = 0
}

/// `(edit.json, events.json, t) -> FrameState`, where `t` is a time on the *edited* timeline: cuts and speed
/// changes are applied here, so the player, the exporter and the timeline all address frames the same way.
struct FrameComposer: Sendable {
    let edit: EditDocument
    let events: EventsDocument
    let source: SourceInfo
    let layout: CanvasLayout
    let timeline: EditTimeline
    let framing: ZoomFraming
    let zoomTimeline: ZoomTimeline
    let cursorTrack: CursorTrack
    let clicks: [ClickEvent]
    /// The key events that can appear on screen, sorted by time.
    let keys: [KeyEvent]
    let cameraDodge: CameraDodgeSchedule?
    let cameraAvailable: Bool
    /// Length of the recording in seconds: the event track's duration, or the media's when that is longer.
    let sourceDuration: Double

    static let rippleDuration = 0.6
    static let maxMasks = 8

    /// - Parameter sourceDuration: the length of `screen.mov` when known; the event track's duration is used
    ///   when it is longer or when nothing is supplied.
    init(edit: EditDocument, events: EventsDocument, source: SourceInfo, cameraAvailable: Bool = false, sourceDuration: Double? = nil) {
        let track = CursorSmoother.smooth(events: events, parameters: Self.cursorParameters(for: edit))
        self.init(edit: edit, events: events, source: source, cursorTrack: track, cameraAvailable: cameraAvailable, sourceDuration: sourceDuration)
    }

    /// Builds a composer around an already smoothed cursor track. The editor uses this so that changing the
    /// background or padding does not re-run cursor smoothing; the track only depends on `cursorParameters(for:)`.
    /// `zoomTimeline` may likewise be supplied prebuilt (see `makeZoomTimeline`) when nothing it depends on changed.
    init(edit: EditDocument, events: EventsDocument, source: SourceInfo, cursorTrack: CursorTrack, cameraAvailable: Bool = false, zoomTimeline: ZoomTimeline? = nil, sourceDuration: Double? = nil) {
        self.edit = edit
        self.events = events
        self.source = source
        self.cursorTrack = cursorTrack
        self.cameraAvailable = cameraAvailable
        let duration = Self.resolvedSourceDuration(events: events, sourceDuration: sourceDuration)
        self.sourceDuration = duration
        let framing = Self.framing(edit: edit, source: source)
        self.framing = framing
        self.layout = CanvasLayout.compute(canvas: edit.canvas, style: edit.style, sourceAspect: Self.contentAspect(framing: framing, source: source))
        self.timeline = EditTimeline(edit: edit, sourceDuration: duration)
        self.zoomTimeline = zoomTimeline ?? Self.makeZoomTimeline(edit: edit, events: events, source: source, cursorTrack: cursorTrack, framing: framing, sourceDuration: duration)
        self.clicks = events.clicks.filter { $0.phase == .down }.sorted { $0.t < $1.t }
        self.keys = (edit.keystrokes.shortcutsOnly ? events.keys.filter(\.isShortcut) : events.keys).sorted { $0.t < $1.t }

        if cameraAvailable, edit.camera.enabled, edit.camera.dodgeCursor, !cursorTrack.isEmpty {
            let home = Self.cameraRect(spec: edit.camera, layout: layout)
            let away = Self.mirroredHorizontally(home, in: layout.canvasSize)
            let margin = max(24.0, home.width * 0.12)
            let homeZone = home.insetBy(dx: -margin, dy: -margin)
            let awayZone = away.insetBy(dx: -margin, dy: -margin)
            let zoomTimeline = self.zoomTimeline
            let sourceSize = source.size
            let contentRect = layout.contentRect
            self.cameraDodge = CameraDodgeSchedule.make(duration: duration) { t in
                guard cursorTrack.opacity(at: t) > 0.05 else { return false }
                let viewport = zoomTimeline.viewport(at: t)
                let normalised = cursorTrack.position(at: t) / sourceSize
                let local = (normalised - viewport.origin) / viewport.size
                let p = CGPoint(x: contentRect.minX + local.x * contentRect.width, y: contentRect.minY + local.y * contentRect.height)
                return homeZone.contains(p) && !awayZone.contains(p)
            }
        } else {
            self.cameraDodge = nil
        }
    }

    static func resolvedSourceDuration(events: EventsDocument, sourceDuration: Double?) -> Double {
        let media = sourceDuration ?? 0
        return max(events.duration, media.isFinite ? media : 0, 0)
    }

    /// The smoothing parameters implied by an edit document. Two documents with equal parameters share a cursor track.
    static func cursorParameters(for edit: EditDocument) -> CursorSmoothingParameters {
        var params = CursorSmoothingParameters()
        params.smoothing = edit.cursor.smoothing
        params.hideWhenIdle = edit.cursor.hideWhenIdle
        return params
    }

    /// The base (un-zoomed) view and the crop implied by an edit document.
    static func framing(edit: EditDocument, source: SourceInfo) -> ZoomFraming {
        let bounds = edit.crop.viewport
        switch edit.canvas.framing {
        case .fit:
            return ZoomFraming(base: bounds, bounds: bounds)
        case .fill:
            let aspect = CanvasLayout.paddedAspect(canvas: edit.canvas, style: edit.style)
            return ZoomFraming(base: Viewport.fitting(pixelAspect: aspect, within: bounds, sourceSize: source.size), bounds: bounds)
        }
    }

    /// Pixel aspect (width / height) of the base view — what the screen frame on the canvas shows.
    static func contentAspect(framing: ZoomFraming, source: SourceInfo) -> Double {
        (framing.base.size.x * source.size.x) / max(framing.base.size.y * source.size.y, 1e-9)
    }

    /// The zooms that play: all of them while auto zoom is on, only the user's own when it is off.
    static func activeZooms(in edit: EditDocument) -> [Zoom] {
        edit.autoZoom.enabled ? edit.zooms : edit.zooms.filter(\.userModified)
    }

    /// The camera path: the idle camera for `fill` framing plus every zoom, both following the smoothed
    /// cursor. Depends only on the active zooms, the framing, the events and the cursor track, so the editor
    /// caches it across inspector changes that touch none of those.
    static func makeZoomTimeline(edit: EditDocument, events: EventsDocument, source: SourceInfo, cursorTrack: CursorTrack, framing: ZoomFraming, sourceDuration: Double? = nil) -> ZoomTimeline {
        let sourceSize = source.size
        let duration = resolvedSourceDuration(events: events, sourceDuration: sourceDuration)
        let follow: (Double) -> SIMD2<Double>? = { t in
            cursorTrack.isEmpty ? nil : cursorTrack.position(at: t) / sourceSize
        }
        let idleCamera: FramingTrack?
        if framing.base.isApproximatelyEqual(to: framing.bounds) {
            idleCamera = nil
        } else {
            idleCamera = FramingTrack.make(duration: duration, size: framing.base.size, bounds: framing.bounds, pointOfInterest: follow)
        }
        return ZoomTimeline(zooms: activeZooms(in: edit), base: framing.base, bounds: framing.bounds, framing: idleCamera, follow: follow)
    }

    /// Length of the edited timeline in seconds.
    var duration: Double { timeline.outputDuration }

    func sourceTime(forOutput t: Double) -> Double { timeline.sourceTime(forOutput: t) }

    func outputTime(forSource t: Double) -> Double { timeline.outputTime(forSource: t) }

    /// The smoothed cursor position at source time `t`, normalised (0–1), or nil without a cursor track.
    func cursorPosition(atSource t: Double) -> SIMD2<Double>? {
        guard !cursorTrack.isEmpty else { return nil }
        return cursorTrack.position(at: t) / source.size
    }

    /// Maps a source-pixel position to canvas pixels for a given viewport.
    func canvasPoint(fromSource p: SIMD2<Double>, viewport: Viewport) -> SIMD2<Double> {
        let normalised = p / source.size
        let local = (normalised - viewport.origin) / viewport.size
        let rect = layout.contentRect
        return SIMD2(rect.minX + local.x * rect.width, rect.minY + local.y * rect.height)
    }

    /// Maps a canvas-pixel position back to source pixels for a given viewport.
    func sourcePoint(fromCanvas p: SIMD2<Double>, viewport: Viewport) -> SIMD2<Double> {
        let rect = layout.contentRect
        let local = SIMD2((p.x - rect.minX) / max(rect.width, 1e-9), (p.y - rect.minY) / max(rect.height, 1e-9))
        return (viewport.origin + local * viewport.size) * source.size
    }

    /// Maps a normalised source rectangle to canvas pixels for a given viewport.
    func canvasRect(fromNormalised rect: CGRect, viewport: Viewport) -> CGRect {
        let a = canvasPoint(fromSource: SIMD2(rect.minX, rect.minY) * source.size, viewport: viewport)
        let b = canvasPoint(fromSource: SIMD2(rect.maxX, rect.maxY) * source.size, viewport: viewport)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Canvas pixels per source point for a given viewport.
    func contentScale(viewport: Viewport) -> Double {
        layout.contentRect.width / (viewport.size.x * Double(source.width)) * source.scale
    }

    /// Where the webcam overlay sits when nothing is in its way, in canvas pixels.
    static func cameraRect(spec: CameraOverlaySpec, layout: CanvasLayout) -> CGRect {
        let canvas = layout.canvasSize
        let height = min(max(spec.size, 0.05), 1) * canvas.y
        let width = height * min(max(spec.aspect, 0.25), 4)
        let margin = 16.0
        let x = min(max(spec.position.x * canvas.x, margin + width / 2), max(canvas.x - margin - width / 2, margin + width / 2))
        let y = min(max(spec.position.y * canvas.y, margin + height / 2), max(canvas.y - margin - height / 2, margin + height / 2))
        return CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
    }

    static func mirroredHorizontally(_ rect: CGRect, in canvas: SIMD2<Double>) -> CGRect {
        CGRect(x: canvas.x - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
    }

    func state(at t: Double, fps: Double = 60) -> FrameState {
        let sourceTime = timeline.sourceTime(forOutput: t)
        let viewport = zoomTimeline.viewport(at: sourceTime)
        let previousOutput = max(0, t - 1 / max(fps, 1))
        let previous: Viewport
        if timeline.segmentIndex(atOutput: t) != timeline.segmentIndex(atOutput: previousOutput) {
            previous = viewport // across a cut there is no motion to blur
        } else {
            previous = zoomTimeline.viewport(at: timeline.sourceTime(forOutput: previousOutput))
        }
        let scale = contentScale(viewport: viewport)

        var cursor: CursorState?
        if !cursorTrack.isEmpty {
            var position = cursorTrack.position(at: sourceTime)
            let outputDuration = timeline.outputDuration
            if edit.cursor.loop, outputDuration > CursorSpec.loopBlend, t > outputDuration - CursorSpec.loopBlend {
                let u = Easing.easeInOutCubic.apply((t - (outputDuration - CursorSpec.loopBlend)) / CursorSpec.loopBlend)
                let home = cursorTrack.position(at: timeline.sourceTime(forOutput: 0))
                position += (home - position) * u
            }
            let size = CursorGlyphs.designSize * scale * max(edit.cursor.scale, 0.05)
            cursor = CursorState(
                position: canvasPoint(fromSource: position, viewport: viewport),
                size: SIMD2(size, size),
                type: cursorTrack.cursorType(at: sourceTime),
                opacity: cursorTrack.opacity(at: sourceTime)
            )
        }

        var ripples: [RippleState] = []
        if edit.cursor.clickHighlight {
            for click in clicks where click.t <= sourceTime && sourceTime - click.t < Self.rippleDuration {
                let progress = (sourceTime - click.t) / Self.rippleDuration
                let eased = Easing.easeOutCubic.apply(progress)
                let radiusPoints = 6 + 30 * eased
                ripples.append(RippleState(
                    center: canvasPoint(fromSource: click.position, viewport: viewport),
                    radius: radiusPoints * scale,
                    thickness: max(1.5, 3 * scale),
                    alpha: 0.75 * (1 - progress)
                ))
                if ripples.count == 8 { break }
            }
        }

        var masks: [MaskState] = []
        for mask in edit.masks where mask.isActive(at: sourceTime) {
            let rect = canvasRect(fromNormalised: mask.rect, viewport: viewport)
            guard rect.intersects(layout.contentRect) else { continue }
            masks.append(MaskState(rect: rect, kind: mask.kind, strength: mask.strength, cornerRadius: mask.cornerRadius))
            if masks.count == Self.maxMasks { break }
        }

        var camera: CameraOverlayState?
        if cameraAvailable, edit.camera.enabled {
            let home = Self.cameraRect(spec: edit.camera, layout: layout)
            var rect = home
            if let cameraDodge, edit.camera.dodgeCursor {
                let u = cameraDodge.progress(at: sourceTime)
                if u > 0 {
                    let away = Self.mirroredHorizontally(home, in: layout.canvasSize)
                    rect = CGRect(
                        x: home.minX + (away.minX - home.minX) * u,
                        y: home.minY,
                        width: home.width,
                        height: home.height
                    )
                }
            }
            camera = CameraOverlayState(
                rect: rect,
                shape: edit.camera.shape,
                cornerRadius: edit.camera.cornerRadius,
                borderWidth: edit.camera.border.width,
                borderColor: edit.camera.border.color,
                mirrored: edit.camera.mirrored,
                opacity: 1,
                shadow: edit.camera.shadow
            )
        }

        var keystroke: KeystrokeLabelState?
        if edit.keystrokes.enabled, !keys.isEmpty, let label = KeystrokeDisplay.label(keys: keys, at: sourceTime), label.opacity > 0.001 {
            let fontSize = 22 * edit.keystrokes.scale * (layout.canvasSize.y / 1080)
            let margin = 1.6 * fontSize
            let y = edit.keystrokes.position == .bottom ? layout.contentRect.maxY - margin : layout.contentRect.minY + margin
            keystroke = KeystrokeLabelState(text: label.text, anchor: SIMD2(layout.contentRect.midX, y), fontSize: fontSize, opacity: label.opacity)
        }

        return FrameState(
            layout: layout,
            viewport: viewport,
            previousViewport: previous,
            cursor: cursor,
            ripples: ripples,
            motionBlur: edit.effects.motionBlur,
            masks: masks,
            camera: camera,
            keystroke: keystroke,
            sourceTime: sourceTime
        )
    }
}
