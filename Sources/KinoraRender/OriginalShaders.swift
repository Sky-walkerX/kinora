// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 The Kinora Contributors

/// The Metal source of Kinora's generative wallpapers. Compiled at run time with
/// `makeLibrary(source:)`, because SwiftPM's command-line build cannot compile `.metal` files.
/// Written for Kinora; the techniques (value noise, fractal sums, domain warping, metaballs)
/// are textbook. Each fragment function's name is a `KinoraOriginal.slug`.
enum OriginalShaders {
    static let vertexFunction = "kinoraVertex"

    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    // Must match OriginalUniforms in OriginalRenderer.swift: five float4s.
    struct Uniforms {
        float4 resolutionTime; // x, y: drawable size in pixels; z: seconds of motion; w: unused
        float4 sun;            // x: elevation in degrees; y: azimuth; z: daylight 0...1; w: sun's offset from the view's centre in degrees
        float4 colorA;
        float4 colorB;
        float4 colorC;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv; // 0...1, y up
    };

    // One triangle that covers the whole drawable.
    vertex VertexOut kinoraVertex(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VertexOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        out.uv = p;
        return out;
    }

    inline float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    inline float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float a = hash21(i);
        float b = hash21(i + float2(1.0, 0.0));
        float c = hash21(i + float2(0.0, 1.0));
        float d = hash21(i + float2(1.0, 1.0));
        float2 s = f * f * (3.0 - 2.0 * f);
        return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
    }

    inline float fbm(float2 p, int octaves) {
        float value = 0.0;
        float amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            value += amplitude * valueNoise(p);
            p = p * 2.03 + float2(17.1, 9.2);
            amplitude *= 0.5;
        }
        return value;
    }

    // Breaks up banding in slow 8-bit gradients.
    inline float3 dither(float3 color, float2 pixel, float t) {
        return color + (hash21(pixel + fract(t)) - 0.5) / 255.0;
    }

    // Soft colour fields that warp into one another.
    fragment float4 tide(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 res = u.resolutionTime.xy;
        float t = u.resolutionTime.z * 0.03;
        float2 p = in.uv * float2(res.x / max(res.y, 1.0), 1.0) * 1.6;
        float2 q = float2(fbm(p + float2(0.0, t), 4), fbm(p + float2(5.2, 1.3 - t), 4));
        float2 r = float2(fbm(p + 3.0 * q + float2(1.7, 9.2) + 0.15 * t, 4), fbm(p + 3.0 * q + float2(8.3, 2.8) - 0.12 * t, 4));
        float f = fbm(p + 2.5 * r, 4);
        float3 color = mix(u.colorA.rgb, u.colorB.rgb, smoothstep(0.2, 0.8, f));
        color = mix(color, u.colorC.rgb, smoothstep(0.55, 0.95, r.x) * 0.6);
        color *= 0.85 + 0.15 * in.uv.y;
        return float4(dither(color, in.position.xy, u.resolutionTime.z), 1.0);
    }

    // Curtains of light over a starry sky.
    fragment float4 aurora(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 res = u.resolutionTime.xy;
        float t = u.resolutionTime.z;
        float aspect = res.x / max(res.y, 1.0);
        float2 uv = in.uv;
        float3 color = mix(u.colorC.rgb * 1.6, u.colorC.rgb * 0.5, uv.y);
        float2 cell = floor(float2(uv.x * aspect, uv.y) * 180.0);
        float star = step(0.996, hash21(cell)) * (0.6 + 0.4 * sin(t * 0.5 + hash21(cell + 3.1) * 6.2831));
        color += star * smoothstep(0.25, 0.6, uv.y) * 0.8;
        float3 light = float3(0.0);
        for (int i = 0; i < 3; i++) {
            float fi = float(i);
            float x = uv.x * aspect * (0.8 + 0.25 * fi) + fi * 1.7;
            float wave = fbm(float2(x * 0.9, t * 0.02 + fi * 3.0), 4);
            float base = 0.45 + 0.12 * fi + 0.25 * (wave - 0.5);
            float d = uv.y - base;
            float curtain = exp(-max(d, 0.0) * (6.0 + 2.0 * fi)) * smoothstep(-0.02, 0.01, d);
            float rays = 0.6 + 0.4 * fbm(float2(x * 8.0, t * 0.05 + fi), 3);
            float3 tint = mix(u.colorA.rgb, u.colorB.rgb, clamp(d * 2.5 + 0.2 * fi, 0.0, 1.0));
            light += tint * curtain * rays * (0.55 - 0.12 * fi);
        }
        color += light;
        return float4(dither(color, in.position.xy, t), 1.0);
    }

    // Wax blobs rising and falling, merging where their fields meet.
    fragment float4 lava(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 res = u.resolutionTime.xy;
        float t = u.resolutionTime.z * 0.12;
        float aspect = res.x / max(res.y, 1.0);
        float2 p = float2(in.uv.x * aspect, in.uv.y);
        float field = 0.0;
        for (int i = 0; i < 7; i++) {
            float fi = float(i);
            float speed = 0.35 + 0.15 * hash21(float2(fi, 1.0));
            float2 c = float2((0.15 + 0.7 * hash21(float2(fi, 7.0))) * aspect + 0.08 * sin(t * 0.7 + fi * 2.1),
                              0.5 + 0.45 * sin(t * speed + fi * 1.3));
            float radius = 0.10 + 0.07 * hash21(float2(fi, 3.0));
            float2 d = p - c;
            field += radius * radius / max(dot(d, d), 0.0001);
        }
        float wax = smoothstep(0.9, 1.15, field);
        float glow = smoothstep(0.25, 1.0, field);
        float3 background = mix(u.colorC.rgb, u.colorC.rgb * 2.2, 1.0 - in.uv.y) + u.colorB.rgb * 0.12 * glow;
        float3 waxColor = mix(u.colorB.rgb, u.colorA.rgb, clamp(in.uv.y * 0.6 + 0.4 * (field - 1.0), 0.0, 1.0));
        float3 color = mix(background, waxColor, wax);
        color += wax * smoothstep(1.4, 3.0, field) * 0.15;
        return float4(dither(color, in.position.xy, u.resolutionTime.z), 1.0);
    }

    // The sky where the Mac is: colours from the sun's real elevation, the sun itself, stars at
    // night, and clouds drifting east.
    fragment float4 liveSky(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 res = u.resolutionTime.xy;
        float t = u.resolutionTime.z;
        float aspect = res.x / max(res.y, 1.0);
        float2 uv = in.uv;
        float elevation = u.sun.x;
        float day = u.sun.z;
        float g = (elevation - 2.0) / 6.0;
        float golden = exp(-g * g);
        float3 zenith = mix(u.colorC.rgb, u.colorA.rgb * 0.75, day);
        float3 horizon = mix(u.colorC.rgb * 2.5 + float3(0.02, 0.03, 0.06), mix(u.colorA.rgb, float3(0.92, 0.95, 1.0), 0.6), day);
        horizon = mix(horizon, u.colorB.rgb, golden * 0.85);
        float3 color = mix(horizon, zenith, pow(clamp(uv.y, 0.0, 1.0), 0.6));

        float2 sunAt = float2(0.5 + u.sun.w / 180.0, elevation / 70.0);
        float2 d = float2((uv.x - sunAt.x) * aspect, uv.y - sunAt.y);
        float dist = length(d);
        float3 sunColor = mix(u.colorB.rgb * 1.2, float3(1.0, 0.97, 0.9), clamp(elevation / 20.0, 0.0, 1.0));
        float risen = smoothstep(-2.0, 1.0, elevation);
        color += sunColor * (smoothstep(0.035, 0.028, dist) * 1.2 + exp(-dist * 7.0) * 0.35 * (0.4 + golden)) * risen;

        float2 cell = floor(float2(uv.x * aspect, uv.y) * 220.0);
        float star = step(0.9965, hash21(cell)) * (0.5 + 0.5 * sin(t * 0.4 + hash21(cell + 7.7) * 6.2831));
        color += star * (1.0 - day) * smoothstep(0.1, 0.5, uv.y) * 0.7;

        float2 cp = float2(uv.x * aspect * 1.4 + t * 0.004, uv.y * 3.0);
        float cloud = fbm(cp + float2(0.0, t * 0.001), 5);
        cloud = smoothstep(0.5, 0.78, cloud) * smoothstep(0.05, 0.35, uv.y) * (1.0 - 0.5 * uv.y);
        float3 lit = mix(float3(0.10, 0.11, 0.16), float3(1.0), day);
        lit = mix(lit, u.colorB.rgb * 1.1 + 0.1, golden * 0.7);
        color = mix(color, lit, cloud * 0.8);
        return float4(dither(color, in.position.xy, t), 1.0);
    }
    """#
}
