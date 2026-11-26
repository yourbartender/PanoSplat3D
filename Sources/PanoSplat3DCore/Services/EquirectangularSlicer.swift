import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

public enum EquirectangularSlicerError: LocalizedError, Sendable {
    case shaderSourceNotFound
    case metalLibraryCompilationFailed(String)
    case metalResourceCreationFailed(String)
    case metalExecutionFailed(String)
    case pngWriteFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .shaderSourceNotFound:
            return "Could not locate Equirectangular.metal shader resource."
        case .metalLibraryCompilationFailed(let message):
            return "Failed to compile Metal shader: \(message)"
        case .metalResourceCreationFailed(let message):
            return "Failed to allocate Metal GPU resource: \(message)"
        case .metalExecutionFailed(let message):
            return "Metal equirectangular slicing failed: \(message)"
        case .pngWriteFailed(let url):
            return "Failed to write PNG image to \(url.lastPathComponent)."
        }
    }
}

/// GPU-side uniform struct matching `PerspectiveSliceParams` in `Equirectangular.metal`.
private struct MetalPerspectiveSliceParams {
    var cameraRight: SIMD3<Float>
    var focalLength: Float
    var cameraDown: SIMD3<Float>
    var cx: Float
    var cameraForward: SIMD3<Float>
    var cy: Float
    var outputWidth: UInt32
    var outputHeight: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
}

/// Native Metal (with CPU bilinear fallback) equirectangular-to-perspective camera slicer.
public final class EquirectangularSlicer: @unchecked Sendable {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?

    public var isUsingMetal: Bool {
        pipelineState != nil && device != nil && commandQueue != nil
    }

    public init() {
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue(),
           let pipeline = try? Self.buildPipeline(device: device) {
            self.device = device
            self.commandQueue = queue
            self.pipelineState = pipeline
        } else {
            self.device = nil
            self.commandQueue = nil
            self.pipelineState = nil
        }
    }

