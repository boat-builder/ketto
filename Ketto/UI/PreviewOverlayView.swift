import SwiftUI

/// Direct manipulation on top of the Metal preview: the crop rectangle while editing the crop, the selected
/// mask's region, the camera bubble, and the selected zoom's target. Everything is drawn in view points from
/// the same `FrameState` the preview renders, so handles sit exactly on what they edit.
struct PreviewOverlayView: View {
    @Bindable var session: ProjectSession
    /// Size of the preview in points.
    let size: CGSize

    var body: some View {
        let composer = session.previewComposer
        let scale = size.width / max(composer.layout.canvasSize.x, 1)
        let state = composer.state(at: session.player.currentTime)
        ZStack(alignment: .topLeading) {
            if session.isEditingCrop {
                CropEditor(session: session, composer: composer, scale: scale)
            } else {
                if let mask = session.selectedMask, mask.isActive(at: state.sourceTime) {
                    MaskEditor(session: session, composer: composer, mask: mask, viewport: state.viewport, scale: scale)
                }
                if let camera = state.camera, session.edit.camera.enabled, session.hasCameraTrack {
                    CameraEditor(session: session, composer: composer, displayed: camera.rect, scale: scale)
                }
                if let zoom = session.selectedZoom, zoom.start <= state.sourceTime, state.sourceTime < zoom.end {
                    ZoomTargetEditor(session: session, composer: composer, zoom: zoom, viewport: state.viewport, scale: scale)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// A rectangle with eight handles. Reports the rectangle (in the same coordinate space as `rect`) as it is
/// moved or resized.
private struct RectEditor: View {
    let rect: CGRect
    let color: Color
    let dimOutside: Bool
    let canvasSize: CGSize
    let onBegin: () -> Void
    let onChange: (CGRect) -> Void
    let onEnd: () -> Void

    @State private var origin: CGRect?

    private static let handleSize: CGFloat = 10
    private static let minimumSide: CGFloat = 12

    var body: some View {
        ZStack(alignment: .topLeading) {
            if dimOutside {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: canvasSize))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            }
            Rectangle()
                .strokeBorder(color, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .contentShape(Rectangle())
                .gesture(moveGesture)
            ForEach(Handle.allCases, id: \.self) { handle in
                let point = handle.point(in: rect)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                    .frame(width: Self.handleSize, height: Self.handleSize)
                    .contentShape(Circle().inset(by: -4))
                    .offset(x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2)
                    .gesture(resizeGesture(handle))
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if origin == nil {
                    origin = rect
                    onBegin()
                }
                guard let origin else { return }
                onChange(origin.offsetBy(dx: value.translation.width, dy: value.translation.height))
            }
            .onEnded { _ in
                origin = nil
                onEnd()
            }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if origin == nil {
                    origin = rect
                    onBegin()
                }
                guard let origin else { return }
                var minX = origin.minX, minY = origin.minY, maxX = origin.maxX, maxY = origin.maxY
                let dx = value.translation.width, dy = value.translation.height
                if handle.movesLeft { minX = min(origin.minX + dx, maxX - Self.minimumSide) }
                if handle.movesRight { maxX = max(origin.maxX + dx, minX + Self.minimumSide) }
                if handle.movesTop { minY = min(origin.minY + dy, maxY - Self.minimumSide) }
                if handle.movesBottom { maxY = max(origin.maxY + dy, minY + Self.minimumSide) }
                onChange(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            .onEnded { _ in
                origin = nil
                onEnd()
            }
    }

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }

        func point(in rect: CGRect) -> CGPoint {
            let x: CGFloat = movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX)
            let y: CGFloat = movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY)
            return CGPoint(x: x, y: y)
        }
    }
}

/// View points ↔ normalised source coordinates through a composer and a viewport.
private struct OverlayMapping {
    let composer: FrameComposer
    let viewport: Viewport
    let scale: CGFloat

    func viewRect(normalised rect: CGRect) -> CGRect {
        let canvas = composer.canvasRect(fromNormalised: rect, viewport: viewport)
        return CGRect(x: canvas.minX * scale, y: canvas.minY * scale, width: canvas.width * scale, height: canvas.height * scale)
    }

    func normalisedPoint(view point: CGPoint) -> SIMD2<Double> {
        composer.sourcePoint(fromCanvas: SIMD2(Double(point.x / scale), Double(point.y / scale)), viewport: viewport) / composer.source.size
    }

    func normalisedRect(view rect: CGRect) -> CGRect {
        let a = normalisedPoint(view: CGPoint(x: rect.minX, y: rect.minY))
        let b = normalisedPoint(view: CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }

    func viewPoint(normalised p: SIMD2<Double>) -> CGPoint {
        let canvas = composer.canvasPoint(fromSource: p * composer.source.size, viewport: viewport)
        return CGPoint(x: canvas.x * scale, y: canvas.y * scale)
    }
}

private struct CropEditor: View {
    let session: ProjectSession
    let composer: FrameComposer
    let scale: CGFloat

    var body: some View {
        let mapping = OverlayMapping(composer: composer, viewport: .full, scale: scale)
        let canvasSize = CGSize(width: composer.layout.canvasSize.x * scale, height: composer.layout.canvasSize.y * scale)
        RectEditor(
            rect: mapping.viewRect(normalised: session.edit.crop.rect),
            color: .yellow,
            dimOutside: true,
            canvasSize: canvasSize,
            onBegin: { session.beginGesture() },
            onChange: { rect in
                let crop = CropSpec(rect: mapping.normalisedRect(view: rect))
                session.updateGesture { $0.crop = crop }
            },
            onEnd: { session.endGesture() }
        )
    }
}

private struct MaskEditor: View {
    let session: ProjectSession
    let composer: FrameComposer
    let mask: Mask
    let viewport: Viewport
    let scale: CGFloat

    var body: some View {
        let mapping = OverlayMapping(composer: composer, viewport: viewport, scale: scale)
        let canvasSize = CGSize(width: composer.layout.canvasSize.x * scale, height: composer.layout.canvasSize.y * scale)
        let id = mask.id
        RectEditor(
            rect: mapping.viewRect(normalised: mask.rect),
            color: mask.kind == .blur ? .teal : .yellow,
            dimOutside: false,
            canvasSize: canvasSize,
            onBegin: {
                session.player.pause()
                session.beginGesture()
            },
            onChange: { rect in
                let normalised = mapping.normalisedRect(view: rect)
                session.updateGesture { doc in doc.updateMask(id: id) { $0.rect = normalised } }
            },
            onEnd: { session.endGesture() }
        )
    }
}

private struct CameraEditor: View {
    let session: ProjectSession
    let composer: FrameComposer
    /// Where the overlay is drawn right now (it may be dodging the cursor), in canvas pixels.
    let displayed: CGRect
    let scale: CGFloat

    @State private var startPosition: SIMD2<Double>?
    @State private var startRect: CGRect?

    var body: some View {
        let viewRect = CGRect(x: displayed.minX * scale, y: displayed.minY * scale, width: displayed.width * scale, height: displayed.height * scale)
        let canvasSize = composer.layout.canvasSize
        RectEditor(
            rect: viewRect,
            color: .white.opacity(0.8),
            dimOutside: false,
            canvasSize: CGSize(width: canvasSize.x * scale, height: canvasSize.y * scale),
            onBegin: {
                session.player.pause()
                startPosition = session.edit.camera.position
                startRect = viewRect
                session.beginGesture()
            },
            onChange: { rect in
                guard let startPosition, let startRect else { return }
                let delta = SIMD2(Double((rect.midX - startRect.midX) / scale) / canvasSize.x, Double((rect.midY - startRect.midY) / scale) / canvasSize.y)
                let position = SIMD2(min(max(startPosition.x + delta.x, 0), 1), min(max(startPosition.y + delta.y, 0), 1))
                let size = min(max(Double(rect.height / scale) / canvasSize.y, 0.05), 1)
                session.updateGesture { doc in
                    doc.camera.position = position
                    doc.camera.size = size
                }
            },
            onEnd: {
                session.endGesture()
                startPosition = nil
                startRect = nil
            }
        )
    }
}

private struct ZoomTargetEditor: View {
    let session: ProjectSession
    let composer: FrameComposer
    let zoom: Zoom
    let viewport: Viewport
    let scale: CGFloat

    @State private var startTarget: SIMD2<Double>?
    @State private var startViewport: Viewport?

    var body: some View {
        let mapping = OverlayMapping(composer: composer, viewport: viewport, scale: scale)
        let point = mapping.viewPoint(normalised: zoom.target)
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: 28, height: 28)
            Circle()
                .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                .frame(width: 32, height: 32)
            Rectangle().fill(Color.white).frame(width: 1.5, height: 10).offset(y: -19)
            Rectangle().fill(Color.white).frame(width: 1.5, height: 10).offset(y: 19)
            Rectangle().fill(Color.white).frame(width: 10, height: 1.5).offset(x: -19)
            Rectangle().fill(Color.white).frame(width: 10, height: 1.5).offset(x: 19)
        }
        .frame(width: 48, height: 48)
        .contentShape(Circle())
        .offset(x: point.x - 24, y: point.y - 24)
        .help("Drag to aim the zoom")
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if startTarget == nil {
                        session.player.pause()
                        startTarget = zoom.target
                        startViewport = viewport
                        session.beginGesture()
                    }
                    guard let startTarget, let startViewport else { return }
                    let content = composer.layout.contentRect
                    let delta = SIMD2(
                        Double(value.translation.width / scale) / content.width * startViewport.size.x,
                        Double(value.translation.height / scale) / content.height * startViewport.size.y
                    )
                    let target = startTarget + delta
                    let id = zoom.id
                    session.updateGesture { doc in doc.updateZoom(id: id) { $0.target = target } }
                }
                .onEnded { _ in
                    session.endGesture()
                    startTarget = nil
                    startViewport = nil
                }
        )
    }
}
