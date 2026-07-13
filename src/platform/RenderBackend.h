#pragma once
#include <cstdint>

struct GradeParams;

class RenderBackend {
public:
    virtual ~RenderBackend() = default;

    virtual bool Init(void* nativeWindow, int width, int height) = 0;
    virtual void BeginFrame() = 0;
    virtual void EndFrame() = 0;
    virtual void Shutdown() = 0;
    virtual void Resize(int width, int height) = 0;

    virtual void* CreateTexture(int w, int h) = 0;
    virtual void  DestroyTexture(void* tex) = 0;
    virtual void  UpdateTexture(void* tex, const uint8_t* data, int w, int h, int components) = 0;

    virtual void* CreateComputeTexture(int w, int h) = 0;
    virtual void  DestroyComputeTexture(void* tex) = 0;

    virtual void BicubicSharperScale(void* srcTex, void* dstTex,
                                      int srcW, int srcH, int dstW, int dstH) = 0;

    virtual void* GetPixelBufferFromTexture(void* tex) = 0;
    virtual void* GetDevice() = 0;
    virtual void* GetCommandQueue() = 0;
    virtual void* GetNextDrawable() { return nullptr; }
};
