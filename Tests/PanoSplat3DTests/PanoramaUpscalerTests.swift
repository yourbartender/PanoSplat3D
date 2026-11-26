import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import PanoSplat3DCore

@Suite("360°-Wrap-Safe AI Upscaler, Multi-Model Variants & Overnight Batch Queue")
struct PanoramaUpscalerTests {
    @Test("All 3 UpscalerModelVariant manifests have valid HTTPS URLs, scales, and compute unit assignments")
    func upscalerVariantMetadata() {
        #expect(UpscalerModelVariant.allCases.count == 3)

        for variant in UpscalerModelVariant.allCases {
            #expect(variant.remoteFiles.count == 3)
            #expect(variant.totalExpectedBytes > 10_000_000)
            #expect(variant.minimumValidWeightBytes > 10_000_000)
            #expect(variant.packageName.hasSuffix(".mlpackage"))
            #expect(variant.compiledName.hasSuffix(".mlmodelc"))
            for file in variant.remoteFiles {
                let url = URL(string: variant.baseDownloadURL + file.relativePath)
                #expect(url != nil, "Invalid remote URL for \(variant.rawValue): \(file.relativePath)")
                #expect(url?.scheme == "https")
            }
        }

        // Both RealPLKSR models MUST use .cpuAndGPU (Metal GPU) on macOS Apple Silicon
        #expect(UpscalerModelVariant.realPLKSR2xNatural.nativeScale == 2)
        #expect(UpscalerModelVariant.realPLKSR2xNatural.preferredComputeUnits == .cpuAndGPU)
        #expect(UpscalerModelVariant.nomosWebPhoto4x.nativeScale == 4)
        #expect(UpscalerModelVariant.nomosWebPhoto4x.preferredComputeUnits == .cpuAndGPU)
        #expect(UpscalerModelVariant.realESRGAN4x.nativeScale == 4)
        #expect(UpscalerModelVariant.realESRGAN4x.preferredComputeUnits == .all)
    }

    @Test("Circular 360° horizontal tile extraction and raised-cosine blending preserve exact seam continuity")
    func wrapSafeTileRoundTrip() {
        let srcW = 320
        let srcH = 160
        let tileSize = 128
        let overlap = 24
        let scale = 2
        let outW = srcW * scale
        let outH = srcH * scale
        let outTileSize = tileSize * scale

        var srcRGBA = [UInt8](repeating: 255, count: srcW * srcH * 4)
        for y in 0..<srcH {
            for x in 0..<srcW {
                let phase = (Double(x) / Double(srcW)) * 2.0 * .pi
                let r = UInt8(127.5 + 100.0 * cos(phase))
                let g = UInt8(127.5 + 100.0 * sin(phase))
                let b = UInt8((Double(y) / Double(srcH)) * 220.0)
                let off = (y * srcW + x) * 4
                srcRGBA[off] = r; srcRGBA[off + 1] = g; srcRGBA[off + 2] = b; srcRGBA[off + 3] = 255
            }
        }

        let (xOrigins, yOrigins) = PanoramaUpscaler.computeTileOrigins(
            width: srcW,
            height: srcH,
            tileSize: tileSize,
            overlap: overlap
        )
        #expect(xOrigins.count >= 3)
        #expect(yOrigins.count >= 2)

        var accumRGB = [Float](repeating: 0, count: outW * outH * 3)
        var accumWeight = [Float](repeating: 0, count: outW * outH)

        for oy in yOrigins {
            let isTop = (oy == 0)
            let isBottom = (oy + tileSize >= srcH)
            for ox in xOrigins {
                let tile = PanoramaUpscaler.extractWrappedTile(
                    from: srcRGBA,
                    srcWidth: srcW,
                    srcHeight: srcH,
                    originX: ox,
                    originY: oy,
                    tileSize: tileSize
                )

                var upTile = [UInt8](repeating: 255, count: outTileSize * outTileSize * 4)
                for ty in 0..<outTileSize {
                    let sy = ty / scale
                    for tx in 0..<outTileSize {
                        let sx = tx / scale
                        let sOff = (sy * tileSize + sx) * 4
                        let dOff = (ty * outTileSize + tx) * 4
                        upTile[dOff] = tile[sOff]
                        upTile[dOff + 1] = tile[sOff + 1]
                        upTile[dOff + 2] = tile[sOff + 2]
                        upTile[dOff + 3] = 255
                    }
                }

                PanoramaUpscaler.blendWrappedTile(
                    tileRGBA: upTile,
                    outTileSize: outTileSize,
                    originOutX: ox * scale,
                    originOutY: oy * scale,
                    outWidth: outW,
                    outHeight: outH,
                    featherPixels: overlap * scale,
                    isTopBoundary: isTop,
                    isBottomBoundary: isBottom,
                    accumRGB: &accumRGB,
                    accumWeight: &accumWeight
                )
            }
        }

        for i in 0..<(outW * outH) {
            #expect(accumWeight[i] > 0.01)
        }

        var maxSeamDiff: Float = 0
        for y in 0..<outH {
            let leftIdx = y * outW
            let rightIdx = y * outW + (outW - 1)
            for c in 0..<3 {
                let lVal = accumRGB[leftIdx * 3 + c] / accumWeight[leftIdx]
                let rVal = accumRGB[rightIdx * 3 + c] / accumWeight[rightIdx]
                maxSeamDiff = max(maxSeamDiff, abs(lVal - rVal))
            }
        }
        #expect(maxSeamDiff < 4.0, "Expected seamless 360° wrap across x=0 / x=outW-1, got diff \(maxSeamDiff)")
    }

