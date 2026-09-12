#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// Shared between Swift (via the bridging header) and Metal so the uniform layout is defined once.

#define kMaxGradientStops 4
#define kMaxRipples 8
#define kMaxMasks 8

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
    vector_float4 maskRects[kMaxMasks];  // x, y, w, h in canvas pixels
    vector_float4 maskParams[kMaxMasks]; // kind (0 blur, 1 highlight), strength, corner radius, unused
    vector_float4 cameraRect;        // x, y, w, h of the webcam overlay in canvas pixels
    vector_float4 cameraUV;          // uv rect of the camera frame shown (aspect fill)
    vector_float4 cameraBorderColor;
    vector_float4 labelRect;         // x, y, w, h of the keystroke label in canvas pixels
    float         rippleThickness;
    float         cornerRadius;
    float         shadowSigma;
    float         shadowOpacity;
    float         shadowOffsetY;
    float         cursorOpacity;
    float         cameraCornerRadius;
    float         cameraBorderWidth;
    float         cameraOpacity;     // 0 = no overlay
    float         labelOpacity;      // 0 = no label
    float         highlightDim;      // 0 = no highlight masks active
    float         padding0;
    int           gradientStopCount;
    int           backgroundType;    // 0 solid, 1 gradient
    int           motionBlurSamples;
    int           rippleCount;
    int           hasSource;
    int           maskCount;
    int           cameraShape;       // 0 circle, 1 rounded rect
    int           cameraMirrored;
    int           cameraShadow;
    int           padding1;
    int           padding2;
    int           padding3;
} FrameUniforms;

#endif /* ShaderTypes_h */
