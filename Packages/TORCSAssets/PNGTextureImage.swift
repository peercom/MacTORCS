// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS GfImgReadPng, Copyright (C) 1999-2014 Eric Espie,
// Bernhard Wymann. ImageIO supplies PNG decompression; compatibility transforms
// are explicit. Gamma-table portions are adapted from libpng 1.6.50, not original
// libpng source. Copyright (c) 1995-2025 The PNG Reference Library Authors;
// (c) 2018-2025 Cosmin Truta; (c) 2000-2002,2004,2006-2018 Glenn Randers-Pehrson;
// (c) 1996-1997 Andreas Dilger; (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.
// The libpng copyright notice, disclaimer and permission terms are retained in
// Upstream/PNGReference/LICENSE (PNG Reference Library License version 2).
import Foundation
import ImageIO

extension TextureImage {
    public static func decodePNG(_ data: Data, screenGamma: Float = 2) throws -> TextureImage {
        let png=try PNGInput(data)
        // Match the original post-transform four-byte-row gate, including its
        // rejection of opaque palette/gray and opaque 16-bit RGB input.
        guard png.color==4 || png.color==6 || !png.transparency.isEmpty || (png.color==2 && png.depth==8) else {
            throw ACError.invalid("Original TORCS PNG transforms do not produce RGBA for this color layout")
        }
        let gamma=try PNGGamma(depth:png.depth,color:png.color,significant:png.significant,file:png.gamma ?? 50_000,screen:screenGamma)
        // Strip color metadata and tRNS in the decode copy. ImageIO must return
        // raw samples, with no inferred sRGB/gAMA/profile transform or alpha loss.
        guard let source=CGImageSourceCreateWithData(png.decodeData as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false,kCGImageSourceShouldAllowFloat:false] as CFDictionary),
              image.width==png.width,image.height==png.height,
              image.bitsPerComponent==(png.depth==16 ? 16:8),
              [.none,.last,.noneSkipLast].contains(image.alphaInfo),
              let provider=image.dataProvider?.data else { throw ACError.invalid("Unsupported ImageIO PNG sample layout or decode failure") }
        let raw=Array(provider as Data),stride=image.bitsPerPixel/image.bitsPerComponent,step=image.bitsPerComponent/8
        guard CGImageSourceGetStatusAtIndex(source,0) == .statusComplete else { throw ACError.invalid("Incomplete PNG image data") }
        let needed=[0:1,2:3,3:1,4:2,6:4][png.color]!
        guard stride>=needed,image.bytesPerRow>=png.width*stride*step,raw.count>=image.bytesPerRow*png.height else { throw ACError.invalid("Truncated ImageIO PNG samples") }
        let order=image.bitmapInfo.intersection(.byteOrderMask)
        guard step==2 ? (order == .byteOrder16Little || order == .byteOrder16Big || order.rawValue==0):order.rawValue==0 else { throw ACError.invalid("Unsupported PNG sample byte order") }
        let little=order == .byteOrder16Little
        func sample(_ start: Int,_ channel: Int) -> Int {
            let i=start+channel*step
            if step==1 { return Int(raw[i]) }
            return little ? Int(raw[i])+Int(raw[i+1])*256:Int(raw[i])*256+Int(raw[i+1])
        }
        func be16(_ bytes: [UInt8],_ i: Int) -> Int { Int(bytes[i])*256+Int(bytes[i+1]) }
        var pixels=Array(repeating:UInt8(0),count:png.width*png.height*4)
        for y in 0..<png.height { for x in 0..<png.width {
            let start=y*image.bytesPerRow+x*stride*step,out=((png.height-1-y)*png.width+x)*4
            var rgb: [Int],alpha=255
            if png.color==3 {
                let index=sample(start,0)
                guard index<png.palette.count/3 else { throw ACError.invalid("PNG palette index out of range") }
                rgb=(0..<3).map { Int(png.palette[index*3+$0]) }
                if index<png.transparency.count { alpha=Int(png.transparency[index]) }
            } else if png.color==0 || png.color==4 {
                let value=sample(start,0);rgb=[value,value,value]
                if png.color==4 { alpha=sample(start,1)>>(png.depth==16 ? 8:0) }
                else if !png.transparency.isEmpty {
                    let original=png.depth<8 ? value*((1<<png.depth)-1)/255:value
                    if original==be16(png.transparency,0) { alpha=0 }
                }
            } else {
                rgb=(0..<3).map { sample(start,$0) }
                if png.color==6 { alpha=sample(start,3)>>(png.depth==16 ? 8:0) }
                else if !png.transparency.isEmpty && (0..<3).allSatisfy({ rgb[$0]==be16(png.transparency,$0*2) }) { alpha=0 }
            }
            for c in 0..<3 { pixels[out+c]=gamma.apply(rgb[c]) };pixels[out+3]=UInt8(alpha)
        } }
        return try TextureImage(width:png.width,height:png.height,channels:4,pixels:pixels)
    }
    public static func decode(_ data: Data) throws -> TextureImage {
        if data.starts(with:PNGInput.signature) { return try decodePNG(data) }
        if data.starts(with:[1,218]) || data.starts(with:[218,1]) { return try decodeSGI(data) }
        throw ACError.invalid("Expected PNG or one-byte SGI texture")
    }
}

