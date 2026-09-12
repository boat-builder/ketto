import Foundation

/// Where the floating camera bubble sat over the captured area when a recording stopped: its centre,
/// normalised (0–1, y down) in the captured area, and its height as a fraction of the area's height. The new
/// project's camera overlay starts out at the same place, so what the user saw while recording is what the
/// edit opens with.
struct CameraPlacement: Equatable, Sendable {
    var center: SIMD2<Double>
    var height: Double

    /// `spec` moved and sized to match this placement on `layout`: the same spot relative to the screen frame,
    /// the same height relative to it. A bubble that was dragged off the captured area lands on its edge.
    func overlay(from spec: CameraOverlaySpec, layout: CanvasLayout) -> CameraOverlaySpec {
        var result = spec
        let content = layout.contentRect
        let canvas = layout.canvasSize
        let x = Double(content.minX) + min(max(center.x, 0), 1) * Double(content.width)
        let y = Double(content.minY) + min(max(center.y, 0), 1) * Double(content.height)
        result.position = SIMD2(min(max(x / canvas.x, 0), 1), min(max(y / canvas.y, 0), 1))
        let height = height.isFinite ? height : 0
        result.size = min(max(height * Double(content.height) / canvas.y, 0.05), 1)
        return result
    }
}