    @Test("360°-wrap-safe blendWithOriginal honors 0%, 50%, and 100% strength without seam artifacts")
    func strengthBlendWrapSafe() throws {
        let srcW = 64
        let srcH = 32
        let dstW = 128
        let dstH = 64

        // Constant color original (40, 80, 120) vs constant AI output (200, 160, 240)
        var origRGBA = [UInt8](repeating: 255, count: srcW * srcH * 4)
        for i in 0..<(srcW * srcH) {
            origRGBA[i * 4] = 40
            origRGBA[i * 4 + 1] = 80
            origRGBA[i * 4 + 2] = 120
        }
        var aiRGBA = [UInt8](repeating: 255, count: dstW * dstH * 4)
        for i in 0..<(dstW * dstH) {
            aiRGBA[i * 4] = 200
            aiRGBA[i * 4 + 1] = 160
            aiRGBA[i * 4 + 2] = 240
        }

        let fullAI = try PanoramaUpscaler.blendWithOriginal(
            aiRGBA: aiRGBA, originalRGBA: origRGBA,
            srcWidth: srcW, srcHeight: srcH, dstWidth: dstW, dstHeight: dstH,
            strength: 1.0
        )
        #expect(fullAI[0] == 200 && fullAI[1] == 160 && fullAI[2] == 240)

        let halfBlend = try PanoramaUpscaler.blendWithOriginal(
            aiRGBA: aiRGBA, originalRGBA: origRGBA,
            srcWidth: srcW, srcHeight: srcH, dstWidth: dstW, dstHeight: dstH,
            strength: 0.5
        )
        // Midpoint: (200+40)/2 = 120, (160+80)/2 = 120, (240+120)/2 = 180
        #expect(abs(Int(halfBlend[0]) - 120) <= 2)
        #expect(abs(Int(halfBlend[1]) - 120) <= 2)
        #expect(abs(Int(halfBlend[2]) - 180) <= 2)

        // Wrap continuity test on a smooth horizontal sine wave resized via blendWithOriginal
        var waveOrig = [UInt8](repeating: 255, count: srcW * srcH * 4)
        for y in 0..<srcH {
            for x in 0..<srcW {
                let phase = (Double(x) / Double(srcW)) * 2.0 * .pi
                let off = (y * srcW + x) * 4
                waveOrig[off] = UInt8(127.5 + 100.0 * cos(phase))
                waveOrig[off + 1] = UInt8(127.5 + 100.0 * sin(phase))
                waveOrig[off + 2] = 128
            }
        }
        let bicubicOnly = try PanoramaUpscaler.blendWithOriginal(
            aiRGBA: aiRGBA, originalRGBA: waveOrig,
            srcWidth: srcW, srcHeight: srcH, dstWidth: dstW, dstHeight: dstH,
            strength: 0.0
        )
        let midY = dstH / 2
        let leftOff = (midY * dstW) * 4
        let rightOff = (midY * dstW + (dstW - 1)) * 4
        let seamDiff = max(
            abs(Int(bicubicOnly[leftOff]) - Int(bicubicOnly[rightOff])),
            abs(Int(bicubicOnly[leftOff + 1]) - Int(bicubicOnly[rightOff + 1]))
        )
        #expect(seamDiff <= 8, "Expected smooth circular wrap at seam, got diff \(seamDiff)")
    }