struct PNGInput {
    static let signature: [UInt8]=[137,80,78,71,13,10,26,10]
    static let crcTable: [UInt32]=(0..<256).map { i in
        var c=UInt32(i);for _ in 0..<8 { c=c & 1 != 0 ? 0xedb88320 ^ (c>>1):c>>1 };return c
    }
    static func paletteChunk(depth: Int) -> Data {
        // ImageIO may return indexed samples or expand a small palette to RGB.
        // Encode each possible index in red so both layouts preserve its exact
        // identity, including duplicate source colors with different tRNS alpha.
        let colors=(0..<(1<<depth)).flatMap { [UInt8($0),UInt8(0),UInt8(255-$0)] }
        let body=Array("PLTE".utf8)+colors
        func word(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:n>>((3-$0)*8)) } }
        var crc: UInt32=0xffffffff
        for value in body { crc=crcTable[Int((crc ^ UInt32(value)) & 255)] ^ (crc>>8) }
        return Data(word(UInt32(colors.count))+body+word(crc ^ 0xffffffff))
    }
    var width=0,height=0,depth=0,color=0
    var gamma: Int?,palette: [UInt8]=[],transparency: [UInt8]=[],significant: [UInt8]=[]
    var decodeData=Data(PNGInput.signature)
    init(_ data: Data) throws {
        guard data.count<=64*1024*1024,data.starts(with:Self.signature) else { throw ACError.invalid("PNG signature or byte limit") }
        let b=Array(data);var cursor=8,header=false,ended=false,sawData=false,dataEnded=false,seen=Set<String>()
        func u32(_ i: Int) -> Int { (0..<4).reduce(0) { $0*256+Int(b[i+$1]) } }
        while cursor<b.count {
            guard b.count-cursor>=12 else { throw ACError.invalid("Truncated PNG chunk") }
            let n=u32(cursor),begin=cursor+8
            guard n<=b.count-cursor-12,let name=String(bytes:b[cursor+4..<cursor+8],encoding:.ascii) else { throw ACError.invalid("Invalid PNG chunk range or type") }
            guard b[cursor+4..<cursor+8].allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),b[cursor+6] & 32==0 else { throw ACError.invalid("Invalid PNG chunk name") }
            let payload=Array(b[begin..<begin+n]);var crc: UInt32=0xffffffff
            for value in b[cursor+4..<begin+n] { crc=Self.crcTable[Int((crc ^ UInt32(value)) & 255)] ^ (crc>>8) }
            guard crc ^ 0xffffffff==UInt32(u32(begin+n)) else { throw ACError.invalid("PNG CRC mismatch") }
            guard !ended,header || name=="IHDR" else { throw ACError.invalid("Invalid PNG chunk order") }
            if ["IHDR","PLTE","tRNS","gAMA","sBIT","IEND"].contains(name) {
                guard seen.insert(name).inserted else { throw ACError.invalid("Duplicate PNG \(name)") }
            }
            if sawData && name != "IDAT" { dataEnded=true }
            switch name {
            case "IHDR":
                guard n==13,!header else { throw ACError.invalid("Invalid PNG header") }
                width=u32(begin);height=u32(begin+4);depth=Int(payload[8]);color=Int(payload[9]);header=true
                let depths=[0:[1,2,4,8,16],2:[8,16],3:[1,2,4,8],4:[8,16],6:[8,16]]
                guard (1...16_384).contains(width),(1...16_384).contains(height),width*height<=16_777_216,
                      depths[color]?.contains(depth)==true,payload[10]==0,payload[11]==0,payload[12]<=1 else { throw ACError.invalid("Unsupported PNG dimensions, depth or coding") }
            case "PLTE":
                guard !sawData,n>0,n<=768,n%3==0 else { throw ACError.invalid("Invalid PNG palette") };palette=payload
            case "tRNS":
                guard !sawData,(color==0 && n==2)||(color==2 && n==6)||(color==3 && n>0 && n<=palette.count/3) else { throw ACError.invalid("Invalid PNG transparency") };transparency=payload
                if color != 3 { for i in stride(from:0,to:n,by:2) { guard Int(payload[i])*256+Int(payload[i+1])<(1<<depth) else { throw ACError.invalid("PNG transparent sample exceeds bit depth") } } }
            case "gAMA":
                guard !sawData,n==4,u32(begin)>0,u32(begin)<=Int(Int32.max) else { throw ACError.invalid("Invalid PNG gamma") };gamma=u32(begin)
            case "sBIT":
                let c=[0:1,2:3,3:3,4:2,6:4][color]!
                guard !sawData,n==c,payload.allSatisfy({ $0>0 && $0<=(color==3 ? 8:depth) }) else { throw ACError.invalid("Invalid PNG significant bits") };significant=payload
            case "IDAT": guard !dataEnded,color != 3 || !palette.isEmpty else { throw ACError.invalid("Invalid PNG data order or missing palette") };sawData=true
            case "IEND": guard n==0,sawData else { throw ACError.invalid("Invalid PNG end") };ended=true
            default: guard b[cursor+4] & 32 != 0 else { throw ACError.invalid("Unsupported critical PNG chunk") }
            }
            if name=="PLTE",color==3 { decodeData.append(Self.paletteChunk(depth:depth)) }
            else if ["IHDR","PLTE","IDAT","IEND"].contains(name) { decodeData.append(contentsOf:b[cursor..<begin+n+4]) }
            cursor=begin+n+4
        }
        guard ended else { throw ACError.invalid("Missing PNG end") }
    }
}

