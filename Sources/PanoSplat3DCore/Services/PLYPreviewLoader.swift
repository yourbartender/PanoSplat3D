import Foundation
import simd

/// Decoded point/splat preview cloud ready for interactive SceneKit 3D inspection.
public struct PLYPreviewCloud: Sendable {
    public let positions: [SIMD3<Float>]
    public let colors: [SIMD4<Float>]
    public let totalVertexCount: Int
    public let isGaussianSplat: Bool
    public let boundingCenter: SIMD3<Float>
    public let boundingRadius: Float

    public init(
        positions: [SIMD3<Float>],
        colors: [SIMD4<Float>],
        totalVertexCount: Int,
        isGaussianSplat: Bool,
        boundingCenter: SIMD3<Float>,
        boundingRadius: Float
    ) {
        self.positions = positions
        self.colors = colors
        self.totalVertexCount = totalVertexCount
        self.isGaussianSplat = isGaussianSplat
        self.boundingCenter = boundingCenter
        self.boundingRadius = boundingRadius
    }
}

public enum PLYPreviewError: LocalizedError, Sendable {
    case unreadableHeader
    case unsupportedFormat(String)
    case missingXYZProperties

    public var errorDescription: String? {
        switch self {
        case .unreadableHeader:
            return "Could not parse PLY header."
        case .unsupportedFormat(let fmt):
            return "Unsupported PLY format '\(fmt)' for 3D preview."
        case .missingXYZProperties:
            return "PLY file does not contain x, y, z vertex coordinates."
        }
    }
}

/// Fast binary little-endian `.ply` parser supporting both trained 3D Gaussian Splat `.ply` files
/// (`x, y, z, f_dc_0..2, opacity, ...`) and raw point clouds (`x, y, z, red, green, blue`).
public enum PLYPreviewLoader {
    private static let shC0: Float = 0.28209479177387814

    private enum PropType {
        case float32, float64, uint8, int8, uint16, int16, uint32, int32

        var byteSize: Int {
            switch self {
            case .uint8, .int8: return 1
            case .uint16, .int16: return 2
            case .float32, .uint32, .int32: return 4
            case .float64: return 8
            }
        }

        init?(plyType: String) {
            switch plyType {
            case "float", "float32": self = .float32
            case "double", "float64": self = .float64
            case "uchar", "uint8": self = .uint8
            case "char", "int8": self = .int8
            case "ushort", "uint16": self = .uint16
            case "short", "int16": self = .int16
            case "uint", "uint32": self = .uint32
            case "int", "int32": self = .int32
            default: return nil
            }
        }
    }

    private struct PropertyOffset {
        let name: String
        let type: PropType
        let offset: Int
    }

