// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSAssets

final class ACSceneTests: XCTestCase {
    func compare(_ data: Data,car: Bool,units: Int = 4,label: String) throws -> (nodes: Int,meshes: Int,scalars: Int) {
        let native=try ACScene.parse(data,car:car,textureUnits:units)
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".acc")
        try data.write(to:path);defer { try? FileManager.default.removeItem(at:path) }
        let json=try XCTUnwrap(ref_ac_load_json(path.path,car ? 1:0,Int32(units)))
        let reference=try JSONDecoder().decode(ACScene.self,from:Data(String(cString:json).utf8))
        XCTAssertEqual(native.nodes.count,reference.nodes.count,label)
        XCTAssertEqual(native.loaderBounds,reference.loaderBounds,label+" raw loader bounds")
        var meshes=0,scalars=0
        func floats(_ a: [Float],_ b: [Float],_ name: String) {
            XCTAssertEqual(a.count,b.count,"\(label) \(name) count")
            for i in a.indices where i<b.count {
                if a[i] != b[i] { XCTFail("\(label) \(name)[\(i)] \(a[i]) != \(b[i])");return }
                scalars += 1
            }
        }
        for (i,pair) in zip(native.nodes,reference.nodes).enumerated() {
            let (a,b)=pair
            XCTAssertEqual(a.parent,b.parent,"node \(i) parent");XCTAssertEqual(a.kind,b.kind,"node \(i) kind");XCTAssertEqual(a.name,b.name,"node \(i) name")
            floats(a.matrix,b.matrix,"node \(i) matrix")
            if let a=a.mesh,let b=b.mesh {
                meshes += 1
                XCTAssertEqual(a.primitive,b.primitive,"node \(i) primitive");XCTAssertEqual(a.indexed,b.indexed);XCTAssertEqual(a.cull,b.cull)
                XCTAssertEqual(a.mapCount,b.mapCount,"node \(i) mapCount");XCTAssertEqual(a.mapLevel,b.mapLevel,"node \(i) mapLevel")
                XCTAssertEqual(a.indices,b.indices,"node \(i) indices");XCTAssertEqual(a.strips,b.strips,"node \(i) strips")
                floats(a.vertices,b.vertices,"node \(i) vertices");floats(a.normals,b.normals,"node \(i) normals");floats(a.colors,b.colors,"node \(i) colors")
                for j in 0..<4 {
                    floats(a.uv[j],b.uv[j],"node \(i) UV \(j)")
                    if let x=a.states[j],let y=b.states[j] {
                        floats(x.material,y.material,"node \(i) material \(j)");floats([x.alphaClamp],[y.alphaClamp],"alphaClamp")
                        XCTAssertEqual(x.alphaCare,y.alphaCare,"node \(i) alpha care \(j)");XCTAssertEqual(x.flags,y.flags,"node \(i) state \(j)");XCTAssertEqual(x.texture,y.texture,"node \(i) texture \(j)")
                    } else { XCTAssertEqual(a.states[j],b.states[j],"node \(i) state \(j) presence") }
                }
            } else { XCTAssertEqual(a.mesh,b.mesh,"node \(i) mesh presence") }
        }
        return (native.nodes.count,meshes,scalars)
    }
    func testSelectedCarAndTrackAgainstOriginalParser() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var nodes=0,meshes=0,scalars=0
        for name in ["155-DTM","aalborg"] {
            let data=try Data(contentsOf:fixtures.appendingPathComponent("Artwork/\(name)/\(name).acc"))
            let r=try compare(data,car:name=="155-DTM",label:name)
            nodes += r.nodes;meshes += r.meshes;scalars += r.scalars
        }
        print("ACC_ORIGINAL files=2 nodes=\(nodes) meshes=\(meshes) scalars=\(scalars) maxAbsolute=0")
    }
}

