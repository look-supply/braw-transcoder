#pragma once
#include <cstdint>
#include <string>

enum class CodecType {
    H264,
    H265,
    ProRes,
};

class IVideoEncoder {
public:
    virtual ~IVideoEncoder() = default;

    virtual bool Open(const std::string& outputPath,
                      int width, int height,
                      float frameRate,
                      CodecType codec,
                      int proResProfile,
                      int dataRateMbps,
                      int audioSampleRate,
                      int audioChannels,
                      int audioSampleCount) = 0;

    virtual bool WriteFrame(void* pixelBuffer, int64_t frameIndex) = 0;
    virtual bool WriteAudio(const float* pcmData, uint64_t sampleCount) = 0;
    virtual bool Close() = 0;
};
