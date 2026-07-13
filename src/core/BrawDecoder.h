#pragma once
#include "core/Types.h"
#include <string>
#include <vector>
#include <functional>
#include <memory>

class BrawDecoder {
public:
    using FrameCallback = std::function<void(void* metalBuffer, int width, int height, int bytesPerRow)>;

    BrawDecoder();
    ~BrawDecoder();

    bool OpenClip(const std::string& path);
    void Close();

    uint32_t GetWidth() const;
    uint32_t GetHeight() const;
    float GetFrameRate() const;
    uint64_t GetFrameCount() const;
    std::string GetCameraType() const;

    std::vector<uint32_t> GetISOList();

    void RequestFrame(uint64_t frameIndex,
                      const ClipAdjustments& adjustments,
                      FrameCallback callback,
                      float scale = 1.0f);

    // Synchronous decode returning CPU-side BGRA8 pixel data
    // scale: 1.0=full, 0.5=half, 0.25=quarter resolution
    std::vector<uint8_t> DecodeFrameSync(uint64_t frameIndex,
                                          int* outWidth, int* outHeight,
                                          int* outBytesPerRow,
                                          const ClipAdjustments& adjustments,
                                          float scale = 1.0f);

    // Capture native camera settings from frame 0
    void CaptureNativeSettings();

    uint32_t GetNativeISO() const;
    uint32_t GetNativeColorTemp() const;
    int16_t  GetNativeTint() const;
    float    GetNativeExposure() const;

    std::string GetClipGamma() const;
    std::string GetClipGamut() const;
    uint16_t    GetColorScienceGen() const;

    void FlushJobs();

    struct Impl;
    friend class BrawDecoderCallback;

private:
    std::unique_ptr<Impl> m_impl;
};
