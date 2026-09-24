// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of PLIB ssgSimpleState/ssgContext, Steve Baker, 1998-2002.
// Derived LGPL-2.0-or-later portions converted to GPL v2 under LGPL v2 section 3,
// effective 2026-09-23. Original notices retained in Upstream.
import TORCSAssets
import simd

/// Per-view basic SSG alpha state. Visibility/order decide which states apply;
/// ordinary ACC materials set the clamp even when alpha enable is inherited.
struct SceneAlphaState:Equatable {
    private(set) var enabled=true
    private(set) var threshold:Float=0.01
    mutating func apply(_ state:ACRenderState) {
        if state.alphaCare & 1 != 0 { enabled=state.flags & 16 != 0 }
        if state.alphaCare & 2 != 0 { threshold=min(1,max(0,state.alphaClamp)) }
    }
    /// Shadows/lights use nonnegative UNORM alpha, SRC_ALPHA blending for every
    /// channel and read-only depth. At threshold zero, rejected fragments would
    /// contribute exactly zero and leave destination color/depth unchanged.
    /// This is not valid for ordinary meshes, which write depth.
    var needsBlendedEffectTest:Bool { enabled && threshold>0 }
    /// Linear/trilinear/anisotropic repeat sampling is bounded by the uploaded
    /// UNORM texels. Scan all uploaded levels at load time, including LA alpha.
    static func minimumAlpha(_ pyramid:TexturePyramid) -> Float {
        var value:UInt8=255
        for image in pyramid.levels where image.channels==2 || image.channels==4 {
            for i in stride(from:image.channels-1,to:image.pixels.count,by:image.channels) {
                value=min(value,image.pixels[i]);if value==0 { return 0 }
            }
        }
        return Float(value)/255
    }
    /// Elide discard only when every fragment must pass. Retain a generous
    /// floating-point margin, and keep all near-boundary/zero-alpha cases tested.
    func needsTest(colorAlpha:Float,minimumTextureAlpha:SIMD4<Float>,maps:SIMD4<UInt32>) -> Bool {
        guard enabled else { return false }
        guard colorAlpha>0,colorAlpha.isFinite else { return true }
        var lower=colorAlpha.nextDown
        for i in 0..<4 where maps[i] != 0 {
            guard minimumTextureAlpha[i]>0,minimumTextureAlpha[i]<=1 else { return true }
            lower=(lower*minimumTextureAlpha[i].nextDown).nextDown
        }
        return !(lower>threshold+8*Float.ulpOfOne*max(1,abs(lower)))
    }
}