    public static func load(from url: URL, maxPreviewPoints: Int = 120_000) throws -> PLYPreviewCloud {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let endMarker = Data("end_header\n".utf8)
        let endMarkerCRLF = Data("end_header\r\n".utf8)

        let headerEnd: Int
        let headerString: String
        if let range = data.range(of: endMarker) {
            headerEnd = range.upperBound
            headerString = String(decoding: data[..<range.upperBound], as: UTF8.self)
        } else if let range = data.range(of: endMarkerCRLF) {
            headerEnd = range.upperBound
            headerString = String(decoding: data[..<range.upperBound], as: UTF8.self)
        } else {
            throw PLYPreviewError.unreadableHeader
        }

        var isBinaryLE = false
        var vertexCount = 0
        var inVertexElement = false
        var properties: [PropertyOffset] = []
        var stride = 0

        for rawLine in headerString.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("format ") {
                if line.contains("binary_little_endian") {
                    isBinaryLE = true
                } else {
                    throw PLYPreviewError.unsupportedFormat(line)
                }
            } else if line.hasPrefix("element ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, parts[1] == "vertex", let count = Int(parts[2]) {
                    vertexCount = count
                    inVertexElement = true
                } else {
                    inVertexElement = false
                }
            } else if inVertexElement && line.hasPrefix("property ") {
                let parts = line.split(separator: " ")
                if parts.count >= 3, let propType = PropType(plyType: String(parts[1])) {
                    let name = String(parts[2])
                    properties.append(PropertyOffset(name: name, type: propType, offset: stride))
                    stride += propType.byteSize
                }
            }
        }

        guard isBinaryLE, stride > 0 else {
            throw PLYPreviewError.unreadableHeader
        }

        let propByName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0) })
        guard let px = propByName["x"], let py = propByName["y"], let pz = propByName["z"] else {
            throw PLYPreviewError.missingXYZProperties
        }

        let pDC0 = propByName["f_dc_0"]
        let pDC1 = propByName["f_dc_1"]
        let pDC2 = propByName["f_dc_2"]
        let pOpacity = propByName["opacity"]
        let pRed = propByName["red"]
        let pGreen = propByName["green"]
        let pBlue = propByName["blue"]

        let isGaussianSplat = (pDC0 != nil && pDC1 != nil && pDC2 != nil)

        let availableVertices = min(vertexCount, (data.count - headerEnd) / stride)
        let step = max(1, availableVertices / max(maxPreviewPoints, 1))
        let estimatedCount = (availableVertices + step - 1) / step

        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        positions.reserveCapacity(estimatedCount)
        colors.reserveCapacity(estimatedCount)

        var sumPos = SIMD3<Double>.zero
        var minBound = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxBound = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            let payloadBase = base.advanced(by: headerEnd)

            func readFloat(_ ptr: UnsafeRawPointer, _ prop: PropertyOffset) -> Float {
                let p = ptr.advanced(by: prop.offset)
                switch prop.type {
                case .float32:
                    var bits: UInt32 = 0
                    memcpy(&bits, p, 4)
                    return Float(bitPattern: UInt32(littleEndian: bits))
                case .float64:
                    var bits: UInt64 = 0
                    memcpy(&bits, p, 8)
                    return Float(Double(bitPattern: UInt64(littleEndian: bits)))
                case .uint8:
                    return Float(p.load(as: UInt8.self)) / 255.0
                case .int8:
                    return Float(p.load(as: Int8.self)) / 127.0
                case .uint16:
                    var v: UInt16 = 0
                    memcpy(&v, p, 2)
                    return Float(UInt16(littleEndian: v)) / 65535.0
                case .int16:
                    var v: Int16 = 0
                    memcpy(&v, p, 2)
                    return Float(Int16(littleEndian: v))
                case .uint32:
                    var v: UInt32 = 0
                    memcpy(&v, p, 4)
                    return Float(UInt32(littleEndian: v))
                case .int32:
                    var v: Int32 = 0
                    memcpy(&v, p, 4)
                    return Float(Int32(littleEndian: v))
                }
            }

            var idx = 0
            while idx < availableVertices {
                let vPtr = payloadBase.advanced(by: idx * stride)
                idx += step

                // Filter out nearly invisible pruned Gaussians when previewing 3DGS files
                if let pOpacity {
                    let rawOpac = readFloat(vPtr, pOpacity)
                    let alpha = 1.0 / (1.0 + exp(-rawOpac))
                    if alpha < 0.04 { continue }
                }

                let x = readFloat(vPtr, px)
                let y = readFloat(vPtr, py)
                let z = readFloat(vPtr, pz)
                guard x.isFinite && y.isFinite && z.isFinite else { continue }

                let pos = SIMD3<Float>(x, y, z)
                positions.append(pos)

                let color: SIMD4<Float>
                if let pDC0, let pDC1, let pDC2 {
                    let r = min(max(0.5 + shC0 * readFloat(vPtr, pDC0), 0.0), 1.0)
                    let g = min(max(0.5 + shC0 * readFloat(vPtr, pDC1), 0.0), 1.0)
                    let b = min(max(0.5 + shC0 * readFloat(vPtr, pDC2), 0.0), 1.0)
                    color = SIMD4<Float>(r, g, b, 1.0)
                } else if let pRed, let pGreen, let pBlue {
                    let r = min(max(readFloat(vPtr, pRed), 0.0), 1.0)
                    let g = min(max(readFloat(vPtr, pGreen), 0.0), 1.0)
                    let b = min(max(readFloat(vPtr, pBlue), 0.0), 1.0)
                    color = SIMD4<Float>(r, g, b, 1.0)
                } else {
                    color = SIMD4<Float>(0.85, 0.85, 0.88, 1.0)
                }
                colors.append(color)

                sumPos += SIMD3<Double>(Double(x), Double(y), Double(z))
                minBound = simd_min(minBound, pos)
                maxBound = simd_max(maxBound, pos)
            }
        }

        let center: SIMD3<Float>
        let radius: Float
        if positions.isEmpty {
            center = .zero
            radius = 10.0
        } else {
            center = SIMD3<Float>(sumPos / Double(positions.count))
            radius = max(simd_length(maxBound - minBound) * 0.5, 1.0)
        }

        return PLYPreviewCloud(
            positions: positions,
            colors: colors,
            totalVertexCount: vertexCount,
            isGaussianSplat: isGaussianSplat,
            boundingCenter: center,
            boundingRadius: radius
        )
    }
}
