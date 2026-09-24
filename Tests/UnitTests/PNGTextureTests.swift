// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSAssets
import CReference

final class PNGTextureTests: XCTestCase {
    static func replacingChunk(_ data: Data,name: String,with replacement: [UInt8]) -> Data {
        let bytes=Array(data);var out=Array(bytes.prefix(8)),i=8
        while i<bytes.count {
            let n=(0..<4).reduce(0) { $0*256+Int(bytes[i+$1]) },tag=String(bytes:bytes[i+4..<i+8],encoding:.ascii)!
            out += tag==name ? chunk(tag,replacement):Array(bytes[i..<i+n+12]);i += n+12
        }
        return Data(out)
    }
    static func chunk(_ name: String,_ bytes: [UInt8]) -> [UInt8] {
        func word(_ n: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:n>>((3-$0)*8)) } }
        let content=Array(name.utf8)+bytes;var crc: UInt32=0xffffffff
        for b in content { crc ^= UInt32(b);for _ in 0..<8 { crc=crc & 1 != 0 ? (crc>>1)^0xedb88320:crc>>1 } }
        return word(UInt32(bytes.count))+content+word(crc ^ 0xffffffff)
    }
    static func fixture(color: Int=6,depth: Int=8,transparency: Bool=false,gamma: Int?=nil,interlace: Bool=false,significant: Int?=nil,sRGB: Bool=false) -> Data {
        let width=17,height=9,channels=[0:1,2:3,3:1,4:2,6:4][color]!,maximum=(1<<depth)-1
        func word(_ n: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded:n>>((3-$0)*8)) } }
        func value(_ x: Int,_ y: Int,_ c: Int) -> Int { (x*7759+y*3361+c*991)&maximum }
        let header=word(width)+word(height)+[UInt8(depth),UInt8(color),0,0,interlace ? 1:0]
        var bytes: [UInt8]=[137,80,78,71,13,10,26,10]+chunk("IHDR",header)
        if let gamma { bytes += chunk("gAMA",word(gamma)) }
        if sRGB { bytes += chunk("sRGB",[0]) }
        if let significant { bytes += chunk("sBIT",Array(repeating:UInt8(significant),count:color==3 ? 3:channels)) }
        if color==3 { bytes += chunk("PLTE",(0..<(1<<depth)*3).map { UInt8(($0*37+11)%256) }) }
        if transparency {
            let t: [UInt8]
            if color==3 { t=(0..<(1<<depth)).map { UInt8(($0*17)%256) } }
            else if color==0 { t=[0,0] }
            else { t=(0..<3).flatMap { c -> [UInt8] in let n=value(0,0,c);return [UInt8(n>>8),UInt8(n&255)] } }
            bytes += chunk("tRNS",t)
        }
        let passes=interlace ? [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]:[(0,0,1,1)]
        var scanlines: [UInt8]=[]
        for (sx,sy,dx,dy) in passes {
            var previous: [UInt8]=[]
            for y in stride(from:sy,to:height,by:dy) {
                let samples=stride(from:sx,to:width,by:dx).flatMap { x in (0..<channels).map { value(x,y,$0) } }
                if samples.isEmpty { continue }
                var row=Array(repeating:UInt8(0),count:(samples.count*depth+7)/8)
                for (i,v) in samples.enumerated() {
                    if depth==16 { row[i*2]=UInt8(v>>8);row[i*2+1]=UInt8(v&255) }
                    else if depth==8 { row[i]=UInt8(v) }
                    else { row[i*depth/8] |= UInt8(v<<(8-depth-(i*depth%8))) }
                }
                if previous.isEmpty { previous=Array(repeating:0,count:row.count) }
                let filter=y%5,pixel=max(1,(channels*depth+7)/8);scanlines.append(UInt8(filter))
                for i in row.indices {
                    let a=i>=pixel ? Int(row[i-pixel]):0,b=Int(previous[i]),c=i>=pixel ? Int(previous[i-pixel]):0
                    let predictor: Int
                    switch filter {
                    case 1: predictor=a
                    case 2: predictor=b
                    case 3: predictor=(a+b)/2
                    case 4:
                        let p=a+b-c,pa=abs(p-a),pb=abs(p-b),pc=abs(p-c)
                        predictor=pa<=pb && pa<=pc ? a:pb<=pc ? b:c
                    default: predictor=0
                    }
                    scanlines.append(UInt8(truncatingIfNeeded:Int(row[i])-predictor))
                }
                previous=row
            }
        }
        // Independent stored-deflate writer avoids relying on either decoder.
        var compressed: [UInt8]=[0x78,0x01],start=0
        while start<scanlines.count {
            let n=min(65535,scanlines.count-start);compressed += [start+n==scanlines.count ? 1:0,UInt8(n&255),UInt8(n>>8),UInt8((n^65535)&255),UInt8((n^65535)>>8)]
            compressed += scanlines[start..<start+n];start += n
        }
        var a=1,b=0;for v in scanlines { a=(a+Int(v))%65521;b=(b+a)%65521 };compressed += word((b<<16)|a)
        bytes += chunk("IDAT",compressed);bytes += chunk("IEND",[]);return Data(bytes)
    }
    func compare(_ data: Data,path: URL,screen: Float=2) throws -> (accepted: Int,bytes: Int) {
        try data.write(to:path);var w: Int32=0,h: Int32=0,count: Int32=0
        let reference=ref_png_load(path.path,screen,&w,&h,&count)
        let native=Result { try TextureImage.decodePNG(data,screenGamma:screen) }
        if let reference {
            let image=try native.get();XCTAssertEqual(image.width,Int(w));XCTAssertEqual(image.height,Int(h))
            let expected=Array(UnsafeBufferPointer(start:reference,count:Int(count)))
            if image.pixels != expected {
                let i=zip(image.pixels,expected).enumerated().first { $0.element.0 != $0.element.1 }!.offset
                XCTFail("\(path.lastPathComponent) byte \(i): \(image.pixels[i]) != \(expected[i])")
            }
            return (1,expected.count)
        }
        if case .success = native { XCTFail("Native accepted original-rejected layout: \(path.lastPathComponent)") }
        return (0,0)
    }
    func testSelectedPNGsAgainstOriginal() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork")
        var bytes=0
        for name in ["aalborg/raceline.png","trb1-3/wheel3d.png"] {
            let path=root.appendingPathComponent(name),temp=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
            defer { try? FileManager.default.removeItem(at:temp) }
            bytes += try compare(Data(contentsOf:path),path:temp).bytes
        }
        print("PNG_SELECTED files=2 bytes=\(bytes) unequalBytes=0 libpng=\(String(cString:ref_png_version()))")
    }
    func testLayoutsGammaFiltersAndInterlaceAgainstOriginal() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:folder) }
        var cases=0,accepted=0,bytes=0
        for color in [0,2,3,4,6] { for depth in (color==0 ? [1,2,4,8,16]:color==3 ? [1,2,4,8]:[8,16]) {
            for trns in ([0,2,3].contains(color) ? [false,true]:[false]) { for interlace in [false,true] { for gamma in [nil,45455,47500,52500,52501,80000,100000] as [Int?] { for screen: Float in [1.7,2,2.2] {
                let name="c\(color)-d\(depth)-t\(trns)-i\(interlace)-g\(gamma ?? 0)-s\(screen).png"
                let result=try compare(Self.fixture(color:color,depth:depth,transparency:trns,gamma:gamma,interlace:interlace),path:folder.appendingPathComponent(name),screen:screen)
                cases += 1;accepted += result.accepted;bytes += result.bytes
            } } } }
        } }
        print("PNG_AUTHORED cases=\(cases) accepted=\(accepted) rejected=\(cases-accepted) bytes=\(bytes) unequalBytes=0")
    }
    func testSignificantBitsAndSRGBPrecedence() throws {
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".png")
        defer { try? FileManager.default.removeItem(at:path) }
        var cases=0,bytes=0
        for color in [4,6] { for bits in [1,6,8,10,11,12,16] { for gamma in [45455,80000] {
            let result=try compare(Self.fixture(color:color,depth:16,gamma:gamma,significant:bits),path:path)
            cases += 1;bytes += result.bytes
        } } }
        for gamma in [nil,45455,80000] as [Int?] { let r=try compare(Self.fixture(gamma:gamma,sRGB:true),path:path);cases += 1;bytes += r.bytes }
        let duplicate=Self.replacingChunk(Self.fixture(color:3,depth:2,transparency:true),name:"PLTE",with:Array(repeating:[UInt8(51),102,153],count:4).flatMap { $0 })
        let result=try compare(duplicate,path:path);cases += 1;bytes += result.bytes
        print("PNG_METADATA cases=\(cases) bytes=\(bytes) unequalBytes=0")
    }
    func testMalformedPNGsAreDiagnosed() throws {
        let data=Self.fixture()
        for i in stride(from:0,to:data.count,by:19) { XCTAssertThrowsError(try TextureImage.decodePNG(data.prefix(i))) }
        for i in [0,12,16,24,40,data.count-1] { var bad=data;bad[i] ^= 127;XCTAssertThrowsError(try TextureImage.decodePNG(bad)) }
        for gamma: Float in [0,-1,.infinity,.nan] { XCTAssertThrowsError(try TextureImage.decodePNG(data,screenGamma:gamma)) }
        XCTAssertThrowsError(try TextureImage.decodePNG(Self.replacingChunk(data,name:"IDAT",with:[0,0,0])))
        var badPalette=Self.replacingChunk(Self.fixture(color:3,transparency:true),name:"PLTE",with:[10,20,30])
        badPalette=Self.replacingChunk(badPalette,name:"tRNS",with:[0])
        XCTAssertThrowsError(try TextureImage.decodePNG(badPalette))
    }
    func testPNGCacheAndOriginalMipBytes() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork")
        var bytes=0,levels=0,cacheBytes=0
        for name in ["aalborg/raceline.png","trb1-3/wheel3d.png"] {
            let file=root.appendingPathComponent(name),data=try Data(contentsOf:file)
            let compiled=try TextureCache.compile(data,filename:file.lastPathComponent),decoded=try TextureCache.decode(compiled)
            XCTAssertEqual(compiled,try TextureCache.compile(data,filename:file.lastPathComponent))
            var w: Int32=0,h: Int32=0,n: Int32=0
            let pixels=try XCTUnwrap(ref_png_load(file.path,2,&w,&h,&n));var count: Int32=0,l: Int32=0
            let result=ref_texture_mips(pixels,w,h,4,4096,1,&count,&l)
            let original=try TextureImageTests().original(result,count:count,levels:l)
            XCTAssertEqual(decoded.pyramid.levels,original)
            bytes += original.reduce(0) { $0+$1.pixels.count };levels += original.count;cacheBytes += compiled.count
        }
        print("PNG_CACHE files=2 levels=\(levels) bytes=\(bytes) cacheBytes=\(cacheBytes) exactRoundTrip=1 unequalBytes=0")
    }
    func testDetailedWheelMeshesAgainstOriginalParser() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork/trb1-3")
        var nodes=0,meshes=0,scalars=0
        for index in 0..<4 {
            let data=try Data(contentsOf:root.appendingPathComponent("wheel\(index).acc"))
            let r=try ACSceneTests().compare(data,car:true,label:"wheel\(index)")
            let compiled=try ACMeshCache.compile(data,options:.init(car:true)),decoded=try ACMeshCache.decode(compiled)
            XCTAssertEqual(decoded.scene,try ACScene.parse(data,car:true))
            nodes += r.nodes;meshes += r.meshes;scalars += r.scalars
        }
        print("PNG_WHEELS files=4 nodes=\(nodes) meshes=\(meshes) scalars=\(scalars) maxAbsolute=0")
    }
}
