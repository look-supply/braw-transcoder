#pragma once
#include "platform/IVideoEncoder.h"
#include <VideoToolbox/VideoToolbox.h>
#include <CoreMedia/CoreMedia.h>
#include <string>
#include <vector>

class VideoToolboxEncoder : public IVideoEncoder {
public:
    VideoToolboxEncoder();
    ~VideoToolboxEncoder() override;

    bool Open(const std::string& outputPath,
              int width, int height,
              float frameRate,
              CodecType codec,
              int proResProfile,
              int dataRateMbps,
              int audioSampleRate,
              int audioChannels,
              int audioSampleCount) override;

    bool WriteFrame(void* pixelBuffer, int64_t frameIndex) override;
    bool WriteAudio(const float* pcmData, uint64_t sampleCount) override;
    bool Close() override;

    void WriteToFile(const void* data, size_t size);

private:
    VTCompressionSessionRef m_session = nullptr;
    CMFormatDescriptionRef  m_audioFmtDesc = nullptr;
    std::string             m_outputPath;
    int                     m_width = 0, m_height = 0;
    float                   m_frameRate = 0.0f;
    CodecType               m_codec = CodecType::H265;
    int64_t                 m_frameCount = 0;
    bool                    m_opened = false;

    int      m_audioSampleRate = 0;
    int      m_audioChannels   = 0;
    uint64_t m_audioSampleCount = 0;
    std::vector<float> m_audioBuffer;

    CMVideoCodecType GetCMCodecType() const;
    bool MuxAudioIntoFile();
};
