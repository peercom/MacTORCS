// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// A lens, as the television and photo views see through one.
///
/// Physical units so the presentation can say what it means — an 85 mm at
/// f/2.8 focused on the car — and the renderer converts to a circle of
/// confusion in pixels for the image it has. The sensor is taken as 36 mm
/// wide. Nothing here is applied to a driver's view.
public struct DepthOfField: Equatable, Sendable {
    /// Distance to the plane in focus, metres.
    public var focusDistance: Float
    /// The f-number; smaller is shallower.
    public var fNumber: Float
    /// Focal length in millimetres.
    public var focalLength: Float
    /// Cap on the circle in pixels of the half-resolution target. The gather
    /// reads a disc this wide, so it is also the pass's cost.
    public var maximumCircle: Float

    public init(focusDistance: Float, fNumber: Float = 2.8, focalLength: Float = 85, maximumCircle: Float = 12) {
        self.focusDistance = max(focusDistance, 0.01)
        self.fNumber = max(fNumber, 0.5)
        self.focalLength = max(focalLength, 1)
        self.maximumCircle = max(maximumCircle, 0)
    }

    /// The circle of confusion in pixels of an image `imageWidth` wide for a
    /// subject at infinity; a subject at distance d has `(d − f) / d` of it.
    /// Thin lens: `f² / (N (F − f))` on the sensor.
    public func circleScale(imageWidth: Int) -> Float {
        let focusMillimetres = focusDistance * 1000
        guard focusMillimetres > focalLength else { return maximumCircle }
        let onSensor = focalLength * focalLength / (fNumber * (focusMillimetres - focalLength))
        return onSensor / 36 * Float(imageWidth)
    }

    /// Signed circle in pixels for a subject at `distance` metres, as the
    /// shader computes it: negative in front of the focus, positive behind.
    public func circle(at distance: Float, imageWidth: Int) -> Float {
        let scale = circleScale(imageWidth: imageWidth)
        let circle = scale * (distance - focusDistance) / max(distance, 1e-3)
        return min(max(circle, -maximumCircle), maximumCircle)
    }
}

/// The half-resolution prefilter and gather; the resolve composites.
public final class DepthOfFieldRenderer {
    private let device: MTLDevice
    private let prefilter: MTLRenderPipelineState
    private let gather: MTLRenderPipelineState
    private var prefiltered: MTLTexture?
    private var blurred: MTLTexture?
    /// The gathered image, valid until the next encode or discard.
    public private(set) var result: MTLTexture?

    public init(device: MTLDevice, library: MTLLibrary, archive: PipelineArchive? = nil) throws {
        self.device = device
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
            return try PipelineArchive.make(descriptor, device: device, archive: archive)
        }
        prefilter = try pipeline("dofPrefilterFragment")
        gather = try pipeline("dofGatherFragment")
    }

    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let prefiltered, let blurred, prefiltered.width == width, prefiltered.height == height {
            return (prefiltered, blurred)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameTargets.colourFormat,
                                                                  width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor), let b = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        a.label = "Depth of field prefilter"
        b.label = "Depth of field gather"
        prefiltered = a
        blurred = b
        return (a, b)
    }

    public var byteCount: Int { (prefiltered.map { $0.width * $0.height * 8 } ?? 0) * 2 }

    /// The uniforms for a source this wide, shared with the resolve so the
    /// composite's circle is the gather's.
    public static func uniforms(_ lens: DepthOfField, near: Float, targetWidth: Int, targetHeight: Int) -> DepthOfFieldUniforms {
        DepthOfFieldUniforms(
            focus: SIMD4(lens.focusDistance, lens.circleScale(imageWidth: targetWidth), lens.maximumCircle, near),
            size: SIMD4(1 / Float(max(targetWidth, 1)), 1 / Float(max(targetHeight, 1)), 0, 0))
    }

    /// Blurs `source` (HDR, any resolution) by the depth (render resolution)
    /// into a target half the source's size. Nil when nothing could be made.
    @discardableResult
    public func encode(into commands: MTLCommandBuffer, source: MTLTexture, depth: MTLTexture,
                       lens: DepthOfField, near: Float, timer: PassTimer? = nil) -> MTLTexture? {
        guard lens.maximumCircle > 0,
              let (prefiltered, blurred) = targets(width: max(1, source.width / 2), height: max(1, source.height / 2)) else {
            result = nil
            return nil
        }
        var uniforms = Self.uniforms(lens, near: near, targetWidth: prefiltered.width, targetHeight: prefiltered.height)
        func pass(_ label: String, into destination: MTLTexture, state: MTLRenderPipelineState,
                  bind: (MTLRenderCommandEncoder) -> Void) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            timer?.attach(descriptor, label)
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.label = label
            encoder.setRenderPipelineState(state)
            bind(encoder)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DepthOfFieldUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        pass("Depth of field prefilter", into: prefiltered, state: prefilter) {
            $0.setFragmentTexture(source, index: 0)
            $0.setFragmentTexture(depth, index: 1)
        }
        pass("Depth of field gather", into: blurred, state: gather) {
            $0.setFragmentTexture(prefiltered, index: 0)
        }
        result = blurred
        return blurred
    }

    public func discard() { result = nil }
}

/// Matches `DepthOfFieldUniforms` in `DepthOfField.metal`.
public struct DepthOfFieldUniforms {
    public var focus: SIMD4<Float>
    public var size: SIMD4<Float>
}
