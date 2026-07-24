#pragma once
#include "core/Types.h"
#include <string>
#include <vector>
#include <map>
#include <functional>
#include <memory>

class BrawDecoder {
public:
    using FrameCallback = std::function<void(const uint8_t* pixels,
                                              int width, int height,
                                              int bytesPerRow)>;

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

    // Decode a single frame synchronously. The callback receives CPU-side
    // BGRA8 pixel data. Blocks until the frame is decoded.
    void RequestFrame(uint64_t frameIndex,
                      const ClipAdjustments& adjustments,
                      FrameCallback callback,
                      float scale = 1.0f);

    // Synchronous decode returning a copy of the BGRA8 pixel data.
    std::vector<uint8_t> DecodeFrameSync(uint64_t frameIndex,
                                          int* outWidth, int* outHeight,
                                          int* outBytesPerRow,
                                          const ClipAdjustments& adjustments,
                                          float scale = 1.0f);

    // Batch CPU decode for export. Decodes all frames in [startFrame, endFrame)
    // using concurrent jobs across available CPU cores. Callbacks fire in frame
    // order. Blocks until all frames complete.
    // concurrency = 0 means auto-detect (CPU core count - 1).
    void DecodeFramesCPUBatch(uint64_t startFrame, uint64_t endFrame,
                               const ClipAdjustments& adjustments,
                               FrameCallback callback,
                               int concurrency = 0);

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
    // Audio format query: gets sample rate and channels without extracting audio.
    bool   GetAudioFormat(uint32_t* outSampleRate, uint32_t* outChannels);

    // Gyroscope / accelerometer data
    struct GyroSample {
        float timestamp;
        float x, y, z;
    };
    struct GyroData {
        std::vector<GyroSample> gyroscope;
        std::vector<GyroSample> accelerometer;
        float gyroSampleRate  = 0;
        float accelSampleRate = 0;
        float focalLength     = 0;
        bool  hasGyro    = false;
        bool  hasAccel   = false;
    };
    GyroData ExtractGyroData();

    // Set pixel format for decode (must be called before OpenClip)
    void SetOutputFormat(int format);  // 0=RGBAU8 (default), 1=RGBU16

    void FlushJobs();

    struct Impl;
    friend class BrawDecoderCallback;

private:
    std::unique_ptr<Impl> m_impl;
};
