import AppKit
import CoreGraphics
import Metal
import QuartzCore
import SwiftUI

private struct MetalViewer360Uniforms {
    var yawRadians: Float
    var pitchRadians: Float
    var tanHalfFovY: Float
    var aspectRatio: Float
    var showSeamGuide: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
}

/// Interactive Metal-backed 360° equirectangular sphere viewer with click-drag pan,
/// scroll-wheel FOV zoom, and an optional 0°/360° back-seam inspection guide.
///
/// Backed directly by `CAMetalLayer` (rather than `MTKView`) so closing and reopening macOS
/// SwiftUI `Window` scenes or swapping images never freezes drawables or displays stale frames.
public struct Panorama360View: NSViewRepresentable {
    public let image: CGImage
    public let imageKey: String
    public let targetYawDegrees: Double
    public let targetPitchDegrees: Double
    public let cameraPresetToken: Int
    public let showSeamGuide: Bool
    public let onOrientationChange: ((Double, Double, Double) -> Void)?

    public init(
        image: CGImage,
        imageKey: String = "",
        targetYawDegrees: Double = 0,
        targetPitchDegrees: Double = 0,
        cameraPresetToken: Int = 0,
        showSeamGuide: Bool = false,
        onOrientationChange: ((Double, Double, Double) -> Void)? = nil
    ) {
        self.image = image
        self.imageKey = imageKey
        self.targetYawDegrees = targetYawDegrees
        self.targetPitchDegrees = targetPitchDegrees
        self.cameraPresetToken = cameraPresetToken
        self.showSeamGuide = showSeamGuide
        self.onOrientationChange = onOrientationChange
    }

    public func makeNSView(context: Context) -> Interactive360MetalView {
        let view = Interactive360MetalView(frame: .zero)
        view.configurePipeline()
        view.onOrientationChange = onOrientationChange
        view.showSeamGuide = showSeamGuide
        view.updateTexture(from: image)
        view.setOrientation(yawDegrees: targetYawDegrees, pitchDegrees: targetPitchDegrees, fovDegrees: 75.0)
        context.coordinator.lastPresetToken = cameraPresetToken
        context.coordinator.lastImage = image
        context.coordinator.lastImageKey = imageKey
        return view
    }

