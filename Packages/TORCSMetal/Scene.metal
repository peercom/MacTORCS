// SPDX-License-Identifier: GPL-2.0-only
#include <metal_stdlib>
using namespace metal;
struct Vertex { float3 position; float3 normal; };
struct Uniforms { float4x4 model; float4x4 viewProjection; float4 color; };
struct Varying { float4 position [[position]]; float3 normal; float4 color; };
vertex Varying sceneVertex(uint id [[vertex_id]], const device Vertex *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    Varying out;
    out.position = u.viewProjection * u.model * float4(vertices[id].position, 1);
    out.normal = normalize((u.model * float4(vertices[id].normal, 0)).xyz);
    out.color = u.color;
    return out;
}
fragment float4 sceneFragment(Varying in [[stage_in]]) {
    float light = 0.28 + 0.72 * max(0.0, dot(normalize(in.normal), normalize(float3(-0.4, -0.5, 1))));
    return float4(in.color.rgb * light, in.color.a);
}

// First scene path: TORCS material color, smooth vertex lighting, three track
// MODULATE layers, car reflection/shade maps, alpha test/blend and separate
// specular. Exact legacy raster parity remains open. Track fog is explicit.
struct AssetVertex { float4 position, normal, uv01, uv23; };
struct AssetUniforms {
    float4x4 model, normalMatrix, viewProjection, view;
    float4 color, specular, emission, ambient, parameters;
    uint4 maps;
    float4 reflection,shadowLinear,shadowOffset;
};
struct EnvironmentUniforms { float4 ambient,diffuse,specular,light,fogColor,fog; };
float4 applyTrackFog(float4 color,float distance,constant EnvironmentUniforms &e) {
    if(e.fog.z>0) {
        float factor=clamp((e.fog.y-distance)/(e.fog.y-e.fog.x),0.0f,1.0f);
        color.rgb=mix(clamp(e.fogColor.rgb,0.0f,1.0f),color.rgb,factor);
    }
    return color;
}
constant bool assetAlphaTest [[function_constant(0)]];
struct AssetVarying { float4 position [[position, invariant]]; float4 primary; float3 secondary; float4 uv01; float4 uv23; float fogDistance; };
vertex AssetVarying assetVertex(uint id [[vertex_id]],const device AssetVertex *v [[buffer(0)]],constant AssetUniforms &u [[buffer(1)]],constant EnvironmentUniforms &e [[buffer(2)]]) {
    AssetVarying o;
    float4 p=u.model*v[id].position;
    o.position=u.viewProjection*p;o.fogDistance=abs((u.view*p).z);o.uv01=v[id].uv01;o.uv23=v[id].uv23;
    if(u.reflection.w>0) {
        o.uv01.z += u.reflection.x;
        float2 uv=o.uv23.xy;
        o.uv23.xy=float2(u.reflection.y*uv.x-u.reflection.z*uv.y,u.reflection.z*uv.x+u.reflection.y*uv.y);
    }
    if(u.shadowOffset.w>0) {
        float2 uv=o.uv23.zw;
        o.uv23.zw=float2(dot(u.shadowLinear.xz,uv),dot(u.shadowLinear.yw,uv))+u.shadowOffset.xy;
    }
    float3 n=normalize((u.normalMatrix*v[id].normal).xyz);
    float3 light=e.light.xyz;
    float diffuse=max(dot(n,light),0.0f);
    // Color-material uses ambient and diffuse. Default global ambient is .2,
    // grscene's default light ambient .2, diffuse .8 and specular .3.
    float3 eyeDirection=normalize((transpose(u.view)*float4(0,0,1,0)).xyz);
    float3 halfVector=normalize(light+eyeDirection);
    float shine=diffuse>0 ? pow(max(dot(n,halfVector),0.0f),clamp(u.parameters.x,0.0f,128.0f)):0.0f;
    o.primary=u.parameters.z>0 ? float4(clamp(u.emission.rgb+u.color.rgb*(float3(0.2f)+e.ambient.rgb+e.diffuse.rgb*diffuse),0.0f,1.0f),u.color.a):u.color;
    o.secondary=u.parameters.z>0 ? clamp(u.specular.rgb*e.specular.rgb*shine,0.0f,1.0f):float3(0);
    return o;
}
fragment float4 assetFragment(AssetVarying in [[stage_in]],constant AssetUniforms &u [[buffer(1)]],texture2d<float> base [[texture(0)]],texture2d<float> detail [[texture(1)]],texture2d<float> overlay [[texture(2)]],texture2d<float> trackShadow [[texture(3)]],sampler s [[sampler(0)]],constant EnvironmentUniforms &e [[buffer(2)]]) {
    float4 color=in.primary;
    if(u.maps.x) color*=base.sample(s,in.uv01.xy);
    if(u.maps.y) color*=detail.sample(s,in.uv01.zw);
    if(u.maps.z) color*=overlay.sample(s,in.uv23.xy);
    if(u.maps.w) color*=trackShadow.sample(s,in.uv23.zw);
    color.rgb=clamp(color.rgb+in.secondary,0.0f,1.0f);
    if(assetAlphaTest && color.a<=u.parameters.y) discard_fragment();
    return applyTrackFog(color,in.fogDistance,e);
}

