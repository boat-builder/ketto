#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

typedef struct {
    vector_float2 targetSize;
    float canvasScale;
    float padding0;
} FrameUniforms;

#endif /* ShaderTypes_h */
