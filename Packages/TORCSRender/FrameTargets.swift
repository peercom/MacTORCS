// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

/// Render targets for one frame size, cached so a steady-state frame allocates
/// nothing. The classic path learned the same lesson with its mirror and MSAA
/// textures; allocating inside the draw loop is what produces hitches.
public final class FrameTargets {
    public let width: Int, height: Int
    /// Linear HDR scene colour. `rgba16Float` rather than `rgba8Unorm` because
    /// the whole point is to carry radiance above 1.0 through to the tonemapper.
    public let colour: MTLTexture
    public let depth: MTLTexture
    /// Display-referred output. Bound as sRGB so the hardware applies the
    /// transfer function on write; the shader must therefore emit linear.
    public let display: MTLTexture

    public static let colourFormat: MTLPixelFormat = .rgba16Float
    public static let depthFormat: MTLPixelFormat = .depth32Float
    public static let displayFormat: MTLPixelFormat = .rgba8Unorm_srgb

    init(device: MTLDevice, width requestedWidth: Int, height requestedHeight: Int) throws {
        let w = max(1, requestedWidth), h = max(1, requestedHeight)
        self.width = w
        self.height = h

        // Free function rather than a method: `self` is not yet fully
        // initialized, so it cannot be captured here.
        func make(_ format: MTLPixelFormat, usage: MTLTextureUsage,
                  storage: MTLStorageMode) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor()
            descriptor.pixelFormat = format
            descriptor.width = w
            descriptor.height = h
            descriptor.usage = usage
            descriptor.storageMode = storage
            descriptor.textureType = .type2D
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.unavailable("Could not allocate a \(w)x\(h) \(format) target")
            }
            return texture
        }

        colour = try make(Self.colourFormat, usage: [.renderTarget, .shaderRead], storage: .private)
        // Kept private rather than memoryless: the depth prepass, ambient
        // occlusion, screen-space reflections and contact shadows all read it
        // in the next phases.
        depth = try make(Self.depthFormat, usage: [.renderTarget, .shaderRead], storage: .private)
        // Shared so offscreen verification renders can read pixels back without
        // a staging blit.
        display = try make(Self.displayFormat, usage: [.renderTarget, .shaderRead], storage: .shared)
    }

    func matches(width: Int, height: Int) -> Bool {
        self.width == max(1, width) && self.height == max(1, height)
    }

    /// Bytes the targets occupy, for the memory budget check.
    public var byteCount: Int {
        width * height * (8 + 4 + 4)
    }
}