/*
Gamma-table adaptation retains the original libpng license:
COPYRIGHT NOTICE, DISCLAIMER, and LICENSE
=========================================

PNG Reference Library License version 2
---------------------------------------

 * Copyright (c) 1995-2025 The PNG Reference Library Authors.
 * Copyright (c) 2018-2025 Cosmin Truta.
 * Copyright (c) 2000-2002, 2004, 2006-2018 Glenn Randers-Pehrson.
 * Copyright (c) 1996-1997 Andreas Dilger.
 * Copyright (c) 1995-1996 Guy Eric Schalnat, Group 42, Inc.

The software is supplied "as is", without warranty of any kind,
express or implied, including, without limitation, the warranties
of merchantability, fitness for a particular purpose, title, and
non-infringement.  In no event shall the Copyright owners, or
anyone distributing the software, be liable for any damages or
other liability, whether in contract, tort or otherwise, arising
from, out of, or in connection with the software, or the use or
other dealings in the software, even if advised of the possibility
of such damage.

Permission is hereby granted to use, copy, modify, and distribute
this software, or portions hereof, for any purpose, without fee,
subject to the following restrictions:

 1. The origin of this software must not be misrepresented; you
    must not claim that you wrote the original software.  If you
    use this software in a product, an acknowledgment in the product
    documentation would be appreciated, but is not required.

 2. Altered source versions must be plainly marked as such, and must
    not be misrepresented as being the original software.

 3. This Copyright notice may not be removed or altered from any
    source or altered source distribution.


*/
struct PNGGamma {
    let table: [UInt8],shift: Int
    init(depth: Int,color: Int,significant: [UInt8],file: Int,screen: Float) throws {
        let screenValue=floor(Double(screen)*100_000+0.5)
        guard screen.isFinite,screenValue>0,screenValue<=Double(Int32.max),1e10/screenValue<=Double(Int32.max) else { throw ACError.invalid("Unsupported PNG screen gamma") }
        let product=floor(Double(file)*screenValue/100_000+0.5)
        let active=product<95_000 || product>105_000
        func reciprocal(_ value: Double) -> Int { let result=floor(value+0.5);return result.isFinite && result>=0 && result<=Double(Int32.max) ? Int(result):0 }
        let correction=reciprocal((1e15/screenValue)/Double(file))
        if depth<=8 {
            shift=0
            table=(0...255).map { value in
                guard active,(correction<95_000 || correction>105_000),value>0,value<255 else { return UInt8(value) }
                return UInt8(floor(255*pow(Double(value)/255,Double(correction)*0.00001)+0.5))
            }
        } else if !active {
            shift=8;table=Array(0...255)
        } else {
            let sig=(color==0 || color==4) ? Int(significant.first ?? 16):Int(significant.prefix(3).max() ?? 16)
            shift=min(8,max(5,16-sig));let maximum=(1<<(16-shift))-1
            let inverse=reciprocal(1e10/Double(correction));var last=0,values=Array(repeating:UInt8(255),count:maximum+1)
            for i in 0..<255 {
                let boundary=Int(floor(65535*pow(Double(i*257+128)/65535,Double(inverse)*0.00001)+0.5))
                let limit=(boundary*maximum+32768)/65535+1
                while last<limit { values[last]=UInt8(i);last += 1 }
            }
            table=values
        }
    }
    func apply(_ value: Int) -> UInt8 { table[value>>shift] }
}
