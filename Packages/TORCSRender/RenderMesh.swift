// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSMath
import TORCSAssets

/// GPU vertex for the modern render path. Must match `PackedVertex` in
/// `Shaders/Common.metal` exactly; `RenderMeshTests` asserts the layout.
///
/// 32 bytes against the classic path's 64, while adding a tangent. Bandwidth is
/// the binding constraint on a 10-core M2, so the halving matters more than the
/// precision given up — see `RENDERER_REPLACEMENT.md` for the measured error.
///
/// Position stays full `Float`: track geometry spans kilometres and half
/// precision would quantize it to visible steps. Everything else is packed.
///
/// Laid out as scalars rather than `SIMD3<Float>` because Swift aligns that
/// type to 16 bytes, which would pad the struct to 48 and silently break the
/// correspondence with Metal's `packed_float3`.
public struct PackedVertex: Equatable, Sendable {
    public var positionX: Float, positionY: Float, positionZ: Float
    /// Octahedral, raw `short2`. Decoded in-shader, never as a snorm attribute.
    public var normal: SIMD2<Int16>
    /// Octahedral plus handedness in the low bit of y.
    public var tangent: SIMD2<Int16>
    public var uv0: SIMD2<Float16>
    public var uv1: SIMD2<Float16>
    /// Material splat weights for blended track surfaces; unused on cars.
    public var blend: SIMD4<UInt8>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD3<Float>,
                handedness: Float, uv0: SIMD2<Float>, uv1: SIMD2<Float> = .zero,
                blend: SIMD4<UInt8> = SIMD4(255, 0, 0, 0)) {
        positionX = position.x; positionY = position.y; positionZ = position.z
        self.normal = OctahedralPacking.encodeNormal(normal)
        self.tangent = OctahedralPacking.encodeTangent(tangent, handedness: handedness)
        self.uv0 = SIMD2(Float16(uv0.x), Float16(uv0.y))
        self.uv1 = SIMD2(Float16(uv1.x), Float16(uv1.y))
        self.blend = blend
    }

    public var position: SIMD3<Float> { SIMD3(positionX, positionY, positionZ) }
}

/// A drawable batch: packed vertices, indices, and the transform that places it
/// in TORCS world space (right-handed, Z up).
public struct RenderMesh: Sendable {
    public let vertices: [PackedVertex]
    public let indices: [UInt32]
    public let transform: simd_float4x4
    /// Bounding sphere for culling, in the mesh's own local space.
    public let center: SIMD3<Float>
    public let radius: Float

    public init(vertices: [PackedVertex], indices: [UInt32], transform: simd_float4x4) {
        self.vertices = vertices
        self.indices = indices
        self.transform = transform
        guard !vertices.isEmpty else {
            center = .zero; radius = 0
            return
        }
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for vertex in vertices {
            low = simd_min(low, vertex.position)
            high = simd_max(high, vertex.position)
        }
        let middle = (low + high) * 0.5
        center = middle
        radius = vertices.reduce(0) { max($0, simd_length($1.position - middle)) }
    }

    /// Builds a mesh from unpacked arrays, deriving tangents from the base UVs.
    ///
    /// Negative-determinant transforms mirror the geometry, which flips the
    /// bitangent. Folding that into the stored handedness keeps the shader free
    /// of a per-draw correction it would otherwise have to apply to every
    /// vertex, and mirrored nodes do occur in the original car meshes.
    public static func build(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                            uv0: [SIMD2<Float>], uv1: [SIMD2<Float>] = [],
                            blend: [SIMD4<UInt8>] = [], indices: [UInt32],
                            transform: simd_float4x4 = matrix_identity_float4x4) throws -> RenderMesh {
        guard positions.count == normals.count else {
            throw ACError.invalid("RenderMesh needs one normal per position")
        }
        guard uv0.isEmpty || uv0.count == positions.count else {
            throw ACError.invalid("RenderMesh needs one base UV per position")
        }
        let mirrored = simd_determinant(transform) < 0
        let frames = TangentGeneration.frames(positions: positions, normals: normals,
                                              uvs: uv0, indices: indices)
        let vertices = (0 ..< positions.count).map { i in
            PackedVertex(position: positions[i],
                         normal: normals[i],
                         tangent: frames[i].tangent,
                         handedness: mirrored ? -frames[i].handedness : frames[i].handedness,
                         uv0: uv0.isEmpty ? .zero : uv0[i],
                         uv1: i < uv1.count ? uv1[i] : .zero,
                         blend: i < blend.count ? blend[i] : SIMD4(255, 0, 0, 0))
        }
        return RenderMesh(vertices: vertices, indices: indices, transform: transform)
    }
}
