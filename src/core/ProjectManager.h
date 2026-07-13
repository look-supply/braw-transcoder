#pragma once
#include "core/Types.h"
#include <vector>
#include <string>

class RenderBackend;

class ProjectManager {
public:
    ProjectManager(RenderBackend* backend);
    ~ProjectManager();

    size_t ImportClip(const std::string& path);
    void RemoveClip(size_t index);
    ClipInfo* GetClip(size_t index);
    const std::vector<ClipInfo>& GetClips() const;
    size_t ClipCount() const;
    void Clear();

    void CopySettings(size_t sourceIndex);
    void PasteSettings(const std::vector<size_t>& targetIndices);
    bool HasClipboard() const { return m_hasClipboard; }

    void SetActiveClip(size_t index);
    size_t GetActiveClipIndex() const { return m_activeIndex; }
    ClipInfo* GetActiveClip();

    RenderBackend* GetBackend() { return m_backend; }

    struct ExportClipInfo {
        std::string filePath;
        ClipAdjustments adjustments;
        uint32_t nativeWidth;
        uint32_t nativeHeight;
        float frameRate;
        uint64_t frameCount;
    };
    ExportClipInfo GetExportInfo(size_t index) const;

private:
    std::vector<ClipInfo> m_clips;
    ClipAdjustments m_clipboard;
    bool m_hasClipboard = false;
    size_t m_activeIndex = 0;
    RenderBackend* m_backend = nullptr;
};
