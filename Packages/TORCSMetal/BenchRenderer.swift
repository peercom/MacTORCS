// SPDX-License-Identifier: GPL-2.0-only
import MetalKit
import simd
import TORCSCore
import os

public enum RenderStyle: String, CaseIterable, Sendable { case classic, enhanced }

/// Renders immutable component snapshots; never advances simulation.
@MainActor public final class BenchRenderer: NSObject, MTKViewDelegate {
    struct Vertex { var position: SIMD3<Float>; var normal: SIMD3<Float> }
    struct Uniforms { var model: simd_float4x4; var viewProjection: simd_float4x4; var color: SIMD4<Float> }
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let depth: MTLDepthStencilState
    let vertices: MTLBuffer
    let vertexCount: Int
    public var snapshot: () -> (previous: SimulationSnapshot, current: SimulationSnapshot, alpha: Float)
    public private(set) var renderedFrames: UInt64 = 0
    private let signposter = OSSignposter(subsystem: "org.torcs.mac", category: "Rendering")

    public init(view: MTKView, snapshot: @escaping () -> (SimulationSnapshot, SimulationSnapshot, Float)) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RendererError.unavailable("A Metal device and command queue are required")
        }
        self.device = device; self.queue = queue; self.snapshot = snapshot
        view.device = device; view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColor(red: 0.025, green: 0.035, blue: 0.05, alpha: 1)
        // SPM's generated accessor searches beside the main bundle, not inside
        // Contents/Resources. Resolve packaged app resources explicitly so the
        // distributable cannot accidentally fall back to this machine's .build.
        let shaderBundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "TORCSMac_TORCSMetal", withExtension: "bundle"),
                  let bundled = Bundle(url: url) else {
                throw RendererError.unavailable("Packaged Metal resource bundle missing")
            }
            shaderBundle = bundled
        } else {
            shaderBundle = .module
        }
        guard let shaderURL = shaderBundle.url(forResource: "Scene", withExtension: "metal") else {
            throw RendererError.unavailable("Scene.metal resource missing")
        }
        let library = try device.makeLibrary(source: String(contentsOf: shaderURL, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less; depthDescriptor.isDepthWriteEnabled = true
        guard let depth = device.makeDepthStencilState(descriptor: depthDescriptor) else { throw RendererError.unavailable("Depth state creation failed") }
        self.depth = depth
        let mesh = Self.cube()
        guard let vertices = device.makeBuffer(bytes: mesh, length: mesh.count * MemoryLayout<Vertex>.stride, options: .storageModeShared) else {
            throw RendererError.unavailable("Vertex buffer allocation failed")
        }
        self.vertices = vertices; vertexCount = mesh.count
        super.init()
        view.delegate = self
    }
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    public func draw(in view: MTKView) {
        guard view.drawableSize.width > 0, view.drawableSize.height > 0,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { return }
        let interval = signposter.beginInterval("Draw preparation")
        encode(pass: pass, command: command, size: view.drawableSize)
        signposter.endInterval("Draw preparation", interval)
        command.present(drawable); command.commit(); renderedFrames += 1
    }
    func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize) {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        let aspect = Float(size.width / size.height)
        let vp = Self.perspective(aspect: aspect) * Self.lookAt(eye: SIMD3(2.6, -4, 2.8), target: SIMD3(0, 0, 0.8))
        let s = snapshot()
        let travel = s.previous.suspensionTravel + (s.current.suspensionTravel - s.previous.suspensionTravel) * s.alpha
        let height = 0.7 + travel * 2
        func box(_ p: SIMD3<Float>, _ scale: SIMD3<Float>, _ color: SIMD4<Float>) {
            var model = matrix_identity_float4x4
            model.columns.0.x = scale.x; model.columns.1.y = scale.y; model.columns.2.z = scale.z
            model.columns.3 = SIMD4(p, 1)
            var uniform = Uniforms(model: model, viewProjection: vp, color: color)
            encoder.setVertexBytes(&uniform, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        box(SIMD3(0, 0, -0.05), SIMD3(3.4, 2.4, 0.1), SIMD4(0.13, 0.18, 0.23, 1))
        box(SIMD3(0, 0, 0.16), SIMD3(1, 0.8, 0.22), SIMD4(0.3, 0.36, 0.42, 1))
        box(SIMD3(0, 0, height * 0.5), SIMD3(0.1, 0.1, height), SIMD4(0.65, 0.7, 0.76, 1))
        for i in 0..<12 {
            let a = Float(i) / 12 * Float.pi * 6
            box(SIMD3(0.17 * cos(a), 0.17 * sin(a), 0.25 + Float(i) / 12 * (height - 0.3)),
                SIMD3(0.12, 0.12, 0.035), SIMD4(0.95, 0.46, 0.12, 1))
        }
        box(SIMD3(0, 0, height), SIMD3(0.8, 0.65, 0.12), SIMD4(0.12, 0.62, 0.66, 1))
        encoder.endEncoding()
    }

    /// Real GPU smoke check: render into an offscreen color/depth pair and read pixels.
    public func offscreenChecksum() throws -> UInt64 {
        let colorDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: 128, height: 128, mipmapped: false)
        colorDesc.usage = [.renderTarget]; colorDesc.storageMode = .shared
        let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 128, height: 128, mipmapped: false)
        depthDesc.usage = [.renderTarget]; depthDesc.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDesc), let depth = device.makeTexture(descriptor: depthDesc),
              let command = queue.makeCommandBuffer() else { throw RendererError.unavailable("Offscreen allocation failed") }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.clearDepth = 1
        encode(pass: pass, command: command, size: CGSize(width: 128, height: 128))
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: 128 * 128 * 4)
        color.getBytes(&bytes, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        let rgb = bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        guard rgb.contains(where: { $0 > 0 }) else { throw RendererError.unavailable("GPU produced an empty image") }
        return rgb.reduce(UInt64(0)) { $0 &+ UInt64($1) }
    }
    static func cube() -> [Vertex] {
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1,0,0),SIMD3(0,1,0),SIMD3(0,0,1)), (SIMD3(-1,0,0),SIMD3(0,-1,0),SIMD3(0,0,1)),
            (SIMD3(0,1,0),SIMD3(-1,0,0),SIMD3(0,0,1)), (SIMD3(0,-1,0),SIMD3(1,0,0),SIMD3(0,0,1)),
            (SIMD3(0,0,1),SIMD3(1,0,0),SIMD3(0,1,0)), (SIMD3(0,0,-1),SIMD3(-1,0,0),SIMD3(0,1,0))]
        return faces.flatMap { n, u, v in
            let p = [n-u-v, n+u-v, n+u+v, n-u+v].map { $0 * 0.5 }
            return [0,1,2,0,2,3].map { Vertex(position: p[$0], normal: n) }
        }
    }
    static func perspective(aspect: Float) -> simd_float4x4 {
        let y: Float = 1 / tan(Float.pi / 7), near: Float = 0.1, far: Float = 100
        return simd_float4x4(SIMD4(y/aspect,0,0,0), SIMD4(0,y,0,0), SIMD4(0,0,far/(near-far),-1), SIMD4(0,0,near*far/(near-far),0))
    }
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let z = normalize(eye-target), x = normalize(cross(SIMD3<Float>(0,0,1),z)), y = cross(z,x)
        return simd_float4x4(SIMD4(x.x,y.x,z.x,0), SIMD4(x.y,y.y,z.y,0), SIMD4(x.z,y.z,z.z,0), SIMD4(-dot(x,eye),-dot(y,eye),-dot(z,eye),1))
    }
}
public enum RendererError: Error { case unavailable(String) }
