// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// One rung of automatic quality: a preset and the share of the output
/// resolution the scene is rendered at before it is scaled up.
public struct QualityLevel: Sendable, Equatable {
    public let preset: RenderSettings.Preset
    public let renderScale: Float
    public init(preset: RenderSettings.Preset, renderScale: Float = 1) {
        self.preset = preset
        self.renderScale = renderScale
    }
    /// The settings a renderer runs this level with. The resolution is the
    /// governor's to choose, so the renderer's own dynamic resolution is off:
    /// two controllers would fight over one scale.
    ///
    /// On a dry road the fanless levels also leave out screen-space
    /// reflections. Measured in a native-resolution window on an M2, their
    /// four passes (trace, blur, temporal resolve, composite) take 1.9 ms of
    /// a 13 ms frame, and dry asphalt is too rough to show them; on a wet
    /// road they are what the picture is made of, so they stay.
    public func settings(wetRoad: Bool = false) -> RenderSettings {
        var settings = RenderSettings(preset: preset)
        if preset == .m2Air {
            settings.renderScale = renderScale
            settings.upscaling = true
            settings.dynamicResolution = false
            if !wetRoad { settings.screenSpaceReflections = .off }
        }
        return settings
    }
}

/// Holds the frame rate by moving down a ladder of quality levels when
/// frames are being dropped, and carefully back up when there is room.
///
/// The presets differ by several times in GPU cost. On a fanless M2 in a
/// native-resolution window the high preset's frame takes about 29 ms, half
/// the display's rate, and the fanless preset's about 13 ms: at the edge of
/// a 60 Hz refresh, missing it often. A fixed choice that does not fit the
/// machine was silently a slow game. The renderer's own dynamic resolution
/// cannot rescue it in a window: it is fed command-buffer spans, which
/// overlapping frames inflate, so it steps down, sees no gain and reverts.
///
/// The governor is fed what the player sees — frames presented in the last
/// second — together with the GPU's span for a frame. Dropped frames move
/// it down after a few seconds; a long steady stretch with the GPU under
/// half its interval moves it up one rung, and a rung that then fails is
/// not tried again.
public struct QualityGovernor: Sendable, Equatable {
    /// Lightest first: the fanless preset at rising resolution, then the
    /// heavier presets at native. The scales are rungs of the renderer's own
    /// resolution ladder, so its scalers are already built for them.
    public static let ladder: [QualityLevel] = [
        QualityLevel(preset: .m2Air, renderScale: 0.5), QualityLevel(preset: .m2Air, renderScale: 0.67),
        QualityLevel(preset: .m2Air, renderScale: 0.85), QualityLevel(preset: .m2Air, renderScale: 1),
        QualityLevel(preset: .balanced), QualityLevel(preset: .high)]
    public private(set) var index: Int
    public var level: QualityLevel { Self.ladder[index] }
    /// The display rate being held, frames per second.
    public var targetRate: Double
    /// No climbing above this rung: the machine's own starting point, or a
    /// rung below one that failed.
    public private(set) var ceiling: Int

    /// The share of the target that still counts as holding it.
    public static let tolerance = 0.85
    /// Seconds ignored after a start or a change: loading, pipeline warm-up
    /// and the exposure settling are not the steady state.
    public static let settleSeconds = 3
    /// Consecutive slow seconds before a step down.
    public static let slowSeconds = 3
    /// Consecutive steady seconds, with the GPU under `headroom` of its
    /// interval, before a step up.
    public static let steadySeconds = 20
    public static let headroom = 0.5
    /// A step up that is undone within this many seconds has failed.
    public static let trialSeconds = 30
    private var settling = QualityGovernor.settleSeconds
    private var slow = 0, steady = 0
    private var trial = 0

    public init(index: Int, ceiling: Int? = nil, targetRate: Double = 60) {
        let top = Self.ladder.count - 1
        self.ceiling = min(max(ceiling ?? top, 0), top)
        self.index = min(max(index, 0), self.ceiling)
        self.targetRate = targetRate
    }

    /// The rung of a preset at native resolution.
    public static func index(of preset: RenderSettings.Preset) -> Int {
        ladder.firstIndex { $0.preset == preset && $0.renderScale >= 1 } ?? 0
    }

    /// The highest rung a machine is let climb to, from its GPU's name: the
    /// largest chips to high, the Pro chips to balanced, everything else to
    /// the fanless preset at native resolution.
    public static func recommended(deviceName: String) -> Int {
        let name = deviceName.lowercased()
        if name.contains("max") || name.contains("ultra") { return index(of: .high) }
        if name.contains("pro") { return index(of: .balanced) }
        return index(of: .m2Air)
    }
    /// Where a machine starts. A base chip starts one rung under its
    /// ceiling: at native resolution in a window its frame sits at the edge
    /// of the refresh interval, and starting there means starting with
    /// dropped frames. It climbs if there turns out to be room.
    public static func start(deviceName: String) -> Int {
        let top = recommended(deviceName: deviceName)
        return top == index(of: .m2Air) ? top - 1 : top
    }

    /// One second of a running session: the frames presented in it and the
    /// GPU's time for a frame. Returns the level to switch to, if any.
    public mutating func record(frameRate: Double, gpuSeconds: Double = 0) -> QualityLevel? {
        guard frameRate.isFinite, frameRate > 0 else { return nil }
        if settling > 0 { settling -= 1; return nil }
        if trial > 0 { trial -= 1 }
        if frameRate < targetRate * Self.tolerance {
            slow += 1; steady = 0
            guard slow >= Self.slowSeconds, index > 0 else { return nil }
            // A rung reached by climbing that did not hold is not climbed to again.
            if trial > 0 { ceiling = index - 1 }
            index -= 1
            slow = 0; trial = 0; settling = Self.settleSeconds
            return level
        }
        slow = 0
        let interval = 1 / targetRate
        let roomy = frameRate >= targetRate * 0.97 && gpuSeconds > 0 && gpuSeconds <= interval * Self.headroom
        steady = roomy ? steady + 1 : 0
        guard steady >= Self.steadySeconds, index < ceiling else { return nil }
        index += 1
        steady = 0; trial = Self.trialSeconds; settling = Self.settleSeconds
        return level
    }

    /// A pause, a restart or a new session: what was measured before no
    /// longer says anything about what comes next.
    public mutating func reset() {
        settling = Self.settleSeconds
        slow = 0; steady = 0
    }
}
