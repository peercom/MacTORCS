// SPDX-License-Identifier: GPL-2.0-only
//
// Auto-exposure: a centre-weighted histogram of the frame's log luminance,
// the mean of its middle taken as the scene's key, and an exposure that
// adapts toward it — fast when the scene brightens, slowly when it darkens,
// as an eye does. The state lives on the GPU and every consumer of the
// exposure reads it from there, so no frame waits for a readback.
#ifndef TORCS_EXPOSURE_METAL
#define TORCS_EXPOSURE_METAL

#include <metal_stdlib>
using namespace metal;

struct ExposureState {
    float adaptedEV;      // the exposure in use, EV100
    float scale;          // radiance multiplier: 1 / (1.2 * 2^EV)
    float targetEV;       // what the meter asked for this frame
    float meanLog2;       // the metered key, log2 luminance
};

struct ExposureUniforms {
    /// x seconds since the last frame, y adaptation time when opening up
    /// (the scene went darker), z when closing down (it went brighter),
    /// w compensation in EV added to the adapted value.
    float4 timing;
    /// x reset (1 snaps to the target), y automatic (0 takes z as the EV),
    /// z manual EV100, w unused.
    float4 control;
};

constant int kExposureBins = 64;
constant float kExposureMinLog2 = -8.0f;
constant float kExposureMaxLog2 = 16.0f;
constant int kExposureGrid = 64;

/// One threadgroup meters the whole frame: a 64×64 grid of samples into a
/// histogram of log2 luminance, weighted toward the centre of the frame,
/// then the weighted mean of the bins between the 25th and 95th percentile
/// of that weight — so a sun disc or a black sky does not set the exposure.
kernel void exposureMeter(texture2d<float> scene [[texture(0)]],
                          device ExposureState &state [[buffer(0)]],
                          constant ExposureUniforms &u [[buffer(1)]],
                          uint tid [[thread_index_in_threadgroup]],
                          uint threads [[threads_per_threadgroup]]) {
    threadgroup atomic_uint bins[kExposureBins];
    for (int i = int(tid); i < kExposureBins; i += int(threads)) {
        atomic_store_explicit(&bins[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    for (int i = int(tid); i < kExposureGrid * kExposureGrid; i += int(threads)) {
        float2 uv = (float2(i % kExposureGrid, i / kExposureGrid) + 0.5f) / float(kExposureGrid);
        float3 c = scene.sample(linearSampler, uv).rgb;
        float luminance = max(dot(c, float3(0.2126f, 0.7152f, 0.0722f)), 1e-5f);
        float l2 = clamp(log2(luminance), kExposureMinLog2, kExposureMaxLog2);
        float2 d = (uv - 0.5f) * 2.0f;
        float weight = 1.0f - 0.7f * saturate(dot(d, d));
        int bin = int((l2 - kExposureMinLog2) / (kExposureMaxLog2 - kExposureMinLog2) * float(kExposureBins - 1) + 0.5f);
        atomic_fetch_add_explicit(&bins[clamp(bin, 0, kExposureBins - 1)], uint(weight * 1024.0f), memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid != 0) { return; }

    float counts[kExposureBins];
    float total = 0.0f;
    for (int i = 0; i < kExposureBins; ++i) {
        counts[i] = float(atomic_load_explicit(&bins[i], memory_order_relaxed));
        total += counts[i];
    }
    float low = total * 0.25f, high = total * 0.95f;
    float accumulated = 0.0f, weighted = 0.0f, used = 0.0f;
    for (int i = 0; i < kExposureBins; ++i) {
        float start = accumulated;
        accumulated += counts[i];
        float inside = max(0.0f, min(accumulated, high) - max(start, low));
        float value = kExposureMinLog2 + float(i) / float(kExposureBins - 1) * (kExposureMaxLog2 - kExposureMinLog2);
        weighted += inside * value;
        used += inside;
    }
    float meanLog2 = used > 0.0f ? weighted / used : 0.0f;
    // EV100 of a scene whose key is this luminance: log2(L * 100 / 12.5).
    float targetEV = meanLog2 + 3.0f;
    bool automatic = u.control.y > 0.5f;
    if (!automatic) { targetEV = u.control.z; }
    float adapted = state.adaptedEV;
    if (!automatic || u.control.x > 0.5f || !isfinite(adapted)) {
        adapted = targetEV;
    } else {
        float tau = targetEV > adapted ? u.timing.z : u.timing.y;
        adapted += (targetEV - adapted) * (1.0f - exp(-u.timing.x / max(tau, 1e-3f)));
    }
    state.adaptedEV = adapted;
    state.targetEV = targetEV;
    state.meanLog2 = meanLog2;
    state.scale = 1.0f / (1.2f * exp2(adapted + u.timing.w));
}

#endif
