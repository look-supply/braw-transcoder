#include "platform/metal/VideoToolboxEncoder.h"
#include <iostream>
#include <fstream>
#include <cstring>

VideoToolboxEncoder::VideoToolboxEncoder()  = default;
VideoToolboxEncoder::~VideoToolboxEncoder() { Close(); }

CMVideoCodecType VideoToolboxEncoder::GetCMCodecType() const {
    switch (m_codec) {
        case CodecType::H264:  return kCMVideoCodecType_H264;
        case CodecType::H265:  return kCMVideoCodecType_HEVC;
        case CodecType::ProRes: return kCMVideoCodecType_AppleProRes4444;
    }
    return kCMVideoCodecType_HEVC;
}

static inline CFNumberRef MakeCFNumber(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static inline CFNumberRef MakeCFNumberFloat(float value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &value);
}

bool VideoToolboxEncoder::Open(const std::string& outputPath,
                                int width, int height,
                                float frameRate,
                                CodecType codec,
                                int proResProfile,
                                int dataRateMbps,
                                int audioSampleRate,
                                int audioChannels,
                                int audioSampleCount) {
    m_outputPath = outputPath;
    m_width      = width;
    m_height     = height;
    m_frameRate  = frameRate;
    m_codec      = codec;
    m_frameCount = 0;
    m_audioSampleRate = audioSampleRate;
    m_audioChannels   = audioChannels;
    m_audioSampleCount = audioSampleCount;
    m_audioBuffer.clear();
    m_opened     = false;

    CMVideoCodecType cmCodec = GetCMCodecType();

    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width, height,
        cmCodec,
        NULL, NULL, NULL,
        nullptr,
        nullptr,
        &m_session);

    if (status != noErr) {
        std::cerr << "VTCompressionSessionCreate failed: " << status << std::endl;
        return false;
    }

    int bitrate = dataRateMbps * 1000000;

    CFNumberRef cfRealTime = MakeCFNumber(0);
    VTSessionSetProperty(m_session, kVTCompressionPropertyKey_RealTime, cfRealTime);
    CFRelease(cfRealTime);

    if (codec == CodecType::H265) {
        VTSessionSetProperty(m_session, kVTCompressionPropertyKey_ProfileLevel,
            kVTProfileLevel_HEVC_Main10_AutoLevel);
    } else if (codec == CodecType::H264) {
        VTSessionSetProperty(m_session, kVTCompressionPropertyKey_ProfileLevel,
            kVTProfileLevel_H264_High_AutoLevel);
    }

    CFNumberRef cfReorder = MakeCFNumber(0);
    VTSessionSetProperty(m_session, kVTCompressionPropertyKey_AllowFrameReordering, cfReorder);
    CFRelease(cfReorder);

    CFNumberRef cfKeyFrame = MakeCFNumber(static_cast<int>(frameRate * 2));
    VTSessionSetProperty(m_session, kVTCompressionPropertyKey_MaxKeyFrameInterval, cfKeyFrame);
    CFRelease(cfKeyFrame);

    CFNumberRef cfBitrate = MakeCFNumber(bitrate);
    VTSessionSetProperty(m_session, kVTCompressionPropertyKey_AverageBitRate, cfBitrate);
    CFRelease(cfBitrate);

    CFNumberRef cfQuality = MakeCFNumberFloat(0.85f);
    VTSessionSetProperty(m_session, kVTCompressionPropertyKey_Quality, cfQuality);
    CFRelease(cfQuality);

    VTCompressionSessionPrepareToEncodeFrames(m_session);

    std::ofstream test(outputPath, std::ios::binary);
    if (!test.is_open()) {
        std::cerr << "Cannot open output file: " << outputPath << std::endl;
        return false;
    }
    test.close();

    m_opened = true;
    return true;
}

static void CompressionOutputCallback(void* outputCallbackRefCon,
                                       void* sourceFrameRefCon,
                                       OSStatus status,
                                       VTEncodeInfoFlags infoFlags,
                                       CMSampleBufferRef sampleBuffer) {
    if (status != noErr || !sampleBuffer) return;

    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (!block) return;

    size_t totalLength = 0;
    char* dataPtr = nullptr;
    OSStatus err = CMBlockBufferGetDataPointer(block, 0, nullptr, &totalLength, &dataPtr);
    if (err != noErr || !dataPtr || totalLength == 0) return;

    VideoToolboxEncoder* self = static_cast<VideoToolboxEncoder*>(outputCallbackRefCon);
    if (self) {
        self->WriteToFile(dataPtr, totalLength);
    }
}

void VideoToolboxEncoder::WriteToFile(const void* data, size_t size) {
    std::ofstream file(m_outputPath, std::ios::binary | std::ios::app);
    if (file.is_open()) {
        file.write(static_cast<const char*>(data), size);
    }
}

bool VideoToolboxEncoder::WriteFrame(void* pixelBuffer, int64_t frameIndex) {
    if (!m_session || !pixelBuffer) return false;
    if (!m_opened) return false;

    CVPixelBufferRef cvBuf = (CVPixelBufferRef)pixelBuffer;

    CMTime pts = CMTimeMake(frameIndex, static_cast<int32_t>(m_frameRate));
    CMTime dur = CMTimeMake(1, static_cast<int32_t>(m_frameRate));

    OSStatus status = VTCompressionSessionEncodeFrame(
        m_session,
        cvBuf,
        pts,
        dur,
        NULL,
        this,
        NULL);

    if (status != noErr && status != kVTInvalidSessionErr) {
        std::cerr << "Encode frame failed: " << status << std::endl;
    }

    CVPixelBufferRelease(cvBuf);
    m_frameCount++;
    return status == noErr;
}

bool VideoToolboxEncoder::WriteAudio(const float* pcmData, uint64_t sampleCount) {
    if (!pcmData || sampleCount == 0) return false;
    m_audioBuffer.assign(pcmData, pcmData + sampleCount * m_audioChannels);
    m_audioSampleCount = sampleCount;
    return true;
}

bool VideoToolboxEncoder::Close() {
    if (m_session) {
        VTCompressionSessionCompleteFrames(m_session, kCMTimeInvalid);
        VTCompressionSessionInvalidate(m_session);
        CFRelease(m_session);
        m_session = nullptr;
    }

    if (!m_audioBuffer.empty()) {
        MuxAudioIntoFile();
    }

    m_opened = false;
    return true;
}

bool VideoToolboxEncoder::MuxAudioIntoFile() {
    return true;
}
