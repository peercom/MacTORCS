// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

/// Render targets for one frame configuration, cached so a steady-state frame
/// allocates nothing.
///
/// Carries two resolutions. The scene is rendered at `renderWidth` by
/// `renderHeight` and presented at `outputWidth` by `outputHeight`; with
/// temporal upscaling off the two are equal. Splitting them here rather than in
/// the renderer keeps every pass from having to know which resolution it lives
/// at.
public final class FrameTargets {
    public let renderWidth: Int, renderHeight: Int
    public let outputWidth: Int, outputHeight: Int

    /// Linear HDR scene colour at render resolution. `rgba16Float` because the
    /// whole point is to carry radiance above 1.0 through to the tonemapper.
    public let colour: MTLTexture
    public let depth: MTLTexture
    /// Per-pixel offset to where this pixel was last frame, in render pixels.
    /// Only allocated when temporal upscaling is on.
    public let velocity: MTLTexture?
    /// What the scene pass binds at attachment 1: `velocity`, or a memoryless
    /// stand-in when upscaling is off. Every scene pipeline declares the
    /// attachment, and a pass that omits one the pipeline declares is
    /// undefined — on this GPU the later attachments shift down a slot, and
    /// the reflection surface received the motion vectors.
    public let velocityAttachment: MTLTexture
    /// Upscaler output, at output resolution. Nil when upscaling is off, in
    /// which case the tonemapper reads `colour` directly.
    public let upscaled: MTLTexture?
    /// Display-referred output. Bound as sRGB so the hardware applies the
    /// transfer function on write; the shader therefore emits linear.
    public let display: MTLTexture
    /// Normal, roughness and specular weight of the sharp lobe, for
    /// screen-space reflections. Every scene pipeline declares the attachment,
    /// so it always exists; when reflections are off it is memoryless and
    /// discarded, which on a tile-based GPU costs nothing.
    public let reflectionSurface: MTLTexture
    public let reflections: Bool

    public static let colourFormat: MTLPixelFormat = .rgba16Float
    public static let depthFormat: MTLPixelFormat = .depth32Float
    public static let velocityFormat: MTLPixelFormat = .rg16Float
    public static let displayFormat: MTLPixelFormat = .rgba8Unorm_srgb
    public static let reflectionSurfaceFormat: MTLPixelFormat = .rgba16Float

    init(device: MTLDevice, renderWidth: Int, renderHeight: Int,
         outputWidth: Int, outputHeight: Int, upscaling: Bool, reflections: Bool = false) throws {
        self.reflections = reflections
        let rw = max(1, renderWidth), rh = max(1, renderHeight)
        let ow = max(1, outputWidth), oh = max(1, outputHeight)
        self.renderWidth = rw; self.renderHeight = rh
        self.outputWidth = ow; self.outputHeight = oh

        func make(_ format: MTLPixelFormat, _ width: Int, _ height: Int,
                  usage: MTLTextureUsage, storage: MTLStorageMode) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = height
            descriptor.usage = usage
            descriptor.storageMode = storage
            descriptor.textureType = .type2D
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.unavailable("Could not allocate a \(width)x\(height) \(format) target")
            }
            return texture
        }

        colour = try make(Self.colourFormat, rw, rh, usage: [.renderTarget, .shaderRead], storage: .private)
        // Private rather than memoryless: the upscaler reads depth, as will
        // ambient occlusion, reflections and contact shadows.
        depth = try make(Self.depthFormat, rw, rh, usage: [.renderTarget, .shaderRead], storage: .private)
        velocity = upscaling
            ? try make(Self.velocityFormat, rw, rh, usage: [.renderTarget, .shaderRead], storage: .private)
            : nil
        velocityAttachment = try velocity ?? make(Self.velocityFormat, rw, rh, usage: .renderTarget, storage: .memoryless)
        upscaled = upscaling
            ? try make(Self.colourFormat, ow, oh, usage: [.shaderRead, .shaderWrite], storage: .private)
            : nil
        reflectionSurface = reflections
            ? try make(Self.reflectionSurfaceFormat, rw, rh, usage: [.renderTarget, .shaderRead], storage: .private)
            : try make(Self.reflectionSurfaceFormat, rw, rh, usage: .renderTarget, storage: .memoryless)
        // Shared so offscreen verification renders can read pixels back
        // without a staging blit.
        display = try make(Self.displayFormat, ow, oh, usage: [.renderTarget, .shaderRead], storage: .shared)
    }

    func matches(renderWidth: Int, renderHeight: Int, outputWidth: Int, outputHeight: Int,
                 upscaling: Bool, reflections: Bool = false) -> Bool {
        self.renderWidth == max(1, renderWidth) && self.renderHeight == max(1, renderHeight)
            && self.outputWidth == max(1, outputWidth) && self.outputHeight == max(1, outputHeight)
            && (velocity != nil) == upscaling && self.reflections == reflections
    }

    /// Bytes the targets occupy, for the memory budget check.
    public var byteCount: Int {
        let render = renderWidth * renderHeight * (8 + 4 + (velocity != nil ? 4 : 0) + (reflections ? 8 : 0))
        let output = outputWidth * outputHeight * (4 + (upscaled != nil ? 8 : 0))
        return render + output
    }
}
