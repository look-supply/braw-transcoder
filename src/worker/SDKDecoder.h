#pragma once
#include "core/Types.h"
#include <functional>
#include <memory>
#include <map>

class SDKDecoder {
public:
    struct Frame { int width=0, height=0, stride=0; std::vector<uint8_t> pixels; };
    struct AudioInfo { uint32_t rate=0, channels=0, bits=0; uint64_t samples=0; };
    struct GyroSample { float timestamp, x, y, z; };
    struct GyroData {
        std::vector<GyroSample> gyroscope, accelerometer;
        float gyroSampleRate=0, accelSampleRate=0, focalLength=0;
        bool hasGyro=false, hasAccel=false;
    };
    SDKDecoder();
    ~SDKDecoder();
    bool Open(const std::string& path, bool metal, int format);
    void Close();
    bool Decode(uint64_t index, const ClipAdjustments&, float scale, Frame&);
    AudioInfo GetAudioInfo();
    bool ReadAudio(uint64_t start, uint32_t count, std::vector<uint8_t>& bytes);
    uint32_t GetWidth() const;
    uint32_t GetHeight() const;
    float GetFrameRate() const;
    uint64_t GetFrameCount() const;
    uint32_t GetNativeISO() const;
    std::vector<uint32_t> GetISOList() const;
    bool ISOIsReadOnly() const;
    uint32_t GetLensCorrectionSupport() const;
    GeometryInfo GetGeometryInfo() const;
    ToneCurveInfo GetToneCurveInfo() const;
    bool HasEmbeddedLUT() const;
    std::string EmbeddedLUTName() const;
    bool ReadEmbeddedLUTCube(std::vector<uint8_t>& bytes);
    uint32_t GetNativeColorTemp() const;
    int16_t GetNativeTint() const;
    float GetNativeExposure() const;
    std::string GetCameraType() const;
    std::string GetClipGamma() const;
    std::string GetClipGamut() const;
    uint16_t GetColorScienceGen() const;
    std::map<std::string,std::string> GetFreeFormMetadata(bool includeAll = false) const;
    bool GetAudioFormat(uint32_t*,uint32_t*);
    GyroData ExtractGyroData();
    std::string Version() const;
    struct Impl;
private:
    std::unique_ptr<Impl> m_impl;
};
