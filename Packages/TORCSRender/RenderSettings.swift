// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Quality configuration for the modern render path.
///
/// Every effect is switchable independently so its cost can be measured and
/// defended in isolation, which is how the per-pass GPU budget is held. The
/// default preset targets the fanless M2 Air: 60 Hz presentation with GPU time
/// deliberately kept well under the 16.6 ms frame so there is headroom left for
/// thermal throttling rather than spending all of it at room temperature.
public struct RenderSettings: Sendable, Equatable {
    public enum Preset: String, Sendable, CaseIterable {
        /// Default. Fanless 10-core M2, 8 GB, upscaled from roughly half resolution.
        case m2Air
        /// Actively cooled Apple silicon with more GPU cores.
        case balanced
        /// Native resolution, every effect at full rate.
        case high
    }

    public enum Quality: Int, Sendable, Comparable, CaseIterable {
        case off = 0, half = 1, full = 2
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
    }

    /// Fraction of output resolution the scene is rendered at before temporal
    /// upscaling. Ignored when `temporalUpscaling` is off.
    public var renderScale: Float
    public var temporalUpscaling: Bool
    public var dynamicResolution: Bool

    public var shadowCascades: Int
    public var shadowResolution: Int
    /// Refresh distant cascades every N frames, staggered. 1 is every frame.
    public var staticShadowRefreshInterval: Int
    public var contactShadows: Bool

    public var ambientOcclusion: Quality
    public var screenSpaceReflections: Quality
    /// Surfaces rougher than this skip SSR entirely; the probe is close enough
    /// and the march cost is wasted.
    public var reflectionRoughnessCutoff: Float

    public var bloom: Bool
    public var motionBlur: Bool

    /// Mirror passes render at this fraction of the main render resolution.
    public var mirrorScale: Float

    /// Soft cap used by the memory budget check. Exceeding it on an 8 GB
    /// machine risks swapping, which costs far more than any effect saves.
    public var textureMemoryBudgetBytes: Int

    public init(preset: Preset = .m2Air) {
        switch preset {
        case .m2Air:
            renderScale = 0.5
            temporalUpscaling = true
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 3
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.45
            bloom = true
            motionBlur = true
            mirrorScale = 0.5
            textureMemoryBudgetBytes = 1_500_000_000
        case .balanced:
            renderScale = 0.67
            temporalUpscaling = true
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 2
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.6
            bloom = true
            motionBlur = true
            mirrorScale = 0.67
            textureMemoryBudgetBytes = 3_000_000_000
        case .high:
            renderScale = 1
            temporalUpscaling = true
            dynamicResolution = false
            shadowCascades = 4
            shadowResolution = 4096
            staticShadowRefreshInterval = 1
            contactShadows = true
            ambientOcclusion = .full
            screenSpaceReflections = .full
            reflectionRoughnessCutoff = 0.8
            bloom = true
            motionBlur = true
            mirrorScale = 1
            textureMemoryBudgetBytes = 6_000_000_000
        }
    }

    /// Render resolution for a given output size, rounded to even pixels so
    /// half-resolution passes tile exactly and motion vectors stay aligned.
    public func renderSize(output: (width: Int, height: Int), scale: Float? = nil) -> (width: Int, height: Int) {
        let effective = temporalUpscaling ? min(max(scale ?? renderScale, 0.25), 1) : 1
        func round(_ value: Int) -> Int {
            let scaled = Int((Float(value) * effective).rounded())
            return max(16, scaled + (scaled % 2))
        }
        return (round(output.width), round(output.height))
    }
}
