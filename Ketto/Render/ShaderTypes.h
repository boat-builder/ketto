#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Shared between Swift (via the bridging header) and Metal so the uniform layout is defined once.

#define kMaxGradientStops 4
#define kMaxRipples 8

typedef struct {
    vector_float2 targetSize;        // render target size in pixels
    float         canvasScale;       // target pixels per canvas pixel
    float         aaWidth;           // anti-aliasing width in canvas pixels
    vector_float2 canvasSize;        // canvas size in canvas pixels
    vector_float2 gradientDirection; // unit vector, canvas space (y down)
    vector_float4 contentRect;       // x, y, w, h of the screen frame in canvas pixels
    vector_float4 viewport;          // normalised source rect x, y, w, h
    vector_float4 prevViewport;      // viewport one frame earlier (motion blur)
    vector_float4 gradientColors[kMaxGradientStops];
    vector_float4 cursorRect;        // x, y, w, h of the cursor glyph box in canvas pixels
    vector_float4 cursorUV;          // atlas uv rect x, y, w, h
    vector_float4 ripples[kMaxRipples]; // cx, cy, radius, alpha (canvas pixels)
    vector_float4 rippleColor;
    float         rippleThickness;
    float         cornerRadius;
    float         shadowSigma;
    float         shadowOpacity;
    float         shadowOffsetY;
    float         cursorOpacity;
    int           gradientStopCount;
    int           backgroundType;    // 0 solid, 1 gradient
    int           motionBlurSamples;
    int           rippleCount;
    int           hasSource;
    int           padding0;
} FrameUniforms;

#endif /* ShaderTypes_h */
