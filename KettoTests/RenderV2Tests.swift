import XCTest
import Metal
@testable import Ketto

/// The v2 render paths — masks, the webcam overlay and the keystroke label — checked by their visible effect
/// rather than by golden images, so no reference PNG needs re-recording. The v1 goldens still guard the
/// base composite, which these paths must leave untouched when they are off.
final class RenderV2Tests: XCTestCase {
    private let width = 960
    private let height = 540

    private var source: SourceInfo { SourceInfo(display: SyntheticSource.events().display) }

    /// The synthetic pattern through the mipmapped upload path: blur masks sample coarse mip levels.
    private func uploadedSource(renderer: FrameRenderer) throws -> MTLTexture {
        let uploader = SourceTextureUploader(device: renderer.device)
        let pixelBuffer = SyntheticSource.pixelBuffer(image: SyntheticSource.patternImage(width: 640, height: 400))
        let commandBuffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        let texture = try XCTUnwrap(uploader.upload(pixelBuffer, commandBuffer: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return texture
    }

    private func render(_ state: FrameState, source: MTLTexture, camera: MTLTexture? = nil, renderer: FrameRenderer) throws -> BGRAImage {
        let target = try renderer.makeReadableTarget(width: width, height: height)
        try renderer.render(state: state, source: source, camera: camera, into: target)
        return BGRAImage(texture: target)
    }

    /// Mean absolute difference between neighbouring pixels inside `rect` (target pixels): a detail measure.
    private func roughness(_ image: BGRAImage, in rect: CGRect) -> Double {
        var total = 0.0
        var count = 0
        let x0 = max(Int(rect.minX), 1), x1 = min(Int(rect.maxX), image.width - 1)
        let y0 = max(Int(rect.minY), 1), y1 = min(Int(rect.maxY), image.height - 1)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * image.width + x) * 4
                let left = (y * image.width + x - 1) * 4
                let up = ((y - 1) * image.width + x) * 4
                for c in 0..<3 {
                    total += Double(abs(Int(image.bytes[i + c]) - Int(image.bytes[left + c])))
                    total += Double(abs(Int(image.bytes[i + c]) - Int(image.bytes[up + c])))
                }
                count += 6
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    private func bytes(_ image: BGRAImage, in rect: CGRect) -> [UInt8] {
        var result: [UInt8] = []
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let start = (y * image.width + Int(rect.minX)) * 4
            result.append(contentsOf: image.bytes[start..<start + Int(rect.width) * 4])
        }
        return result
    }

    private func pixel(_ image: BGRAImage, x: Int, y: Int) -> (b: Int, g: Int, r: Int) {
        let i = (y * image.width + x) * 4
        return (Int(image.bytes[i]), Int(image.bytes[i + 1]), Int(image.bytes[i + 2]))
    }

    private func targetRect(_ canvasRect: CGRect, layout: CanvasLayout) -> CGRect {
        let scale = Double(width) / layout.canvasSize.x
        return CGRect(x: canvasRect.minX * scale, y: canvasRect.minY * scale, width: canvasRect.width * scale, height: canvasRect.height * scale)
    }

    func testBlurMaskSoftensOnlyItsRegion() throws {
        let renderer = try FrameRenderer()
        let sourceTexture = try uploadedSource(renderer: renderer)
        let events = SyntheticSource.events()
        var edit = EditDocument.default
        let plain = FrameComposer(edit: edit, events: events, source: source)
        let maskRect = CGRect(x: 0.25, y: 0.3, width: 0.4, height: 0.4) // over the synthetic window's text bars
        edit.masks = [Mask(id: "m", kind: .blur, rect: maskRect)]
        let masked = FrameComposer(edit: edit, events: events, source: source)

        let before = try render(plain.state(at: 0.5), source: sourceTexture, renderer: renderer)
        let after = try render(masked.state(at: 0.5), source: sourceTexture, renderer: renderer)
        let region = targetRect(masked.canvasRect(fromNormalised: maskRect, viewport: .full), layout: masked.layout).insetBy(dx: 6, dy: 6)
        let sharp = roughness(before, in: region)
        let soft = roughness(after, in: region)
        XCTAssertGreaterThan(sharp, 4, "the text bars are high contrast to begin with")
        XCTAssertLessThan(soft, sharp * 0.5, "blur removes most of the detail (\(soft) vs \(sharp))")

        // Content well outside the mask is byte-identical.
        let outside = targetRect(masked.canvasRect(fromNormalised: CGRect(x: 0.03, y: 0.03, width: 0.15, height: 0.15), viewport: .full), layout: masked.layout)
        XCTAssertEqual(bytes(after, in: outside), bytes(before, in: outside))
    }

    func testHighlightMaskDimsEverythingElse() throws {
        let renderer = try FrameRenderer()
        let sourceTexture = SyntheticSource.texture(device: renderer.device, image: SyntheticSource.patternImage(width: 640, height: 400))
        let events = SyntheticSource.events()
        var edit = EditDocument.default
        edit.cursor.hideWhenIdle = false
        let plain = FrameComposer(edit: edit, events: events, source: source)
        let maskRect = CGRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3)
        edit.masks = [Mask(id: "h", kind: .highlight, rect: maskRect, strength: 1)]
        let masked = FrameComposer(edit: edit, events: events, source: source)

        let before = try render(plain.state(at: 0.5), source: sourceTexture, renderer: renderer)
        let after = try render(masked.state(at: 0.5), source: sourceTexture, renderer: renderer)
        let inside = targetRect(masked.canvasRect(fromNormalised: maskRect, viewport: .full), layout: masked.layout).insetBy(dx: 8, dy: 8)
        XCTAssertEqual(bytes(after, in: inside), bytes(before, in: inside), "the highlighted region is untouched")
        let outsideRect = masked.canvasRect(fromNormalised: CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2), viewport: .full)
        let outside = targetRect(outsideRect, layout: masked.layout)
        let x = Int(outside.midX), y = Int(outside.midY)
        let lit = pixel(before, x: x, y: y)
        let dim = pixel(after, x: x, y: y)
        XCTAssertLessThan(dim.r + dim.g + dim.b, (lit.r + lit.g + lit.b) * 4 / 10 + 3, "outside is dimmed to a quarter")
        // The background around the frame is not content and stays as it was.
        XCTAssertEqual(pixel(after, x: 4, y: 4).g, pixel(before, x: 4, y: 4).g)
    }

    func testCameraOverlayShowsTheCameraFrameWithItsBorder() throws {
        let renderer = try FrameRenderer()
        let sourceTexture = SyntheticSource.texture(device: renderer.device, image: SyntheticSource.patternImage(width: 640, height: 400))
        let events = SyntheticSource.events()
        var edit = EditDocument.default
        edit.camera.dodgeCursor = false
        let composer = FrameComposer(edit: edit, events: events, source: source, cameraAvailable: true)
        let state = composer.state(at: 0.5)
        let overlay = try XCTUnwrap(state.camera)

        var green = [UInt8](repeating: 0, count: 64 * 48 * 4)
        for i in stride(from: 0, to: green.count, by: 4) {
            green[i + 1] = 200
            green[i + 3] = 255
        }
        let cameraTexture = SyntheticSource.texture(device: renderer.device, image: BGRAImage(width: 64, height: 48, bytes: green))
        let image = try render(state, source: sourceTexture, camera: cameraTexture, renderer: renderer)
        let rect = targetRect(overlay.rect, layout: composer.layout)
        let centre = pixel(image, x: Int(rect.midX), y: Int(rect.midY))
        XCTAssertGreaterThan(centre.g, 150)
        XCTAssertLessThan(centre.r, 60)
        XCTAssertLessThan(centre.b, 60)
        // One pixel inside the edge of the circle sits in the 4 px (2 target px) white border.
        let radius = rect.height / 2
        let border = pixel(image, x: Int(rect.midX + radius - 1), y: Int(rect.midY))
        XCTAssertGreaterThan(border.r, 200)
        XCTAssertGreaterThan(border.g, 200)
        XCTAssertGreaterThan(border.b, 200)

        // Without a camera texture the overlay is skipped, and the frame equals one composed with no camera.
        let withoutTexture = try render(state, source: sourceTexture, renderer: renderer)
        let noCamera = FrameComposer(edit: edit, events: events, source: source).state(at: 0.5)
        XCTAssertNil(noCamera.camera)
        let reference = try render(noCamera, source: sourceTexture, renderer: renderer)
        XCTAssertEqual(withoutTexture.bytes, reference.bytes)
    }

    func testKeystrokeLabelIsDrawnAtItsAnchor() throws {
        let renderer = try FrameRenderer()
        let label = try XCTUnwrap(renderer.labels.label(text: "⌘⇧S", fontPixelSize: 24))
        XCTAssertGreaterThan(label.texture.width, label.texture.height)
        XCTAssertGreaterThan(label.texture.height, 24)
        XCTAssertTrue(renderer.labels.label(text: "⌘⇧S", fontPixelSize: 24)!.texture === label.texture, "cached")

        var events = SyntheticSource.events()
        events.keys = [KeyEvent(t: 1.0, chars: "S", modifiers: ["cmd", "shift"])]
        let composer = FrameComposer(edit: .default, events: events, source: source)
        let state = composer.state(at: 1.2)
        let keystroke = try XCTUnwrap(state.keystroke)
        let sourceTexture = SyntheticSource.texture(device: renderer.device, image: SyntheticSource.patternImage(width: 640, height: 400))
        let with = try render(state, source: sourceTexture, renderer: renderer)
        var plainState = state
        plainState.keystroke = nil
        let without = try render(plainState, source: sourceTexture, renderer: renderer)
        XCTAssertNotEqual(with.bytes, without.bytes)

        // A point in the pill's padding, left of the glyphs: darker than the bare frame underneath.
        let scale = Double(width) / composer.layout.canvasSize.x
        let drawn = try XCTUnwrap(renderer.labels.label(text: keystroke.text, fontPixelSize: keystroke.fontSize * scale))
        let x = Int(keystroke.anchor.x * scale - drawn.size.width / 2 + 3)
        let y = Int(keystroke.anchor.y * scale)
        let a = pixel(with, x: x, y: y)
        let b = pixel(without, x: x, y: y)
        XCTAssertLessThan(a.r + a.g + a.b, b.r + b.g + b.b - 10)
        // Far from the label nothing changes.
        XCTAssertEqual(pixel(with, x: 30, y: 30).g, pixel(without, x: 30, y: 30).g)
    }
}
