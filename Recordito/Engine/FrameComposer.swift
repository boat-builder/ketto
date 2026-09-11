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

    static func compute(canvas: CanvasSpec, style: StyleSpec, sourceAspect: Double) -> CanvasLayout {
        let w = Double(canvas.width), h = Double(canvas.height)
        let padding = min(max(style.padding, 0), min(w, h) / 2 - 8)
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

/// Everything the renderer needs to draw one frame. Pure data: preview and export render the same state.
struct FrameState: Equatable, Sendable {
    var layout: CanvasLayout
    var viewport: Viewport
    var previousViewport: Viewport
    var cursor: CursorState?
    var ripples: [RippleState]
    var motionBlur: Bool
}

/// `(edit.json, events.json, t) -> FrameState`.
struct FrameComposer: Sendable {
    let edit: EditDocument
    let events: EventsDocument
    let source: SourceInfo
    let layout: CanvasLayout
    let zoomTimeline: ZoomTimeline
    let cursorTrack: CursorTrack
    let clicks: [ClickEvent]

    static let rippleDuration = 0.6

    init(edit: EditDocument, events: EventsDocument, source: SourceInfo) {
        self.edit = edit
        self.events = events
        self.source = source
        self.layout = CanvasLayout.compute(canvas: edit.canvas, style: edit.style, sourceAspect: source.aspect)
        self.zoomTimeline = edit.autoZoom.enabled ? ZoomTimeline(zooms: edit.zooms) : .identity
        var params = CursorSmoothingParameters()
        params.smoothing = edit.cursor.smoothing
        params.hideWhenIdle = edit.cursor.hideWhenIdle
        self.cursorTrack = CursorSmoother.smooth(events: events, parameters: params)
        self.clicks = events.clicks.filter { $0.phase == .down }.sorted { $0.t < $1.t }
    }

    var duration: Double { events.duration }

    /// Maps a source-pixel position to canvas pixels for a given viewport.
    func canvasPoint(fromSource p: SIMD2<Double>, viewport: Viewport) -> SIMD2<Double> {
        let normalised = p / source.size
        let local = (normalised - viewport.origin) / viewport.size
        let rect = layout.contentRect
        return SIMD2(rect.minX + local.x * rect.width, rect.minY + local.y * rect.height)
    }

    /// Canvas pixels per source point for a given viewport.
    func contentScale(viewport: Viewport) -> Double {
        layout.contentRect.width / (viewport.size.x * Double(source.width)) * source.scale
    }

    func state(at t: Double, fps: Double = 60) -> FrameState {
        let viewport = zoomTimeline.viewport(at: t)
        let previous = zoomTimeline.viewport(at: max(0, t - 1 / max(fps, 1)))
        let scale = contentScale(viewport: viewport)

        var cursor: CursorState?
        if !cursorTrack.isEmpty {
            let position = cursorTrack.position(at: t)
            let size = CursorGlyphs.designSize * scale * max(edit.cursor.scale, 0.05)
            cursor = CursorState(
                position: canvasPoint(fromSource: position, viewport: viewport),
                size: SIMD2(size, size),
                type: cursorTrack.cursorType(at: t),
                opacity: cursorTrack.opacity(at: t)
            )
        }

        var ripples: [RippleState] = []
        if edit.cursor.clickHighlight {
            for click in clicks where click.t <= t && t - click.t < Self.rippleDuration {
                let progress = (t - click.t) / Self.rippleDuration
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

        return FrameState(
            layout: layout,
            viewport: viewport,
            previousViewport: previous,
            cursor: cursor,
            ripples: ripples,
            motionBlur: edit.effects.motionBlur
        )
    }
}
