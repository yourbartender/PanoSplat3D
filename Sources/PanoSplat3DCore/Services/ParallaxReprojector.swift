import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

public enum ParallaxReprojectorError: LocalizedError, Sendable {
    case metalUnavailable
    case shaderSourceNotFound
    case pipelineBuildFailed(String)
    case resourceAllocationFailed(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "Metal GPU device is required for Z-buffer parallax re-projection."
        case .shaderSourceNotFound:
            return "Could not locate ParallaxReprojector.metal shader resource."
        case .pipelineBuildFailed(let msg):
            return "Failed to compile ParallaxReprojector Metal pipeline: \(msg)"
        case .resourceAllocationFailed(let msg):
            return "Failed to allocate Metal buffers/textures: \(msg)"
        case .renderFailed(let msg):
            return "Metal Z-buffer parallax re-projection failed: \(msg)"
        }
    }
}

/// Output of a single re-projected parallax camera view.
public struct ReprojectedViewResult: Sendable {
    public let colorImage: CGImage
    /// 8-bit grayscale mask image where `0` (black) = disoccluded hole ignored by Brush, `255` (white) = valid surface pixel.
    public let maskImage: CGImage
    /// Fraction of pixels in `[0, 1]` that are valid (white).
    public let validPixelFraction: Double
}

private struct MetalDepthMeshVertex {
    var px: Float
    var py: Float
    var pz: Float
    var u: Float
    var v: Float
}

private struct MetalReprojectionUniforms {
    var rRow0: SIMD3<Float>
    var tx: Float
    var rRow1: SIMD3<Float>
    var ty: Float
    var rRow2: SIMD3<Float>
    var tz: Float
    var focalLength: Float
    var cx: Float
    var cy: Float
    var width: Float
    var height: Float
    var zNear: Float
    var zFar: Float
    var _pad0: Float = 0
}

private struct MetalMaskErodeParams {
    var width: UInt32
    var height: UInt32
    var radius: Int32
    var _pad0: UInt32 = 0
}

