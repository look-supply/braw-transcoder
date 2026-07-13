#include "core/ProjectManager.h"
#include "core/BrawDecoder.h"
#include "platform/RenderBackend.h"
#include <cstring>

ProjectManager::ProjectManager(RenderBackend* backend) : m_backend(backend) {}
ProjectManager::~ProjectManager() { Clear(); }

size_t ProjectManager::ImportClip(const std::string& path) {
    BrawDecoder decoder;
    if (!decoder.OpenClip(path)) return -1;

    ClipInfo info;
    info.filePath     = path;
    info.nativeWidth  = decoder.GetWidth();
    info.nativeHeight = decoder.GetHeight();
    info.frameRate    = decoder.GetFrameRate();
    info.frameCount   = decoder.GetFrameCount();

    size_t lastSlash = path.rfind('/');
    info.fileName = (lastSlash != std::string::npos) ? path.substr(lastSlash + 1) : path;

    info.adjustments = {};
    m_clips.push_back(info);

    decoder.Close();
    return m_clips.size() - 1;
}

void ProjectManager::RemoveClip(size_t index) {
    if (index >= m_clips.size()) return;
    if (m_clips[index].thumbnailTexture) {
        m_backend->DestroyTexture(m_clips[index].thumbnailTexture);
    }
    m_clips.erase(m_clips.begin() + index);
    if (m_activeIndex >= m_clips.size() && !m_clips.empty()) {
        m_activeIndex = m_clips.size() - 1;
    }
}

ClipInfo* ProjectManager::GetClip(size_t index) {
    return (index < m_clips.size()) ? &m_clips[index] : nullptr;
}

const std::vector<ClipInfo>& ProjectManager::GetClips() const {
    return m_clips;
}

size_t ProjectManager::ClipCount() const { return m_clips.size(); }

void ProjectManager::Clear() {
    for (auto& clip : m_clips) {
        if (clip.thumbnailTexture) m_backend->DestroyTexture(clip.thumbnailTexture);
    }
    m_clips.clear();
    m_activeIndex = 0;
}

void ProjectManager::CopySettings(size_t sourceIndex) {
    if (sourceIndex >= m_clips.size()) return;
    m_clipboard = m_clips[sourceIndex].adjustments;
    m_hasClipboard = true;
}

void ProjectManager::PasteSettings(const std::vector<size_t>& targetIndices) {
    if (!m_hasClipboard) return;
    for (auto idx : targetIndices) {
        if (idx < m_clips.size()) {
            m_clips[idx].adjustments = m_clipboard;
        }
    }
}

void ProjectManager::SetActiveClip(size_t index) {
    if (index < m_clips.size()) m_activeIndex = index;
}

ClipInfo* ProjectManager::GetActiveClip() {
    return GetClip(m_activeIndex);
}

ProjectManager::ExportClipInfo ProjectManager::GetExportInfo(size_t index) const {
    ExportClipInfo info;
    if (index < m_clips.size()) {
        info.filePath     = m_clips[index].filePath;
        info.adjustments  = m_clips[index].adjustments;
        info.nativeWidth  = m_clips[index].nativeWidth;
        info.nativeHeight = m_clips[index].nativeHeight;
        info.frameRate    = m_clips[index].frameRate;
        info.frameCount   = m_clips[index].frameCount;
    }
    return info;
}
