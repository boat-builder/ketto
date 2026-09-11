import XCTest
import Metal
@testable import Recordito

/// Golden-frame tests: fixed events + edit document → rendered frame compared with a committed reference.
/// Run with `TEST_RUNNER_RECORDITO_UPDATE_GOLDEN=1 xcodebuild test …` to (re)record the references.
final class GoldenFrameTests: XCTestCase {
    private static let updateGolden = ProcessInfo.processInfo.environment["RECORDITO_UPDATE_GOLDEN"] == "1"

    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private func makeComposer() -> FrameComposer {
        let events = SyntheticSource.events()
        var edit = EditDocument.default
        edit.zooms = AutoZoomGenerator().generate(events: events)
        return FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
    }

    private func render(state: FrameState, width: Int, height: Int) throws -> BGRAImage {
        let renderer = try FrameRenderer()
        let source = SyntheticSource.texture(device: renderer.device, image: SyntheticSource.patternImage(width: 640, height: 400))
        let target = try renderer.makeReadableTarget(width: width, height: height)
        try renderer.render(state: state, source: source, into: target)
        return BGRAImage(texture: target)
    }

    private func compareWithGolden(_ image: BGRAImage, name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = fixturesDirectory.appendingPathComponent("\(name).png")
        if Self.updateGolden {
            try image.pngData()!.write(to: url)
        }
        guard let data = try? Data(contentsOf: url), let reference = BGRAImage(pngData: data) else {
            XCTFail("Missing golden image \(url.lastPathComponent); record it with RECORDITO_UPDATE_GOLDEN=1", file: file, line: line)
            return
        }
        guard let diff = image.difference(to: reference) else {
            XCTFail("Golden image size mismatch", file: file, line: line)
            return
        }
        if diff.meanAbsolute > 1.0 || diff.fractionOverThreshold > 0.005 {
            let failedURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-failed.png")
            try? image.pngData()?.write(to: failedURL)
            XCTFail("Rendered frame differs from golden \(name): mean \(diff.meanAbsolute), max \(diff.maxAbsolute), over-threshold \(diff.fractionOverThreshold). Actual written to \(failedURL.path)", file: file, line: line)
        }
    }

    func testZoomedFrameMatchesGolden() throws {
        let composer = makeComposer()
        let state = composer.state(at: 1.72) // mid-zoom, cursor at click, ripple active
        XCTAssertGreaterThan(state.viewport.scale, 1.5)
        let image = try render(state: state, width: 960, height: 540)
        try compareWithGolden(image, name: "golden_zoomed_frame")
    }

    func testFullViewFrameMatchesGolden() throws {
        let composer = makeComposer()
        let state = composer.state(at: 0.5)
        XCTAssertEqual(state.viewport, .full)
        let image = try render(state: state, width: 960, height: 540)
        try compareWithGolden(image, name: "golden_full_frame")
    }

    func testSolidBackgroundWithoutShadowMatchesGolden() throws {
        let events = SyntheticSource.events()
        var edit = EditDocument.default
        edit.style.background = BackgroundSpec(type: .solid, colors: [RGBAColor(hex: "#202124")!])
        edit.style.shadow.opacity = 0
        edit.style.cornerRadius = 0
        edit.style.padding = 24
        edit.cursor.scale = 2.5
        let composer = FrameComposer(edit: edit, events: events, source: SourceInfo(display: events.display))
        let image = try render(state: composer.state(at: 6.0), width: 640, height: 360)
        try compareWithGolden(image, name: "golden_solid_frame")
    }

    /// Preview and export use the same renderer; rendering into a drawable-like texture and into a
    /// pixel-buffer backed texture (the export path) must be identical.
    func testPixelBufferTargetMatchesTextureTarget() throws {
        let renderer = try FrameRenderer()
        let composer = makeComposer()
        let state = composer.state(at: 1.72)
        let source = SyntheticSource.texture(device: renderer.device, image: SyntheticSource.patternImage(width: 640, height: 400))
        let target = try renderer.makeReadableTarget(width: 960, height: 540)
        try renderer.render(state: state, source: source, into: target)
        let direct = BGRAImage(texture: target)

        let pixelBuffer = SyntheticSource.pixelBuffer(image: BGRAImage(width: 960, height: 540, bytes: [UInt8](repeating: 0, count: 960 * 540 * 4)))
        let uploader = SourceTextureUploader(device: renderer.device)
        let (wrapped, cvTexture) = try XCTUnwrap(uploader.wrap(pixelBuffer))
        try renderer.render(state: state, source: source, into: wrapped)
        withExtendedLifetime(cvTexture) {}
        let viaPixelBuffer = try XCTUnwrap(BGRAImage(pixelBuffer: pixelBuffer))
        XCTAssertEqual(direct.bytes, viaPixelBuffer.bytes)
    }

    func testRenderIsDeterministic() throws {
        let composer = makeComposer()
        let state = composer.state(at: 3.0)
        let a = try render(state: state, width: 480, height: 270)
        let b = try render(state: state, width: 480, height: 270)
        XCTAssertEqual(a.bytes, b.bytes)
    }

    func testMipmappedUploadPathRenders() throws {
        let renderer = try FrameRenderer()
        let uploader = SourceTextureUploader(device: renderer.device)
        let pixelBuffer = SyntheticSource.pixelBuffer(image: SyntheticSource.patternImage(width: 640, height: 400))
        let commandBuffer = try XCTUnwrap(renderer.commandQueue.makeCommandBuffer())
        let texture = try XCTUnwrap(uploader.upload(pixelBuffer, commandBuffer: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertGreaterThan(texture.mipmapLevelCount, 1)
        let composer = makeComposer()
        let target = try renderer.makeReadableTarget(width: 320, height: 180)
        try renderer.render(state: composer.state(at: 0.5), source: texture, into: target)
        let image = BGRAImage(texture: target)
        // A point inside the synthetic window's white interior (between two text bars) must render white.
        let canvasPoint = composer.canvasPoint(fromSource: SIMD2(320, 206), viewport: .full) * (320.0 / 1920.0)
        let index = (Int(canvasPoint.y) * 320 + Int(canvasPoint.x)) * 4
        XCTAssertGreaterThan(Int(image.bytes[index + 1]), 200)
        XCTAssertGreaterThan(Int(image.bytes[index + 2]), 200)
    }
}
