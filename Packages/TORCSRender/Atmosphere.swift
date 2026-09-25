// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Precomputed atmosphere lookup tables.
///
/// Three tables, on three different schedules, which is the whole reason this
/// technique is affordable:
///
/// - **Transmittance** and **multiple scattering** depend only on the medium,
///   so they are computed once at startup and never again.
/// - **Sky view** depends on sun direction and camera altitude, so it is
///   recomputed only when the sun actually moves — not every frame. At
///   192x108 that is a trivial dispatch even when it does run.
///
/// The result replaces both the classic path's sky cylinder and its per-camera
/// linear fog with one physical model.
public final class AtmosphereResources {
    public let transmittance: MTLTexture
    public let multiScatter: MTLTexture
    public let skyView: MTLTexture

    private let transmittancePipeline: MTLComputePipelineState
    private let multiScatterPipeline: MTLComputePipelineState
    private let skyViewPipeline: MTLComputePipelineState
    private let irradiancePipeline: MTLComputePipelineState
    /// Nine SH coefficients as float4, consumed directly by the forward shader.
    public let irradiance: MTLBuffer
    private var staticTablesReady = false
    private var lastSun: SIMD4<Float>?

    /// Sized from the reference technique: transmittance and multiple
    /// scattering are smooth enough to stay small, sky view gets the resolution
    /// because horizon gradients are what the eye actually reads.
    public static let transmittanceSize = (width: 256, height: 64)
    public static let multiScatterSize = (width: 32, height: 32)
    public static let skyViewSize = (width: 192, height: 108)

    struct SkyUniforms {
        var sunDirection: SIMD4<Float>
        var sunIlluminance: SIMD4<Float>
    }

    public init(device: MTLDevice, library: MTLLibrary, archive: PipelineArchive? = nil) throws {
        func table(_ size: (width: Int, height: Int)) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.unavailable("Could not allocate an atmosphere table")
            }
            return texture
        }
        transmittance = try table(Self.transmittanceSize)
        multiScatter = try table(Self.multiScatterSize)

        // The sky table is mipped so the forward pass can sample it along the
        // reflection vector at a roughness-selected level: a cheap specular
        // probe that costs one blit rather than a prefiltering pass.
        let skyDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Self.skyViewSize.width,
            height: Self.skyViewSize.height, mipmapped: true)
        skyDescriptor.usage = [.shaderRead, .shaderWrite]
        skyDescriptor.storageMode = .private
        guard let sky = device.makeTexture(descriptor: skyDescriptor) else {
            throw RenderError.unavailable("Could not allocate the sky table")
        }
        skyView = sky

        guard let irradiance = device.makeBuffer(length: 9 * MemoryLayout<SIMD4<Float>>.stride,
                                                 options: .storageModePrivate) else {
            throw RenderError.unavailable("Could not allocate the sky irradiance buffer")
        }
        self.irradiance = irradiance

        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.unavailable("Missing atmosphere kernel \(name)")
            }
            let descriptor = MTLComputePipelineDescriptor()
            descriptor.computeFunction = function
            descriptor.label = name
            return try PipelineArchive.make(descriptor, device: device, archive: archive)
        }
        transmittancePipeline = try pipeline("atmosphereTransmittanceLUT")
        multiScatterPipeline = try pipeline("atmosphereMultiScatterLUT")
        skyViewPipeline = try pipeline("atmosphereSkyViewLUT")
        irradiancePipeline = try pipeline("atmosphereIrradianceSH")
    }

    static func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                         width: Int, height: Int) {
        encoder.setComputePipelineState(pipeline)
        let side = max(1, Int(Double(pipeline.threadExecutionWidth).squareRoot()))
        let group = MTLSize(width: side, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / side), depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
    }

    /// Encodes only the work that is actually stale.
    public func update(into commands: MTLCommandBuffer, lighting: SunLighting, cameraAltitude: Float,
                       timer: PassTimer? = nil) {
        var uniforms = SkyUniforms(
            sunDirection: SIMD4(lighting.direction, max(cameraAltitude / 1000, 0.0005)),
            sunIlluminance: SIMD4(lighting.illuminance, 0))

        // A sun move below this is invisible in the sky gradient and not worth
        // a dispatch; altitude is folded in because it changes the horizon.
        let changed = lastSun.map { simd_distance($0, uniforms.sunDirection) > 1e-4 } ?? true
        guard !staticTablesReady || changed else { return }

        let tablesPass = MTLComputePassDescriptor()
        timer?.attach(tablesPass, "Atmosphere tables")
        guard let encoder = commands.makeComputeCommandEncoder(descriptor: tablesPass) else { return }
        encoder.label = "Atmosphere tables"
        if !staticTablesReady {
            encoder.setTexture(transmittance, index: 0)
            Self.dispatch(encoder, pipeline: transmittancePipeline,
                          width: Self.transmittanceSize.width, height: Self.transmittanceSize.height)

            encoder.setTexture(multiScatter, index: 0)
            encoder.setTexture(transmittance, index: 1)
            Self.dispatch(encoder, pipeline: multiScatterPipeline,
                          width: Self.multiScatterSize.width, height: Self.multiScatterSize.height)
            staticTablesReady = true
        }
        encoder.setTexture(skyView, index: 0)
        encoder.setTexture(transmittance, index: 1)
        encoder.setTexture(multiScatter, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SkyUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: skyViewPipeline,
                      width: Self.skyViewSize.width, height: Self.skyViewSize.height)
        encoder.endEncoding()

        // Mips must exist before the irradiance projection reads the table.
        let mipPass = MTLBlitPassDescriptor()
        timer?.attach(mipPass, "Sky mips")
        if let blit = commands.makeBlitCommandEncoder(descriptor: mipPass) {
            blit.label = "Sky mips"
            blit.generateMipmaps(for: skyView)
            blit.endEncoding()
        }

        let irradiancePass = MTLComputePassDescriptor()
        timer?.attach(irradiancePass, "Sky irradiance")
        if let shEncoder = commands.makeComputeCommandEncoder(descriptor: irradiancePass) {
            shEncoder.label = "Sky irradiance"
            shEncoder.setComputePipelineState(irradiancePipeline)
            shEncoder.setBuffer(irradiance, offset: 0, index: 0)
            shEncoder.setTexture(skyView, index: 0)
            // A single threadgroup: the reduction is in threadgroup memory.
            shEncoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                           threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            shEncoder.endEncoding()
        }
        lastSun = uniforms.sunDirection
    }

    /// Forces a full recompute, for a medium change or a test.
    public func invalidate() {
        staticTablesReady = false
        lastSun = nil
    }
}
