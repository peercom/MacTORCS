// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of PLIB ssgLoadSGI.cxx, Copyright (C) 1998,2002 Steve Baker,
// and TORCS grtexture.cpp, Copyright (C) 2005 Bernhard Wymann.
// Derived LGPL-2.0-or-later portions converted to GPL v2 under LGPL v2 section 3,
// effective 2026-09-23. Original notices retained in Upstream/Reference/textures.
import Foundation

public struct TextureImage: Sendable, Equatable {
    public let width: Int, height: Int, channels: Int
    /// Interleaved unsigned bytes, bottom row first; straight alpha, no color conversion.
    public let pixels: [UInt8]
    public init(width: Int, height: Int, channels: Int, pixels: [UInt8]) throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height),
              (1...4).contains(channels), width*height<=16_777_216,
              pixels.count==width*height*channels else { throw ACError.invalid("Invalid texture dimensions or pixel storage") }
        self.width=width; self.height=height; self.channels=channels; self.pixels=pixels
    }
    /// Expand only after mip generation: original two-channel alpha is averaged,
    /// whereas original four-channel alpha uses the maximum of four samples.
    public var rgba8: [UInt8] {
        if channels==4 { return pixels }
        var result=[UInt8](); result.reserveCapacity(width*height*4)
        for i in stride(from:0,to:pixels.count,by:channels) {
            switch channels {
            case 1: result += [pixels[i],pixels[i],pixels[i],255]
            case 2: result += [pixels[i],pixels[i],pixels[i],pixels[i+1]]
            default: result += [pixels[i],pixels[i+1],pixels[i+2],255]
            }
        }
        return result
    }
    public static func decodeSGI(_ data: Data) throws -> TextureImage {
        guard (512...64*1024*1024).contains(data.count) else { throw ACError.invalid("SGI byte limit or truncated header") }
        let b=Array(data)
        guard (b[0]==1 && b[1]==218) || (b[0]==218 && b[1]==1) else { throw ACError.invalid("Not an SGI image") }
        var bigEndian=b[0]==1
        func u16(_ i: Int) -> Int { bigEndian ? Int(b[i])*256+Int(b[i+1]):Int(b[i+1])*256+Int(b[i]) }
        func u32(_ i: Int) -> Int {
            let bytes=bigEndian ? Array(b[i..<i+4]):Array(b[i..<i+4].reversed())
            return bytes.reduce(0) { $0*256+Int($1) }
        }
        guard b[2]<=1,b[3]==1 else { throw ACError.invalid("Unsupported SGI storage or bytes per component") }
        var dimension=u16(4)
        if dimension>255 { bigEndian.toggle(); dimension=u16(4) }
        let width=u16(6); var height=u16(8),channels=u16(10)
        // Preserve the original MultiGen header repair before validating dimensions.
        if height>1 && dimension<2 { dimension=2 }
        if channels>1 && dimension<3 { dimension=3 }
        if dimension<1 { height=1 }
        if dimension<2 { channels=1 }
        guard (1...16_384).contains(width),(1...16_384).contains(height),(1...4).contains(channels),
              width*height<=16_777_216 else { throw ACError.invalid("SGI dimensions exceed limits") }
        let rows=height*channels, tableEnd=512+rows*8
        if b[2]==1 { guard tableEnd<=b.count else { throw ACError.invalid("Truncated SGI row tables") } }
        else { guard width*rows<=b.count-512 else { throw ACError.invalid("Truncated SGI planes") } }
        var pixels=Array(repeating:UInt8(0),count:width*rows)
        for channel in 0..<channels { for y in 0..<height {
            let row=channel*height+y
            if b[2]==0 {
                for x in 0..<width { pixels[(y*width+x)*channels+channel]=b[512+row*width+x] }
                continue
            }
            let start=u32(512+row*4),length=u32(512+rows*4+row*4)
            guard start>=tableEnd,start<=b.count,length>0,length<=b.count-start else { throw ACError.invalid("Invalid SGI row range") }
            var input=start,x=0; let end=start+length
            while input<end {
                let code=b[input]; input += 1; let count=Int(code & 127)
                if count==0 { break }
                guard count<=width-x else { throw ACError.invalid("SGI run exceeds row width") }
                if code & 128 != 0 {
                    guard count<=end-input else { throw ACError.invalid("Truncated SGI literal run") }
                    for offset in 0..<count { pixels[(y*width+x+offset)*channels+channel]=b[input+offset] }
                    input += count
                } else {
                    guard input<end else { throw ACError.invalid("Truncated SGI repeated run") }
                    for offset in 0..<count { pixels[(y*width+x+offset)*channels+channel]=b[input] }
                    input += 1
                }
                x += count
            }
            guard x==width else { throw ACError.invalid("Incomplete SGI row") }
        } }
        return try TextureImage(width:width,height:height,channels:channels,pixels:pixels)
    }
}

public struct TextureCompileOptions: Sendable, Equatable {
    public var mipmaps: Bool, maximumDimension: Int
    public init(mipmaps: Bool = true, maximumDimension: Int = 4096) {
        self.mipmaps=mipmaps; self.maximumDimension=maximumDimension
    }
}
public struct TexturePyramid: Sendable, Equatable {
    public let sourceWidth: Int, sourceHeight: Int, levels: [TextureImage]
    /// Original case-sensitive doMipMap rule, applied to the whole source path.
    public static func usesMipmaps(filename: String, requested: Bool) -> Bool {
        var stem=filename
        if let dot=stem.lastIndex(of:".") { stem=String(stem[..<dot]) }
        if let underscore=stem.lastIndex(of:"_"),stem[underscore...]=="_n" { return false }
        return requested && !(filename.split(separator:"/",omittingEmptySubsequences:false).last?.contains("shadow") ?? false)
    }
    public init(image: TextureImage, filename: String, options: TextureCompileOptions = .init()) throws {
        guard (1...16_384).contains(options.maximumDimension),
              image.width & (image.width-1)==0,image.height & (image.height-1)==0 else {
            throw ACError.invalid("TORCS texture upload requires power-of-two dimensions and a valid size limit")
        }
        var chain=[image]
        while let parent=chain.last,parent.width>1 || parent.height>1 {
            let width=max(1,parent.width/2),height=max(1,parent.height/2),channels=parent.channels
            var pixels=Array(repeating:UInt8(0),count:width*height*channels)
            for y in 0..<height { for x in 0..<width { for c in 0..<channels {
                let x0=x*2,x1=(x0+1)%parent.width,y0=y*2,y1=(y0+1)%parent.height
                let a=Int(parent.pixels[(y0*parent.width+x0)*channels+c]),b=Int(parent.pixels[(y1*parent.width+x0)*channels+c])
                let d=Int(parent.pixels[(y0*parent.width+x1)*channels+c]),e=Int(parent.pixels[(y1*parent.width+x1)*channels+c])
                pixels[(y*width+x)*channels+c]=UInt8(c==3 ? max(a,b,d,e):(a+b+d+e)/4)
            } } }
            chain.append(try TextureImage(width:width,height:height,channels:channels,pixels:pixels))
        }
        var first=0,rawWidth=image.width,rawHeight=image.height
        while rawWidth>options.maximumDimension || rawHeight>options.maximumDimension {
            rawWidth >>= 1; rawHeight >>= 1; first += 1
            guard rawWidth>0,rawHeight>0 else { throw ACError.invalid("Original texture downsizing would create a zero dimension") }
        }
        sourceWidth=image.width; sourceHeight=image.height
        levels=Self.usesMipmaps(filename:filename,requested:options.mipmaps) ? Array(chain[first...]):[chain[first]]
    }
}
