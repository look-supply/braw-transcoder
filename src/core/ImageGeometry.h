#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
#include <algorithm>
#include <cmath>

constexpr uint32_t CustomAnamorphicMode=8;
inline bool ValidCustomDesqueeze(float ratio) {
    return std::isfinite(ratio) && ratio>=1.0f && ratio<=4.0f;
}
inline int CustomDesqueezeHeight(int height,float ratio) {
    if(ratio==1.0f)return height;
    // Even output heights are accepted by all supported export codecs.
    return std::min(height,std::max(2,int(std::lround(height/double(ratio)/2))*2));
}

// Flips are relative to the displayed image, after clockwise rotation.
template<size_t PixelBytes>
inline void TransformImage(std::vector<uint8_t>& pixels, int& width, int& height,
                           uint32_t turns, uint32_t flips) {
    turns &= 3; flips &= 3;
    if (!turns && !flips) return;
    const int outW=(turns&1)?height:width, outH=(turns&1)?width:height;
    std::vector<uint8_t> output(pixels.size());
    for(int y=0;y<height;y++)for(int x=0;x<width;x++) {
        int dx=x,dy=y;
        if(turns==1){dx=height-1-y;dy=x;}
        else if(turns==2){dx=width-1-x;dy=height-1-y;}
        else if(turns==3){dx=y;dy=width-1-x;}
        if(flips&1)dx=outW-1-dx;
        if(flips&2)dy=outH-1-dy;
        memcpy(output.data()+(size_t(dy)*outW+dx)*PixelBytes,
               pixels.data()+(size_t(y)*width+x)*PixelBytes,PixelBytes);
    }
    pixels=std::move(output);width=outW;height=outH;
}
