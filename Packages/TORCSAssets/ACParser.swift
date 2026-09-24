// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 grloadac.cpp (PLIB), Copyright (C) 2001 Steve Baker.
// Derived LGPL-2.0-or-later portions converted to GPL v2 under LGPL v2 section 3,
// effective 2026-09-23. Unlike the legacy parser, malformed input is diagnosed.
import Foundation

final class ACParser {
    struct Material { var values: [Float],color: [Float] }
    let bytes: [UInt8],limits: ACLimits,car: Bool,units: Int
    var cursor=0,lineNumber=0,vertexTotal=0,referenceTotal=0
    var nodes=[ACNode(parent:-1,kind:0,name:"",matrix:acIdentity,mesh:nil)]
    var warnings: [String]=[]
    var bounds=ACLoaderBounds(minimumX:999999,maximumX:-999999,minimumY:999999,maximumY:-999999)
    var materials: [Material]=[],material: Int?
    var texture: [String?]=Array(repeating:nil,count:4),mapCount=1,mapLevel=1
    var repeatUV: [Float]=[1,1],offsetUV: [Float]=[0,0]
    var vertices: [Float]=[],normals: [Float]=[],uv: [[Float]]=Array(repeating:[],count:4)
    var indices: [UInt32]=[],strips: [UInt32]=[],written: [Bool]=[]
    var usesNormals=false,usesStrip=false,inGroup=false,window=false,flags=0
    init(data: Data,car: Bool,textureUnits: Int,limits: ACLimits) throws {
        guard data.count<=limits.bytes,(1...4).contains(textureUnits),limits.depth>0 else { throw ACError.invalid("ACC input or texture-unit limit exceeded") }
        bytes=Array(data);self.car=car;units=textureUnits;self.limits=limits
    }
    func fail(_ s: String) -> ACError { .invalid("AC line \(lineNumber): \(s)") }
    func line() throws -> String? {
        guard cursor<bytes.count else { return nil }
        let start=cursor
        while cursor<bytes.count,bytes[cursor] != 10 { cursor += 1; if cursor-start>limits.lineBytes { throw fail("Line limit exceeded") } }
        let end=cursor;if cursor<bytes.count { cursor += 1 };lineNumber += 1
        let slice=bytes[start..<end]
        guard !slice.contains(0) else { throw fail("NUL in text record") }
        return (String(bytes:slice,encoding:.utf8) ?? String(bytes:slice,encoding:.isoLatin1)!).trimmingCharacters(in:.whitespacesAndNewlines)
    }
    func record() throws -> [String]? {
        while let s=try line() {
            if s.isEmpty || s.hasPrefix("#") || s.hasPrefix(";") { continue }
            var tokens: [String]=[],token="",quoted=false,started=false
            for c in s {
                if c=="\"" { quoted.toggle();started=true }
                else if c.isWhitespace && !quoted { if started { tokens.append(token);token="";started=false } }
                else { token.append(c);started=true }
            }
            guard !quoted else { throw fail("Unclosed quoted string") }
            if started { tokens.append(token) }
            if !tokens.isEmpty {
                let key=tokens[0].lowercased()
                tokens[0]=["material":"MATERIAL","object":"OBJECT","surf":"SURF"][key] ?? key
            }
            return tokens
        }
        return nil
    }
    func need() throws -> [String] { guard let r=try record() else { throw fail("Unexpected end of file") };return r }
    func integer(_ s: String) throws -> Int {
        let n=s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2),radix:16):Int(s)
        guard let n else { throw fail("Invalid integer") };return n
    }
    func number(_ s: String) throws -> Float { guard let n=Float(s),n.isFinite else { throw fail("Invalid or nonfinite number") };return n }
    func floats(_ r: [String],_ count: Int) throws -> [Float] { guard r.count==count else { throw fail("Unexpected numeric record width") };return try r.map(number) }
    func count(_ r: [String],maximum: Int) throws -> Int { guard r.count==2 else { throw fail("Invalid count record") };let n=try integer(r[1]);guard n>=0,n<=maximum else { throw fail("Count limit exceeded") };return n }
    func append(_ node: ACNode) throws -> Int { guard nodes.count<limits.nodes else { throw fail("Node limit exceeded") };nodes.append(node);return nodes.count-1 }
    func parse() throws -> ACScene {
        let header=try need();guard header.count==1,header[0].uppercased().hasPrefix("AC3D") else { throw fail("Not an AC3D file") }
        while let r=try record() {
            switch r.first {
            case "MATERIAL": try readMaterial(r)
            case "OBJECT": try object(r,parent:0,depth:0)
            default: throw fail("Unsupported top-level record")
            }
        }
        return ACScene(nodes:nodes,loaderBounds:vertexTotal>0 ? bounds:nil,warnings:warnings.isEmpty ? nil:warnings)
    }
    func readMaterial(_ r: [String]) throws {
        guard materials.count<limits.materials,r.count==22,r[2]=="rgb",r[6]=="amb",r[10]=="emis",r[14]=="spec",r[18]=="shi",r[20]=="trans" else { throw fail("Invalid MATERIAL") }
        let rgb=try r[3...5].map(number),amb=try r[7...9].map(number),emis=try r[11...13].map(number),spec=try r[15...17].map(number)
        let shininess=try integer(r[19]),opacity=try Float(1)-number(r[21])
        materials.append(Material(values:spec+[1]+emis+[1]+amb+[1]+[Float(shininess)],color:rgb+[opacity]));material=materials.count-1
    }
    func object(_ r: [String],parent: Int,depth: Int) throws {
        guard depth<limits.depth,r.count==2,["world","poly","group","light"].contains(r[1].lowercased()) else { throw fail("Unsupported object or excessive depth") }
        texture[0]=nil;repeatUV=[1,1];offsetUV=[0,0];inGroup=r[1].lowercased()=="group"
        var parent=parent
        if inGroup { parent=try append(.init(parent:parent,kind:1,name:"",matrix:[],mesh:nil)) }
        let node=try append(.init(parent:parent,kind:0,name:"",matrix:acIdentity,mesh:nil))
        while true {
            let r=try need()
            switch r[0] {
            case "name":
                guard r.count==2 else { throw fail("Invalid name") }
                var name=r[1];window=name.hasPrefix("WI")
                if name.hasPrefix("TKMN"),let suffix=name.range(of:"_g") { name=String(name[..<suffix.lowerBound]) }
                if name.hasPrefix("DR") { name="DRIVER" };nodes[node].name=name
            case "texture": try readTexture(r)
            case "texrep": repeatUV=try floats(Array(r.dropFirst()),2)
            case "texoff": offsetUV=try floats(Array(r.dropFirst()),2)
            case "loc":
                let v=try floats(Array(r.dropFirst()),3);nodes[node].matrix[12]=v[0];nodes[node].matrix[13] = -v[2];nodes[node].matrix[14]=v[1];nodes[node].matrix[15]=1
            case "rot":
                let v=try floats(Array(r.dropFirst()),9);nodes[node].matrix=acIdentity
                for i in 0..<3 { for j in 0..<3 { nodes[node].matrix[i*4+j]=v[i*3+j] } }
            case "data":
                let n=try count(r,maximum:limits.bytes);guard n<=bytes.count-cursor else { throw fail("Truncated data block") };cursor += n
                guard cursor<bytes.count,bytes[cursor]==10 || bytes[cursor]==13 else { throw fail("Missing data terminator") }
                if bytes[cursor]==13 { cursor += 1 };if cursor<bytes.count,bytes[cursor]==10 { cursor += 1 }
            case "url": break // Default upstream options make no branch from data and ignore URLs.
            case "numvert": try readVertices(count(r,maximum:limits.vertices))
            case "numsurf":
                let n=try count(r,maximum:limits.references)
                for _ in 0..<n { try surface(parent:node) }
            case "kids":
                let n=try count(r,maximum:limits.nodes)
                if n==0,usesStrip,!inGroup { try emitIndexed(parent:node) }
                mapCount=1;mapLevel=1
                for i in 0..<n {
                    guard let child=try record() else { warnings.append("Object \(nodes[node].name) declares \(n) children; EOF after \(i). Original ACC loader accepts this short child list.");break }
                    if child[0]=="OBJECT" { try object(child,parent:node,depth:depth+1) }
                    else if child[0]=="MATERIAL" { try readMaterial(child) }
                    else { throw fail("Expected child OBJECT or MATERIAL") }
                }
                return
            default: throw fail("Unsupported object record: \(r[0])")
            }
        }
    }
    func readTexture(_ r: [String]) throws {
        guard (2...3).contains(r.count) else { throw fail("Invalid texture record") }
        let layer: Int
        switch r.count==2 ? "base":r[2] { case "base": layer=0;case "tiled":layer=1;case "skids":layer=2;case "shad":layer=3;default:throw fail("Unsupported texture layer") }
        for i in layer..<4 { texture[i]=nil }
        if layer==0 { mapCount=1;mapLevel=1;texture[0]=r[1] }
        else if !r[1].contains("empty_texture_no_mapping") { mapCount += 1;mapLevel |= 1<<layer;texture[layer]=r[1] }
        if let name=texture[layer] {
            guard !name.isEmpty,!name.hasPrefix("/"),!name.contains("\\"),!name.split(separator:"/",omittingEmptySubsequences:false).contains(".."),!name.contains(":") else { throw fail("Unsafe texture path") }
        }
    }
    func readVertices(_ n: Int) throws {
        guard n<=limits.vertices-vertexTotal else { throw fail("Total vertex limit exceeded") };vertexTotal += n
        vertices=[];normals=[];uv=Array(repeating:Array(repeating:0,count:n*2),count:4);written=Array(repeating:false,count:n);indices=[];strips=[]
        var format: Int?
        for _ in 0..<n {
            let r=try need();guard r.count==3 || r.count==6 else { throw fail("Invalid vertex") }
            if let format,format != r.count { throw fail("Mixed normal presence has undefined original storage") };format=r.count
            let v=try r.map(number);vertices += [v[0],-v[2],v[1]]
            bounds.minimumX=min(bounds.minimumX,v[0]);bounds.maximumX=max(bounds.maximumX,v[0])
            bounds.minimumY=min(bounds.minimumY,-v[2]);bounds.maximumY=max(bounds.maximumY,-v[2])
            if v.count==6 { normals += [v[3],-v[5],v[4]] };usesNormals=v.count==6
        }
    }
    func surface(parent: Int) throws {
        let r=try need();guard r.count==2,r[0]=="SURF" else { throw fail("Expected SURF") };flags=try integer(r[1])
        while true {
            let r=try need()
            if r[0]=="mat" { guard r.count==2 else { throw fail("Invalid material index") };let i=try integer(r[1]);guard materials.indices.contains(i) else { throw fail("Material index out of range") };material=i }
            else if r[0]=="refs" { try references(count(r,maximum:limits.references),parent:parent);return }
            else { throw fail("Unsupported surface record") }
        }
    }
    func references(_ n: Int,parent: Int) throws {
        guard n<=limits.references-referenceTotal else { throw fail("Total reference limit exceeded") };referenceTotal += n
        if n==0 { return }
        var points: [Float]=[],normalValues: [Float]=[],coords=Array(repeating:[Float](),count:4)
        let originalMaps=mapCount
        for _ in 0..<n {
            let r=try need();guard [3,5,7,9].contains(r.count) else { throw fail("Invalid reference") }
            let index=try integer(r[0]);guard index>=0,index<vertices.count/3 else { throw fail("Vertex index out of range") }
            var values=try Array(r.dropFirst()).map(number);values += Array(repeating:0,count:8-values.count)
            values[0] *= repeatUV[0];values[1] *= repeatUV[1];values[0] += offsetUV[0];values[1] += offsetUV[1]
            guard values.allSatisfy(\.isFinite) else { throw fail("UV transform overflow") }
            for layer in 0..<4 { uv[layer][index*2]=values[layer*2];uv[layer][index*2+1]=values[layer*2+1];if layer==0 || originalMaps>layer { coords[layer] += values[(layer*2)...(layer*2+1)] } }
            points += vertices[(index*3)...(index*3+2)];if usesNormals { normalValues += normals[(index*3)...(index*3+2)] }
            indices.append(UInt32(UInt16(truncatingIfNeeded:index)));written[index]=true
        }
        if !usesNormals { normalValues=try normal(points) }
        let type=flags & 15;guard (0...4).contains(type) else { throw fail("Unsupported primitive") }
        if type==4 { usesStrip=true }
        mapCount=min(mapCount,units)
        if car { mapLevel = -1;if originalMaps>1 && units>1 { mapLevel = -2;mapCount=2 };if originalMaps>2 && units>2 { mapLevel = -3;mapCount=3 } }
        if usesStrip { strips.append(UInt32(UInt16(truncatingIfNeeded:n))) }
        else {
            let primitive=[6,2,3,4,5][type]
            try emit(parent:parent,mesh:ACMesh(primitive:primitive,vertices:points,normals:normalValues,uv:coords,colors:[],indices:[],strips:[],indexed:false,cull:flags & 32==0,mapCount:mapCount,mapLevel:mapLevel,states:[]))
        }
    }
    func normal(_ p: [Float]) throws -> [Float] {
        if p.count<9 { return [0,0,1] }
        let a=(0..<3).map { p[3+$0]-p[$0] },b=(0..<3).map { p[6+$0]-p[$0] }
        let v=[a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]]
        let length=sqrt(v[0]*v[0]+v[1]*v[1]+v[2]*v[2]);guard length>0,length.isFinite else { throw fail("Degenerate face has undefined original normal") }
        let scale: Float=1/length;return v.map { $0*scale }
    }
    func emitIndexed(parent: Int) throws {
        guard written.allSatisfy({ $0 }) else { throw fail("Indexed vertex has undefined original UV storage") }
        mapCount=min(mapCount,units)
        if car { mapLevel = -1;if units>2 { mapLevel = -3;mapCount=3 } }
        try emit(parent:parent,mesh:ACMesh(primitive:5,vertices:vertices,normals:usesNormals ? normals:[],uv:uv,colors:[],indices:indices,strips:strips,indexed:true,cull:flags & 32==0,mapCount:mapCount,mapLevel:mapLevel,states:[]))
    }
    func emit(parent: Int,mesh: ACMesh) throws {
        guard let material else { throw fail("Geometry has no material") }
        let m=materials[material];var mesh=mesh;mesh.colors=m.color
        var bits: UInt32=6
        if window { bits |= 1|32 } else if car { bits |= 1 } else if m.color[3]<0.99 { bits |= 1|16|32 }
        var clamp: Float=0
        let cutout=texture[0].map { $0.contains("tree") || $0.contains("trans-") || $0.contains("arbor") } ?? false
        if texture[0] != nil { bits |= 8;if cutout { bits |= 1|16;clamp=0.65 } } else { bits &= ~1 }
        mesh.states=[ACRenderState(material:m.values,texture:texture[0],flags:bits,alphaClamp:clamp,alphaCare:ACRenderState.loaderAlphaCare(flags:bits,layer:0))]
        for layer in 1..<4 {
            mesh.states.append(mapCount>layer && texture[layer] != nil ? ACRenderState(material:Array(repeating:0,count:13),texture:texture[layer],flags:cutout ? 25:8,alphaClamp:cutout ? 0.7:0,alphaCare:cutout ? 3:0):nil)
        }
        _ = try append(.init(parent:parent,kind:2,name:"",matrix:[],mesh:mesh))
    }
}
