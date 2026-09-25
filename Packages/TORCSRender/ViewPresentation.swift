// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore
import Metal
import MetalKit
import QuartzCore
import simd

public extension ForwardRenderer {
    /// Pixel format the drawable must use.
    ///
    /// The tonemapper emits linear display-referred colour and relies on the
    /// hardware to apply the sRGB transfer function exactly once. A non-sRGB
    /// drawable would skip that and the frame would come out dark — the mirror
    /// image of the double-encoding fault recorded in RENDERER_REPLACEMENT.md.
    static var drawableFormat: MTLPixelFormat { .rgba8Unorm_srgb }

    /// Configures an `MTKView` for this renderer. Call once, before drawing.
    func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = Self.drawableFormat
        // Depth and stencil live in the renderer's own targets, not the view's:
        // the scene is rendered to an HDR target and only the tonemapped result
        // reaches the drawable.
        view.depthStencilPixelFormat = .invalid
        view.framebufferOnly = true
    }

    /// Renders one frame into the view's drawable.
    ///
    /// Returns without presenting if the view has no drawable, which happens
    /// while the window is off-screen or mid-resize.
    @discardableResult
    func present(in view: MTKView, resources: [SceneResources], instances: [RenderInstance],
                 camera: RenderCamera, lighting: SunLighting, mirror: MirrorRequest? = nil) throws -> Bool {
        guard let drawable = view.currentDrawable else { return false }
        let width = drawable.texture.width, height = drawable.texture.height
        guard width > 0, height > 0 else { return false }
        guard drawable.texture.pixelFormat == Self.drawableFormat else {
            throw RenderError.unavailable(
                "Drawable is \(drawable.texture.pixelFormat); the renderer needs \(Self.drawableFormat). Call configure(_:) first.")
        }

        let now = CACurrentMediaTime()
        if animationTime > 0 { presentedFrameInterval = min(max(now - animationTime, 1.0 / 240.0), 0.5) }
        animationTime = now
        let preparation = PerformanceSignposts.begin("Draw preparation")
        // Every scaler the resolution ladder can ask for, built before the
        // first frame at this size rather than on the frame that steps.
        try prewarmIfNeeded(outputWidth: width, outputHeight: height)
        // Last frame's measured cost decides this frame's render scale.
        let measured = gpuTime
        if measured > 0 { recordDynamicResolution(gpuTime: measured) }
        let targets = try targets(outputWidth: width, outputHeight: height)
        guard let commands = queue.makeCommandBuffer() else {
            throw RenderError.unavailable("Could not create a command buffer")
        }
        commands.label = "Driving frame"
        // The mirror first: its own renderer and targets, one command buffer.
        let mirrorView = try mirror.map { try encodeMirrorView(into: commands, $0, lighting: lighting) }
        encodeFrame(into: commands, targets: targets, resources: resources, instances: instances,
                    camera: camera, lighting: lighting, aspect: Float(width) / Float(height))
        // Tonemap straight into the drawable rather than into `targets.display`
        // and blitting: one less full-resolution write per frame.
        encodeResolve(into: commands, source: tonemapSource(targets), destination: drawable.texture,
                      lighting: lighting, depthOfField: depthOfFieldRenderer.result)
        if let mirror, let mirrorView {
            encodeMirrorComposite(into: commands, mirror: mirrorView, destination: drawable.texture, rect: mirror.rect)
        }

        // GPU time is sampled on completion, which is one frame behind. That is
        // what dynamic resolution wants anyway: it reacts to measured cost, and
        // blocking to make the measurement current would cost more than it saves.
        PerformanceSignposts.end("Draw preparation", preparation)
        // The GPU interval spans commit to completion; it ends on the
        // completion handler's thread, which the signposter allows.
        let gpu = PerformanceSignposts.begin("GPU duration")
        let recordTime: (MTLCommandBuffer) -> Void = { [weak self] buffer in
            PerformanceSignposts.end("GPU duration", gpu)
            guard let self, buffer.gpuEndTime > buffer.gpuStartTime else { return }
            self.recordFrameTime(buffer.gpuEndTime - buffer.gpuStartTime)
        }
        commands.addCompletedHandler(recordTime)
        commands.present(drawable)
        commands.commit()
        return true
    }
}
