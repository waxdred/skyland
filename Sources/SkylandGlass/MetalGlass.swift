import AppKit
import CoreMedia
import CoreVideo
import Metal
import QuartzCore
import ScreenCaptureKit

/// Liquid Glass drawn by skyland, on any macOS: ScreenCaptureKit shows what is behind
/// the window (skyland's own windows left out), and a shader looks at it through each
/// glass shape, as a lens would: the edges bend it inwards, split its colors a little, a
/// light blur and saturation, the glass's own light, a rim lit from the top left, a sheen
/// over the top, a faint inner shadow below. Shapes closer than glass_spacing melt together.
final class MetalGlass: GlassRenderer {
    static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device else { return nil }
        do {
            let library = try device.makeLibrary(source: glassShader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "glass_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "glass_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            FileHandle.standardError.write(Data("skyland: glass shader: \(error)\n".utf8))
            return nil
        }
    }()

    /// A GPU, the shader, and Screen Recording allowed.
    static var isAvailable: Bool { pipeline != nil && CGPreflightScreenCaptureAccess() }

    let view: NSView
    private let metalLayer: CAMetalLayer
    private let capture = BackdropCapture()
    private var textureCache: CVMetalTextureCache?
    /// the last picture of what is behind, kept alive while the GPU reads it
    private var backdrop: CVMetalTexture?
    private var shapes: [GlassShape] = []
    private var settings = GlassSettings()
    private weak var window: NSWindow?
    private(set) var failed = false

    init?() {
        guard let device = Self.device, Self.pipeline != nil else { return nil }
        let layer = CAMetalLayer()
        metalLayer = layer
        view = MetalHost(layer: layer)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        capture.onFrame = { [weak self] buffer in self?.received(buffer) }
        capture.onFailure = { [weak self] in self?.failed = true }
    }

    deinit { capture.stop() }

    func update(_ shapes: [GlassShape], settings: GlassSettings, window: NSWindow) {
        self.shapes = shapes
        self.settings = settings
        self.window = window
        if shapes.isEmpty {
            capture.stop()
        } else if let screen = window.screen ?? NSScreen.main,
                  let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        {
            // the view (skyland: anywhere in the window) in the display's points, top-left
            // origin, as ScreenCaptureKit counts
            let frame = window.convertToScreen(view.convert(view.bounds, to: nil)), screenFrame = screen.frame
            let local = CGRect(x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY, width: frame.width, height: frame.height)
            capture.windowNumber = CGWindowID(max(0, window.windowNumber))
            capture.follow(display: display, window: local, screen: CGSize(width: screenFrame.width, height: screenFrame.height),
                           scale: screen.backingScaleFactor)
        }
        render()
    }

    private func received(_ buffer: CVPixelBuffer) {
        guard let textureCache else { return }
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture)
        guard let texture else { return }
        backdrop = texture
        render()
    }

    private func render() {
        guard let window, let pipeline = Self.pipeline, let queue = Self.queue else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard size.width >= 1, size.height >= 1 else { return }
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        guard let drawable = metalLayer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let backdrop, let texture = CVMetalTextureGetTexture(backdrop), !shapes.isEmpty {
            let s = Float(scale)
            var gpuShapes = shapes.prefix(32).map { shape in
                GPUShape(rect: SIMD4(Float(shape.rect.minX) * s, Float(shape.rect.minY) * s, Float(shape.rect.width) * s, Float(shape.rect.height) * s),
                         tint: SIMD4(Float(shape.tint.red), Float(shape.tint.green), Float(shape.tint.blue), Float(shape.tint.alpha)),
                         radius: Float(shape.radius) * s, clear: shape.style == "clear" ? 1 : shape.style == "lens" ? 2 : shape.style == "hover" ? 3 : 0,
                         pad: SIMD2(Float(shape.lift), 0),
                         tail: shape.tail.map { SIMD4(Float($0.minX) * s, Float($0.minY) * s, Float($0.width) * s, Float($0.height) * s) } ?? .zero)
            }
            let origin = capture.origin(of: window, scale: scale)
            var uniforms = GPUUniforms(size: SIMD2(Float(size.width), Float(size.height)), origin: SIMD2(Float(origin.x), Float(origin.y)),
                                       textureSize: SIMD2(Float(texture.width), Float(texture.height)), scale: s,
                                       count: Int32(gpuShapes.count), refraction: Float(settings.refraction), blur: Float(settings.blur),
                                       saturation: Float(settings.saturation),
                                       dark: view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0,
                                       spacing: Float(settings.spacing) * s)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GPUUniforms>.stride, index: 0)
            gpuShapes.withUnsafeMutableBytes { bytes in
                if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: 1) }
            }
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// The shader's inputs; the same layout as `Uniforms` and `Shape` in the shader.
private struct GPUUniforms {
    var size: SIMD2<Float>
    var origin: SIMD2<Float>
    var textureSize: SIMD2<Float>
    var scale: Float
    var count: Int32
    var refraction: Float
    var blur: Float
    var saturation: Float
    var dark: Float
    var spacing: Float
}

