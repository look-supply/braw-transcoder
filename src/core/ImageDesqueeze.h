#pragma once
#include "core/Types.h"
#include "core/ImageGeometry.h"
#include <Accelerate/Accelerate.h>

template<typename Image>
inline bool DesqueezeImage(Image& frame,int format,float ratio) {
    if(!ValidCustomDesqueeze(ratio))return false;
    const int height=CustomDesqueezeHeight(frame.height,ratio);
    if(height==frame.height)return true;
    const size_t width=frame.width;
    std::vector<uint8_t> output(width*height*(format==1?6:4));
    if(format==1) {
        // Resample each RGB channel at 16-bit precision; never pass through BGRA8.
        std::vector<uint16_t> source(width*frame.height),destination(width*height);
        for(size_t channel=0;channel<3;channel++) {
            for(size_t pixel=0;pixel<source.size();pixel++)
                memcpy(&source[pixel],frame.pixels.data()+(pixel*3+channel)*2,2);
            vImage_Buffer input{source.data(),size_t(frame.height),width,width*2};
            vImage_Buffer result{destination.data(),size_t(height),width,width*2};
            if(vImageScale_Planar16U(&input,&result,nullptr,kvImageHighQualityResampling)!=kvImageNoError)return false;
            for(size_t pixel=0;pixel<destination.size();pixel++)
                memcpy(output.data()+(pixel*3+channel)*2,&destination[pixel],2);
        }
    } else {
        vImage_Buffer input{frame.pixels.data(),size_t(frame.height),width,width*4};
        vImage_Buffer result{output.data(),size_t(height),width,width*4};
        if(vImageScale_ARGB8888(&input,&result,nullptr,kvImageHighQualityResampling)!=kvImageNoError)return false;
    }
    frame.pixels=std::move(output);frame.height=height;frame.stride=width*(format==1?6:4);
    return true;
}
