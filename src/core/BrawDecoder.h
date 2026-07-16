#pragma once
#include "core/Types.h"
#include <string>
#include <vector>
#include <map>
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
    std::vector<uint8_t> DecodeFrameSync(uint64_t frameIndex,
                                          int* outWidth, int* outHeight,
                                          int* outBytesPerRow,
                                          const ClipAdjustments& adjustments,
                                          float scale = 1.0f);

    // Parallel CPU decode: submit count frames, decode across available cores.
    // Returns pixel data in frame order. Blocks until all complete.
    // count=0 defaults to number of CPU cores.
    std::vector<std::vector<uint8_t>> DecodeFramesSyncBatch(
        uint64_t startFrame, int count,
        const ClipAdjustments& adjustments,
        int* outWidth, int* outHeight, float scale = 1.0f);

    // GPU decode: returns retained MTLBuffer on GPU (caller must CFRelease)
    void* DecodeFrameGPU(uint64_t frameIndex,
                          int* outWidth, int* outHeight,
                          int* outBytesPerRow,
                          const ClipAdjustments& adjustments);

    // GPU decode at reduced scale: returns retained MTLBuffer (caller must CFRelease)
    void* DecodeFrameGPUScaled(uint64_t frameIndex,
                                int* outWidth, int* outHeight,
                                int* outBytesPerRow,
                                const ClipAdjustments& adjustments,
                                float scale);

    // Capture native camera settings from frame 0
    void CaptureNativeSettings();

    uint32_t GetNativeISO() const;
    uint32_t GetNativeColorTemp() const;
    int16_t  GetNativeTint() const;
    float    GetNativeExposure() const;

    std::string GetClipGamma() const;
    std::string GetClipGamut() const;
    uint16_t    GetColorScienceGen() const;
    std::map<std::string, std::string> GetFreeFormMetadata() const;

    // Audio extraction: returns PCM float samples (caller frees with free())
    float* ExtractAudio(uint32_t* outSampleRate, uint32_t* outChannels,
                        uint64_t* outSampleCount);

    void FlushJobs();

    struct Impl;
    friend class BrawDecoderCallback;

private:
    std::unique_ptr<Impl> m_impl;
};
