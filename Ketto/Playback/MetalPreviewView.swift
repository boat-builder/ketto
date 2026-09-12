import SwiftUI
import MetalKit
import QuartzCore

/// Live preview: an `MTKView` on its own display link that renders `composer.state(at:)` for the frame the
/// player is currently showing. Preview and export share `FrameRenderer` and `SourceTextureUploader`,
/// so what this view shows is what the exporter writes.
struct MetalPreviewView: NSViewRepresentable {
    let session: ProjectSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> MTKView {
        let coordinator = context.coordinator
        let view = MTKView(frame: .zero, device: coordinator.renderer?.device ?? MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = FrameRenderer.pixelFormat
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.session = session
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        nsView.isPaused = true
        nsView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency MTKViewDelegate {
        var session: ProjectSession
        let renderer: FrameRenderer?
        let uploader: SourceTextureUploader?
        let cameraUploader: SourceTextureUploader?

        init(session: ProjectSession) {
            self.session = session
            let renderer = try? FrameRenderer()
            self.renderer = renderer
            self.uploader = renderer.map { SourceTextureUploader(device: $0.device) }
            self.cameraUploader = renderer.map { SourceTextureUploader(device: $0.device) }
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let renderer, let uploader, let cameraUploader,
                  view.drawableSize.width >= 1, view.drawableSize.height >= 1,
                  let drawable = view.currentDrawable,
                  let commandBuffer = renderer.commandQueue.makeCommandBuffer() else { return }
            let frame = session.player.pollFrame(hostTime: CACurrentMediaTime())
            if let pixelBuffer = frame.pixelBuffer {
                uploader.upload(pixelBuffer, commandBuffer: commandBuffer)
            }
            if let cameraBuffer = frame.cameraPixelBuffer {
                cameraUploader.upload(cameraBuffer, commandBuffer: commandBuffer)
            }
            let state = session.previewComposer.state(at: frame.time, fps: Double(view.preferredFramesPerSecond))
            let camera = session.player.hasCamera ? cameraUploader.texture : nil
            renderer.encode(state: state, source: uploader.texture, camera: camera, into: drawable.texture, commandBuffer: commandBuffer)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
