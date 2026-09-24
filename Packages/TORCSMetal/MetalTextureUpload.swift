// SPDX-License-Identifier: GPL-2.0-only
import Metal
import Foundation
import TORCSAssets

@MainActor public enum MetalTextureUpload {
    /// Prepare textures during content loading, never inside the race draw loop.
    /// Unorm preserves original byte values; no implicit sRGB or alpha conversion.
    public static func make(device: MTLDevice, pyramid: TexturePyramid) throws -> MTLTexture {
        guard let base=pyramid.levels.first else { throw RendererError.unavailable("Empty texture pyramid") }
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:base.width,height:base.height,mipmapped:pyramid.levels.count>1)
        descriptor.mipmapLevelCount=pyramid.levels.count;descriptor.storageMode = .shared;descriptor.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:descriptor) else { throw RendererError.unavailable("Texture allocation failed") }
        for (level,image) in pyramid.levels.enumerated() {
            let rgba=image.rgba8
            rgba.withUnsafeBytes { bytes in
                texture.replace(region:MTLRegionMake2D(0,0,image.width,image.height),mipmapLevel:level,withBytes:bytes.baseAddress!,bytesPerRow:image.width*4)
            }
        }
        return texture
    }
    /// Diagnostic path: execute real GPU blits, then compare every uploaded byte.
    /// This validates resource transfer, not rasterization, filtering or lighting.
    public static func verifyCaches(_ files: [URL]) throws -> Int {
        guard !files.isEmpty,let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw RendererError.unavailable("Texture smoke test needs files and a Metal device") }
        var verified=0
        for file in files {
            verified += try autoreleasepool {
                let asset=try TextureCache.decode(ContentSearchPath.readBounded(file,maximumBytes:96*1024*1024))
                let texture=try make(device:device,pyramid:asset.pyramid)
                var count=0
                for (level,image) in asset.pyramid.levels.enumerated() {
                    let pitch=(image.width*4+255) & ~255
                    guard let buffer=device.makeBuffer(length:pitch*image.height,options:.storageModeShared),
                          let command=queue.makeCommandBuffer(),let blit=command.makeBlitCommandEncoder() else { throw RendererError.unavailable("Texture readback allocation failed") }
                    blit.copy(from:texture,sourceSlice:0,sourceLevel:level,sourceOrigin:MTLOrigin(x:0,y:0,z:0),sourceSize:MTLSize(width:image.width,height:image.height,depth:1),to:buffer,destinationOffset:0,destinationBytesPerRow:pitch,destinationBytesPerImage:pitch*image.height)
                    blit.endEncoding();command.commit();command.waitUntilCompleted()
                    if let error=command.error { throw error }
                    let pixels=buffer.contents().assumingMemoryBound(to:UInt8.self),expected=image.rgba8
                    for y in 0..<image.height { for x in 0..<image.width*4 {
                        guard pixels[y*pitch+x]==expected[y*image.width*4+x] else { throw RendererError.unavailable("GPU texture byte mismatch at level \(level)") }
                    } }
                    count += expected.count
                }
                return count
            }
        }
        return verified
    }
}
