import Foundation
import AppKit
import Metal
import CoreVideo
import CoreImage

final class MetalRenderer: @unchecked Sendable {
    static let shared = MetalRenderer()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    let ciContext: CIContext

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache!
        ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpaceCreateDeviceRGB()])
    }

    func makeNSImageFromMetalBuffer(_ buffer: MTLBuffer, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        let size = bytesPerRow * height

        if let pixelBuffer = createCVPixelBuffer(width: width, height: height) {
            blit(buffer: buffer, to: pixelBuffer, width: width, height: height, bytesPerRow: bytesPerRow)
            return nsImage(from: pixelBuffer)
        }

        let data = Data(bytes: buffer.contents(), count: size)
        return makeNSImageFromBGRA(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    func makeNSImageFromMetalBufferReadback(_ buffer: MTLBuffer, width: Int, height: Int) -> NSImage? {
        let bytesPerRow = width * 4
        let size = bytesPerRow * height
        let data = Data(bytes: buffer.contents(), count: size)
        return makeNSImageFromBGRA(data: data, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    private func createCVPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if width != poolWidth || height != poolHeight || pixelBufferPool == nil {
            poolWidth = width
            poolHeight = height
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            pixelBufferPool = pool
        }

        guard let pool = pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        return pixelBuffer
    }

    private func blit(buffer: MTLBuffer, to pixelBuffer: CVPixelBuffer, width: Int, height: Int, bytesPerRow: Int) {
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache,
            pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &cvTexture
        )
        guard let cvTex = cvTexture, let dstTexture = CVMetalTextureGetTexture(cvTex) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return }

        blit.copy(from: buffer, sourceOffset: 0,
                  sourceBytesPerRow: bytesPerRow,
                  sourceBytesPerImage: bytesPerRow * height,
                  sourceSize: MTLSizeMake(width, height, 1),
                  to: dstTexture, destinationSlice: 0,
                  destinationLevel: 0,
                  destinationOrigin: MTLOriginMake(0, 0, 0))
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    private func nsImage(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    private func makeNSImageFromBGRA(data: Data, width: Int, height: Int, bytesPerRow: Int) -> NSImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let cg = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    func flushPools() {
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
    }
}
