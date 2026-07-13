#pragma once
#include "Types.h"

struct ExportJob {
    size_t           clipIndex;
    ClipInfo         clip;
    ExportSettings   settings;
    int              outputWidth  = 0;
    int              outputHeight = 0;
};