    public func updateNSView(_ nsView: Interactive360MetalView, context: Context) {
        nsView.onOrientationChange = onOrientationChange

        let keyChanged = !imageKey.isEmpty && context.coordinator.lastImageKey != imageKey
        let imageChanged = context.coordinator.lastImage !== image
        if keyChanged || imageChanged {
            nsView.updateTexture(from: image)
            context.coordinator.lastImage = image
            context.coordinator.lastImageKey = imageKey
        }

        if nsView.showSeamGuide != showSeamGuide {
            nsView.showSeamGuide = showSeamGuide
            nsView.renderFrame()
        }

        if context.coordinator.lastPresetToken != cameraPresetToken {
            context.coordinator.lastPresetToken = cameraPresetToken
            nsView.setOrientation(yawDegrees: targetYawDegrees, pitchDegrees: targetPitchDegrees, fovDegrees: 75.0)
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public final class Coordinator {
        var lastPresetToken: Int = -1
        var lastImage: CGImage?
        var lastImageKey: String = ""
    }
}

/// Direct `CAMetalLayer`-backed `NSView` handling mouse drag (look around) and scroll wheel (FOV zoom)
/// with 0% idle GPU usage and 100% deterministic redraws across window close/reopen cycles.
@MainActor
public final class Interactive360MetalView: NSView {
    private let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var metalLayer: CAMetalLayer?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var equirectTexture: MTLTexture?

    private var yawDegrees: Double = 0.0
    private var pitchDegrees: Double = 0.0
    private var fovDegrees: Double = 75.0
    public var showSeamGuide: Bool = false
    public var onOrientationChange: ((Double, Double, Double) -> Void)?

    private var lastDragPoint: NSPoint?
    private var isDragging: Bool = false
    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.wantsLayer = true
    }

    deinit {
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.presentsWithTransaction = false
        layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        self.metalLayer = layer
        return layer
    }

    public func configurePipeline() {
        self.wantsLayer = true
        if self.metalLayer == nil {
            self.metalLayer = self.layer as? CAMetalLayer
        }
        self.metalLayer?.device = device
        self.metalLayer?.pixelFormat = .bgra8Unorm
        self.metalLayer?.framebufferOnly = true

        guard let device,
              let queue = device.makeCommandQueue() else {
            return
        }
        self.commandQueue = queue

        guard let library = Self.loadLibrary(device: device),
              let vertexFn = library.makeFunction(name: "panoramaViewer360Vertex"),
              let fragmentFn = library.makeFunction(name: "panoramaViewer360Fragment") else {
            return
        }

        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = vertexFn
        rpd.fragmentFunction = fragmentFn
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm

        self.pipelineState = try? device.makeRenderPipelineState(descriptor: rpd)
    }

    public func setOrientation(yawDegrees: Double, pitchDegrees: Double, fovDegrees: Double) {
        self.yawDegrees = Self.wrapYaw(yawDegrees)
        self.pitchDegrees = min(max(pitchDegrees, -88.0), 88.0)
        self.fovDegrees = min(max(fovDegrees, 35.0), 110.0)
        onOrientationChange?(self.yawDegrees, self.pitchDegrees, self.fovDegrees)
        renderFrame()
    }

    public func updateTexture(from cgImage: CGImage) {
        guard let device else { return }

        // Cap interactive preview texture at 4096px wide for instant uploads and low VRAM usage
        let maxWidth = 4096
        let targetWidth = min(cgImage.width, maxWidth)
        let targetHeight = max(1, Int((Double(cgImage.height) * (Double(targetWidth) / Double(max(cgImage.width, 1)))).rounded()))

        let rgbaBytes: [UInt8]
        if targetWidth == cgImage.width && targetHeight == cgImage.height {
            rgbaBytes = PanoramaLoader.extractRGBA8Bytes(from: cgImage)
        } else {
            rgbaBytes = Self.resizedRGBA8Bytes(from: cgImage, width: targetWidth, height: targetHeight)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else { return }
        rgbaBytes.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, targetWidth, targetHeight),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: targetWidth * 4
                )
            }
        }
        self.equirectTexture = texture
        renderFrame()
    }

    // MARK: - Window & Layout Lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installWindowObservers(for: window)
        if let scale = window?.backingScaleFactor {
            metalLayer?.contentsScale = scale
        }
        scheduleRender()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            metalLayer?.contentsScale = scale
        }
        renderFrame()
    }

    public override func layout() {
        super.layout()
        renderFrame()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderFrame()
    }

    private func installWindowObservers(for targetWindow: NSWindow?) {
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()

        guard let targetWindow else { return }
        let names: [NSNotification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification
        ]
        for name in names {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: targetWindow,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.renderFrame()
                }
            }
            windowObservers.append(token)
        }
    }

    private func scheduleRender() {
        renderFrame()
        DispatchQueue.main.async { [weak self] in
            self?.renderFrame()
        }
    }

    // MARK: - Mouse & Scroll Controls

    public override var acceptsFirstResponder: Bool { true }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Esc (keyCode 53) exits true fullscreen on the 360° viewer window immediately
        if event.keyCode == 53, let window, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            return
        }
        super.keyDown(with: event)
    }

    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    public override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        if !isDragging {
            isDragging = true
            NSCursor.closedHand.push()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        lastDragPoint = nil
        if isDragging {
            isDragging = false
            NSCursor.pop()
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        defer { lastDragPoint = pt }
        guard let prev = lastDragPoint else { return }

        let dx = pt.x - prev.x
        let dy = pt.y - prev.y

        // Natural grab-and-drag sensitivity scaled by current FOV
        let sensitivity = (fovDegrees / max(Double(bounds.height), 200.0)) * 0.9
        yawDegrees = Self.wrapYaw(yawDegrees - Double(dx) * sensitivity)
        // AppKit view coordinates have +Y upward: dragging upward pulls view down -> decreases pitch
        pitchDegrees = min(max(pitchDegrees - Double(dy) * sensitivity, -88.0), 88.0)

        onOrientationChange?(yawDegrees, pitchDegrees, fovDegrees)
        renderFrame()
    }

    public override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? Double(delta) * 0.12 : Double(delta) * 2.5
        fovDegrees = min(max(fovDegrees - step, 35.0), 110.0)
        onOrientationChange?(yawDegrees, pitchDegrees, fovDegrees)
        renderFrame()
    }

    // MARK: - Direct Metal Rendering

    public func renderFrame() {
        guard let window,
              window.isVisible,
              !isHiddenOrHasHiddenAncestor,
              bounds.width > 1,
              bounds.height > 1,
              let metalLayer = self.metalLayer ?? (self.layer as? CAMetalLayer),
              let pipelineState,
              let commandQueue,
              let equirectTexture else {
            return
        }

        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let drawableW = max(1, Int((bounds.width * scale).rounded()))
        let drawableH = max(1, Int((bounds.height * scale).rounded()))
        if Int(metalLayer.drawableSize.width) != drawableW || Int(metalLayer.drawableSize.height) != drawableH {
            metalLayer.drawableSize = CGSize(width: drawableW, height: drawableH)
        }

        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        renderPassDesc.colorAttachments[0].storeAction = .store
        renderPassDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc) else {
            return
        }

        var uniforms = MetalViewer360Uniforms(
            yawRadians: Float(yawDegrees * (.pi / 180.0)),
            pitchRadians: Float(pitchDegrees * (.pi / 180.0)),
            tanHalfFovY: Float(tan((fovDegrees * 0.5) * (.pi / 180.0))),
            aspectRatio: Float(Double(drawableW) / Double(drawableH)),
            showSeamGuide: showSeamGuide ? 1 : 0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(equirectTexture, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MetalViewer360Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Helpers

    private static func wrapYaw(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 }
        if d <= -180.0 { d += 360.0 }
        return d
    }

    private static func loadLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLib = device.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "panoramaViewer360Vertex") != nil {
            return defaultLib
        }

        let shaderURL =
            Bundle.main.url(forResource: "PanoramaViewer360", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.main.url(forResource: "PanoramaViewer360", withExtension: "metal")
            ?? Bundle.module.url(forResource: "PanoramaViewer360", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "PanoramaViewer360", withExtension: "metal")

        guard let shaderURL,
              let source = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            return nil
        }
        return try? device.makeLibrary(source: source, options: nil)
    }

    private static func resizedRGBA8Bytes(from image: CGImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        bytes.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress,
               let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
               ) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return bytes
    }
}