// Original textured ground-projected shadow with white color-material lighting.
struct ShadowVertex { float4 position,uv; };
struct ShadowVarying { float4 position [[position, invariant]];float2 uv;float fogDistance;float3 lighting; };
struct ShadowUniforms { float4x4 viewProjection,view;float4 normal; };
vertex ShadowVarying shadowVertex(uint id [[vertex_id]],constant ShadowVertex *v [[buffer(0)]],constant ShadowUniforms &u [[buffer(1)]],constant EnvironmentUniforms &e [[buffer(2)]]) {
    ShadowVarying o;o.position=u.viewProjection*v[id].position;o.uv=v[id].uv.xy;o.fogDistance=abs((u.view*v[id].position).z);o.lighting=clamp(float3(0.2f)+e.ambient.rgb+e.diffuse.rgb*max(dot(normalize(u.normal.xyz),e.light.xyz),0.0f),0.0f,1.0f);return o;
}
fragment float4 shadowFragment(ShadowVarying in [[stage_in]],texture2d<float> shadow [[texture(0)]],sampler s [[sampler(0)]],constant EnvironmentUniforms &e [[buffer(2)]],constant float &threshold [[buffer(3)]]) {
    float4 color=shadow.sample(s,in.uv);if(assetAlphaTest && color.a<=threshold) discard_fragment();color.rgb*=in.lighting;return applyTrackFog(color,in.fogDistance,e);
}
vertex ShadowVarying backgroundVertex(uint id [[vertex_id]],const device ShadowVertex *v [[buffer(0)]],constant float4x4 &vp [[buffer(1)]]) {
    ShadowVarying o;o.position=vp*v[id].position;o.uv=v[id].uv.xy;o.fogDistance=0;o.lighting=1;return o;
}
fragment float4 backgroundFragment(ShadowVarying in [[stage_in]],texture2d<float> sky [[texture(0)]],sampler s [[sampler(0)]]) {
    return sky.sample(s,in.uv);
}

// Original rear-view mirror: horizontal reversal, RGB copy, no lighting/fog.
// Semantic port of grcam.cpp, Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
struct MirrorVarying { float4 position [[position, invariant]];float2 uv; };
vertex MirrorVarying mirrorVertex(uint id [[vertex_id]],constant float4 &rect [[buffer(0)]]) {
    float2 p=float2(id/2,id%2);
    MirrorVarying o;o.position=float4(rect.x+p.x*rect.z,rect.y-p.y*rect.w,0,1);o.uv=float2(1-p.x,p.y);return o;
}
fragment float4 mirrorFragment(MirrorVarying in [[stage_in]],texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    return float4(image.sample(s,in.uv).rgb,1);
}

