#import "platform/metal/MetalBackend.h"
#import <MetalKit/MetalKit.h>
#import <AppKit/AppKit.h>

struct MetalBackend::Impl {
    id<MTLDevice>        device        = nil;
    id<MTLCommandQueue>  commandQueue  = nil;
    id<MTLLibrary>       library       = nil;
    id<MTLFunction>      bicubicKernel = nil;
    id<MTLFunction>      colorGradeKernel = nil;
    id<MTLFunction>      copyKernel    = nil;
    CAMetalLayer*        metalLayer    = nil;
    int                  windowWidth   = 0;
    int                  windowHeight  = 0;
};

@interface MetalTextureEntry : NSObject
@property (nonatomic, strong) id<MTLTexture> texture;
@end

@implementation MetalTextureEntry
@end

MetalBackend::MetalBackend() : m_impl(std::make_unique<Impl>()) {}
MetalBackend::~MetalBackend() { Shutdown(); }

bool MetalBackend::Init(void* nativeWindow, int width, int height) {
    m_impl->windowWidth  = width;
    m_impl->windowHeight = height;

    m_impl->device = MTLCreateSystemDefaultDevice();
    if (!m_impl->device) return false;

    m_impl->commandQueue = [m_impl->device newCommandQueue];
    if (!m_impl->commandQueue) return false;

    NSWindow* nsWindow = (__bridge NSWindow*)nativeWindow;
    NSView* contentView = [nsWindow contentView];
    [contentView setWantsLayer:YES];

    m_impl->metalLayer = [CAMetalLayer layer];
    m_impl->metalLayer.device = m_impl->device;
    m_impl->metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    m_impl->metalLayer.framebufferOnly = NO;
    m_impl->metalLayer.drawableSize = CGSizeMake(width, height);
    [contentView setLayer:m_impl->metalLayer];

    NSError* error = nil;
    NSString* shaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

constant float B = 0.0f;
constant float C = 0.75f;

inline float bicubic_weight(float x) {
    x = fabs(x);
    if (x < 1.0f) {
        return ((12.0f - 9.0f * B - 6.0f * C) * x * x * x +
                (-18.0f + 12.0f * B + 6.0f * C) * x * x +
                (6.0f - 2.0f * B)) / 6.0f;
    } else if (x < 2.0f) {
        return ((-B - 6.0f * C) * x * x * x +
                (6.0f * B + 30.0f * C) * x * x +
                (-12.0f * B - 48.0f * C) * x +
                (8.0f * B + 24.0f * C)) / 6.0f;
    }
    return 0.0f;
}

kernel void bicubic_sharper_scale(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint dstW = dstTex.get_width();
    uint dstH = dstTex.get_height();
    uint srcW = srcTex.get_width();
    uint srcH = srcTex.get_height();

    if (gid.x >= dstW || gid.y >= dstH) return;

    float scaleX = float(srcW) / float(dstW);
    float scaleY = float(srcH) / float(dstH);

    float srcX = (float(gid.x) + 0.5f) * scaleX - 0.5f;
    float srcY = (float(gid.y) + 0.5f) * scaleY - 0.5f;

    int ix = int(floor(srcX));
    int iy = int(floor(srcY));

    float4 result = float4(0.0f);

    for (int dy = -1; dy <= 2; ++dy) {
        float wy = bicubic_weight(float(dy) - (srcY - float(iy)));
        int sy = clamp(iy + dy, 0, int(srcH) - 1);

        for (int dx = -1; dx <= 2; ++dx) {
            float wx = bicubic_weight(float(dx) - (srcX - float(ix)));
            int sx = clamp(ix + dx, 0, int(srcW) - 1);

            result += wx * wy * srcTex.read(uint2(sx, sy));
        }
    }

    dstTex.write(result, gid);
}

kernel void color_grade(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    constant float& exposure  [[buffer(0)]],
    constant float& kelvinScale  [[buffer(1)]],
    constant float& tintBias   [[buffer(2)]],
    constant float& highlightRecovery [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    float4 color = srcTex.read(gid);

    float exposureMult = exp2(exposure);
    color.rgb *= exposureMult;

    color.r *= kelvinScale;
    color.b /= kelvinScale;

    color.r += tintBias;
    color.b -= tintBias;

    if (highlightRecovery > 0.5f) {
        float maxComp = max(max(color.r, color.g), color.b);
        if (maxComp > 1.0f) {
            float over = maxComp - 1.0f;
            float blendFactor = min(over / max(maxComp, 0.001f), 0.9f);
            float lum = dot(color.rgb, float3(0.2126f, 0.7152f, 0.0722f));
            color.rgb = mix(color.rgb, float3(lum), blendFactor * 0.5f);
        }
    }

    color = clamp(color, 0.0f, 1.0f);

    dstTex.write(color, gid);
}

kernel void copy_texture(
    texture2d<float, access::read>  srcTex  [[texture(0)]],
    texture2d<float, access::write> dstTex  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x < dstTex.get_width() && gid.y < dstTex.get_height()) {
        dstTex.write(srcTex.read(gid), gid);
    }
}
)";

    MTLCompileOptions* options = [[MTLCompileOptions alloc] init];
    options.languageVersion = MTLLanguageVersion2_4;
    m_impl->library = [m_impl->device newLibraryWithSource:shaderSource options:options error:&error];

    if (!m_impl->library) {
        NSLog(@"Metal shader compile error: %@", error);
        return false;
    }

    m_impl->bicubicKernel    = [m_impl->library newFunctionWithName:@"bicubic_sharper_scale"];
    m_impl->colorGradeKernel = [m_impl->library newFunctionWithName:@"color_grade"];
    m_impl->copyKernel       = [m_impl->library newFunctionWithName:@"copy_texture"];

    return true;
}

