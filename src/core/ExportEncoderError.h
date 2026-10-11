#pragma once
#include <string>

inline std::string ExportEncoderError(int codec,int width,int height,const std::string& detail) {
    const std::string name=codec==0?"H.264":codec==1?"HEVC":"ProRes";
    const std::string dimensions=std::to_string(width)+" × "+std::to_string(height);
    if(codec<2&&(detail.find("Cannot prepare encoder")!=std::string::npos||
                 detail.find("Error while opening encoder")!=std::string::npos)) {
        return "macOS could not initialize the hardware "+name+" encoder for "+dimensions+
            ". This output size or encoding setting is unsupported. Choose 4K or 1080p in Resolution and retry. "
            "The original BRAW frames are still decoded at full resolution before resizing.\n"+detail;
    }
    if(detail.find("memory budget")!=std::string::npos)
        return name+" encoding at "+dimensions+" exceeded the processing memory budget. Choose a smaller output resolution and retry.\n"+detail;
    return name+" encoder failed at "+dimensions+": "+detail;
}
