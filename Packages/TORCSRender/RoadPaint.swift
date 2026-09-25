// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Painted boxes on the road: the starting grid, from the native grid.
///
/// Static decals in the skid marks' vertex layout, drawn by the same
/// renderer with a paint pipeline: white lines blended over the tarmac,
/// depth-tested read-only against the road they lie on. The boxes come from
/// `StartingGrid.slots`, which is the parity-verified placement the cars
/// actually start from, so the paint is where the grid is by construction.
public final class RoadPaint {
    public struct Box: Sendable, Equatable {
        /// World position of the box centre, on the surface.
        public var centre: SIMD3<Float>
        /// Heading of the box's long axis, radians.
        public var yaw: Float
        public var length: Float
        public var width: Float
        public init(centre: SIMD3<Float>, yaw: Float, length: Float = 4.7, width: Float = 2.2) {
            self.centre = centre; self.yaw = yaw; self.length = length; self.width = width
        }
    }

    /// Lift above the surface, as for the skid marks.
    public var lift: Float = 0.003
    public private(set) var boxes: [Box] = []
    public var quadCount: Int { boxes.count }
    private let device: MTLDevice
    public private(set) var buffer: MTLBuffer?

    public init(device: MTLDevice) { self.device = device }

    /// Replaces every box. One quad per box, its texture coordinates in
    /// metres along and across so the fragment can paint an outline of a
    /// fixed width whatever the box's size.
    public func set(_ boxes: [Box]) {
        self.boxes = boxes
        guard !boxes.isEmpty else { buffer = nil; return }
        var vertices: [SkidMarks.Vertex] = []
        vertices.reserveCapacity(boxes.count * 6)
        for box in boxes {
            let forward = SIMD3(cos(box.yaw), sin(box.yaw), 0) * (box.length / 2)
            let right = SIMD3(sin(box.yaw), -cos(box.yaw), 0) * (box.width / 2)
            let c = box.centre + SIMD3(0, 0, lift)
            let a = c - forward - right, b = c - forward + right, d = c + forward + right, e = c + forward - right
            let v0 = SkidMarks.Vertex(positionIntensity: SIMD4(a, 1), uv: SIMD4(0, 0, box.length, box.width))
            let v1 = SkidMarks.Vertex(positionIntensity: SIMD4(b, 1), uv: SIMD4(0, box.width, box.length, box.width))
            let v2 = SkidMarks.Vertex(positionIntensity: SIMD4(d, 1), uv: SIMD4(box.length, box.width, box.length, box.width))
            let v3 = SkidMarks.Vertex(positionIntensity: SIMD4(e, 1), uv: SIMD4(box.length, 0, box.length, box.width))
            vertices += [v0, v1, v2, v0, v2, v3]
        }
        buffer = vertices.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
        }
    }
}
