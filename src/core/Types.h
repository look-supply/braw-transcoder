#pragma once
#include <cstdint>
#include <string>
#include <vector>
#include <cmath>
#include <algorithm>

enum class TargetHeightPreset {
    HEIGHT_2160_4K_DCI,
    HEIGHT_2160_4K_UHD,
    HEIGHT_1080_2K_DCI,
    HEIGHT_1080_HD,
};

constexpr int TargetHeightValue(TargetHeightPreset p) {
    switch (p) {
        case TargetHeightPreset::HEIGHT_2160_4K_DCI:  return 2160;
        case TargetHeightPreset::HEIGHT_2160_4K_UHD:  return 2160;
        case TargetHeightPreset::HEIGHT_1080_2K_DCI:  return 1080;
        case TargetHeightPreset::HEIGHT_1080_HD:      return 1080;
    }
    return 1080;
}

constexpr const char* TargetHeightLabel(TargetHeightPreset p) {
    switch (p) {
        case TargetHeightPreset::HEIGHT_2160_4K_DCI: return "4K DCI (4096)";
        case TargetHeightPreset::HEIGHT_2160_4K_UHD: return "4K UHD (3840)";
        case TargetHeightPreset::HEIGHT_1080_2K_DCI: return "2K DCI (2048)";
        case TargetHeightPreset::HEIGHT_1080_HD:     return "1080p HD (1920)";
    }
    return "1080p HD";
}

enum class OutputCodec {
    H264,
    H265,
    ProRes,
};

constexpr const char* OutputCodecLabel(OutputCodec c) {
    switch (c) {
        case OutputCodec::H264:  return "H.264";
        case OutputCodec::H265:  return "H.265";
        case OutputCodec::ProRes: return "ProRes";
    }
    return "H.265";
}

enum class ProResProfile {
    PROXY,
    LT,
    STANDARD,
    HQ,
    _4444,
    _4444XQ,
};

constexpr const char* ProResProfileLabel(ProResProfile p) {
    switch (p) {
        case ProResProfile::PROXY:    return "422 Proxy";
        case ProResProfile::LT:       return "422 LT";
        case ProResProfile::STANDARD: return "422";
        case ProResProfile::HQ:       return "422 HQ";
        case ProResProfile::_4444:    return "4444";
        case ProResProfile::_4444XQ:  return "4444 XQ";
    }
    return "422 HQ";
}

enum class DataRateMbps {
    RATE_100 = 100,
    RATE_150 = 150,
    RATE_200 = 200,
    RATE_250 = 250,
    RATE_300 = 300,
    RATE_400 = 400,
    RATE_500 = 500,
    RATE_600 = 600,
};

constexpr int DataRateValue(DataRateMbps r) { return static_cast<int>(r); }

struct ClipAdjustments {
    uint32_t iso         = 0;
    uint32_t colorTemp   = 5600;
    int16_t  tint        = 0;
    float    exposure    = 0.0f;
    bool     highlightRecovery = false;
    bool     previewLUT  = true;
};

struct ClipInfo {
    std::string filePath;
    std::string fileName;
    uint32_t nativeWidth  = 0;
    uint32_t nativeHeight = 0;
    float    frameRate    = 0.0f;
    uint64_t frameCount   = 0;
    ClipAdjustments adjustments;
    void* thumbnailTexture = nullptr;
    uint32_t audioSampleRate = 0;
    uint32_t audioChannels   = 0;
    uint64_t audioSampleCount = 0;
    uint64_t selectedFrame = 0;
};

struct ExportSettings {
    OutputCodec       codec       = OutputCodec::H265;
    ProResProfile     proResProfile = ProResProfile::HQ;
    TargetHeightPreset heightPreset = TargetHeightPreset::HEIGHT_1080_HD;
    DataRateMbps      dataRate    = DataRateMbps::RATE_200;
    std::string       outputDir;
};

inline int CalculateOutputWidth(int targetHeight, int nativeW, int nativeH) {
    if (nativeH <= 0) return targetHeight * 16 / 9;
    int w = static_cast<int>(std::round(
        (static_cast<float>(targetHeight) * static_cast<float>(nativeW))
        / static_cast<float>(nativeH)));
    return (w + 1) & ~1;
}

// Export mode IDs retain the old 2160/1080 aliases for existing callers.
// Heights are ceilings, not requested sizes: exports must never upscale.
inline bool CalculateExportDimensions(int mode, int nativeW, int nativeH, int& width, int& height) {
    int ceiling = 0;
    switch (mode) {
        case 0: break;
        case 1: case 2: ceiling = 2160; break;
        case 3: case 4: ceiling = 1080; break;
        case 5: ceiling = 4320; break;
        case 6: ceiling = 3240; break;
        default: return false;
    }
    if (nativeW <= 0 || nativeH <= 0) return false;
    width = nativeW;
    height = nativeH;
    if (ceiling && nativeH > ceiling) {
        height = ceiling;
        const double proportionalWidth = double(nativeW) * height / nativeH;
        width = std::min(nativeW & ~1, std::max(2, int(std::lround(proportionalWidth / 2)) * 2));
    }
    return width > 0 && height > 0;
}