private struct GPUShape {
    var rect: SIMD4<Float>
    var tint: SIMD4<Float>
    var radius: Float
    var clear: Float
    var pad = SIMD2<Float>(0, 0)
    var tail: SIMD4<Float> // a lens's drop left behind (0: none)
}

/// A view whose layer is the Metal layer, letting the mouse through to the items' view.
private final class MetalHost: NSView {
    private let metal: CAMetalLayer

    init(layer: CAMetalLayer) {
        metal = layer
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { metal }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What is behind a window: a ScreenCaptureKit stream of a part of its display a little
/// larger than the window (so a window moving a few points needs no new stream), without
/// skyland's own windows. Frames come only when what is there changes.
final class BackdropCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onFailure: (() -> Void)?
    /// the part of the display captured, in its points, top-left origin
    private(set) var region = CGRect.zero
    private var scale: CGFloat = 2
    private var display: CGDirectDisplayID = 0
    private var stream: SCStream?
    /// skyland's windows are left out by app; until it has one on screen, by none
    private var excludesSelf = false
    private var asking = false
    private var selfRetries = 0
    /// the glass's window, which the stream must leave out
    var windowNumber: CGWindowID = 0
    private var pending: (display: CGDirectDisplayID, window: CGRect, screen: CGSize, scale: CGFloat)?
    private var lastAsk = 0.0
    private var window = CGRect.zero
    private let queue = DispatchQueue(label: "skyland.glass.capture", qos: .userInteractive)

    /// Captures around `window` (display points, top-left origin) on `display`.
    func follow(display: CGDirectDisplayID, window: CGRect, screen: CGSize, scale: CGFloat) {
        self.window = window
        let moved = display != self.display || scale != self.scale || !region.contains(window)
        let now = ProcessInfo.processInfo.systemUptime
        if asking { // skyland: a window moved while the stream starts (made, then placed) is followed after
            pending = moved ? (display, window, screen, scale) : pending
            return
        }
        guard moved || (!excludesSelf && now - lastAsk > 1) else { return }
        self.display = display
        self.scale = scale
        let margin: CGFloat = 48
        region = window.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: screen)).integral
        start()
    }

    /// Where the window's top-left is in the captured picture, in its pixels.
    func origin(of window: NSWindow, scale: CGFloat) -> CGPoint {
        CGPoint(x: (self.window.minX - region.minX) * scale, y: (self.window.minY - region.minY) * scale)
    }

    private func start() {
        asking = true
        lastAsk = ProcessInfo.processInfo.systemUptime
        let display = self.display, region = self.region, scale = self.scale
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                if let next = self.pending {
                    self.pending = nil
                    self.follow(display: next.display, window: next.window, screen: next.screen, scale: next.scale)
                    if self.asking { return } // started again for the new place
                }
                guard let content, let screen = content.displays.first(where: { $0.displayID == display }) else {
                    self.onFailure?()
                    return
                }
                // skyland: left out by app when it has a bundle (an app without one, the wallpaper
                // picker, matches nothing: its own text showed blurred through its glass), else by
                // window. Until the glass's own window is on screen, asked again soon.
                let me = content.applications.first { $0.processID == getpid() && !$0.bundleIdentifier.isEmpty }
                let mine = content.windows.filter { $0.owningApplication?.processID == getpid() }
                self.excludesSelf = mine.contains { $0.windowID == self.windowNumber }
                if !self.excludesSelf, self.selfRetries < 10 {
                    self.selfRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
                }
                let filter = me.map { SCContentFilter(display: screen, excludingApplications: [$0], exceptingWindows: []) }
                    ?? SCContentFilter(display: screen, excludingWindows: mine)
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = region
                configuration.width = max(1, Int(region.width * scale))
                configuration.height = max(1, Int(region.height * scale))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = false
                configuration.queueDepth = 3
                if let stream = self.stream {
                    stream.updateContentFilter(filter, completionHandler: nil)
                    stream.updateConfiguration(configuration, completionHandler: nil)
                    return
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                do {
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.onFailure?()
                    return
                }
                self.stream = stream
                stream.startCapture { [weak self] error in
                    guard error != nil else { return }
                    DispatchQueue.main.async {
                        self?.stream = nil
                        self?.onFailure?()
                    }
                }
            }
        }
    }

    func stop() {
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return } // idle frames carry none
        DispatchQueue.main.async { [weak self] in self?.onFrame?(buffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.stream = nil
            self?.onFailure?()
        }
    }
}