// TORCS grcarlight, Copyright (C) 2001 Christophe Guionneau; GPL-2.0-or-later.
// GL_CLAMP clamps coordinates before filtering with the default transparent border.
struct LightUniforms { float4x4 viewProjection,view; };
struct LightVarying { float4 position [[position, invariant]];float2 uv;float fogDistance; };
vertex LightVarying lightVertex(uint id [[vertex_id]],constant ShadowVertex *v [[buffer(0)]],constant LightUniforms &u [[buffer(1)]]) {
    LightVarying o;o.position=u.viewProjection*v[id].position;o.uv=v[id].uv.xy;o.fogDistance=abs((u.view*v[id].position).z);return o;
}
fragment float4 lightFragment(LightVarying in [[stage_in]],texture2d<float> image [[texture(0)]],constant EnvironmentUniforms &e [[buffer(2)]],constant float &threshold [[buffer(3)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_zero,filter::linear);
    float4 color=image.sample(s,clamp(in.uv,0.0f,1.0f),level(0))*float4(0.8f,0.8f,0.8f,0.75f);
    if(assetAlphaTest && color.a<=threshold) discard_fragment();
    return applyTrackFog(color,in.fogDistance,e);
}

// Optional volume trees. Shared trunks and foliage sprays retain the source atlas;
// this isolated enhancement does not change original material-state inheritance.
struct VegetationInstance { float4x4 model,normal;float4 tint; };
struct VegetationView { float4x4 model,normal,viewProjection,view; };
struct VegetationVarying { float4 position [[position, invariant]];float3 normal;float4 uv;float3 tint; };
vertex VegetationVarying vegetationVertex(uint vertexID [[vertex_id]],uint instanceID [[instance_id]],
    const device AssetVertex *vertices [[buffer(0)]],const device VegetationInstance *trees [[buffer(1)]],
    constant VegetationView &view [[buffer(3)]],constant uint *selected [[buffer(4)]]) {
    AssetVertex v=vertices[vertexID];VegetationInstance tree=trees[selected[instanceID]];
    float4 p=view.model*tree.model*v.position;
    VegetationVarying o;o.position=view.viewProjection*p;o.normal=(view.normal*tree.normal*v.normal).xyz;
    o.uv=v.uv01;o.tint=tree.tint.rgb;return o;
}
fragment float4 vegetationFragment(VegetationVarying in [[stage_in]],bool front [[front_facing]],
    texture2d<float> atlas [[texture(0)]],sampler s [[sampler(0)]],constant EnvironmentUniforms &e [[buffer(2)]]) {
    float4 color;
    if(in.uv.z>0.5f) {
        float grain=0.85f+0.15f*sin(in.uv.x*88.0f+sin(in.uv.y*3.0f));
        color=float4(float3(0.26f,0.20f,0.13f)*grain,1.0f);
    } else {
        color=atlas.sample(s,in.uv.xy);
    }
    float3 normal=normalize(in.normal)*(front ? 1.0f:-1.0f);
    float sun=max(dot(normal,e.light.xyz),0.0f);
    // Source foliage already carries photographed local shading. Soft fill
    // avoids lighting it twice; trunks retain stronger directional shading.
    float3 lighting=in.uv.z>0.5f ? clamp(float3(0.35f)+e.ambient.rgb*0.5f+e.diffuse.rgb*(0.65f*sun),0.0f,1.1f):clamp(float3(0.62f)+e.ambient.rgb*0.4f+e.diffuse.rgb*(0.30f*sun),0.0f,1.1f);
    color.rgb*=lighting*in.tint*in.uv.w;
    // SceneCamera uses perspective clip w = -eye z. Metal fragment position.w
    // is reciprocal clip w, so this recovers the same eye-space fog distance
    // without an additional varying. Keep the fog clamp in the fragment stage.
    color.a=1.0f;return applyTrackFog(color,1.0f/in.position.w,e);
}
