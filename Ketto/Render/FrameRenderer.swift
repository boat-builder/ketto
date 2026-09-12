import Foundation
import Metal
import simd

enum RenderError: Error, LocalizedError {
    case noMetalDevice
    case libraryNotFound
    case functionNotFound(String)
    case contextCreationFailed
    case textureCreationFailed
    case commandBufferFailed

    var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "No Metal device is available."
        case .libraryNotFound: return "The Metal shader library could not be loaded."
        case .functionNotFound(let name): return "Shader function \(name) was not found."
        case .contextCreationFailed: return "A drawing context could not be created."
        case .textureCreationFailed: return "A texture could not be created."
        case .commandBufferFailed: return "A Metal command buffer could not be created."
        }
    }
}

/// The render pipeline: `(source texture, camera texture, FrameState) -> target texture`. One code path
/// serves the preview (`MTKView` drawable) and the export encoder (pixel-buffer backed texture). Thread-safe
/// for use from a single thread at a time.
final class FrameRenderer: @unchecked Sendable {
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let cursorAtlas: CursorAtlas
    let labels: KeystrokeLabelRenderer
    private let pipeline: MTLRenderPipelineState
    private let sourceSampler: MTLSamplerState
    private let atlasSampler: MTLSamplerState

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.commandBufferFailed }
        self.commandQueue = queue
        guard let library = try? device.makeDefaultLibrary(bundle: Bundle(for: FrameRenderer.self)) else {
            throw RenderError.libraryNotFound
        }
        guard let vertex = library.makeFunction(name: "compositeVertex") else { throw RenderError.functionNotFound("compositeVertex") }
        guard let fragment = library.makeFunction(name: "compositeFragment") else { throw RenderError.functionNotFound("compositeFragment") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Ketto composite"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let sourceDescriptor = MTLSamplerDescriptor()
        sourceDescriptor.minFilter = .linear
        sourceDescriptor.magFilter = .linear
        sourceDescriptor.mipFilter = .linear
        sourceDescriptor.sAddressMode = .clampToEdge
        sourceDescriptor.tAddressMode = .clampToEdge
        guard let sourceSampler = device.makeSamplerState(descriptor: sourceDescriptor) else { throw RenderError.textureCreationFailed }
        self.sourceSampler = sourceSampler

        let atlasDescriptor = MTLSamplerDescriptor()
        atlasDescriptor.minFilter = .linear
        atlasDescriptor.magFilter = .linear
        atlasDescriptor.mipFilter = .notMipmapped
        atlasDescriptor.sAddressMode = .clampToEdge
        atlasDescriptor.tAddressMode = .clampToEdge
        guard let atlasSampler = device.makeSamplerState(descriptor: atlasDescriptor) else { throw RenderError.textureCreationFailed }
        self.atlasSampler = atlasSampler

        self.cursorAtlas = try CursorAtlas(device: device)
        self.labels = KeystrokeLabelRenderer(device: device)
    }

    convenience init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        try self.init(device: device)
    }

    /// Builds the shader uniforms for a frame. Everything is expressed in canvas pixels and scaled by
    /// `canvasScale`, so any target size renders the same picture. `cameraSize` is the pixel size of the
    /// bound camera texture (nil when there is none); `labelSize` the pixel size of the keystroke label.
    func makeUniforms(state: FrameState, hasSource: Bool, targetWidth: Int, targetHeight: Int, cameraSize: CGSize? = nil, labelSize: CGSize? = nil) -> FrameUniforms {
        var u = FrameUniforms()
        let layout = state.layout
        let canvasScale = Float(targetWidth) / Float(layout.canvasSize.x)
        u.targetSize = SIMD2(Float(targetWidth), Float(targetHeight))
        u.canvasScale = canvasScale
        u.aaWidth = 0.75 / max(canvasScale, 1e-4)
        u.canvasSize = SIMD2(Float(layout.canvasSize.x), Float(layout.canvasSize.y))
        u.contentRect = SIMD4(Float(layout.contentRect.minX), Float(layout.contentRect.minY), Float(layout.contentRect.width), Float(layout.contentRect.height))
        u.viewport = SIMD4(Float(state.viewport.origin.x), Float(state.viewport.origin.y), Float(state.viewport.size.x), Float(state.viewport.size.y))
        u.prevViewport = SIMD4(Float(state.previousViewport.origin.x), Float(state.previousViewport.origin.y), Float(state.previousViewport.size.x), Float(state.previousViewport.size.y))

        let style = layout.style
        let background = style.background
        let stops = Array(background.colors.prefix(Int(kMaxGradientStops)))
        withUnsafeMutablePointer(to: &u.gradientColors) { pointer in
            pointer.withMemoryRebound(to: SIMD4<Float>.self, capacity: Int(kMaxGradientStops)) { colors in
                for i in 0..<Int(kMaxGradientStops) {
                    colors[i] = i < stops.count ? stops[i].simd : (stops.last?.simd ?? SIMD4(0, 0, 0, 1))
                }
            }
        }
        u.gradientStopCount = Int32(max(stops.count, 1))
        u.backgroundType = background.type == .gradient ? 1 : 0
        let angle = background.angle * Double.pi / 180
        u.gradientDirection = SIMD2(Float(sin(angle)), Float(-cos(angle)))

        u.cornerRadius = Float(max(style.cornerRadius, 0))
        u.shadowSigma = Float(max(style.shadow.radius, 0) / 2)
        u.shadowOpacity = Float(min(max(style.shadow.opacity, 0), 1))
        u.shadowOffsetY = Float(style.shadow.y)

        if let cursor = state.cursor, cursor.opacity > 0.001 {
            let hotspot = CursorGlyphs.hotspot(for: cursor.type)
            let origin = cursor.position - hotspot * cursor.size
            u.cursorRect = SIMD4(Float(origin.x), Float(origin.y), Float(cursor.size.x), Float(cursor.size.y))
            u.cursorUV = cursorAtlas.uvRect(for: cursor.type)
            u.cursorOpacity = Float(min(cursor.opacity, 1))
        } else {
            u.cursorOpacity = 0
        }

        let ripples = Array(state.ripples.prefix(Int(kMaxRipples)))
        withUnsafeMutablePointer(to: &u.ripples) { pointer in
            pointer.withMemoryRebound(to: SIMD4<Float>.self, capacity: Int(kMaxRipples)) { slots in
                for (i, ripple) in ripples.enumerated() {
                    slots[i] = SIMD4(Float(ripple.center.x), Float(ripple.center.y), Float(ripple.radius), Float(ripple.alpha))
                }
            }
        }
        u.rippleCount = Int32(ripples.count)
        u.rippleThickness = Float(ripples.first?.thickness ?? 2)
        u.rippleColor = SIMD4(1, 1, 1, 1)

        // Masks: rects in canvas pixels; the highlight dimming is the strongest active highlight's.
        let masks = Array(state.masks.prefix(Int(kMaxMasks)))
        withUnsafeMutablePointer(to: &u.maskRects) { pointer in
            pointer.withMemoryRebound(to: SIMD4<Float>.self, capacity: Int(kMaxMasks)) { slots in
                for (i, mask) in masks.enumerated() {
                    slots[i] = SIMD4(Float(mask.rect.minX), Float(mask.rect.minY), Float(mask.rect.width), Float(mask.rect.height))
                }
            }
        }
        withUnsafeMutablePointer(to: &u.maskParams) { pointer in
            pointer.withMemoryRebound(to: SIMD4<Float>.self, capacity: Int(kMaxMasks)) { slots in
                for (i, mask) in masks.enumerated() {
                    slots[i] = SIMD4(mask.kind == .blur ? 0 : 1, Float(mask.strength), Float(mask.cornerRadius), 0)
                }
            }
        }
        u.maskCount = Int32(masks.count)
        var highlightDim: Float = 0
        for mask in masks where mask.kind == .highlight {
            highlightDim = max(highlightDim, Float(0.25 + 0.5 * min(max(mask.strength, 0), 1)))
        }
        u.highlightDim = highlightDim

        // Webcam overlay: aspect-fill the camera frame into the overlay box.
        if let camera = state.camera, let cameraSize, cameraSize.width > 0, cameraSize.height > 0, camera.opacity > 0.001, camera.rect.width > 0 {
            u.cameraRect = SIMD4(Float(camera.rect.minX), Float(camera.rect.minY), Float(camera.rect.width), Float(camera.rect.height))
            let boxWidth = camera.shape == .circle ? min(camera.rect.width, camera.rect.height) : camera.rect.width
            let boxHeight = camera.shape == .circle ? min(camera.rect.width, camera.rect.height) : camera.rect.height
            let boxAspect = boxWidth / max(boxHeight, 1e-6)
            let textureAspect = cameraSize.width / cameraSize.height
            if textureAspect > boxAspect {
                let w = Float(boxAspect / textureAspect)
                u.cameraUV = SIMD4((1 - w) / 2, 0, w, 1)
            } else {
                let h = Float(textureAspect / boxAspect)
                u.cameraUV = SIMD4(0, (1 - h) / 2, 1, h)
            }
            u.cameraShape = camera.shape == .circle ? 0 : 1
            u.cameraCornerRadius = Float(max(camera.cornerRadius, 0))
            u.cameraBorderWidth = Float(max(camera.borderWidth, 0))
            u.cameraBorderColor = camera.borderColor.simd
            u.cameraMirrored = camera.mirrored ? 1 : 0
            u.cameraShadow = camera.shadow ? 1 : 0
            u.cameraOpacity = Float(min(camera.opacity, 1))
        } else {
            u.cameraOpacity = 0
        }

        // Keystroke label: the texture is rasterised at target resolution; place it in canvas pixels.
        if let label = state.keystroke, let labelSize, labelSize.width > 0, label.opacity > 0.001 {
            let width = labelSize.width / Double(canvasScale)
            let height = labelSize.height / Double(canvasScale)
            u.labelRect = SIMD4(Float(label.anchor.x - width / 2), Float(label.anchor.y - height / 2), Float(width), Float(height))
            u.labelOpacity = Float(min(label.opacity, 1))
        } else {
            u.labelOpacity = 0
        }

        // Motion blur: the number of taps grows with how far the viewport moved since the previous frame.
        var samples = 1
        if state.motionBlur {
            let pixelsPerUnit = layout.contentRect.width / max(state.viewport.size.x, 1e-6)
            let originDelta = simd_length(state.viewport.origin - state.previousViewport.origin)
            let sizeDelta = abs(state.viewport.size.x - state.previousViewport.size.x)
            let movementPixels = (originDelta + sizeDelta) * pixelsPerUnit * Double(canvasScale)
            samples = min(max(Int(movementPixels / 1.5), 1), 12)
        }
        u.motionBlurSamples = Int32(samples)
        u.hasSource = hasSource ? 1 : 0
        return u
    }

    /// Encodes one frame into `target` on `commandBuffer`. `camera` is the current webcam frame, if any.
    func encode(state: FrameState, source: MTLTexture?, camera: MTLTexture? = nil, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Ketto composite"
        encoder.setRenderPipelineState(pipeline)
        let canvasScale = Double(target.width) / max(state.layout.canvasSize.x, 1)
        var labelTexture: MTLTexture?
        var labelSize: CGSize?
        if let keystroke = state.keystroke, keystroke.opacity > 0.001,
           let label = labels.label(text: keystroke.text, fontPixelSize: keystroke.fontSize * canvasScale) {
            labelTexture = label.texture
            labelSize = label.size
        }
        let cameraSize = camera.map { CGSize(width: $0.width, height: $0.height) }
        var uniforms = makeUniforms(state: state, hasSource: source != nil, targetWidth: target.width, targetHeight: target.height, cameraSize: cameraSize, labelSize: labelSize)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setFragmentTexture(source ?? cursorAtlas.texture, index: 0)
        encoder.setFragmentTexture(cursorAtlas.texture, index: 1)
        encoder.setFragmentTexture(camera ?? cursorAtlas.texture, index: 2)
        encoder.setFragmentTexture(labelTexture ?? cursorAtlas.texture, index: 3)
        encoder.setFragmentSamplerState(sourceSampler, index: 0)
        encoder.setFragmentSamplerState(atlasSampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Renders one frame synchronously.
    func render(state: FrameState, source: MTLTexture?, camera: MTLTexture? = nil, into target: MTLTexture) throws {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        encode(state: state, source: source, camera: camera, into: target, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// A CPU-readable render target.
    func makeReadableTarget(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.textureCreationFailed }
        return texture
    }
}
