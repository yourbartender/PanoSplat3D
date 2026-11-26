import CoreML
import Foundation

/// Selectable 360°-wrap-safe CoreML super-resolution models supported natively on Apple Silicon.
public enum UpscalerModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Non-GAN RealPLKSR 2× model trained with MSSIM loss (gumka/realplksr-coreml, MIT).
    /// Preserves organic micro-texture (moss, rocks, foliage, water) without waxy/plastic GAN hallucinations.
    case realPLKSR2xNatural = "realPLKSR2xNatural"

    /// RealPLKSR 4× model trained on Nomos-v2 real photography (333i/4xNomosWebPhoto_RealPLKSR-coreml-ios, CC-BY-4.0).
    /// Downsampled to 2× for crisp photographic detail with minimal synthetic gloss.
    case nomosWebPhoto4x = "nomosWebPhoto4x"

    /// Classic Real-ESRGAN x4+ (arraypress/upscale-realesrgan, BSD-3-Clause).
    /// Strongest edge sharpening; pair with 70–85% blend strength to reduce glossy surfaces.
    case realESRGAN4x = "realESRGAN4x"

    public var id: String { rawValue }

    public struct RemoteFile: Sendable, Equatable {
        public let relativePath: String
        public let expectedBytes: Int64

        public init(relativePath: String, expectedBytes: Int64) {
            self.relativePath = relativePath
            self.expectedBytes = expectedBytes
        }
    }

    public var displayName: String {
        switch self {
        case .realPLKSR2xNatural:
            return "RealPLKSR 2× Natural"
        case .nomosWebPhoto4x:
            return "4xNomosWebPhoto"
        case .realESRGAN4x:
            return "Real-ESRGAN x4+"
        }
    }

    public var shortBadgeName: String {
        switch self {
        case .realPLKSR2xNatural:
            return "RealPLKSR 2×"
        case .nomosWebPhoto4x:
            return "NomosPhoto"
        case .realESRGAN4x:
            return "Real-ESRGAN"
        }
    }

    public var pickerLabel: String {
        switch self {
        case .realPLKSR2xNatural:
            return "RealPLKSR 2× Natural — Organic, No Plasticity (~15 MB)"
        case .nomosWebPhoto4x:
            return "4xNomosWebPhoto — Real Photography Detail (~15 MB)"
        case .realESRGAN4x:
            return "Real-ESRGAN x4+ — Strongest Sharpening (~34 MB)"
        }
    }

    public var shortDescription: String {
        switch self {
        case .realPLKSR2xNatural:
            return "MIT • Native 2× non-GAN MSSIM (~15 MB, Metal GPU). Sharpens moss, bark, rocks & water without waxy GAN blobs."
        case .nomosWebPhoto4x:
            return "CC-BY-4.0 (Philip Hofmann) • 4×→2× (~15 MB, Metal GPU). Trained on Nomos-v2 real photography for crisp natural detail."
        case .realESRGAN4x:
            return "BSD-3-Clause • 4×→2× (~34 MB, ANE+GPU). Strongest edge sharpening; best at 70–80% strength to keep organic grain."
        }
    }

    public var packageName: String {
        switch self {
        case .realPLKSR2xNatural:
            return "RealPLKSR-2x.mlpackage"
        case .nomosWebPhoto4x:
            return "4xNomosWebPhoto_RealPLKSR_512.mlpackage"
        case .realESRGAN4x:
            return "RealESRGAN-x4plus.mlpackage"
        }
    }

    public var compiledName: String {
        packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc")
    }

    public var baseDownloadURL: String {
        switch self {
        case .realPLKSR2xNatural:
            return "https://huggingface.co/gumka/realplksr-coreml/resolve/main/"
        case .nomosWebPhoto4x:
            return "https://huggingface.co/333i/4xNomosWebPhoto_RealPLKSR-coreml-ios/resolve/main/"
        case .realESRGAN4x:
            return "https://huggingface.co/arraypress/upscale-realesrgan/resolve/main/"
        }
    }

    public var remoteFiles: [RemoteFile] {
        switch self {
        case .realPLKSR2xNatural:
            return [
                RemoteFile(
                    relativePath: "RealPLKSR-2x.mlpackage/Manifest.json",
                    expectedBytes: 617
                ),
                RemoteFile(
                    relativePath: "RealPLKSR-2x.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    expectedBytes: 344_036
                ),
                RemoteFile(
                    relativePath: "RealPLKSR-2x.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    expectedBytes: 14_771_288
                )
            ]
        case .nomosWebPhoto4x:
            return [
                RemoteFile(
                    relativePath: "4xNomosWebPhoto_RealPLKSR_512.mlpackage/Manifest.json",
                    expectedBytes: 617
                ),
                RemoteFile(
                    relativePath: "4xNomosWebPhoto_RealPLKSR_512.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    expectedBytes: 439_672
                ),
                RemoteFile(
                    relativePath: "4xNomosWebPhoto_RealPLKSR_512.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    expectedBytes: 14_812_832
                )
            ]
        case .realESRGAN4x:
            return [
                RemoteFile(
                    relativePath: "RealESRGAN-x4plus.mlpackage/Manifest.json",
                    expectedBytes: 617
                ),
                RemoteFile(
                    relativePath: "RealESRGAN-x4plus.mlpackage/Data/com.apple.CoreML/model.mlmodel",
                    expectedBytes: 645_662
                ),
                RemoteFile(
                    relativePath: "RealESRGAN-x4plus.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
                    expectedBytes: 33_440_896
                )
            ]
        }
    }

    public var totalExpectedBytes: Int64 {
        remoteFiles.reduce(0) { $0 + $1.expectedBytes }
    }

    public var approximateSizeMB: Int {
        Int((Double(totalExpectedBytes) / 1_048_576.0).rounded())
    }

    public var minimumValidWeightBytes: Int64 {
        Int64(Double(remoteFiles.last?.expectedBytes ?? 0) * 0.85)
    }

    /// Native spatial scale factor produced by a single CoreML tile pass.
    public var nativeScale: Int {
        switch self {
        case .realPLKSR2xNatural:
            return 2
        case .nomosWebPhoto4x, .realESRGAN4x:
            return 4
        }
    }

    /// Optimal CoreML compute units per model architecture.
    /// Both RealPLKSR architectures (`RealPLKSR-2x` and `4xNomosWebPhoto_RealPLKSR`) require `.cpuAndGPU`
    /// on macOS Apple Silicon (Metal GPU) because ANE either produces fp16 inaccuracy or E5RT status 0x16.
    public var preferredComputeUnits: MLComputeUnits {
        switch self {
        case .realPLKSR2xNatural, .nomosWebPhoto4x:
            return .cpuAndGPU
        case .realESRGAN4x:
            return .all
        }
    }
}
