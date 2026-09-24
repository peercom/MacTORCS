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

    /// MetalFX temporal upscaling. Implemented, working, and off by default.
    ///
    /// Measured on this content it is a net loss, because the renderer is not
    /// pixel-bound: the same scene costs 1.34 ms at 320x208 and 1.29 ms at
    /// 2560x1664, a 64-fold difference in pixel count for no difference in
    /// time. 1,366 draw calls with per-draw uniform uploads dominate, so
    /// halving the render resolution saves almost nothing while the upscaler
    /// adds a fixed cost of roughly 1.5 ms.
    ///
    /// Turn it on once the renderer is submission-efficient — merged static
    /// batches, argument buffers, indirect command buffers — and the fragment
    /// shader is carrying real work. At that point it becomes the largest lever
    /// available, which is why it is built rather than deferred.
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
    /// Weight the bloom pyramid is added with. Small: the pyramid carries only
    /// radiance above `BloomRenderer.threshold`, and this is how much of that
    /// spreads rather than staying in the highlight.
    public var bloomStrength: Float
    /// Exposed value above which light starts to spread. AgX maps 1.0 to about
    /// 0.8 on the display and does not reach white until several stops higher,
    /// so with the soft knee this confines bloom to the upper tones and above:
    /// sun glints, the sky near the sun, lit specular highlights. A sunlit
    /// diffuse surface at a sensible exposure sits below it and does not glow.
    public var bloomThreshold: Float
    public var motionBlur: Bool

    /// Render a depth-only pass before shading.
    ///
    /// Off by default, and deliberately so. Apple GPUs remove hidden surfaces
    /// in hardware, so the prepass that is standard on immediate-mode
    /// architectures is usually redundant here and costs an extra geometry
    /// submission. It is exposed as a setting so the claim can be measured on
    /// real content rather than assumed either way.
    public var depthPrepass: Bool

    /// Mirror passes render at this fraction of the main render resolution.
    public var mirrorScale: Float

    /// Soft cap used by the memory budget check. Exceeding it on an 8 GB
    /// machine risks swapping, which costs far more than any effect saves.
    public var textureMemoryBudgetBytes: Int

    public init(preset: Preset = .m2Air) {
        switch preset {
        case .m2Air:
            renderScale = 0.5
            temporalUpscaling = false
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 3
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.45
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            depthPrepass = false
            mirrorScale = 0.5
            textureMemoryBudgetBytes = 1_500_000_000
        case .balanced:
            renderScale = 0.67
            temporalUpscaling = false
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 2
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.6
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            depthPrepass = false
            mirrorScale = 0.67
            textureMemoryBudgetBytes = 3_000_000_000
        case .high:
            renderScale = 1
            temporalUpscaling = false
            dynamicResolution = false
            shadowCascades = 4
            shadowResolution = 4096
            staticShadowRefreshInterval = 1
            contactShadows = true
            ambientOcclusion = .full
            screenSpaceReflections = .full
            reflectionRoughnessCutoff = 0.8
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            depthPrepass = false
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
