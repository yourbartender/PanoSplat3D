import CoreML
import Foundation

/// How a monocular CoreML depth model's raw output values map to distance.
public enum DepthOutputPolarity: Sendable, Equatable {
    /// Higher raw output value = closer to camera (inverse depth / disparity).
    /// Examples: Depth Anything V2 Small, Apple Depth Pro Normalized Inverse Depth.
    case disparity
    /// Higher raw output value = farther from camera (direct depth).
    /// Example: Depth Anything V3 Base (`DA3-BASE`).
    case depth
}

/// Selectable CoreML monocular depth estimation models supported natively on Apple Silicon.
public enum DepthModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case depthAnythingV2Small = "depthAnythingV2Small"
    case depthAnythingV3Base = "depthAnythingV3Base"
    case appleDepthPro = "appleDepthPro"

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
        case .depthAnythingV2Small: return "Depth Anything V2 Small"
        case .depthAnythingV3Base: return "Depth Anything V3 Base"
        case .appleDepthPro: return "Apple Depth Pro (1536px)"
        }
    }

    public var pickerLabel: String {
        switch self {
        case .depthAnythingV2Small: return "Depth Anything V2 Small — Fast (~50 MB)"
        case .depthAnythingV3Base: return "Depth Anything V3 Base — High Detail (~233 MB)"
        case .appleDepthPro: return "Apple Depth Pro 1536px — Ultra-Sharp Foliage (~745 MB)"
        }
    }

    public var shortDescription: String {
        switch self {
        case .depthAnythingV2Small:
            return "Apple CoreML • 518×392 • Fastest (~1s on ANE)"
        case .depthAnythingV3Base:
            return "DA3-Base Apache-2.0 • 504×504 Square • Better 3D geometry (~10–15s on Metal GPU)"
        case .appleDepthPro:
            return "Apple Depth Pro Quantized • 1536×1536 • Ultra-sharp branches/foliage (~2–3 min on Metal GPU)"
        }
    }

    public var packageName: String {
        switch self {
        case .depthAnythingV2Small:
            return "DepthAnythingV2SmallF16.mlpackage"
        case .depthAnythingV3Base:
            return "DepthAnythingV3_base_504.mlpackage"
        case .appleDepthPro:
            return "DepthProNormalizedInverseDepthPruned10QuantizedLinear.mlpackage"
        }
    }

    public var compiledName: String {
        packageName.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc")
    }

    public var baseDownloadURL: String {
        switch self {
        case .depthAnythingV2Small:
            return "https://huggingface.co/apple/coreml-depth-anything-v2-small/resolve/main/"
        case .depthAnythingV3Base:
            return "https://huggingface.co/mlboydaisuke/Depth-Anything-3-Base-CoreML/resolve/main/"
        case .appleDepthPro:
            return "https://huggingface.co/KeighBee/coreml-DepthPro/resolve/main/"
        }
    }

    public var remoteFiles: [RemoteFile] {
        switch self {
        case .depthAnythingV2Small:
            return [
                RemoteFile(relativePath: "DepthAnythingV2SmallF16.mlpackage/Manifest.json", expectedBytes: 617),
                RemoteFile(relativePath: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedBytes: 399_433),
                RemoteFile(relativePath: "DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedBytes: 49_419_072)
            ]
        case .depthAnythingV3Base:
            return [
                RemoteFile(relativePath: "DepthAnythingV3_base_504.mlpackage/Manifest.json", expectedBytes: 617),
                RemoteFile(relativePath: "DepthAnythingV3_base_504.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedBytes: 317_533),
                RemoteFile(relativePath: "DepthAnythingV3_base_504.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedBytes: 233_223_744)
            ]
        case .appleDepthPro:
            return [
                RemoteFile(relativePath: "DepthProNormalizedInverseDepthPruned10QuantizedLinear.mlpackage/Manifest.json", expectedBytes: 617),
                RemoteFile(relativePath: "DepthProNormalizedInverseDepthPruned10QuantizedLinear.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedBytes: 928_152),
                RemoteFile(relativePath: "DepthProNormalizedInverseDepthPruned10QuantizedLinear.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedBytes: 744_074_880)
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

    public var outputPolarity: DepthOutputPolarity {
        switch self {
        case .depthAnythingV2Small: return .disparity
        case .depthAnythingV3Base: return .depth
        case .appleDepthPro: return .disparity
        }
    }

    /// Equirectangular stitched depth buffer dimensions matched to model resolution.
    public var recommendedStitchedSize: (width: Int, height: Int) {
        switch self {
        case .depthAnythingV2Small, .depthAnythingV3Base:
            return (1024, 512)
        case .appleDepthPro:
            return (1536, 768)
        }
    }

    /// Sampling face rig matched to model inference cost (12 faces for fast 504/518px models, 8 wide 115° faces for 1536px Depth Pro).
    public var samplingFaces: [DepthSamplingFace] {
        switch self {
        case .depthAnythingV2Small, .depthAnythingV3Base:
            return DepthSamplingFace.standard12Faces
        case .appleDepthPro:
            return DepthSamplingFace.compact8Faces
        }
    }

    /// Optimal CoreML compute target per architecture.
    /// Large 1536×1536 quantized ViT graphs (`Apple Depth Pro`) trigger an infamous hours-long hang inside
    /// macOS's `ANECompilerService` when loaded with `.all`, whereas `.cpuAndGPU` compiles on Metal MPSGraph
    /// in seconds and runs cleanly on Apple Silicon GPU.
    public var preferredComputeUnits: MLComputeUnits {
        switch self {
        case .depthAnythingV2Small:
            return .all
        case .depthAnythingV3Base:
            return .cpuAndGPU
        case .appleDepthPro:
            return .cpuAndGPU
        }
    }
}