    @Test("GenerationSettings decodes legacy JSON cleanly with RealPLKSR 2x Natural and 80% strength defaults")
    func legacySettingsDecoding() throws {
        let legacyJSON = """
        {
          "depthScaleMeters": 14.0,
          "parallaxBaselineMeters": 0.45,
          "trainingSteps": 8000,
          "shDegree": 3,
          "exportMode": "plySplat",
          "perspectiveResolution": 1280,
          "fieldOfViewDegrees": 82.0,
          "initialPointCount": 220000,
          "autoUpscaleLowRes": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GenerationSettings.self, from: legacyJSON)
        #expect(decoded.upscalerModel == .realPLKSR2xNatural)
        #expect(abs(decoded.upscalerBlendStrength - 0.80) < 1e-6)
        #expect(decoded.depthScaleMeters == 14.0)
        #expect(decoded.shDegree == .three)
    }

    @Test("BatchQueueItem.deduplicatedOutputURL avoids collisions for both .ply and COLMAP folders")
    func batchOutputDeduplication() {
        let dir = URL(fileURLWithPath: "/tmp/PanoSplat3D-DedupTest", isDirectory: true)
        var reserved: Set<URL> = []

        let first = BatchQueueItem.deduplicatedOutputURL(
            in: dir, baseName: "lapland_river", mode: .plySplat, reservedURLs: reserved, checkFileSystem: false
        )
        reserved.insert(first)
        let second = BatchQueueItem.deduplicatedOutputURL(
            in: dir, baseName: "lapland_river", mode: .plySplat, reservedURLs: reserved, checkFileSystem: false
        )
        reserved.insert(second)
        let third = BatchQueueItem.deduplicatedOutputURL(
            in: dir, baseName: "lapland_river", mode: .plySplat, reservedURLs: reserved, checkFileSystem: false
        )

        #expect(first.lastPathComponent == "lapland_river.ply")
        #expect(second.lastPathComponent == "lapland_river_2.ply")
        #expect(third.lastPathComponent == "lapland_river_3.ply")

        var colmapReserved: Set<URL> = []
        let c1 = BatchQueueItem.deduplicatedOutputURL(
            in: dir, baseName: "tundra", mode: .colmapDataset, reservedURLs: colmapReserved, checkFileSystem: false
        )
        colmapReserved.insert(c1)
        let c2 = BatchQueueItem.deduplicatedOutputURL(
            in: dir, baseName: "tundra", mode: .colmapDataset, reservedURLs: colmapReserved, checkFileSystem: false
        )
        #expect(c1.lastPathComponent == "tundra_colmap")
        #expect(c2.lastPathComponent == "tundra_2_colmap")
    }

    @Test("Live CoreML RealPLKSR 2x Natural & 4xNomosWebPhoto download, compile, and 360° 2x upscale (opt-in via PANOSPLAT_LIVE_UPSCALER=1)")
    func liveCoreMLMultiModelUpscale() async throws {
        guard ProcessInfo.processInfo.environment["PANOSPLAT_LIVE_UPSCALER"] == "1" else {
            return
        }

        let w = 256
        let h = 128
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let phase = (Double(x) / Double(w)) * 2.0 * .pi
                let checker: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 190 : 70
                let off = (y * w + x) * 4
                rgba[off] = checker
                rgba[off + 1] = UInt8(127.5 + 80.0 * cos(phase))
                rgba[off + 2] = UInt8((Double(y) / Double(h)) * 200.0)
                rgba[off + 3] = 255
            }
        }

        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        let img = try #require(CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: w * 4, space: cs, bitmapInfo: info,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ))

        let asset = PanoramaAsset(
            sourceURL: URL(fileURLWithPath: "/tmp/upscale_test.png"),
            width: w, height: h, isHDR: false, fileSizeBytes: Int64(rgba.count),
            cgImage: img, thumbnail: img
        )

        let upscaler = PanoramaUpscaler()
        for variant in [UpscalerModelVariant.realPLKSR2xNatural, UpscalerModelVariant.nomosWebPhoto4x] {
            let upscaled = try await upscaler.upscale(
                panorama: asset,
                variant: variant,
                factor: .x2,
                blendStrength: 0.80
            )
            #expect(upscaled.width == 512)
            #expect(upscaled.height == 256)

            // Verify non-black, high-contrast RGB output (guards against wrong [0,1] scaling or stride mismatch)
            let bytes = PanoramaLoader.extractRGBA8Bytes(from: upscaled.cgImage)
            var minR: UInt8 = 255
            var maxR: UInt8 = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                minR = min(minR, bytes[i])
                maxR = max(maxR, bytes[i])
            }
            #expect(maxR > 160 && minR < 110, "\(variant.displayName) output range unexpectedly flat: \(minR)...\(maxR)")
        }
    }
}
