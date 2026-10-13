import AppKit
import SwiftUI
import MetalKit

/// Playback uploads the worker's bounded BGRA frames directly to Metal, avoiding
/// an NSImage conversion for each frame. The SDK worker also decodes with Metal.
struct MetalPlaybackView: NSViewRepresentable {
    let frame: DecodedPixels
    var zoom: CGFloat = 1
    var pan: CGSize = .zero

    func makeNSView(context: Context) -> PlaybackSurface { PlaybackSurface() }
    func updateNSView(_ view: PlaybackSurface, context: Context) { view.display(frame, zoom: zoom, pan: pan) }

    @MainActor final class PlaybackSurface: NSView {
        private let metalView: MTKView
        private let renderer: Renderer?
        private let fallback = NSImageView()
        private var fallbackZoom: CGFloat = 1
        private var fallbackPan: CGSize = .zero

        init() {
            let device = MTLCreateSystemDefaultDevice()
            metalView = MTKView(frame: .zero, device: device)
            renderer = device.flatMap { try? Renderer(device: $0) }
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            metalView.isPaused = true
            metalView.enableSetNeedsDisplay = true
            metalView.colorPixelFormat = .bgra8Unorm
            metalView.colorspace = CGColorSpaceCreateDeviceRGB()
            metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
            metalView.delegate = renderer
            fallback.imageScaling = .scaleProportionallyUpOrDown
            fallback.wantsLayer = true
            let content: NSView = renderer == nil ? fallback : metalView
            content.autoresizingMask = [.width, .height]
            addSubview(content)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            updateFallbackTransform()
        }
        private func updateFallbackTransform() {
            guard let image = fallback.image, image.size.width > 0, image.size.height > 0 else { return }
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            var transform = CGAffineTransform(scaleX: fallbackZoom, y: fallbackZoom)
            transform.tx = fallbackPan.width * image.size.width * scale * fallbackZoom
            transform.ty = -fallbackPan.height * image.size.height * scale * fallbackZoom
            fallback.layer?.setAffineTransform(transform)
        }
        func display(_ frame: DecodedPixels, zoom: CGFloat, pan: CGSize = .zero) {
            if let renderer {
                renderer.frame = frame
                renderer.zoom = Float(zoom)
                renderer.pan = SIMD2(Float(pan.width), Float(pan.height))
                metalView.needsDisplay = true
            } else {
                fallback.image = makeNSImageBGRA(frame: frame)
                fallbackZoom = zoom
                fallbackPan = pan
                updateFallbackTransform()
            }
        }
    }

    @MainActor final class Renderer: NSObject, MTKViewDelegate {
        private let device: MTLDevice
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let slots = (0..<3).map { _ in TextureSlot() }
        var frame: DecodedPixels?
        var zoom: Float = 1
        var pan = SIMD2<Float>(repeating: 0)
        private(set) var submittedFrames = 0

        init(device: MTLDevice) throws {
            self.device = device
            guard let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
            self.queue = queue
            let library = try device.makeLibrary(source: """
                #include <metal_stdlib>
                using namespace metal;
                struct Vertex { float4 position [[position]]; float2 uv; };
                struct Parameters { float4 geometry; float4 pan; };
                vertex Vertex playbackVertex(uint i [[vertex_id]]) {
                    const float2 positions[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
                    Vertex v;
                    v.position = float4(positions[i], 0, 1);
                    v.uv = float2((positions[i].x + 1) * 0.5, (1 - positions[i].y) * 0.5);
                    return v;
                }
                fragment float4 playbackFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]], constant Parameters& parameters [[buffer(0)]]) {
                    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
                    float2 uv = (v.uv - 0.5) * parameters.geometry.yz / parameters.geometry.x + 0.5 - parameters.pan.xy;
                    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);
                    return float4(image.sample(s, uv).rgb, 1);
                }
                """, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "playbackVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "playbackFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let frame, frame.width > 0, frame.height > 0,
                  frame.data.count == frame.width * frame.height * 4,
                  let slot = slots.first(where: { $0.acquire() }) else { return }
            var submitted = false
            defer { if !submitted { slot.release() } }
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer() else { return }
            if slot.texture?.width != frame.width || slot.texture?.height != frame.height {
                slot.texture = makeTexture(frame)
            }
            guard let texture = slot.texture, encode(frame, texture: texture, pass: pass, command: command) else { return }
            command.addCompletedHandler { _ in slot.release() }
            command.present(drawable)
            submitted = true
            command.commit()
            submittedFrames += 1
        }

        func encode(_ frame: DecodedPixels, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) -> Bool {
            guard let texture = makeTexture(frame) else { return false }
            return encode(frame, texture: texture, pass: pass, command: command)
        }

        private func makeTexture(_ frame: DecodedPixels) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            descriptor.usage = .shaderRead
            return device.makeTexture(descriptor: descriptor)
        }

        private func encode(_ frame: DecodedPixels, texture: MTLTexture, pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) -> Bool {
            frame.data.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                                mipmapLevel: 0, withBytes: bytes.baseAddress!, bytesPerRow: frame.width * 4)
            }
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            let target = pass.colorAttachments[0].texture!
            let viewportAspect = Float(target.width) / Float(target.height)
            let imageAspect = Float(frame.width) / Float(frame.height)
            let parameters = [SIMD4<Float>(zoom,
                max(1, viewportAspect / imageAspect), max(1, imageAspect / viewportAspect), 0),
                SIMD4<Float>(pan.x, pan.y, 0, 0)]
            parameters.withUnsafeBytes { bytes in
                encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            return true
        }
        /// Texture storage is reused only after the GPU completes its submission.
        private final class TextureSlot: @unchecked Sendable {
            var texture: MTLTexture?
            private let lock = NSLock()
            private var inUse = false
            func acquire() -> Bool {
                lock.withLock {
                    guard !inUse else { return false }
                    inUse = true
                    return true
                }
            }
            func release() { lock.withLock { inUse = false } }
        }
        private enum RenderError: Error { case unavailable }
    }
}
