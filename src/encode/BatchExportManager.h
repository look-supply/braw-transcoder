#pragma once
#include "core/ExportSettings.h"
#include "core/ProjectManager.h"
#include <vector>
#include <thread>
#include <atomic>
#include <mutex>

class RenderBackend;
class IVideoEncoder;

class BatchExportManager {
public:
    BatchExportManager(ProjectManager* project, RenderBackend* backend);
    ~BatchExportManager();

    void SetExportSettings(const ExportSettings& settings);
    void QueueClips(const std::vector<size_t>& clipIndices);
    void StartExport();
    void CancelExport();

    bool IsExporting() const { return m_running.load(); }
    float GetProgress() const { return m_progress.load(); }
    int GetCurrentClipIndex() const { return m_currentClip.load(); }

private:
    void ExportThreadFunc();

    ProjectManager*    m_project;
    RenderBackend*     m_backend;
    ExportSettings     m_settings;
    std::vector<ExportJob> m_queue;

    std::atomic<bool>  m_running{false};
    std::atomic<bool>  m_cancel{false};
    std::atomic<float> m_progress{0.0f};
    std::atomic<int>   m_currentClip{-1};
    std::thread        m_thread;
    std::mutex         m_mutex;
};
