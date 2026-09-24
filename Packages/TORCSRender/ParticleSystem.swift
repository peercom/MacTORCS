// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Tyre smoke and dust: camera-facing puffs simulated on the CPU and drawn in
/// one instanced pass after the opaque scene.
///
/// A few thousand particles at most, stepped once per frame, is cheaper on
/// the CPU than the bookkeeping a GPU simulation would need to get the same
/// result back for tests. The draw reads the opaque depth so puffs fade into
/// the ground and the car instead of cutting through them, and it writes
/// neither depth nor velocity: smoke is drawn into the colour target only.
///
/// Emission is described by sources — a wheel's contact patch with a skid
/// intensity, or a wheel on a loose surface — supplied by whoever knows the
/// simulation; the renderer never sees the physics.
public final class ParticleSystem {
    public enum Kind: Int, Sendable {
        case smoke = 0
        case dust = 1
        /// Water thrown up by a tyre on a wet road: short-lived white mist.
        case spray = 2
    }

    /// One emitter for one frame.
    public struct Source: Sendable, Equatable {
        public var kind: Kind
        /// World position of the contact patch.
        public var position: SIMD3<Float>
        /// World velocity of the surface throwing the particles: the wheel
        /// hub's, so smoke trails behind a moving car.
        public var velocity: SIMD3<Float>
        /// 0–1; scales the emission rate and the initial opacity.
        public var intensity: Float
        public init(kind: Kind, position: SIMD3<Float>, velocity: SIMD3<Float>, intensity: Float) {
            self.kind = kind; self.position = position; self.velocity = velocity; self.intensity = intensity
        }
    }

    /// Mirrors `Particle` in `Particles.metal`: what the draw reads.
    public struct Particle: Sendable, Equatable {
        /// xyz world position, w size in metres (the billboard's half-width).
        public var positionSize: SIMD4<Float>
        /// rgb linear tint, a opacity.
        public var colourAlpha: SIMD4<Float>
        /// x rotation in radians, y age fraction 0–1, z kind, w seed.
        public var attributes: SIMD4<Float>
    }

    /// The simulation side of a particle, kept off the GPU.
    struct Live {
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var age: Float
        var life: Float
        var size: Float
        var growth: Float
        var opacity: Float
        var rotation: Float
        var spin: Float
        var kind: Kind
        var seed: Float
    }

    public struct Parameters: Sendable, Equatable {
        /// Particles per second at intensity 1 from one source.
        public var smokeRate: Float = 48
        public var dustRate: Float = 30
        public var smokeLife: ClosedRange<Float> = 0.9 ... 1.7
        public var dustLife: ClosedRange<Float> = 1.5 ... 3.0
        /// Initial half-width in metres, and how fast it grows per second.
        public var smokeSize: Float = 0.16, smokeGrowth: Float = 0.55
        public var dustSize: Float = 0.22, dustGrowth: Float = 0.45
        /// Fraction of the source velocity a particle keeps when thrown.
        public var inheritance: Float = 0.15
        /// Per-second velocity retention: smoke stalls quickly in air.
        public var drag: Float = 0.08
        public var smokeRise: Float = 0.5
        public var dustSettle: Float = -0.6
        public var smokeColour = SIMD3<Float>(0.82, 0.82, 0.84)
        public var dustColour = SIMD3<Float>(0.62, 0.53, 0.38)
        public var sprayRate: Float = 70
        public var sprayLife: ClosedRange<Float> = 0.35 ... 0.8
        public var spraySize: Float = 0.14, sprayGrowth: Float = 0.8
        public var sprayColour = SIMD3<Float>(0.78, 0.8, 0.82)
        public init() {}
    }

    public var parameters = Parameters()
    /// Emitters for the next `advance`. Cleared after each step so a source
    /// that stops being supplied stops emitting.
    public var sources: [Source] = []
    public let capacity: Int
    private(set) var live: [Live] = []
    public var count: Int { live.count }

    private let device: MTLDevice
    private let buffers: [MTLBuffer]
    private var bufferIndex = 0
    /// Bytes of the current frame's particles, uploaded by `advance`.
    private(set) var buffer: MTLBuffer?
    private var emissionCredit: [Int: Float] = [:]
    private var random: SplitMix

    public init(device: MTLDevice, capacity: Int = 4096, seed: UInt64 = 0x5EED) throws {
        self.device = device
        self.capacity = max(capacity, 1)
        random = SplitMix(seed: seed)
        var made: [MTLBuffer] = []
        for _ in 0 ..< 3 {
            guard let buffer = device.makeBuffer(length: self.capacity * MemoryLayout<Particle>.stride,
                                                 options: .storageModeShared) else {
                throw RenderError.unavailable("Could not allocate the particle buffer")
            }
            made.append(buffer)
        }
        buffers = made
        live.reserveCapacity(self.capacity)
    }