void MetalBackend::BeginFrame() {}
void MetalBackend::EndFrame() {}

void MetalBackend::Shutdown() {
    m_impl->library       = nil;
    m_impl->bicubicKernel = nil;
    m_impl->colorGradeKernel = nil;
    m_impl->copyKernel    = nil;
    m_impl->commandQueue  = nil;
    m_impl->metalLayer    = nil;
    m_impl->device        = nil;
}

void MetalBackend::Resize(int width, int height) {
    m_impl->windowWidth  = width;
    m_impl->windowHeight = height;
    m_impl->metalLayer.drawableSize = CGSizeMake(width, height);
}

void* MetalBackend::CreateTexture(int w, int h) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:desc];
    return (__bridge_retained void*)tex;
}

void MetalBackend::DestroyTexture(void* tex) {
    if (tex) {
        CFRelease(tex);
    }
}

void MetalBackend::UpdateTexture(void* tex, const uint8_t* data, int w, int h, int components) {
    if (!tex || !data) return;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)tex;
    MTLRegion region = MTLRegionMake2D(0, 0, w, h);
    [texture replaceRegion:region
               mipmapLevel:0
                 withBytes:data
               bytesPerRow:w * components];
}

void* MetalBackend::CreateComputeTexture(int w, int h) {
    MTLTextureDescriptor* desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:w
                                    height:h
                                 mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> tex = [m_impl->device newTextureWithDescriptor:desc];
    return (__bridge_retained void*)tex;
}

void MetalBackend::DestroyComputeTexture(void* tex) {
    if (tex) {
        CFRelease(tex);
    }
}

void MetalBackend::BicubicSharperScale(void* srcTex, void* dstTex,
                                        int srcW, int srcH, int dstW, int dstH) {
    if (!m_impl->bicubicKernel || !srcTex || !dstTex) return;

    id<MTLTexture> src = (__bridge id<MTLTexture>)srcTex;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)dstTex;

    NSError* error = nil;
    id<MTLComputePipelineState> pipeline =
        [m_impl->device newComputePipelineStateWithFunction:m_impl->bicubicKernel error:&error];
    if (!pipeline) {
        NSLog(@"Bicubic pipeline error: %@", error);
        return;
    }

    id<MTLCommandBuffer> cmdBuf = [m_impl->commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [cmdBuf computeCommandEncoder];

    [encoder setComputePipelineState:pipeline];
    [encoder setTexture:src atIndex:0];
    [encoder setTexture:dst atIndex:1];

    MTLSize threadGroupSize = MTLSizeMake(16, 16, 1);
    MTLSize gridSize = MTLSizeMake(dstW, dstH, 1);

    [encoder dispatchThreads:gridSize threadsPerThreadgroup:threadGroupSize];
    [encoder endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];
}

void* MetalBackend::GetPixelBufferFromTexture(void* tex) {
    if (!tex) return nil;
    id<MTLTexture> src = (__bridge id<MTLTexture>)tex;

    CVPixelBufferRef pixelBuffer = NULL;
    NSDictionary* attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferWidthKey: @(src.width),
        (id)kCVPixelBufferHeightKey: @(src.height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVReturn cvRet = CVPixelBufferCreate(
        kCFAllocatorDefault,
        src.width, src.height,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

    if (cvRet != kCVReturnSuccess || !pixelBuffer) return nil;

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void* baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

    id<MTLBuffer> tempBuf = [m_impl->device newBufferWithLength:bytesPerRow * src.height
                                                   options:MTLResourceStorageModeShared];

    id<MTLCommandBuffer> cmdBuf = [m_impl->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
    [blit copyFromTexture:src
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(src.width, src.height, 1)
                 toBuffer:tempBuf
        destinationOffset:0
   destinationBytesPerRow:bytesPerRow
 destinationBytesPerImage:0];
    [blit endEncoding];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];

    memcpy(baseAddr, [tempBuf contents], bytesPerRow * src.height);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    return pixelBuffer;
}

void* MetalBackend::GetDevice() {
    return (__bridge void*)m_impl->device;
}

void* MetalBackend::GetCommandQueue() {
    return (__bridge void*)m_impl->commandQueue;
}

void* MetalBackend::GetNextDrawable() {
    id<CAMetalDrawable> drawable = [m_impl->metalLayer nextDrawable];
    return (__bridge_retained void*)drawable;
}
