// SPDX-License-Identifier: GPL-2.0-only
//
// Shared types and decoding for the modern render path.
//
// TORCS world space is right-handed with Z up. That convention is inherited
// from the physics and track code and is not changed here.
#ifndef TORCS_COMMON_METAL
#define TORCS_COMMON_METAL

#include <metal_stdlib>
using namespace metal;

/// 32-byte vertex. Half the classic path's 64 bytes while adding a tangent,
/// because bandwidth is the binding constraint on a 10-core M2.
///
/// Normal and tangent arrive as raw `short2` rather than a normalized vertex
/// format: the tangent's handedness lives in the low bit of its y component,
/// and hardware snorm conversion would destroy that bit before the shader
/// could read it. Decoding both by hand also guarantees the GPU reproduces
/// `OctahedralPacking` in Swift exactly, which the unit tests pin.
struct PackedVertex {
    packed_float3 position;
    short2 normal;
    short2 tangent;
    half2 uv0;
    half2 uv1;
    uchar4 blend;
};

/// Sign that treats zero as positive, matching the Swift encoder. Using a plain
/// sign() here would collapse the octahedral fold along the axes.
inline float2 signNotZero(float2 v) {
    return float2(v.x >= 0.0f ? 1.0f : -1.0f, v.y >= 0.0f ? 1.0f : -1.0f);
}

/// Inverse of `OctahedralPacking.project`.
inline float3 decodeOctahedral(float2 e) {
    float3 v = float3(e.x, e.y, 1.0f - abs(e.x) - abs(e.y));
    if (v.z < 0.0f) {
        float2 folded = (1.0f - abs(float2(v.y, v.x))) * signNotZero(v.xy);
        v.x = folded.x;
        v.y = folded.y;
    }
    return normalize(v);
}

inline float3 decodeNormal(short2 packed) {
    // max(v / 32767, -1) mirrors the Swift dequantize and the snorm rule.
    float2 e = max(float2(packed) / 32767.0f, -1.0f);
    return decodeOctahedral(e);
}

/// Returns the tangent in xyz and the bitangent handedness in w.
inline float4 decodeTangent(short2 packed) {
    float handedness = (packed.y & 1) != 0 ? -1.0f : 1.0f;
    // Arithmetic shift recovers the 15-bit magnitude, including negatives.
    float y = max(float(packed.y >> 1) / 16383.0f, -1.0f);
    float x = max(float(packed.x) / 32767.0f, -1.0f);
    return float4(decodeOctahedral(float2(x, y)), handedness);
}

/// Rebuilds an orthonormal tangent basis after interpolation. Interpolating
/// two unit vectors across a triangle does not preserve either unit length or
/// orthogonality, so both must be restored before use.
inline float3x3 tangentBasis(float3 normal, float4 tangent) {
    float3 n = normalize(normal);
    float3 t = normalize(tangent.xyz - n * dot(n, tangent.xyz));
    float3 b = tangent.w * cross(n, t);
    return float3x3(t, b, n);
}

/// Reconstructs a BC5 normal. Only X and Y are stored; Z follows from the unit
/// length constraint, which is why BC5 beats storing three channels.
inline float3 unpackNormalMap(float2 xy, float strength) {
    float2 n = (xy * 2.0f - 1.0f) * strength;
    float z = sqrt(saturate(1.0f - dot(n, n)));
    return float3(n, z);
}

#endif
