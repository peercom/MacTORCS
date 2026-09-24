// SPDX-License-Identifier: GPL-2.0-only
import Metal
import simd

@MainActor final class VegetationRenderState {
    struct Instance { var model,normal:simd_float4x4;var tint:SIMD4<Float> }
    struct View { var model,normal,viewProjection,view:simd_float4x4 }
    struct BufferMesh { let vertices,indices:MTLBuffer;let count:Int }
    let forest:VegetationForest,resource:Int
    private let meshes:[BufferMesh],instances:MTLBuffer,texture:MTLTexture
    private let pipelines:[Int:MTLRenderPipelineState]
    init(forest:VegetationForest,resource:Int,texture:MTLTexture,device:MTLDevice,library:MTLLibrary) throws {
        self.forest=forest;self.resource=resource;self.texture=texture
        meshes=try forest.meshes.map { mesh in
            guard let vertices=device.makeBuffer(bytes:mesh.vertices,length:mesh.vertices.count*MemoryLayout<SceneVertex>.stride),
                  let indices=device.makeBuffer(bytes:mesh.indices,length:mesh.indices.count*MemoryLayout<UInt32>.stride) else { throw RendererError.unavailable("Vegetation geometry allocation failed") }
            return BufferMesh(vertices:vertices,indices:indices,count:mesh.indices.count)
        }
        let values=forest.placements.enumerated().map { i,p in Instance(model:p.transform,normal:p.transform.inverse.transpose,tint:SIMD4(repeating:0.96+Float(i%7)*0.012)) }
        guard !values.isEmpty,let buffer=device.makeBuffer(bytes:values,length:values.count*MemoryLayout<Instance>.stride) else { throw RendererError.unavailable("Vegetation placements unavailable") }
        instances=buffer
        var variants:[Int:MTLRenderPipelineState]=[:]
        for samples in [1,4] where device.supportsTextureSampleCount(samples) {
            let p=MTLRenderPipelineDescriptor();p.vertexFunction=library.makeFunction(name:"vegetationVertex");p.fragmentFunction=library.makeFunction(name:"vegetationFragment")
            p.colorAttachments[0].pixelFormat = .rgba8Unorm;p.depthAttachmentPixelFormat = .depth32Float
            p.rasterSampleCount=samples
            variants[samples]=try device.makeRenderPipelineState(descriptor:p)
        }
        pipelines=variants
    }
    func selections(camera:SceneCamera,pixelHeight:Float,transform:simd_float4x4) -> [Int] {
        forest.placements.indices.map { forest.detail(for:$0,camera:camera,pixelHeight:pixelHeight,transform:transform) }
    }
    func encode(_ encoder:MTLRenderCommandEncoder,selection:[Int],camera:SceneCamera,aspect:Float,transform:simd_float4x4,samples:Int) -> (draws:Int,triangles:Int) {
        var groups=Array(repeating:[UInt32](),count:forest.meshes.count)
        for (i,detail) in selection.enumerated() where detail<2 {
            let p=forest.placements[i];groups[p.family*6+p.variant*2+detail].append(UInt32(i))
        }
        encoder.setRenderPipelineState(pipelines[samples]!)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(instances,offset:0,index:1)
        var view=View(model:transform,normal:transform.inverse.transpose,viewProjection:camera.viewProjection(aspect:aspect),view:camera.view())
        encoder.setVertexBytes(&view,length:MemoryLayout<View>.stride,index:3)
        encoder.setFragmentTexture(texture,index:0)
        var draws=0,triangles=0
        for (index,ids) in groups.enumerated() where !ids.isEmpty {
            let mesh=meshes[index];encoder.setVertexBuffer(mesh.vertices,offset:0,index:0)
            // setVertexBytes has a 4 KiB bound. Chunk larger imported forests.
            for start in stride(from:0,to:ids.count,by:512) {
                let chunk=Array(ids[start..<min(ids.count,start+512)])
                encoder.setVertexBytes(chunk,length:chunk.count*MemoryLayout<UInt32>.stride,index:4)
                encoder.drawIndexedPrimitives(type:.triangle,indexCount:mesh.count,indexType:.uint32,indexBuffer:mesh.indices,indexBufferOffset:0,instanceCount:chunk.count)
                draws += 1;triangles += mesh.count/3*chunk.count
            }
        }
        return (draws,triangles)
    }
}
