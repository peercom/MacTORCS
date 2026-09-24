// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSAssets
import CReference

final class TextureImageTests: XCTestCase {
    func original(_ pointer: UnsafePointer<UInt8>?, count: Int32, levels: Int32) throws -> [TextureImage] {
        let bytes=Array(UnsafeBufferPointer(start:try XCTUnwrap(pointer),count:Int(count)))
        var cursor=0,result: [TextureImage]=[]
        func integer() -> Int { defer { cursor += 4 };return (0..<4).reduce(0) { $0 | Int(bytes[cursor+$1])<<($1*8) } }
        for _ in 0..<levels {
            let w=integer(),h=integer(),c=integer(),n=integer()
            result.append(try TextureImage(width:w,height:h,channels:c,pixels:Array(bytes[cursor..<cursor+n])));cursor += n
        }
        XCTAssertEqual(cursor,bytes.count);return result
    }
    func compare(_ data: Data, filename: String, maximum: Int = 4096) throws -> (levels: Int,bytes: Int) {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let path=folder.appendingPathComponent(filename);try data.write(to:path)
        let decoded=try TextureImage.decodeSGI(data),native=try TexturePyramid(image:decoded,filename:path.path,options:.init(maximumDimension:maximum))
        var count: Int32=0,levels: Int32=0
        let pointer=ref_texture_sgi(path.path,Int32(maximum),&count,&levels)
        let reference=try original(pointer,count:count,levels:levels)
        XCTAssertEqual(native.levels.count,reference.count)
        var compared=0
        for (i,pair) in zip(native.levels,reference).enumerated() {
            XCTAssertEqual(pair.0.width,pair.1.width);XCTAssertEqual(pair.0.height,pair.1.height);XCTAssertEqual(pair.0.channels,pair.1.channels)
            if pair.0.pixels != pair.1.pixels { XCTFail("Pixel mismatch in \(filename) level \(i)") }
            compared += pair.0.pixels.count
        }
        return (reference.count,compared)
    }
    func testSelectedSGITexturesAgainstOriginalUploadBytes() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork")
        let files=try ["155-DTM","aalborg"].flatMap { name in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent(name),includingPropertiesForKeys:nil).filter { $0.pathExtension=="rgb" } }.sorted { $0.path<$1.path }
        XCTAssertEqual(files.count,27)
        var bytes=0,levels=0
        for path in files { let r=try compare(Data(contentsOf:path),filename:path.lastPathComponent);bytes += r.bytes;levels += r.levels }
        print("TEXTURE_SELECTED files=\(files.count) levels=\(levels) bytes=\(bytes) unequalBytes=0")
    }
    static func fixture(channels: Int = 4,rle: Bool = true,little: Bool = false,dimension: Int = 3) -> Data {
        let w=8,h=4,rows=h*channels
        var b=Array(repeating:UInt8(0),count:512+(rle ? rows*8:0))
        func write(_ value: Int,_ offset: Int,_ size: Int) { for i in 0..<size { b[offset+i]=UInt8(truncatingIfNeeded:value>>((little ? i:size-1-i)*8)) } }
        write(474,0,2);b[2]=rle ? 1:0;b[3]=1;write(dimension,4,2);write(w,6,2);write(h,8,2);write(channels,10,2);write(255,16,4)
        for c in 0..<channels { for y in 0..<h {
            let row=(0..<w).map { x in UInt8((c*37+y*19+(x<3 ? 11:x*23))%256) }
            if rle {
                let encoded: [UInt8]=[3,row[0],133]+Array(row[3...])+[0]
                write(b.count,512+(c*h+y)*4,4);write(encoded.count,512+rows*4+(c*h+y)*4,4);b += encoded
            } else { b += row }
        } }
        return Data(b)
    }
    func testChannelsStorageEndiannessAndHeaderRepair() throws {
        var cases=0,bytes=0
        for c in 1...4 { for rle in [false,true] { for little in [false,true] { for dimension in [0,1,2,3] {
            let r=try compare(Self.fixture(channels:c,rle:rle,little:little,dimension:dimension),filename:"authored.rgb")
            cases += 1;bytes += r.bytes
        } } } }
        print("TEXTURE_SGI_AUTHORED cases=\(cases) bytes=\(bytes) unequalBytes=0")
    }
    func testMipmapsDownsizingAndNamingAgainstOriginal() throws {
        var cases=0,bytes=0
        for c in 1...4 { for (w,h) in [(1,1),(1,16),(16,1),(8,4),(4,8)] { for mip in [false,true] { for limit in [4,16] {
            if min(w,h)==1 && max(w,h)>limit { continue } // Original proxy loop would receive a zero dimension.
            let pixels=(0..<w*h*c).map { UInt8(($0*43+17)%256) }
            let img=try TextureImage(width:w,height:h,channels:c,pixels:pixels)
            let native=try TexturePyramid(image:img,filename:"authored.rgb",options:.init(mipmaps:mip,maximumDimension:limit))
            var size: Int32=0,levels: Int32=0
            let result=pixels.withUnsafeBufferPointer { ref_texture_mips($0.baseAddress,Int32(w),Int32(h),Int32(c),Int32(limit),mip ? 1:0,&size,&levels) }
            let ref=try original(result,count:size,levels:levels)
            XCTAssertEqual(native.levels,ref);cases += 1;bytes += ref.reduce(0) { $0+$1.pixels.count }
        } } } }
        let names=["track.rgb","track_n.rgb","track_N.rgb","shadow.rgb","Shadow.rgb","foo_shadowbar.rgb","shadow/path.rgb","dir_n/noextension","dir.dot/noextension","dir_n/image.rgb","foo_n.extra.rgb"]
        for name in names { for requested in [false,true] { XCTAssertEqual(TexturePyramid.usesMipmaps(filename:name,requested:requested),ref_texture_mipmap_rule(name,requested ? 1:0) != 0) } }
        print("TEXTURE_MIPS cases=\(cases) namingCases=\(names.count*2) bytes=\(bytes) unequalBytes=0")
    }
    func testRGBAExpansionAndUnsafeSGIInputs() throws {
        for c in 1...4 {
            let image=try TextureImage(width:1,height:1,channels:c,pixels:Array([UInt8(20),40,60,80].prefix(c)))
            XCTAssertEqual(image.rgba8,[[20,20,20,255],[20,20,20,40],[20,40,60,255],[20,40,60,80]][c-1])
        }
        let data=Self.fixture();var invalid: [Data]=[Data(),Data("not SGI".utf8)]
        for (offset,value) in [(0,0),(2,2),(3,2),(6,255),(10,255),(11,5),(512,255),(640,127)] {
            var copy=data;copy[offset]=UInt8(value);invalid.append(copy)
        }
        // A row offset into the header, an incomplete row, and an overlong run.
        var copy=data;copy.replaceSubrange(512..<516,with:[0,0,0,1]);invalid.append(copy)
        copy=data;copy[640]=0;invalid.append(copy)
        for value in invalid { XCTAssertThrowsError(try TextureImage.decodeSGI(value)) }
        for n in stride(from:0,to:data.count,by:11) { XCTAssertThrowsError(try TextureImage.decodeSGI(data.prefix(n))) }
        let img=try TextureImage(width:1,height:16,channels:1,pixels:Array(repeating:1,count:16))
        XCTAssertThrowsError(try TexturePyramid(image:img,filename:"test",options:.init(maximumDimension:4)))
        let nonPower=try TextureImage(width:3,height:1,channels:1,pixels:[1,2,3])
        XCTAssertThrowsError(try TexturePyramid(image:nonPower,filename:"test"))
    }
}
