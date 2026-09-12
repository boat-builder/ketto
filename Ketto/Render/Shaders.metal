#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

// One full-screen pass composites the whole frame: background, analytic drop shadow, the zoomed source
// with rounded corners and motion blur, blur and highlight masks, click ripples, the cursor glyph, the
// webcam overlay and the keystroke label. The same shader serves the live preview and the export encoder;
// only the render target differs.

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut compositeVertex(uint vid [[vertex_id]]) {
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    return out;
}

static float roundedRectSDF(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Analytic Gaussian-blurred rounded rectangle (Evan Wallace, "Fast rounded rectangle shadows").
static float gaussian(float x, float sigma) {
    const float pi = 3.141592653589793;
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * pi) * sigma);
}

static float2 erf2(float2 x) {
    float2 s = sign(x), a = abs(x);
    x = 1.0 + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

static float roundedBoxShadowX(float x, float y, float sigma, float corner, float2 halfSize) {
    float delta = min(halfSize.y - corner - abs(y), 0.0);
    float curved = halfSize.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf2((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

static float roundedBoxShadow(float2 lower, float2 upper, float2 point, float sigma, float corner) {
    float2 center = (lower + upper) * 0.5;
    float2 halfSize = (upper - lower) * 0.5;
    point -= center;
    float low = point.y - halfSize.y;
    float high = point.y + halfSize.y;
    float start = clamp(-3.0 * sigma, low, high);
    float end = clamp(3.0 * sigma, low, high);
    float step = (end - start) / 4.0;
    float y = start + step * 0.5;
    float value = 0.0;
    for (int i = 0; i < 4; i++) {
        value += roundedBoxShadowX(point.x, point.y - y, sigma, corner, halfSize) * gaussian(y, sigma) * step;
        y += step;
    }
    return value;
}

static float3 backgroundColor(constant FrameUniforms &u, float2 p) {
    if (u.backgroundType == 0 || u.gradientStopCount < 2) {
        return u.gradientColors[0].rgb;
    }
    float2 c = u.canvasSize * 0.5;
    float2 d = u.gradientDirection;
    float halfLength = abs(d.x) * c.x + abs(d.y) * c.y;
    float t = clamp(dot(p - c, d) / (2.0 * max(halfLength, 1e-3)) + 0.5, 0.0, 1.0);
    float pos = t * float(u.gradientStopCount - 1);
    int i = clamp(int(floor(pos)), 0, u.gradientStopCount - 2);
    float f = clamp(pos - float(i), 0.0, 1.0);
    return mix(u.gradientColors[i].rgb, u.gradientColors[i + 1].rgb, f);
}

static float3 sampleSource(texture2d<float> source, sampler s, constant FrameUniforms &u, float2 local) {
    int n = max(u.motionBlurSamples, 1);
    if (n == 1) {
        float2 uv = u.viewport.xy + local * u.viewport.zw;
        return source.sample(s, uv).rgb;
    }
    float3 acc = float3(0.0);
    for (int i = 0; i < n; i++) {
        float f = (float(i) + 0.5) / float(n);
        float4 vp = mix(u.prevViewport, u.viewport, f);
        float2 uv = vp.xy + local * vp.zw;
        acc += source.sample(s, uv).rgb;
    }
    return acc / float(n);
}

// A heavy, cheap blur for masks: a small cross of taps at a coarse mip level of the source.
static float3 sampleSourceBlurred(texture2d<float> source, sampler s, constant FrameUniforms &u, float2 local, float lod) {
    float2 uv = u.viewport.xy + local * u.viewport.zw;
    float2 texel = exp2(lod) / float2(max(source.get_width(), 1u), max(source.get_height(), 1u));
    float3 acc = source.sample(s, uv, level(lod)).rgb * 0.4;
    acc += source.sample(s, uv + float2(texel.x, 0.0), level(lod)).rgb * 0.15;
    acc += source.sample(s, uv - float2(texel.x, 0.0), level(lod)).rgb * 0.15;
    acc += source.sample(s, uv + float2(0.0, texel.y), level(lod)).rgb * 0.15;
    acc += source.sample(s, uv - float2(0.0, texel.y), level(lod)).rgb * 0.15;
    return acc;
}

fragment float4 compositeFragment(VertexOut in [[stage_in]],
                                  constant FrameUniforms &u [[buffer(0)]],
                                  texture2d<float> source [[texture(0)]],
                                  texture2d<float> cursorAtlas [[texture(1)]],
                                  texture2d<float> camera [[texture(2)]],
                                  texture2d<float> label [[texture(3)]],
                                  sampler sourceSampler [[sampler(0)]],
                                  sampler atlasSampler [[sampler(1)]]) {
    float2 p = in.position.xy / u.canvasScale;
    float3 color = backgroundColor(u, p);

    float2 rectOrigin = u.contentRect.xy;
    float2 rectSize = u.contentRect.zw;
    float2 halfSize = rectSize * 0.5;
    float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));

    if (u.shadowOpacity > 0.0 && u.shadowSigma > 0.0) {
        float2 lower = rectOrigin + float2(0.0, u.shadowOffsetY);
        float s = roundedBoxShadow(lower, lower + rectSize, p, u.shadowSigma, radius) * u.shadowOpacity;
        color = mix(color, float3(0.0), clamp(s, 0.0, 1.0));
    }

    float d = roundedRectSDF(p - (rectOrigin + halfSize), halfSize, radius);
    float coverage = 1.0 - smoothstep(-u.aaWidth, u.aaWidth, d);
    if (coverage > 0.0) {
        float2 local = (p - rectOrigin) / rectSize;
        float3 content = u.hasSource != 0 ? sampleSource(source, sourceSampler, u, local) : float3(0.11, 0.11, 0.13);

        if (u.maskCount > 0) {
            float blurCoverage = 0.0;
            float blurStrength = 0.0;
            float highlightCoverage = 0.0;
            for (int i = 0; i < u.maskCount; i++) {
                float4 m = u.maskRects[i];
                float4 mp = u.maskParams[i];
                float2 mHalf = m.zw * 0.5;
                float md = roundedRectSDF(p - (m.xy + mHalf), mHalf, min(mp.z, min(mHalf.x, mHalf.y)));
                float cov = 1.0 - smoothstep(-u.aaWidth, u.aaWidth, md);
                if (mp.x < 0.5) {
                    blurCoverage = max(blurCoverage, cov);
                    blurStrength = max(blurStrength, mp.y);
                } else {
                    highlightCoverage = max(highlightCoverage, cov);
                }
            }
            if (blurCoverage > 0.0 && u.hasSource != 0) {
                float lod = 2.5 + 2.5 * clamp(blurStrength, 0.0, 1.0);
                float3 blurred = sampleSourceBlurred(source, sourceSampler, u, local, lod);
                content = mix(content, blurred, blurCoverage);
            }
            if (u.highlightDim > 0.0) {
                content = mix(content * (1.0 - u.highlightDim), content, highlightCoverage);
            }
        }

        for (int i = 0; i < u.rippleCount; i++) {
            float4 r = u.ripples[i];
            float dist = length(p - r.xy);
            float ring = 1.0 - smoothstep(0.0, max(u.rippleThickness, 0.5), abs(dist - r.z));
            float fill = (1.0 - smoothstep(r.z * 0.55, r.z, dist)) * 0.28;
            float a = clamp(ring + fill, 0.0, 1.0) * r.w;
            content = mix(content, u.rippleColor.rgb, a);
        }

        if (u.cursorOpacity > 0.0 && u.cursorRect.z > 0.0) {
            float2 c = (p - u.cursorRect.xy) / u.cursorRect.zw;
            if (all(c >= 0.0) && all(c <= 1.0)) {
                float4 g = cursorAtlas.sample(atlasSampler, u.cursorUV.xy + c * u.cursorUV.zw); // premultiplied
                float a = g.a * u.cursorOpacity;
                content = content * (1.0 - a) + g.rgb * u.cursorOpacity;
            }
        }
        color = mix(color, content, coverage);
    }

    if (u.cameraOpacity > 0.0 && u.cameraRect.z > 0.0) {
        float2 cHalf = u.cameraRect.zw * 0.5;
        float2 cCenter = u.cameraRect.xy + cHalf;
        float2 cHalfShape = u.cameraShape == 0 ? float2(min(cHalf.x, cHalf.y)) : cHalf;
        float cRadius = u.cameraShape == 0 ? min(cHalfShape.x, cHalfShape.y) : min(u.cameraCornerRadius, min(cHalfShape.x, cHalfShape.y));
        if (u.cameraShadow != 0 && u.shadowOpacity > 0.0 && u.shadowSigma > 0.0) {
            float sigma = max(u.shadowSigma * 0.5, 1.0);
            float2 lower = cCenter - cHalfShape + float2(0.0, u.shadowOffsetY * 0.5);
            float s = roundedBoxShadow(lower, lower + cHalfShape * 2.0, p, sigma, cRadius) * u.shadowOpacity * u.cameraOpacity;
            color = mix(color, float3(0.0), clamp(s, 0.0, 1.0));
        }
        float cd = roundedRectSDF(p - cCenter, cHalfShape, cRadius);
        float cCoverage = 1.0 - smoothstep(-u.aaWidth, u.aaWidth, cd);
        if (cCoverage > 0.0) {
            float2 cl = (p - (cCenter - cHalfShape)) / (cHalfShape * 2.0);
            if (u.cameraMirrored != 0) { cl.x = 1.0 - cl.x; }
            float2 uv = u.cameraUV.xy + clamp(cl, 0.0, 1.0) * u.cameraUV.zw;
            float3 cam = camera.sample(sourceSampler, uv).rgb;
            float3 inside = cam;
            if (u.cameraBorderWidth > 0.0) {
                float inner = 1.0 - smoothstep(-u.aaWidth, u.aaWidth, cd + u.cameraBorderWidth);
                inside = mix(u.cameraBorderColor.rgb, cam, inner);
            }
            color = mix(color, inside, cCoverage * u.cameraOpacity);
        }
    }

    if (u.labelOpacity > 0.0 && u.labelRect.z > 0.0) {
        float2 l = (p - u.labelRect.xy) / u.labelRect.zw;
        if (all(l >= 0.0) && all(l <= 1.0)) {
            float4 g = label.sample(atlasSampler, float2(l.x, 1.0 - l.y)); // premultiplied, rendered y-up
            float a = g.a * u.labelOpacity;
            color = color * (1.0 - a) + g.rgb * u.labelOpacity;
        }
    }
    return float4(color, 1.0);
}