/// Metal hardware Z-buffer re-projector rendering the depth-displaced 360° surface into offset virtual cameras
/// and generating crisp disocclusion masks (`0` = disoccluded hole, `255` = valid pixels) for true 3D parallax.
public final class ParallaxReprojector: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let renderPipeline: MTLRenderPipelineState
    private let depthStencilState: MTLDepthStencilState
    private let erodePipeline: MTLComputePipelineState

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw ParallaxReprojectorError.metalUnavailable
        }

        let library = try Self.loadLibrary(device: device)

        guard let vertexFn = library.makeFunction(name: "parallaxReprojectVertex"),
              let fragmentFn = library.makeFunction(name: "parallaxReprojectFragment"),
              let erodeFn = library.makeFunction(name: "erodeDisocclusionMask") else {
            throw ParallaxReprojectorError.pipelineBuildFailed("Missing required Metal entry points.")
        }

        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = vertexFn
        rpd.fragmentFunction = fragmentFn
        rpd.colorAttachments[0].pixelFormat = .rgba8Unorm
        rpd.colorAttachments[1].pixelFormat = .r8Unorm
        rpd.depthAttachmentPixelFormat = .depth32Float

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true

        guard let depthState = device.makeDepthStencilState(descriptor: dsd) else {
            throw ParallaxReprojectorError.pipelineBuildFailed("Could not create MTLDepthStencilState.")
        }

        do {
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: rpd)
            self.erodePipeline = try device.makeComputePipelineState(function: erodeFn)
        } catch {
            throw ParallaxReprojectorError.pipelineBuildFailed(error.localizedDescription)
        }

        self.device = device
        self.commandQueue = commandQueue
        self.depthStencilState = depthState
    }

    private static func loadLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let defaultLib = device.makeDefaultLibrary(),
           defaultLib.makeFunction(name: "parallaxReprojectVertex") != nil {
            return defaultLib
        }

        guard let shaderURL = locateShaderSourceURL() else {
            throw ParallaxReprojectorError.shaderSourceNotFound
        }

        let source = try String(contentsOf: shaderURL, encoding: .utf8)
        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            throw ParallaxReprojectorError.pipelineBuildFailed(error.localizedDescription)
        }
    }

    private static func locateShaderSourceURL() -> URL? {
        if let mainURL = Bundle.main.url(forResource: "ParallaxReprojector", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.main.url(forResource: "ParallaxReprojector", withExtension: "metal") {
            return mainURL
        }
        if let resourceBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("PanoSplat3D_PanoSplat3DCore.bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let bundledURL = resourceBundle.url(forResource: "ParallaxReprojector", withExtension: "metal", subdirectory: "Shaders")
            ?? resourceBundle.url(forResource: "ParallaxReprojector", withExtension: "metal") {
            return bundledURL
        }
        return Bundle.module.url(forResource: "ParallaxReprojector", withExtension: "metal", subdirectory: "Shaders")
            ?? Bundle.module.url(forResource: "ParallaxReprojector", withExtension: "metal")
    }

    /// Re-projects the depth-displaced 360° panorama surface into a batch of offset camera poses using a hardware Metal Z-buffer.
    /// - Parameters:
    ///   - panoramaImage: Full-resolution equirectangular RGBA8 sRGB image.
    ///   - depthMap: Seamless 360° metric depth buffer `R(u, v)`.
    ///   - poses: Offset virtual camera poses in +Y Up world space.
    ///   - intrinsics: COLMAP `SIMPLE_PINHOLE` camera intrinsics.
    ///   - meshWidth: Horizontal resolution of the spherical surface mesh (default `512`).
    ///   - meshHeight: Vertical resolution of the spherical surface mesh (default `256`).
    ///   - depthTearRatio: Adjacent triangle max/min radius ratio threshold above which triangles are torn/discarded to expose true disocclusion holes (default `1.12`).
    ///   - maskErosionRadius: Pixel erosion radius applied to disocclusion masks to eliminate boundary fringes (default `2`).
    public func reprojectViews(
        panoramaImage: CGImage,
        depthMap: EquirectangularDepthMap,
        poses: [VirtualCameraPose],
        intrinsics: PinholeCameraIntrinsics,
        meshWidth: Int = 1024,
        meshHeight: Int = 512,
        depthTearRatio: Float = 1.08,
        minGrazingCosine: Float = 0.16,
        maskErosionRadius: Int = 3,
        onViewRendered: (Int, Int, ReprojectedViewResult) throws -> Void
    ) throws {
        guard !poses.isEmpty else { return }

        // 1. Build high-resolution depth-displaced spherical surface mesh, tearing triangles across
        //    depth discontinuities AND grazing ramp slopes so blurred transition walls never pollute Brush training.
        let (vertices, indices) = buildDepthDisplacedMesh(
            depthMap: depthMap,
            gridWidth: meshWidth,
            gridHeight: meshHeight,
            depthTearRatio: depthTearRatio,
            minGrazingCosine: minGrazingCosine
        )

        guard !vertices.isEmpty, !indices.isEmpty else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Generated depth mesh has zero triangles.")
        }

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<MetalDepthMeshVertex>.stride,
            options: .storageModeShared
        ),
              let indexBuffer = device.makeBuffer(
                bytes: indices,
                length: indices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
              ) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to allocate mesh buffers.")
        }

        // 2. Upload full-resolution equirectangular RGB texture once
        let srcWidth = panoramaImage.width
        let srcHeight = panoramaImage.height
        let srcRGBA = PanoramaLoader.extractRGBA8Bytes(from: panoramaImage)

        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: srcWidth,
            height: srcHeight,
            mipmapped: false
        )
        srcDesc.usage = [.shaderRead]
        srcDesc.storageMode = .shared
        guard let equirectTexture = device.makeTexture(descriptor: srcDesc) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create source panorama texture.")
        }
        srcRGBA.withUnsafeBytes { raw in
            if let ptr = raw.baseAddress {
                equirectTexture.replace(
                    region: MTLRegionMake2D(0, 0, srcWidth, srcHeight),
                    mipmapLevel: 0,
                    withBytes: ptr,
                    bytesPerRow: srcWidth * 4
                )
            }
        }

        // 3. Allocate reusable render targets (Color RGBA8, Raw Mask R8, Eroded Mask R8, Depth32Float)
        let outW = intrinsics.width
        let outH = intrinsics.height

        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: outW, height: outH, mipmapped: false)
        colorDesc.usage = [.renderTarget]
        colorDesc.storageMode = .shared

        let rawMaskDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: outW, height: outH, mipmapped: false)
        rawMaskDesc.usage = [.renderTarget, .shaderRead]
        rawMaskDesc.storageMode = .shared

        let erodedMaskDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: outW, height: outH, mipmapped: false)
        erodedMaskDesc.usage = [.shaderWrite]
        erodedMaskDesc.storageMode = .shared

        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: outW, height: outH, mipmapped: false)
        depthDesc.usage = [.renderTarget]
        depthDesc.storageMode = .private

        guard let colorTexture = device.makeTexture(descriptor: colorDesc),
              let rawMaskTexture = device.makeTexture(descriptor: rawMaskDesc),
              let erodedMaskTexture = device.makeTexture(descriptor: erodedMaskDesc),
              let depthTexture = device.makeTexture(descriptor: depthDesc) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create render target textures.")
        }

        var colorBytes = [UInt8](repeating: 0, count: outW * outH * 4)
        var maskBytes = [UInt8](repeating: 0, count: outW * outH)

        let threadW = erodePipeline.threadExecutionWidth
        let threadH = max(1, erodePipeline.maxTotalThreadsPerThreadgroup / threadW)
        let threadsPerGroup = MTLSize(width: threadW, height: threadH, depth: 1)
        let threadsPerGrid = MTLSize(width: outW, height: outH, depth: 1)

        // 4. Render each offset camera view through the Z-buffer
        for (index, pose) in poses.enumerated() {
            try Task.checkCancellation()

            let t = pose.colmapTranslation
            var uniforms = MetalReprojectionUniforms(
                rRow0: SIMD3<Float>(pose.cameraRight),
                tx: Float(t.x),
                rRow1: SIMD3<Float>(pose.cameraDown),
                ty: Float(t.y),
                rRow2: SIMD3<Float>(pose.cameraForward),
                tz: Float(t.z),
                focalLength: Float(intrinsics.focalLength),
                cx: Float(intrinsics.cx),
                cy: Float(intrinsics.cy),
                width: Float(outW),
                height: Float(outH),
                zNear: 0.2,
                zFar: 200.0
            )

            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = colorTexture
            passDesc.colorAttachments[0].loadAction = .clear
            passDesc.colorAttachments[0].storeAction = .store
            passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            passDesc.colorAttachments[1].texture = rawMaskTexture
            passDesc.colorAttachments[1].loadAction = .clear
            passDesc.colorAttachments[1].storeAction = .store
            passDesc.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

            passDesc.depthAttachment.texture = depthTexture
            passDesc.depthAttachment.loadAction = .clear
            passDesc.depthAttachment.storeAction = .dontCare
            passDesc.depthAttachment.clearDepth = 1.0

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
                throw ParallaxReprojectorError.renderFailed("Failed to create Metal render encoder.")
            }

            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setDepthStencilState(depthStencilState)
            renderEncoder.setCullMode(.none)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBytes(&uniforms, length: MemoryLayout<MetalReprojectionUniforms>.stride, index: 1)
            renderEncoder.setFragmentTexture(equirectTexture, index: 0)
            renderEncoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: indices.count,
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
            renderEncoder.endEncoding()

            // Optional mask erosion compute pass to trim silhouette fringes cleanly
            let finalMaskTexture: MTLTexture
            if maskErosionRadius > 0 {
                guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw ParallaxReprojectorError.renderFailed("Failed to create mask erosion compute encoder.")
                }
                var erodeParams = MetalMaskErodeParams(
                    width: UInt32(outW),
                    height: UInt32(outH),
                    radius: Int32(maskErosionRadius)
                )
                computeEncoder.setComputePipelineState(erodePipeline)
                computeEncoder.setTexture(rawMaskTexture, index: 0)
                computeEncoder.setTexture(erodedMaskTexture, index: 1)
                computeEncoder.setBytes(&erodeParams, length: MemoryLayout<MetalMaskErodeParams>.stride, index: 0)
                computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerGroup)
                computeEncoder.endEncoding()
                finalMaskTexture = erodedMaskTexture
            } else {
                finalMaskTexture = rawMaskTexture
            }

            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()

            if let error = commandBuffer.error {
                throw ParallaxReprojectorError.renderFailed(error.localizedDescription)
            }

            colorBytes.withUnsafeMutableBytes { raw in
                if let ptr = raw.baseAddress {
                    colorTexture.getBytes(
                        ptr,
                        bytesPerRow: outW * 4,
                        from: MTLRegionMake2D(0, 0, outW, outH),
                        mipmapLevel: 0
                    )
                }
            }
            maskBytes.withUnsafeMutableBytes { raw in
                if let ptr = raw.baseAddress {
                    finalMaskTexture.getBytes(
                        ptr,
                        bytesPerRow: outW,
                        from: MTLRegionMake2D(0, 0, outW, outH),
                        mipmapLevel: 0
                    )
                }
            }

            var validCount = 0
            for idx in 0..<maskBytes.count {
                if maskBytes[idx] >= 128 {
                    maskBytes[idx] = 255
                    validCount += 1
                } else {
                    maskBytes[idx] = 0
                    // Keep masked-out pixels clean black in RGB too
                    let cOff = idx * 4
                    colorBytes[cOff] = 0
                    colorBytes[cOff + 1] = 0
                    colorBytes[cOff + 2] = 0
                    colorBytes[cOff + 3] = 255
                }
            }

            let colorImage = try makeRGBA8CGImage(bytes: colorBytes, width: outW, height: outH)
            let maskImage = try makeGrayscaleCGImage(bytes: maskBytes, width: outW, height: outH)
            let validFraction = Double(validCount) / Double(max(maskBytes.count, 1))

            try onViewRendered(
                index,
                poses.count,
                ReprojectedViewResult(
                    colorImage: colorImage,
                    maskImage: maskImage,
                    validPixelFraction: validFraction
                )
            )
        }
    }

    /// Generates a solid white (`255`) grayscale mask `CGImage` for center-origin views where every pixel is valid.
    public static func makeSolidWhiteMask(width: Int, height: Int) throws -> CGImage {
        let bytes = [UInt8](repeating: 255, count: width * height)
        return try makeGrayscaleCGImageStatic(bytes: bytes, width: width, height: height)
    }

    private func buildDepthDisplacedMesh(
        depthMap: EquirectangularDepthMap,
        gridWidth: Int,
        gridHeight: Int,
        depthTearRatio: Float,
        minGrazingCosine: Float
    ) -> ([MetalDepthMeshVertex], [UInt32]) {
        // Use (gridWidth + 1) columns so the seam column duplicates u = 0 / u = 1 with continuous UVs
        let cols = gridWidth + 1
        let rows = gridHeight + 1

        var vertices: [MetalDepthMeshVertex] = []
        vertices.reserveCapacity(cols * rows)
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(cols * rows)
        var radii = [Float](repeating: 12.0, count: cols * rows)

        for row in 0..<rows {
            // Clamp polar v slightly inside (0, 1) to avoid degenerate zero-area pole spikes
            let v = min(max(Double(row) / Double(gridHeight), 0.001), 0.999)
            for col in 0..<cols {
                let u = Double(col) / Double(gridWidth)
                let sampleU = (col == gridWidth) ? 0.0 : u
                let radius = Float(depthMap.radius(u: sampleU, v: v))
                let dir = SphericalMath.equirectangularUVToWorldDirection(u: sampleU, v: v)
                let pos = SIMD3<Float>(
                    Float(dir.x) * radius,
                    Float(dir.y) * radius,
                    Float(dir.z) * radius
                )
                radii[row * cols + col] = radius
                positions.append(pos)
                vertices.append(
                    MetalDepthMeshVertex(
                        px: pos.x,
                        py: pos.y,
                        pz: pos.z,
                        u: Float(u),
                        v: Float(v)
                    )
                )
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(gridWidth * gridHeight * 6)

        func isValidContinuousTriangle(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            let ra = radii[a]
            let rb = radii[b]
            let rc = radii[c]
            let minR = min(ra, min(rb, rc))
            let maxR = max(ra, max(rb, rc))
            guard minR > 0.1 else { return false }

            let pa = positions[a]
            let pb = positions[b]
            let pc = positions[c]
            let crossVec = simd_cross(pb - pa, pc - pa)
            let areaLen = simd_length(crossVec)
            guard areaLen > 1e-7 else { return false }
            let normal = crossVec / areaLen

            // Distinguish flat horizontal ground/ceiling surfaces (|normal.y| > 0.65) from vertical depth-cliff walls.
            // A flat ground plane viewed from a 1.7m tripod at 10–25m hits a shallow 4°–10° grazing angle (cos ~0.07–0.17)
            // and radial step ratio ~1.06–1.15; rejecting those tears away the entire midground floor!
            let isFlatGroundOrCeiling = abs(normal.y) > 0.65
            let effectiveTearRatio: Float = isFlatGroundOrCeiling ? max(depthTearRatio, 1.22) : depthTearRatio
            guard (maxR / minR) <= effectiveTearRatio else { return false }

            let centroid = (pa + pb + pc) * (1.0 / 3.0)
            let viewDir = simd_normalize(centroid)
            let effectiveMinCosine: Float = isFlatGroundOrCeiling ? min(minGrazingCosine, 0.03) : minGrazingCosine
            return abs(simd_dot(normal, viewDir)) >= effectiveMinCosine
        }

        for row in 0..<gridHeight {
            for col in 0..<gridWidth {
                let i00 = row * cols + col
                let i10 = row * cols + (col + 1)
                let i01 = (row + 1) * cols + col
                let i11 = (row + 1) * cols + (col + 1)

                if isValidContinuousTriangle(i00, i01, i10) {
                    indices.append(UInt32(i00))
                    indices.append(UInt32(i01))
                    indices.append(UInt32(i10))
                }

                if isValidContinuousTriangle(i10, i01, i11) {
                    indices.append(UInt32(i10))
                    indices.append(UInt32(i01))
                    indices.append(UInt32(i11))
                }
            }
        }

        return (vertices, indices)
    }

    private func makeRGBA8CGImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create RGBA CGDataProvider.")
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
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create RGBA CGImage.")
        }
        return image
    }

    private func makeGrayscaleCGImage(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        try Self.makeGrayscaleCGImageStatic(bytes: bytes, width: width, height: height)
    }

    private static func makeGrayscaleCGImageStatic(bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create Grayscale CGDataProvider.")
        }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ParallaxReprojectorError.resourceAllocationFailed("Failed to create Grayscale CGImage.")
        }
        return image
    }
}
