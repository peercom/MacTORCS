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

    public enum UpscalingMode: String, Sendable, CaseIterable {
        case temporal, spatial
    }

    public enum Quality: Int, Sendable, Comparable, CaseIterable {
        case off = 0, quarter = 1, half = 2, full = 3
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        /// Divisor of the render resolution the pass runs at.
        public var divisor: Int {
            switch self { case .off, .full: return 1; case .half: return 2; case .quarter: return 4 }
        }
    }

    /// Fraction of output resolution the scene is rendered at, at rest.
    /// Dynamic resolution lowers it from here under load and never raises it
    /// above it. Ignored when `upscaling` is off, and at 1.0 the scaler is
    /// bypassed: a native frame is not scaled to itself.
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
    public var upscaling: Bool
    /// Which MetalFX scaler `upscaling` engages. The temporal scaler
    /// reconstructs from history and needs jitter and motion vectors; the
    /// spatial one is a single-frame sharpening upsample at a fraction of the
    /// cost, for when the frame must be cheaper and the history is not worth
    /// its price.
    public var upscalingMode: UpscalingMode
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
    /// Reuse last frame's reflections, reprojected and clamped, so the
    /// trace's per-frame dither averages out instead of crawling.
    public var reflectionTemporal: Bool

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
    /// Tyre smoke and dust billboards, drawn after the opaque scene.
    public var particles: Bool
    /// Rubber laid on the road by skidding tyres, as a darkening decal.
    public var skidMarks: Bool
    /// Glare from the sun when it is in frame and unoccluded: a halo, an
    /// anamorphic streak and a starburst added at the resolve.
    public var sunGlare: Bool
    public var sunGlareStrength: Float
    /// Shimmer over the far road under a high sun.
    public var heatHaze: Bool
    public var heatHazeStrength: Float

    /// Anisotropic filtering for the normal and roughness maps, 1 to 16. The
    /// albedo keeps the full 8: at the road's grazing angles that is what keeps
    /// the surface legible. These two maps carry less that anisotropy
    /// preserves, and each step of it costs the forward pass a few tenths of
    /// a millisecond on a road-filled view.
    public var detailAnisotropy: Int

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
            // Native at rest. The spatial scaler is the thermal valve: dynamic
            // resolution steps the render scale down the ladder as sustained
            // GPU time rises, which on a fanless chip it does after a few
            // minutes, and back up when it falls.
            renderScale = 1.0
            upscaling = true
            upscalingMode = .spatial
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 1
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.45
            reflectionTemporal = true
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            particles = true
            skidMarks = true
            sunGlare = true
            sunGlareStrength = 0.35
            heatHaze = true
            heatHazeStrength = 1
            detailAnisotropy = 2
            depthPrepass = false
            mirrorScale = 0.5
            textureMemoryBudgetBytes = 1_500_000_000
        case .balanced:
            renderScale = 1.0
            upscaling = true
            upscalingMode = .spatial
            dynamicResolution = true
            shadowCascades = 4
            shadowResolution = 2048
            staticShadowRefreshInterval = 1
            contactShadows = true
            ambientOcclusion = .half
            screenSpaceReflections = .half
            reflectionRoughnessCutoff = 0.6
            reflectionTemporal = true
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            particles = true
            skidMarks = true
            sunGlare = true
            sunGlareStrength = 0.35
            heatHaze = true
            heatHazeStrength = 1
            detailAnisotropy = 4
            depthPrepass = false
            mirrorScale = 0.67
            textureMemoryBudgetBytes = 3_000_000_000
        case .high:
            renderScale = 1
            upscaling = false
            upscalingMode = .spatial
            dynamicResolution = false
            shadowCascades = 4
            shadowResolution = 4096
            staticShadowRefreshInterval = 1
            contactShadows = true
            ambientOcclusion = .full
            screenSpaceReflections = .full
            reflectionRoughnessCutoff = 0.8
            reflectionTemporal = true
            bloom = true
            bloomStrength = 0.06
            bloomThreshold = 1.0
            motionBlur = true
            particles = true
            skidMarks = true
            sunGlare = true
            sunGlareStrength = 0.35
            heatHaze = true
            heatHazeStrength = 1
            detailAnisotropy = 8
            depthPrepass = false
            mirrorScale = 1
            textureMemoryBudgetBytes = 6_000_000_000
        }
    }

    /// Render resolution for a given output size, rounded to even pixels so
    /// half-resolution passes tile exactly and motion vectors stay aligned.
    public func renderSize(output: (width: Int, height: Int), scale: Float? = nil) -> (width: Int, height: Int) {
        let effective = upscaling ? min(max(scale ?? renderScale, 0.25), 1) : 1
        func round(_ value: Int) -> Int {
            let scaled = Int((Float(value) * effective).rounded())
            return max(16, scaled + (scaled % 2))
        }
        return (round(output.width), round(output.height))
    }
}
