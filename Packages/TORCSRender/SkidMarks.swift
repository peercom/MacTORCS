// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Rubber laid on the road by skidding tyres: a ring buffer of quads drawn
/// as a darkening decal over the opaque scene.
///
/// The same published skid signal that throws smoke lays marks. Each wheel
/// that skids extends its own strip by one quad whenever its contact patch
/// has moved far enough since the last one; a wheel that stops skidding
/// ends its strip, and the next skid starts a new one. The oldest quads are
/// overwritten when the ring is full, which is how marks eventually vanish.
public final class SkidMarks {
    public struct Source: Sendable, Equatable {
        /// Which tyre: strips are continued per key across frames.
        public var key: Int
        /// World position of the contact patch, on the surface.
        public var position: SIMD3<Float>
        /// Unit vector across the tyre, along the axle.
        public var lateral: SIMD3<Float>
        /// Tread width in metres.
        public var width: Float
        /// 0–1, darkness of the mark.
        public var intensity: Float
        public init(key: Int, position: SIMD3<Float>, lateral: SIMD3<Float>, width: Float, intensity: Float) {
            self.key = key; self.position = position; self.lateral = lateral; self.width = width; self.intensity = intensity
        }
    }

    /// Mirrors `SkidVertex` in `SkidMarks.metal`.
    public struct Vertex: Sendable, Equatable {
        /// xyz world position, w darkness.
        public var positionIntensity: SIMD4<Float>
        /// x metres along the strip, y 0–1 across it, zw unused.
        public var uv: SIMD4<Float>
    }

    struct Strip {
        var position: SIMD3<Float>
        var left: SIMD3<Float>, right: SIMD3<Float>
        var along: Float
        var intensity: Float
    }

    /// Minimum contact travel before another quad is laid. Shorter makes
    /// smoother curves and fills the ring faster.
    public var segmentLength: Float = 0.25
    /// Lift above the surface so the decal wins the depth test against the
    /// road it lies on, in metres.
    public var lift: Float = 0.015

    public let capacity: Int
    public var sources: [Source] = []
    public private(set) var quadCount = 0
    private var next = 0
    private var vertices: [Vertex]
    private var strips: [Int: Strip] = [:]
    private var dirty = false

    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    private(set) var buffer: MTLBuffer?

    public init(device: MTLDevice, capacity: Int = 4096) throws {
        self.capacity = max(capacity, 1)
        vertices = Array(repeating: Vertex(positionIntensity: .zero, uv: .zero), count: self.capacity * 6)
        var made: [MTLBuffer] = []
        for _ in 0 ..< 3 {
            guard let buffer = device.makeBuffer(length: self.capacity * 6 * MemoryLayout<Vertex>.stride,
                                                 options: .storageModeShared) else {
                throw RenderError.unavailable("Could not allocate the skid mark buffer")
            }
            made.append(buffer)
        }
        buffers = made
    }

    /// Lays quads for this frame's sources and clears them.
    public func advance() {
        var seen = Set<Int>()
        for source in sources where source.intensity > 0.02 && source.width > 0 {
            seen.insert(source.key)
            let half = simd_normalize(source.lateral) * (source.width / 2)
            let position = source.position + SIMD3(0, 0, lift)
            let left = position - half, right = position + half
            guard var strip = strips[source.key] else {
                strips[source.key] = Strip(position: position, left: left, right: right, along: 0, intensity: source.intensity)
                continue
            }
            let travel = simd_length(position - strip.position)
            guard travel >= segmentLength else { continue }
            let along = strip.along + travel
            append(a: strip.left, b: strip.right, c: right, d: left,
                   fromAlong: strip.along, toAlong: along,
                   fromIntensity: strip.intensity, toIntensity: source.intensity)
            strip = Strip(position: position, left: left, right: right, along: along, intensity: source.intensity)
            strips[source.key] = strip
        }
        // A tyre that stopped skidding ends its strip.
        for key in strips.keys where !seen.contains(key) { strips[key] = nil }
        sources.removeAll(keepingCapacity: true)
        if dirty { upload() }
    }

    private func append(a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, d: SIMD3<Float>,
                        fromAlong: Float, toAlong: Float, fromIntensity: Float, toIntensity: Float) {
        let base = next * 6
        let v0 = Vertex(positionIntensity: SIMD4(a, fromIntensity), uv: SIMD4(fromAlong, 0, 0, 0))
        let v1 = Vertex(positionIntensity: SIMD4(b, fromIntensity), uv: SIMD4(fromAlong, 1, 0, 0))
        let v2 = Vertex(positionIntensity: SIMD4(c, toIntensity), uv: SIMD4(toAlong, 1, 0, 0))
        let v3 = Vertex(positionIntensity: SIMD4(d, toIntensity), uv: SIMD4(toAlong, 0, 0, 0))
        // Two triangles, no culling in the draw so the winding is free.
        vertices[base] = v0; vertices[base + 1] = v1; vertices[base + 2] = v2
        vertices[base + 3] = v0; vertices[base + 4] = v2; vertices[base + 5] = v3
        next = (next + 1) % capacity
        quadCount = min(quadCount + 1, capacity)
        dirty = true
    }

