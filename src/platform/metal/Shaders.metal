#include <metal_stdlib>
using namespace metal;

constant float B = 0.0f;
constant float C = 0.75f;

inline float bicubic_weight(float x) {
    x = fabs(x);
    if (x < 1.0f) {
        return ((12.0f - 9.0f * B - 6.0f * C) * x * x * x +
                (-18.0f + 12.0f * B + 6.0f * C) * x * x +
                (6.0f - 2.0f * B)) / 6.0f;
    } else if (x < 2.0f) {
        return ((-B - 6.0f * C) * x * x * x +
                (6.0f * B + 30.0f * C) * x * x +
                (-12.0f * B - 48.0f * C) * x +
                (8.0f * B + 24.0f * C)) / 6.0f;
    }
    return 0.0f;
}

kernel void bicubic_sharper_scale(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint dstW = dstTex.get_width();
    uint dstH = dstTex.get_height();
    uint srcW = srcTex.get_width();
    uint srcH = srcTex.get_height();

    if (gid.x >= dstW || gid.y >= dstH) return;

    float scaleX = float(srcW) / float(dstW);
    float scaleY = float(srcH) / float(dstH);

    float srcX = (float(gid.x) + 0.5f) * scaleX - 0.5f;
    float srcY = (float(gid.y) + 0.5f) * scaleY - 0.5f;

    int ix = int(floor(srcX));
    int iy = int(floor(srcY));

    float4 result = float4(0.0f);

    for (int dy = -1; dy <= 2; ++dy) {
        float wy = bicubic_weight(float(dy) - (srcY - float(iy)));
        int sy = clamp(iy + dy, 0, int(srcH) - 1);

        for (int dx = -1; dx <= 2; ++dx) {
            float wx = bicubic_weight(float(dx) - (srcX - float(ix)));
            int sx = clamp(ix + dx, 0, int(srcW) - 1);

            result += wx * wy * srcTex.read(uint2(sx, sy));
        }
    }

    dstTex.write(result, gid);
}

kernel void color_grade(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    constant float& exposure  [[buffer(0)]],
    constant float& kelvinScale  [[buffer(1)]],
    constant float& tintBias   [[buffer(2)]],
    constant float& highlightRecovery [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 color = srcTex.read(gid);

    float exposureMult = exp2(exposure);
    color.rgb *= exposureMult;

    color.r *= kelvinScale;
    color.b /= kelvinScale;

    color.r += tintBias;
    color.b -= tintBias;

    if (highlightRecovery > 0.5f) {
        float maxComp = max(max(color.r, color.g), color.b);
        if (maxComp > 1.0f) {
            float over = maxComp - 1.0f;
            float blendFactor = min(over / max(maxComp, 0.001f), 0.9f);
            float lum = dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
            color.rgb = mix(color.rgb, float3(lum), blendFactor * 0.5f);
        }
    }

    color = clamp(color, 0.0f, 1.0f);

    dstTex.write(color, gid);
}

kernel void copy_texture(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x < dstTex.get_width() && gid.y < dstTex.get_height()) {
        dstTex.write(srcTex.read(gid), gid);
    }
}
