#include "encode/BatchExportManager.h"
#include "core/BrawDecoder.h"
#include "platform/RenderBackend.h"
#include "platform/IVideoEncoder.h"
#include "platform/metal/VideoToolboxEncoder.h"
#import <Metal/Metal.h>
#include <iostream>
#include <filesystem>
#include <chrono>

namespace fs = std::filesystem;

BatchExportManager::BatchExportManager(ProjectManager* project, RenderBackend* backend)
    : m_project(project), m_backend(backend) {}

BatchExportManager::~BatchExportManager() {
    CancelExport();
    if (m_thread.joinable()) m_thread.join();
}

void BatchExportManager::SetExportSettings(const ExportSettings& settings) {
    m_settings = settings;
}

void BatchExportManager::QueueClips(const std::vector<size_t>& clipIndices) {
    m_queue.clear();
    for (auto idx : clipIndices) {
        auto info = m_project->GetExportInfo(idx);
        if (info.nativeWidth == 0) continue;

        ExportJob job;
        job.clipIndex     = idx;
        job.settings      = m_settings;
        job.outputHeight  = TargetHeightValue(m_settings.heightPreset);
        job.outputWidth   = CalculateOutputWidth(job.outputHeight,
                                                  info.nativeWidth, info.nativeHeight);
        job.clip.filePath     = info.filePath;
        job.clip.adjustments  = info.adjustments;
        job.clip.nativeWidth  = info.nativeWidth;
        job.clip.nativeHeight = info.nativeHeight;
        job.clip.frameRate    = info.frameRate;
        job.clip.frameCount   = info.frameCount;
        m_queue.push_back(job);
    }
}

void BatchExportManager::StartExport() {
    if (m_running) return;
    m_running = true;
    m_cancel  = false;
    m_progress = 0.0f;

    if (m_thread.joinable()) m_thread.join();
    m_thread = std::thread(&BatchExportManager::ExportThreadFunc, this);
}

void BatchExportManager::CancelExport() {
    m_cancel = true;
}

void BatchExportManager::ExportThreadFunc() {
    for (size_t i = 0; i < m_queue.size(); ++i) {
        if (m_cancel) break;
        m_currentClip = static_cast<int>(i);

        const ExportJob& job = m_queue[i];

        BrawDecoder decoder;
        if (!decoder.OpenClip(job.clip.filePath)) {
            std::cerr << "Export: failed to open " << job.clip.filePath << std::endl;
            continue;
        }

        uint64_t totalFrames = decoder.GetFrameCount();
        float fps = decoder.GetFrameRate();

        std::string outDir = m_settings.outputDir;
        if (outDir.empty()) {
            outDir = fs::path(job.clip.filePath).parent_path().string();
        }

        std::string baseName = fs::path(job.clip.filePath).stem().string();
        std::string ext = (m_settings.codec == OutputCodec::ProRes) ? ".mov" : ".mp4";
        std::string outPath = outDir + "/" + baseName + "_transcoded" + ext;

        CodecType encCodec;
        switch (m_settings.codec) {
            case OutputCodec::H264:  encCodec = CodecType::H264;  break;
            case OutputCodec::H265:  encCodec = CodecType::H265;  break;
            case OutputCodec::ProRes: encCodec = CodecType::ProRes; break;
        }

        VideoToolboxEncoder encoder;
        if (!encoder.Open(outPath, job.outputWidth, job.outputHeight, fps,
                          encCodec,
                          static_cast<int>(m_settings.proResProfile),
                          DataRateValue(m_settings.dataRate),
                          0, 0, 0)) {
            std::cerr << "Export: failed to open encoder for " << outPath << std::endl;
            decoder.Close();
            continue;
        }

        for (uint64_t frameIdx = 0; frameIdx < totalFrames; ++frameIdx) {
            if (m_cancel) break;

            decoder.RequestFrame(frameIdx, job.clip.adjustments,
                [&](void* metalBuffer, int width, int height, int bytesPerRow) {
                    void* srcTex = m_backend->CreateComputeTexture(width, height);

                    id<MTLTexture> mtlTex = ((__bridge id<MTLTexture>)metalBuffer);
                    // For BGRA texture update

                    void* scaledTex = m_backend->CreateComputeTexture(
                        job.outputWidth, job.outputHeight);

                    m_backend->BicubicSharperScale(
                        metalBuffer, scaledTex,
                        width, height,
                        job.outputWidth, job.outputHeight);

                    void* pixelBuf = m_backend->GetPixelBufferFromTexture(scaledTex);
                    if (pixelBuf) {
                        encoder.WriteFrame(pixelBuf, static_cast<int64_t>(frameIdx));
                    }

                    m_backend->DestroyComputeTexture(scaledTex);
                    m_backend->DestroyComputeTexture(srcTex);
                });

            m_progress = (static_cast<float>(frameIdx + 1) / totalFrames)
                         * (1.0f / m_queue.size())
                         + (static_cast<float>(i) / m_queue.size());
        }

        encoder.Close();
        decoder.Close();
    }

    m_running   = false;
    m_currentClip = -1;
}