    private func upload() {
        bufferIndex = (bufferIndex + 1) % buffers.count
        let target = buffers[bufferIndex]
        let count = quadCount * 6
        vertices.withUnsafeBytes { raw in
            target.contents().copyMemory(from: raw.baseAddress!, byteCount: count * MemoryLayout<Vertex>.stride)
        }
        buffer = target
        dirty = false
    }

    /// The quads laid so far, oldest first once the ring has wrapped.
    public var laid: [Vertex] { Array(vertices[0 ..< quadCount * 6]) }

    public func reset() {
        quadCount = 0; next = 0; strips.removeAll(); sources.removeAll(); buffer = nil; dirty = false
    }
}

/// Draws `SkidMarks` as a multiplicative decal: the road under a mark gets
/// darker, nothing else changes.
public final class SkidMarkRenderer {
    private let pipeline: MTLRenderPipelineState
    private let paintPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    public private(set) var lastDrawnQuads = 0
    public private(set) var lastPaintedBoxes = 0

    public init(device: MTLDevice, library: MTLLibrary, archive: PipelineArchive? = nil) throws {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "skidMarks"
        descriptor.vertexFunction = library.makeFunction(name: "skidVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "skidFragment")
        let colour = descriptor.colorAttachments[0]!
        colour.pixelFormat = FrameTargets.colourFormat
        colour.isBlendingEnabled = true
        // Darken: destination × (1 − source). The fragment emits darkness.
        colour.sourceRGBBlendFactor = .zero
        colour.destinationRGBBlendFactor = .oneMinusSourceColor
        colour.sourceAlphaBlendFactor = .zero
        colour.destinationAlphaBlendFactor = .one
        descriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
        pipeline = try PipelineArchive.make(descriptor, device: device, archive: archive)

        // Paint: straight alpha over the road, same vertex layout.
        let paintDescriptor = MTLRenderPipelineDescriptor()
        paintDescriptor.label = "roadPaint"
        paintDescriptor.vertexFunction = library.makeFunction(name: "skidVertex")
        paintDescriptor.fragmentFunction = library.makeFunction(name: "roadPaintFragment")
        let paint = paintDescriptor.colorAttachments[0]!
        paint.pixelFormat = FrameTargets.colourFormat
        paint.isBlendingEnabled = true
        paint.sourceRGBBlendFactor = .sourceAlpha
        paint.destinationRGBBlendFactor = .oneMinusSourceAlpha
        paint.sourceAlphaBlendFactor = .zero
        paint.destinationAlphaBlendFactor = .one
        paintDescriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
        paintPipeline = try PipelineArchive.make(paintDescriptor, device: device, archive: archive)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .greaterEqual
        depth.isDepthWriteEnabled = false
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw RenderError.unavailable("Could not create the skid mark depth state")
        }
        self.depthState = depthState
    }

    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       marks: SkidMarks, frame: inout FrameUniforms, timer: PassTimer? = nil) {
        lastDrawnQuads = 0
        guard let buffer = marks.buffer, marks.quadCount > 0 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.colour
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store
        timer?.attach(pass, "Skid marks")
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Skid marks"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: marks.quadCount * 6)
        encoder.endEncoding()
        lastDrawnQuads = marks.quadCount
    }

    /// Draws the painted boxes; each box's length and width ride in its
    /// vertices, so one draw covers boxes of any size.
    public func encodePaint(into commands: MTLCommandBuffer, targets: FrameTargets,
                            paint: RoadPaint, frame: inout FrameUniforms, lineWidth: Float = 0.12,
                            timer: PassTimer? = nil) {
        lastPaintedBoxes = 0
        guard let buffer = paint.buffer, paint.quadCount > 0 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = targets.colour
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = targets.depth
        pass.depthAttachment.loadAction = .load
        pass.depthAttachment.storeAction = .store
        timer?.attach(pass, "Road paint")
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Road paint"
        encoder.setRenderPipelineState(paintPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        // One draw per box so the fragment sees that box's size.
        for (i, box) in paint.boxes.enumerated() {
            var parameters = SIMD4<Float>(lineWidth, 0.9, box.length, box.width)
            encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
        }
        encoder.endEncoding()
        lastPaintedBoxes = paint.quadCount
    }
}
