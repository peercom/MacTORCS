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
        let entered = CACurrentMediaTime()
        guard let drawable = view.currentDrawable else { return false }
        let acquired = CACurrentMediaTime()
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
                      lighting: lighting, depthOfField: depthOfFieldRenderer.result, velocity: targets.velocity)
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
        // TORCS_FRAME_LOG=1: where each presented frame's time went, for a
        // window of frames once the session has settled.
        if FrameLog.enabled {
            let index = FrameLog.next()
            if let index {
                let encoded = CACurrentMediaTime()
                commands.addScheduledHandler { _ in FrameLog.note(index, scheduled: CACurrentMediaTime()) }
                commands.addCompletedHandler { buffer in
                    FrameLog.note(index, entered: entered, acquired: acquired, encoded: encoded,
                                  gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime,
                                  kernelStart: buffer.kernelStartTime, kernelEnd: buffer.kernelEndTime)
                }
                drawable.addPresentedHandler { shown in FrameLog.note(index, presented: shown.presentedTime) }
            }
        }
        commands.present(drawable)
        commands.commit()
        // With a pass timer set (a diagnostic) the frame is waited for so
        // its stages can be read back before the next one reuses the samples.
        if let passTimer {
            commands.waitUntilCompleted()
            FrameLog.note(passes: passTimer.resolve(), gpu: commands.gpuEndTime - commands.gpuStartTime)
        }
        return true
    }
}


/// A diagnostic record of a run of presented frames: when the draw began,
/// when the drawable came, when encoding ended, when the GPU ran the buffer
/// and when the frame reached the display.
public enum FrameLog {
    public static let enabled = ProcessInfo.processInfo.environment["TORCS_FRAME_LOG"] != nil
    struct Entry { var entered = 0.0, acquired = 0.0, encoded = 0.0, scheduled = 0.0, gpuStart = 0.0, gpuEnd = 0.0, kernelStart = 0.0, kernelEnd = 0.0, presented = 0.0 }
    nonisolated(unsafe) static var entries: [Entry] = []
    nonisolated(unsafe) static var frame = 0
    static let lock = NSLock()
    static let first = 240, count = 40
    static func next() -> Int? {
        lock.lock(); defer { lock.unlock() }
        frame += 1
        guard frame > first, entries.count < count else { return nil }
        entries.append(Entry()); return entries.count - 1
    }
    static func note(_ index: Int, scheduled: Double) { lock.lock(); entries[index].scheduled = scheduled; lock.unlock() }
    static func note(_ index: Int, presented: Double) { lock.lock(); entries[index].presented = presented; lock.unlock() }
    static func note(_ index: Int, entered: Double, acquired: Double, encoded: Double, gpuStart: Double, gpuEnd: Double,
                     kernelStart: Double, kernelEnd: Double) {
        lock.lock()
        entries[index].entered = entered; entries[index].acquired = acquired; entries[index].encoded = encoded
        entries[index].gpuStart = gpuStart; entries[index].gpuEnd = gpuEnd
        entries[index].kernelStart = kernelStart; entries[index].kernelEnd = kernelEnd
        lock.unlock()
    }
    nonisolated(unsafe) static var passSamples: [String: [Double]] = [:]
    nonisolated(unsafe) static var passOrder: [String] = []
    nonisolated(unsafe) static var gpuSamples: [Double] = []
    nonisolated(unsafe) static var passFrames = 0
    static func note(passes: [PassTimer.Sample], gpu: Double) {
        lock.lock(); defer { lock.unlock() }
        passFrames += 1
        guard passFrames > 120 else { return }
        gpuSamples.append(gpu * 1000)
        for sample in passes where sample.seconds.isFinite {
            if passSamples[sample.name] == nil { passOrder.append(sample.name) }
            passSamples[sample.name, default: []].append(sample.seconds * 1000)
        }
    }
    /// Median stage times of the presented frames, slowest first.
    public static func passReport() -> String {
        lock.lock(); defer { lock.unlock() }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        var out = String(format: "presented frames: %d, gpu median %.2f ms\n", gpuSamples.count, median(gpuSamples))
        for name in passOrder.sorted(by: { median(passSamples[$0]!) > median(passSamples[$1]!) }) {
            out += String(format: "  %-30@ %6.2f ms\n", name as NSString, median(passSamples[name]!))
        }
        return out
    }
    /// The log as text, times in milliseconds from the first frame's draw.
    public static func report() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let origin = entries.first?.entered else { return "frame log: no frames" }
        var out = "frame  enter  +drawable  +encode  +sched  gpuStart  gpuRun  kernelRun  presented  interval\n"
        var previous = 0.0
        for (i, e) in entries.enumerated() {
            func ms(_ t: Double) -> String { t == 0 ? "     -" : String(format: "%6.1f", (t - origin) * 1000) }
            out += String(format: "%3d  %@  %6.1f  %6.1f  %@  %@  %6.1f  %6.1f  %@  %6.1f\n", i, ms(e.entered),
                          (e.acquired - e.entered) * 1000, (e.encoded - e.acquired) * 1000, ms(e.scheduled), ms(e.gpuStart),
                          (e.gpuEnd - e.gpuStart) * 1000, (e.kernelEnd - e.kernelStart) * 1000, ms(e.presented),
                          previous == 0 || e.presented == 0 ? 0 : (e.presented - previous) * 1000)
            previous = e.presented
        }
        return out
    }
}
