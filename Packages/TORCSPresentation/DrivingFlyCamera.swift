// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets
import TORCSSimulation

/// The fly camera as the driving session uses it: the original motion, fed
/// the height of the scene under it.
///
/// The classic path answered that height by walking the baked scene graph
/// as `grGetHOT` did, car shadow and all. The modern path draws a generated
/// terrain from the track's own height query, so that query is the scene
/// height, and the caller passes it as a closure.
public struct DrivingFlyCamera: Sendable {
    public typealias Height = @Sendable (SIMD2<Float>) throws -> Float
    private(set) var motion: FlyCamera
    private let height: Height

    public init(height: @escaping Height, seed: UInt32 = 12345) throws {
        self.height = height
        motion = try FlyCamera(seed: seed)
    }

    /// Equal simulation timestamps hold motion even when redraws publish
    /// geometry. A nil view means the caller retains the preceding camera.
    public mutating func draw(time: Double, selected: Bool, snapshot: VehicleVisualSnapshot,
                              zoom: Float = 67.5) throws -> SceneCamera? {
        guard selected else { return nil }
        var next = motion
        try next.update(time: time, carIndex: 0, position: snapshot.body.position, sceneHeight: height)
        let camera = try next.camera(zoom: zoom)
        motion = next
        return camera
    }
}