extension ACSceneTests {
    static func fixture(primitive: Int = 4,normals: Bool = true,textured: Bool = true,window: Bool = false) -> Data {
        let tail=normals ? " 0 1 0":""
        return Data("""
        AC3Db
        MATERIAL "first" rgb 0.2 0.3 0.4 amb 0.1 0.2 0.3 emis 0.3 0.2 0.1 spec 0.7 0.6 0.5 shi 23 trans 0.4
        MATERIAL "last" rgb 0.8 0.6 0.2 amb 0.4 0.5 0.6 emis 0.1 0.3 0.2 spec 0.2 0.4 0.6 shi 41 trans 0
        OBJECT world
        kids 1
        OBJECT group
        name "TKMNsegment_g7"
        rot 0 -1 0 1 0 0 0 0 1
        loc 3 5 7
        kids 1
        OBJECT poly
        name "\(window ? "WIfront":"DRdriver")"
        loc 1 2 3
        rot 1 0 0 0 0 -1 0 1 0
        data 4
        test
        \(textured ? "texture \"tree-base.rgb\" base\ntexture \"detail.rgb\" tiled\ntexture \"skids.png\" skids\ntexture \"shade.png\" shad":"")
        texrep 2.3 -1.7
        texoff 0.13 0.27
        numvert 4
        0 0 0\(tail)
        1 0 0\(tail)
        0 0 1\(tail)
        1 0 1\(tail)
        numsurf 2
        SURF \(16+primitive)
        mat 0
        refs 4
        0 0.11 0.21 0.31 0.41 0.51 0.61 0.71 0.81
        1 0.12 0.22 0.32 0.42 0.52 0.62 0.72 0.82
        2 0.13 0.23 0.33 0.43 0.53 0.63 0.73 0.83
        3 0.14 0.24 0.34 0.44 0.54 0.64 0.74 0.84
        SURF \(48+primitive)
        mat 1
        refs 4
        1 0.92 0.82 0.72 0.62 0.52 0.42 0.32 0.22
        0 0.91 0.81 0.71 0.61 0.51 0.41 0.31 0.21
        3 0.94 0.84 0.74 0.64 0.54 0.44 0.34 0.24
        2 0.93 0.83 0.73 0.63 0.53 0.43 0.33 0.23
        kids 0

        """.utf8)
    }
    func testAuthoredMaterialsTransformsPrimitivesAndTextureUnits() throws {
        var cases=0,scalars=0
        for primitive in 0...4 { for normals in [false,true] { for car in [false,true] { for units in 1...4 {
            let data=Self.fixture(primitive:primitive,normals:normals,textured:units != 2,window:units==3)
            let r=try compare(data,car:car,units:units,label:"mode \(primitive) normal \(normals) car \(car) units \(units)")
            cases += 1;scalars += r.scalars
        } } } }
        print("ACC_AUTHORED cases=\(cases) scalars=\(scalars) maxAbsolute=0")
    }
    func testCaseInsensitiveTagsMissingTextureLayersAndShortChildLists() throws {
        var xml=String(decoding:Self.fixture(),as:UTF8.self)
        xml=xml.replacingOccurrences(of:"OBJECT",with:"object").replacingOccurrences(of:"MATERIAL",with:"material").replacingOccurrences(of:"numvert",with:"NUMVERT")
        xml=xml.replacingOccurrences(of:"texture \"skids.png\" skids",with:"texture empty_texture_no_mapping skids")
        xml=xml.replacingOccurrences(of:"texture \"shade.png\" shad",with:"texture empty_texture_no_mapping shad")
        xml=xml.replacingOccurrences(of:"kids 1",with:"kids 2")
        let data=Data(xml.utf8),scene=try ACScene.parse(data)
        XCTAssertFalse(try XCTUnwrap(scene.warnings).isEmpty)
        _ = try compare(data,car:false,label:"case/layers/short children")
    }
    func testMalformedAndBoundedInputsAreDiagnosed() throws {
        let base=String(decoding:Self.fixture(),as:UTF8.self)
        let invalid=[
            "not a model",base.replacingOccurrences(of:"numvert 4",with:"numvert -1"),
            base.replacingOccurrences(of:"numvert 4",with:"numvert 2147483647"),
            base.replacingOccurrences(of:"mat 1",with:"mat 99"),base.replacingOccurrences(of:"refs 4",with:"refs 2147483647"),
            base.replacingOccurrences(of:"tree-base.rgb",with:"../outside.rgb"),base.replacingOccurrences(of:"tree-base.rgb",with:"/outside.rgb"),
            base.replacingOccurrences(of:"1 0 0 0 1 0",with:"nan 0 0 0 1 0"),
            base.replacingOccurrences(of:"0 0.11",with:"9 0.11"),base.replacingOccurrences(of:"data 4",with:"data 99999999"),
            base.replacingOccurrences(of:"SURF 20",with:"SURF 31"),base.replacingOccurrences(of:"rot 1 0 0 0 0 -1 0 1 0",with:"rot 1 2"),
            base.replacingOccurrences(of:"name \"DRdriver\"",with:"name \"unterminated"),base.replacingOccurrences(of:"numvert 4",with:"unknown 4")
        ]
        for (i,xml) in invalid.enumerated() { XCTAssertThrowsError(try ACScene.parse(Data(xml.utf8)),"invalid case \(i)") }
        var limits=ACLimits();limits.depth=1
        XCTAssertThrowsError(try ACScene.parse(Data(base.utf8),limits:limits))
        limits=ACLimits();limits.references=4
        XCTAssertThrowsError(try ACScene.parse(Data(base.utf8),limits:limits))
        limits=ACLimits();limits.lineBytes=20
        XCTAssertThrowsError(try ACScene.parse(Data(base.utf8),limits:limits))
        let bytes=Array(base.utf8)
        for length in stride(from:0,to:bytes.count,by:17) {
            do { let scene=try ACScene.parse(Data(bytes.prefix(length)));try scene.validate() }
            catch { /* Prefixes must be safely diagnosed or produce a valid completed subtree. */ }
        }
        print("ACC_INVALID cases=\(invalid.count+3) truncatedPrefixes=\((bytes.count+16)/17)")
    }
}