    /// Steps every particle by `deltaTime`, emits from `sources`, and uploads
    /// the result. Deterministic for a given seed and sequence of calls.
    public func advance(by deltaTime: Float) {
        let dt = min(max(deltaTime, 0), 0.1)
        let p = parameters

        // Age, move, retire.
        var kept: [Live] = []
        kept.reserveCapacity(live.count)
        for var particle in live {
            particle.age += dt
            if particle.age >= particle.life { continue }
            let retention = pow(p.drag, dt)
            particle.velocity *= retention
            particle.velocity.z += (particle.kind == .smoke ? p.smokeRise : particle.kind == .spray ? -2.5 : p.dustSettle) * dt
            particle.position += particle.velocity * dt
            particle.size += particle.growth * dt
            particle.rotation += particle.spin * dt
            kept.append(particle)
        }
        live = kept

        // Emit. Fractional credit accumulates per source slot so low rates
        // still emit, and a source that vanishes takes its credit with it.
        var credit: [Int: Float] = [:]
        for (index, source) in sources.enumerated() where source.intensity > 0.01 {
            let rate = (source.kind == .smoke ? p.smokeRate : source.kind == .spray ? p.sprayRate : p.dustRate) * min(source.intensity, 1)
            var due = (emissionCredit[index] ?? 0) + rate * dt
            while due >= 1, live.count < capacity {
                due -= 1
                live.append(spawn(source, dt: dt))
            }
            credit[index] = due
        }
        emissionCredit = credit
        sources.removeAll(keepingCapacity: true)

        upload()
    }

    private func spawn(_ source: Source, dt: Float) -> Live {
        let p = parameters
        let kind = source.kind
        // Thrown from a disc the size of the contact patch, back along the
        // motion and up, with a little scatter so a stream is a cloud. Spray
        // is flung: it keeps more of the wheel's speed and goes higher.
        let scatter = SIMD3(random.symmetric() * 0.6, random.symmetric() * 0.6, random.unit() * 0.5 + 0.3)
        let offset = SIMD3(random.symmetric() * 0.15, random.symmetric() * 0.15, 0.03)
        let inherited = source.velocity * (kind == .spray ? 0.6 : p.inheritance)
        let velocity = inherited + scatter * (kind == .smoke ? 1.2 : kind == .spray ? 3.0 : 1.6)
        let life = kind == .smoke ? p.smokeLife : kind == .spray ? p.sprayLife : p.dustLife
        // Sub-frame spawn: distribute along the frame so a fast car leaves
        // a trail rather than clumps.
        let lead = random.unit() * dt
        return Live(position: source.position + offset - source.velocity * lead,
                    velocity: velocity, age: lead, life: life.lowerBound + random.unit() * (life.upperBound - life.lowerBound),
                    size: kind == .smoke ? p.smokeSize : kind == .spray ? p.spraySize : p.dustSize,
                    growth: kind == .smoke ? p.smokeGrowth : kind == .spray ? p.sprayGrowth : p.dustGrowth,
                    opacity: min(source.intensity, 1) * (kind == .smoke ? 0.45 : kind == .spray ? 0.3 : 0.3),
                    rotation: random.unit() * 2 * .pi, spin: random.symmetric() * 0.8,
                    kind: kind, seed: random.unit())
    }

    /// Packs the live particles for the draw.
    private func upload() {
        guard !live.isEmpty else { buffer = nil; return }
        bufferIndex = (bufferIndex + 1) % buffers.count
        let target = buffers[bufferIndex]
        let pointer = target.contents().bindMemory(to: Particle.self, capacity: capacity)
        for (i, particle) in live.enumerated() {
            pointer[i] = Self.packed(particle, parameters: parameters)
        }
        buffer = target
    }

    static func packed(_ particle: Live, parameters p: Parameters) -> Particle {
        let t = particle.age / max(particle.life, 1e-3)
        // In fast, out slow: a puff appears in a tenth of its life and thins
        // over the rest.
        let fade = min(t / 0.1, 1) * (1 - t) * (1 - t)
        let colour = particle.kind == .smoke ? p.smokeColour : particle.kind == .spray ? p.sprayColour : p.dustColour
        return Particle(positionSize: SIMD4(particle.position, particle.size),
                        colourAlpha: SIMD4(colour, particle.opacity * fade),
                        attributes: SIMD4(particle.rotation, t, Float(particle.kind.rawValue), particle.seed))
    }

