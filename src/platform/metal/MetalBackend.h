#pragma once
#include "platform/RenderBackend.h"
#include <memory>

class MetalBackend : public RenderBackend {
public:
    MetalBackend();
    ~MetalBackend() override;

    bool Init(void* nativeWindow, int width, int height) override;
    void BeginFrame() override;
    void EndFrame() override;
    void Shutdown() override;
    void Resize(int width, int height) override;

    void* CreateTexture(int w, int h) override;
    void  DestroyTexture(void* tex) override;
    void  UpdateTexture(void* tex, const uint8_t* data, int w, int h, int components) override;

    void* CreateComputeTexture(int w, int h) override;
    void  DestroyComputeTexture(void* tex) override;

    void BicubicSharperScale(void* srcTex, void* dstTex,
                              int srcW, int srcH, int dstW, int dstH) override;

    void* GetPixelBufferFromTexture(void* tex) override;
    void* GetDevice() override;
    void* GetCommandQueue() override;

    void* GetNextDrawable() override;

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
