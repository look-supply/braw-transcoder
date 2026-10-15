std::string SDKDecoder::GetClipGamma() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v; VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamma, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v); attrs->Release();
    return result;
}

std::string SDKDecoder::GetClipGamut() const {
    if (!m_impl->clip) return "";
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return "";
    Variant v; VariantInit(&v);
    std::string result;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeGamut, &v))
        && v.vt == blackmagicRawVariantTypeString && v.bstrVal) {
        result = Impl::FromCFString(v.bstrVal);
    }
    VariantClear(&v); attrs->Release();
    return result;
}

std::map<std::string, std::string> SDKDecoder::GetFreeFormMetadata(bool includeAll) const {
    std::map<std::string, std::string> result;
    if (!m_impl->clip) return result;
    IBlackmagicRawMetadataIterator* it = nullptr;
    if (SUCCEEDED(m_impl->clip->GetMetadataIterator(&it)) && it) {
        std::map<std::string,std::string> scalar;
        auto all=ReadCameraMetadata(it, &scalar);
        result=includeAll ? std::move(all) : std::move(scalar);
        it->Release();
    }
    for(const auto& [key,value]:includeAll ? m_impl->frameMetadata : m_impl->frameExportMetadata) {
        // Preserve a differing clip value while keeping the established frame
        // value at the original key for consumers such as MOV export.
        auto clipValue=result.find(key);
        if(includeAll&&clipValue!=result.end()&&clipValue->second!=value)result["clip."+key]=clipValue->second;
        result[key]=value;
    }
    return result;
}

uint16_t SDKDecoder::GetColorScienceGen() const {
    if (!m_impl->clip) return 0;
    IBlackmagicRawClipProcessingAttributes* attrs = nullptr;
    m_impl->clip->CloneClipProcessingAttributes(&attrs);
    if (!attrs) return 0;
    Variant v; VariantInit(&v);
    uint16_t result = 0;
    if (SUCCEEDED(attrs->GetClipAttribute(blackmagicRawClipProcessingAttributeColorScienceGen, &v))
        && v.vt == blackmagicRawVariantTypeU16) {
        result = v.uiVal;
    }
    VariantClear(&v); attrs->Release();
    return result;
}

// ── Audio ──────────────────────────────────────────────────────

bool SDKDecoder::GetAudioFormat(uint32_t* outSampleRate, uint32_t* outChannels) {
    *outSampleRate = 48000; *outChannels = 2;
    if (!m_impl->clip) return false;
    IBlackmagicRawClipAudio* audio = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&audio)) && audio) {
        audio->GetAudioSampleRate(outSampleRate);
        audio->GetAudioChannelCount(outChannels);
        audio->Release();
    }
    return *outSampleRate > 0 && *outChannels > 0;
}

// ── Gyro Data ──────────────────────────────────────────────────

SDKDecoder::GyroData SDKDecoder::ExtractGyroData() {
    GyroData result;
    if (!m_impl->clip) return result;

    IBlackmagicRawClipGyroscopeMotion* gyro = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipGyroscopeMotion, (void**)&gyro)) && gyro) {
        float sampleRate = 0; uint32_t sampleCount = 0;
        gyro->GetSampleRate(&sampleRate);
        gyro->GetSampleCount(&sampleCount);
        if (sampleCount > 0) {
            result.gyroscope.resize(sampleCount);
            float* buf = new float[sampleCount * 3];
            uint32_t readCount = 0;
            if (SUCCEEDED(gyro->GetSampleRange(0, sampleCount, buf, &readCount)) && readCount > 0) {
                for (uint32_t i = 0; i < readCount; i++) {
                    float t = (float)i / sampleRate;
                    result.gyroscope[i] = {t, buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]};
                }
                result.gyroSampleRate = sampleRate; result.hasGyro = true;
                result.gyroscope.resize(readCount);
            }
            delete[] buf;
        }
        gyro->Release();
    }

    IBlackmagicRawClipAccelerometerMotion* accel = nullptr;
    if (SUCCEEDED(m_impl->clip->QueryInterface(IID_IBlackmagicRawClipAccelerometerMotion, (void**)&accel)) && accel) {
        float sampleRate = 0; uint32_t sampleCount = 0;
        accel->GetSampleRate(&sampleRate);
        accel->GetSampleCount(&sampleCount);
        if (sampleCount > 0) {
            result.accelerometer.resize(sampleCount);
            float* buf = new float[sampleCount * 3];
            uint32_t readCount = 0;
            if (SUCCEEDED(accel->GetSampleRange(0, sampleCount, buf, &readCount)) && readCount > 0) {
                for (uint32_t i = 0; i < readCount; i++) {
                    float t = (float)i / sampleRate;
                    result.accelerometer[i] = {t, buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]};
                }
                result.accelSampleRate = sampleRate; result.hasAccel = true;
                result.accelerometer.resize(readCount);
            }
            delete[] buf;
        }
        accel->Release();
    }
    return result;
}