    /// Places one particle directly, at rest, for tests and diagnostics.
    /// Takes effect at the next `advance`.
    public func place(_ kind: Kind, at position: SIMD3<Float>, size: Float, opacity: Float = 0.6, life: Float = 10) {
        guard live.count < capacity else { return }
        live.append(Live(position: position, velocity: .zero, age: life * 0.15, life: life, size: size, growth: 0,
                         opacity: opacity, rotation: 0, spin: 0, kind: kind, seed: 0.5))
    }

    /// The packed particles of the last `advance`, for tests.
    public var packed: [Particle] { live.map { Self.packed($0, parameters: parameters) } }

    public func reset() {
        live.removeAll(keepingCapacity: true)
        emissionCredit.removeAll()
        sources.removeAll()
        buffer = nil
    }

    /// SplitMix64: tiny, seedable, and the same on every run.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        /// 0 ..< 1
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
        /// -1 ..< 1
        mutating func symmetric() -> Float { unit() * 2 - 1 }
    }
}

/// Draws a `ParticleSystem`: one instanced quad per particle, depth-tested
/// by hand against the opaque depth so it can also fade near it.
public final class ParticleRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let pointSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState
    /// Particles are drawn at half the render resolution. Overdraw is what
    /// a cloud of overlapping soft quads costs, and a quarter of the pixels
    /// is a quarter of it; smoke has no edge that half resolution loses.
    private var target: MTLTexture?
    public private(set) var lastDrawnCount = 0

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "particles"
        descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
        let colour = descriptor.colorAttachments[0]!
        colour.pixelFormat = FrameTargets.colourFormat
        colour.isBlendingEnabled = true
        // Premultiplied under, accumulating coverage in alpha: the composite
        // then blends the whole cloud over the scene in one step.
        colour.sourceRGBBlendFactor = .one
        colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
        colour.sourceAlphaBlendFactor = .one
        colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.label = "particleComposite"
        compositeDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        compositeDescriptor.fragmentFunction = library.makeFunction(name: "particleCompositeFragment")
        let over = compositeDescriptor.colorAttachments[0]!
        over.pixelFormat = FrameTargets.colourFormat
        over.isBlendingEnabled = true
        over.sourceRGBBlendFactor = .one
        over.destinationRGBBlendFactor = .oneMinusSourceAlpha
        over.sourceAlphaBlendFactor = .zero
        over.destinationAlphaBlendFactor = .one
        composite = try device.makeRenderPipelineState(descriptor: compositeDescriptor)

        func sampler(_ filter: MTLSamplerMinMagFilter) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter; d.magFilter = filter
            d.sAddressMode = .clampToEdge; d.tAddressMode = .clampToEdge
            guard let s = device.makeSamplerState(descriptor: d) else {
                throw RenderError.unavailable("Could not create the particle sampler")
            }
            return s
        }
        pointSampler = try sampler(.nearest)
        linearSampler = try sampler(.linear)
    }

    private func target(for targets: FrameTargets) -> MTLTexture? {
        let width = max(1, targets.renderWidth / 2), height = max(1, targets.renderHeight / 2)
        if let target, target.width == width, target.height == height { return target }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameTargets.colourFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        target = device.makeTexture(descriptor: descriptor)
        return target
    }

    /// Draws into `targets.colour` over the opaque scene. `frame` must be the
    /// scene pass's uniforms so the billboards land where the geometry did.
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       system: ParticleSystem, frame: inout FrameUniforms, near: Float) {
        lastDrawnCount = 0
        guard let buffer = system.buffer, system.count > 0, let half = target(for: targets) else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = half
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Particles"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ParticleUniforms(parameters: SIMD4(near, 0.6, Float(half.width), Float(half.height)))
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ParticleUniforms>.stride, index: 2)
        encoder.setFragmentTexture(targets.depth, index: 0)
        encoder.setFragmentSamplerState(pointSampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: system.count)
        encoder.endEncoding()

        let over = MTLRenderPassDescriptor()
        over.colorAttachments[0].texture = targets.colour
        over.colorAttachments[0].loadAction = .load
        over.colorAttachments[0].storeAction = .store
        guard let compositor = commands.makeRenderCommandEncoder(descriptor: over) else { return }
        compositor.label = "Particle composite"
        compositor.setRenderPipelineState(composite)
        compositor.setFragmentTexture(half, index: 0)
        compositor.setFragmentSamplerState(linearSampler, index: 0)
        compositor.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositor.endEncoding()
        lastDrawnCount = system.count
    }
}

/// Mirrors `ParticleUniforms` in `Particles.metal`: x projection near, y
/// soft-fade distance in metres, zw render size.
struct ParticleUniforms {
    var parameters: SIMD4<Float>
}