    private static func buildPipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library: MTLLibrary
        if let defaultLib = device.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "sliceEquirectangularToPerspective") != nil {
            library = defaultLib
        } else if let shaderURL = locateShaderSourceURL() {
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                throw EquirectangularSlicerError.metalLibraryCompilationFailed(error.localizedDescription)
            }
        } else if let moduleLib = try? device.makeDefaultLibrary(bundle: .module),
                  moduleLib.makeFunction(name: "sliceEquirectangularToPerspective") != nil {
            library = moduleLib
        } else {
            throw EquirectangularSlicerError.shaderSourceNotFound
        }

        guard let kernel = library.makeFunction(name: "sliceEquirectangularToPerspective") else {
            throw EquirectangularSlicerError.metalLibraryCompilationFailed("Kernel function not found")
        }
        return try device.makeComputePipelineState(function: kernel)
    }

    private static func locateShaderSourceURL() -> URL? {
        // 1. Standard macOS .app bundle Contents/Resources/Shaders/Equirectangular.metal
        if let mainURL = Bundle.main.url(forResource: "Equirectangular", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.main.url(forResource: "Equirectangular", withExtension: "metal") {
            return mainURL
        }

        // 2. Resource bundle placed inside Contents/Resources/
        if let resourceBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("PanoSplat3D_PanoSplat3DCore.bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let bundledURL = resourceBundle.url(forResource: "Equirectangular", withExtension: "metal", subdirectory: "Shaders")
            ?? resourceBundle.url(forResource: "Equirectangular", withExtension: "metal") {
            return bundledURL
        }

        // 3. SwiftPM / Xcode test bundle (Bundle.module)
        return Bundle.module.url(forResource: "Equirectangular", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "Equirectangular", withExtension: "metal")
    }

    /// Slices a batch of perspective views from a single equirectangular panorama,
    /// reusing the uploaded GPU source texture across all views for high throughput.
    public func sliceViews(
        from equirectangularImage: CGImage,
        poses: [VirtualCameraPose],
        intrinsics: PinholeCameraIntrinsics,
        onViewRendered: ((Int, Int, CGImage) throws -> Void)
    ) throws {
        let srcWidth = equirectangularImage.width
        let srcHeight = equirectangularImage.height
        let srcRGBA = PanoramaLoader.extractRGBA8Bytes(from: equirectangularImage)

        if let device, let commandQueue, let pipelineState {
            try sliceViewsMetal(
                device: device,
                commandQueue: commandQueue,
                pipelineState: pipelineState,
                srcRGBA: srcRGBA,
                srcWidth: srcWidth,
                srcHeight: srcHeight,
                poses: poses,
                intrinsics: intrinsics,
                onViewRendered: onViewRendered
            )
        } else {
            try sliceViewsCPU(
                srcRGBA: srcRGBA,
                srcWidth: srcWidth,
                srcHeight: srcHeight,
                poses: poses,
                intrinsics: intrinsics,
                onViewRendered: onViewRendered
            )
        }
    }

    /// Convenience helper for slicing a single perspective view.
    public func sliceSingleView(
        from equirectangularImage: CGImage,
        pose: VirtualCameraPose,
        intrinsics: PinholeCameraIntrinsics
    ) throws -> CGImage {
        var result: CGImage?
        try sliceViews(from: equirectangularImage, poses: [pose], intrinsics: intrinsics) { _, _, image in
            result = image
        }
        guard let result else {
            throw EquirectangularSlicerError.metalExecutionFailed("No output image produced.")
        }
        return result
    }

    private func sliceViewsMetal(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipelineState: MTLComputePipelineState,
        srcRGBA: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        poses: [VirtualCameraPose],
        intrinsics: PinholeCameraIntrinsics,
        onViewRendered: ((Int, Int, CGImage) throws -> Void)
    ) throws {
        // Upload equirectangular source once to Metal texture
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: srcWidth,
            height: srcHeight,
            mipmapped: false
        )
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .shared

        guard let srcTexture = device.makeTexture(descriptor: srcDesc) else {
            throw EquirectangularSlicerError.metalResourceCreationFailed("Could not create input texture.")
        }
        srcRGBA.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                srcTexture.replace(
                    region: MTLRegionMake2D(0, 0, srcWidth, srcHeight),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: srcWidth * 4
                )
            }
        }

        // Reusable output texture
        let outWidth = intrinsics.width
        let outHeight = intrinsics.height
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: outWidth,
            height: outHeight,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite]
        outDesc.storageMode = .shared

        guard let outTexture = device.makeTexture(descriptor: outDesc) else {
            throw EquirectangularSlicerError.metalResourceCreationFailed("Could not create output texture.")
        }

        var outBytes = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        let bytesPerRow = outWidth * 4

        let threadWidth = pipelineState.threadExecutionWidth
        let threadHeight = max(1, pipelineState.maxTotalThreadsPerThreadgroup / threadWidth)
        let threadsPerGroup = MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        let threadsPerGrid = MTLSize(width: outWidth, height: outHeight, depth: 1)

        for (index, pose) in poses.enumerated() {
            var params = MetalPerspectiveSliceParams(
                cameraRight: SIMD3<Float>(pose.cameraRight),
                focalLength: Float(intrinsics.focalLength),
                cameraDown: SIMD3<Float>(pose.cameraDown),
                cx: Float(intrinsics.cx),
                cameraForward: SIMD3<Float>(pose.cameraForward),
                cy: Float(intrinsics.cy),
                outputWidth: UInt32(outWidth),
                outputHeight: UInt32(outHeight)
            )

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                throw EquirectangularSlicerError.metalExecutionFailed("Could not create Metal command encoder.")
            }

            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(srcTexture, index: 0)
            encoder.setTexture(outTexture, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<MetalPerspectiveSliceParams>.stride, index: 0)
            encoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                throw EquirectangularSlicerError.metalExecutionFailed(error.localizedDescription)
            }

            outBytes.withUnsafeMutableBytes { raw in
                if let ptr = raw.baseAddress {
                    outTexture.getBytes(
                        ptr,
                        bytesPerRow: bytesPerRow,
                        from: MTLRegionMake2D(0, 0, outWidth, outHeight),
                        mipmapLevel: 0
                    )
                }
            }

            let cgImage = try makeCGImage(rgbaBytes: outBytes, width: outWidth, height: outHeight)
            try onViewRendered(index, poses.count, cgImage)
        }
    }

    /// Mathematically equivalent CPU bilinear fallback (runs if Metal device is unavailable).
    private func sliceViewsCPU(
        srcRGBA: [UInt8],
        srcWidth: Int,
        srcHeight: Int,
        poses: [VirtualCameraPose],
        intrinsics: PinholeCameraIntrinsics,
        onViewRendered: ((Int, Int, CGImage) throws -> Void)
    ) throws {
        let outWidth = intrinsics.width
        let outHeight = intrinsics.height
        var outBytes = [UInt8](repeating: 0, count: outWidth * outHeight * 4)

        for (index, pose) in poses.enumerated() {
            let right = pose.cameraRight
            let down = pose.cameraDown
            let forward = pose.cameraForward

            for y in 0..<outHeight {
                let ry = ((Double(y) + 0.5) - intrinsics.cy) / intrinsics.focalLength
                for x in 0..<outWidth {
                    let rx = ((Double(x) + 0.5) - intrinsics.cx) / intrinsics.focalLength
                    let dir = simd_normalize(rx * right + ry * down + forward)
                    let uv = SphericalMath.worldDirectionToEquirectangularUV(dir)

                    let sample = sampleBilinear(
                        rgba: srcRGBA,
                        width: srcWidth,
                        height: srcHeight,
                        u: uv.x,
                        v: uv.y
                    )

                    let dstOffset = (y * outWidth + x) * 4
                    outBytes[dstOffset] = sample.0
                    outBytes[dstOffset + 1] = sample.1
                    outBytes[dstOffset + 2] = sample.2
                    outBytes[dstOffset + 3] = 255
                }
            }

            let cgImage = try makeCGImage(rgbaBytes: outBytes, width: outWidth, height: outHeight)
            try onViewRendered(index, poses.count, cgImage)
        }
    }

    private func sampleBilinear(
        rgba: [UInt8],
        width: Int,
        height: Int,
        u: Double,
        v: Double
    ) -> (UInt8, UInt8, UInt8) {
        let fx = u * Double(width) - 0.5
        let fy = v * Double(height) - 0.5

        let x0 = Int(floor(fx))
        let y0 = Int(floor(fy))
        let tx = fx - Double(x0)
        let ty = fy - Double(y0)

        let wx0 = ((x0 % width) + width) % width
        let wx1 = (wx0 + 1) % width
        let cy0 = min(max(y0, 0), height - 1)
        let cy1 = min(max(y0 + 1, 0), height - 1)

        let i00 = (cy0 * width + wx0) * 4
        let i10 = (cy0 * width + wx1) * 4
        let i01 = (cy1 * width + wx0) * 4
        let i11 = (cy1 * width + wx1) * 4

        let w00 = (1.0 - tx) * (1.0 - ty)
        let w10 = tx * (1.0 - ty)
        let w01 = (1.0 - tx) * ty
        let w11 = tx * ty

        let r = Double(rgba[i00]) * w00 + Double(rgba[i10]) * w10 + Double(rgba[i01]) * w01 + Double(rgba[i11]) * w11
        let g = Double(rgba[i00 + 1]) * w00 + Double(rgba[i10 + 1]) * w10 + Double(rgba[i01 + 1]) * w01 + Double(rgba[i11 + 1]) * w11
        let b = Double(rgba[i00 + 2]) * w00 + Double(rgba[i10 + 2]) * w10 + Double(rgba[i01 + 2]) * w01 + Double(rgba[i11 + 2]) * w11

        return (
            UInt8(min(max(r.rounded(), 0), 255)),
            UInt8(min(max(g.rounded(), 0), 255)),
            UInt8(min(max(b.rounded(), 0), 255))
        )
    }

    private func makeCGImage(rgbaBytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(rgbaBytes)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw EquirectangularSlicerError.metalResourceCreationFailed("Failed to create CGDataProvider.")
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw EquirectangularSlicerError.metalResourceCreationFailed("Failed to construct output CGImage.")
        }
        return image
    }

    /// Saves a `CGImage` to disk as lossless PNG.
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw EquirectangularSlicerError.pngWriteFailed(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw EquirectangularSlicerError.pngWriteFailed(url)
        }
    }
}
