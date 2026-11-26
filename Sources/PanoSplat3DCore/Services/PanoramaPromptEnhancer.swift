import Foundation

/// Style presets for expanding short user descriptions into structured 360° equirectangular Virtual Production prompts.
public enum PanoramaPromptStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case photorealVP = "Photorealistic VP"
    case natureLandscape = "Nature & Forest"
    case architecturalInterior = "Interior Architecture"
    case cinematicSet = "Cinematic Film Set"

    public var id: String { rawValue }

    var styleDirectives: String {
        switch self {
        case .photorealVP:
            return "photorealistic 8K HDRI virtual production environment, natural realistic lighting, crisp surface micro-textures, balanced exposure from shadow to highlight"
        case .natureLandscape:
            return "photorealistic outdoor 8K nature photography, crisp layered foreground midground and distant background, continuous sky dome, sharp foliage and terrain detail, natural daylight"
        case .architecturalInterior:
            return "photorealistic architectural interior photography, plumb vertical walls and clean geometry, balanced ambient and bounced lighting, unobstructed 360-degree floor plane, crisp material textures"
        case .cinematicSet:
            return "cinematic film production set, rich atmospheric depth, motivated key and fill lighting, crisp practical details, realistic PBR materials, high dynamic range"
        }
    }
}

/// Pure-Swift 360° equirectangular prompt enhancer tailored for Gaussian Splatting & Virtual Production panoramas.
public enum PanoramaPromptEnhancer {
    public static let defaultNegativePrompt =
        "visible seam, split horizon, tilted horizon, tripod, camera shadow, photographer, fisheye circle, vignette, frame, border, watermark, text, blurry, motion blur, double exposure, stretched poles"

    public struct EnhancedResult: Equatable, Sendable {
        public let prompt: String
        public let negativePrompt: String
    }

    /// Expands a brief scene description into a seamless 2:1 equirectangular prompt optimized for depth estimation & 3DGS.
    /// Avoids duplicating framing clauses if the user already included them.
    public static func enhance(
        prompt rawPrompt: String,
        existingNegativePrompt: String = "",
        style: PanoramaPromptStyle = .photorealVP
    ) -> EnhancedResult {
        let base = rawPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.;"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !base.isEmpty else {
            return EnhancedResult(prompt: rawPrompt, negativePrompt: existingNegativePrompt)
        }

        let lower = base.lowercased()
        var segments: [String] = []

        if !lower.contains("equirectangular") && !lower.contains("360") {
            segments.append("360-degree equirectangular panorama")
        }

        segments.append(base)

        if !lower.contains("seamless") {
            segments.append("seamless 360 horizontal wrap")
        }
        if !lower.contains("horizon") {
            segments.append("level centered horizon from 1.7m eye-level tripod perspective")
        }
        if !lower.contains("depth separation") && !lower.contains("sharp focus") {
            segments.append("deep focus sharp throughout with clear foreground-to-background depth separation")
        }

        segments.append(style.styleDirectives)

        let enhancedPrompt = segments.joined(separator: ", ")

        let trimmedNeg = existingNegativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let enhancedNeg = trimmedNeg.isEmpty ? defaultNegativePrompt : trimmedNeg

        return EnhancedResult(prompt: enhancedPrompt, negativePrompt: enhancedNeg)
    }
}
