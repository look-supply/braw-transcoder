import AppKit
import Foundation
import MetalKit
import SwiftUI

@main struct PlaybackTests {
    @MainActor static func checkMetalPixels() throws {
        if let device = MTLCreateSystemDefaultDevice() {
            let renderer = try MetalPlaybackView.Renderer(device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
            descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
            descriptor.usage = [.renderTarget, .shaderRead]
            let texture = device.makeTexture(descriptor: descriptor)!
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let queue = device.makeCommandQueue()!
            let command = queue.makeCommandBuffer()!
            let input = Data([0,0,255,255, 0,255,0,255, 255,0,0,255, 255,255,255,255])
            precondition(renderer.encode(DecodedPixels(data: input, width: 2, height: 2), pass: pass, command: command))
            let readback = device.makeBuffer(length: 512, options: .storageModeShared)!
            let blit = command.makeBlitCommandEncoder()!
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: readback,
                      destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 512)
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            precondition(command.status == .completed, "Metal renderer failed")
            var output = Data(bytes: readback.contents(), count: 8)
            output.append(Data(bytes: readback.contents().advanced(by: 256), count: 8))
            precondition(output == input, "Metal playback flipped the image or altered RGB channels")
            renderer.zoom = 0.25
            let zoomed = queue.makeCommandBuffer()!
            precondition(renderer.encode(DecodedPixels(data: input, width: 2, height: 2), pass: pass, command: zoomed))
            let copy = zoomed.makeBlitCommandEncoder()!
            copy.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: readback,
                      destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 512)
            copy.endEncoding()
            zoomed.commit(); zoomed.waitUntilCompleted()
            var zoomedPixels = Data(bytes: readback.contents(), count: 8)
            zoomedPixels.append(Data(bytes: readback.contents().advanced(by: 256), count: 8))
            precondition(zoomedPixels == Data([0,0,0,255, 0,0,0,255, 0,0,0,255, 0,0,0,255]),
                         "Zoom-out sampled beyond the image instead of showing black borders")
            renderer.zoom = 4
            renderer.pan = SIMD2<Float>(repeating: 0.375)
            let panned = queue.makeCommandBuffer()!
            precondition(renderer.encode(DecodedPixels(data: input, width: 2, height: 2), pass: pass, command: panned))
            let panCopy = panned.makeBlitCommandEncoder()!
            panCopy.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: 2, height: 2, depth: 1), to: readback,
                         destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 512)
            panCopy.endEncoding(); panned.commit(); panned.waitUntilCompleted()
            var panPixels = Data(bytes: readback.contents(), count: 8)
            panPixels.append(Data(bytes: readback.contents().advanced(by: 256), count: 8))
            precondition(panPixels == Data([0,0,255,255, 0,0,255,255, 0,0,255,255, 0,0,255,255]),
                         "Metal pan did not reveal the top-left image corner")
        }
    }

    @MainActor static func checkPreviewNavigation(clip: ClipModel) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = PreviewNavigation.Anchor()
        view.clip = clip
        window.contentView = view
        window.orderFront(nil)
        defer { view.removeMonitor(); window.orderOut(nil); clip.resetZoom() }
        let center = NSPoint(x: 200, y: 150)
        let zoomButton = PreviewZoomButton.Control(frame: .zero)
        zoomButton.onPress = clip.zoomIn
        clip.resetZoom()
        for _ in 0..<12 { zoomButton.performClick(nil) }
        precondition(clip.previewZoom == 8, "Repeated Zoom In clicks did not reach 800 percent")
        zoomButton.onPress = clip.zoomOut
        for _ in 0..<20 { zoomButton.performClick(nil) }
        precondition(clip.previewZoom == 0.25, "Repeated Zoom Out clicks did not reach 25 percent")
        clip.resetZoom()
        precondition(!view.handleScroll(deltaX: 20, deltaY: 10, precise: true, modifiers: .shift, location: center, eventWindow: window),
                     "Shift-scroll pan changed a fitted image")
        precondition(!view.beginPan(location: center, eventWindow: window), "Middle drag started at fit")
        for precise in [false, true] {
            clip.resetZoom()
            precondition(view.handleScroll(deltaX: 0, deltaY: 20, precise: precise,
                location: center, eventWindow: window) && clip.previewZoom > 1 && clip.previewPan == .zero,
                "Unmodified mouse wheel did not zoom")
        }
        precondition(view.handleScroll(deltaX: 0, deltaY: 50, precise: true, modifiers: .command,
            location: center, eventWindow: window) && clip.previewZoom > 1, "Command-scroll did not zoom")
        clip.resetZoom(); clip.zoomPreview(by: 4)
        let zoom = clip.previewZoom
        precondition(view.handleScroll(deltaX: 40, deltaY: 20, precise: true, modifiers: .shift, location: center, eventWindow: window))
        precondition(clip.previewPan.width > 0 && clip.previewPan.height > 0 && clip.previewZoom == zoom,
                     "Shift-scroll did not pan both axes without changing zoom")
        let offset = clip.previewPan
        precondition(!view.handleScroll(deltaX: 20, deltaY: 20, precise: true,
            location: NSPoint(x: -20, y: -20), eventWindow: window) && clip.previewPan == offset,
                     "Scroll outside image changed pan")
        precondition(view.beginPan(location: center, eventWindow: window))
        precondition(view.dragPan(location: NSPoint(x: 240, y: 130), eventWindow: window))
        precondition(clip.previewPan.width > offset.width && clip.previewPan.height > offset.height,
                     "Middle drag moved the image in the wrong direction")
        precondition(view.endPan() && !view.dragPan(location: center, eventWindow: window), "Middle drag did not end")
        clip.panPreview(by: CGSize(width: 1e9, height: -1e9))
        precondition(clip.previewPan.width < 0.5 && clip.previewPan.height > -0.5, "Pan went beyond the image")
        clip.setPreviewViewport(CGSize(width: 2000, height: 100))
        precondition(clip.previewPan.width == 0, "Resizing exposed a horizontal image edge")
        clip.setPreviewViewport(view.bounds.size)
        clip.zoomOut()
        precondition(clip.previewPan.width < 0.5 && clip.previewZoom == 3.2)
        clip.zoomPreview(by: 0.25)
        precondition(clip.previewPan == .zero, "Zooming out to fit did not recenter")
        clip.zoomPreview(by: 4); clip.panPreview(by: CGSize(width: 40, height: 40))
        clip.resetZoom()
        precondition(clip.previewPan == .zero && clip.previewZoom == 1, "Reset did not recenter the image")
    }

    @MainActor static func checkSelectAllKeyboard(project: ProjectModel) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = PlaybackKeyboardShortcuts.Anchor()
        anchor.project = project
        window.contentView = anchor
        window.orderFront(nil)
        defer { anchor.removeMonitor(); window.orderOut(nil) }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(window.makeFirstResponder(anchor))
        project.selectClip(0, toggling: true)
        precondition(project.selectedIndices.isEmpty)
        precondition(anchor.handle(event) == nil && project.selectedIndices == Set(0..<project.clipCount),
                     "Command-A did not select clips with no active selection")
        project.isExporting = true
        let selection = project.selectedIndices
        _ = anchor.handle(event)
        precondition(project.selectedIndices == selection, "Command-A changed selection during export")
        project.isExporting = false
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        anchor.addSubview(editor)
        precondition(window.makeFirstResponder(editor))
        precondition(anchor.handle(event) != nil, "Command-A intercepted text editing")
        precondition(project.selectedIndices == selection)
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let timeline = PlaybackTimeline(firstFrame: 10, frameCount: 100, fps: 23.976)
        precondition(timeline.frame(at: 0) == 10)
        precondition(timeline.frame(at: 1) == 33)
        precondition(timeline.frame(at: 1000) == 99)
        precondition(timeline.frame(at: -1) == 10)
        let reverseTimeline = PlaybackTimeline(firstFrame: 30, frameCount: 100, fps: 24, direction: .reverse)
        precondition(reverseTimeline.frame(at: 1) == 6 && reverseTimeline.frame(at: 100) == 0)
        precondition(PlaybackTimeline(firstFrame: 0, frameCount: 0, fps: 0).frame(at: 1) == 0)
        for bits: UInt32 in [16, 24, 32] {
            let stride = Int(bits / 8)
            var raw = Data(repeating: 0, count: stride * 3)
            raw[stride * 2 - 1] = 0x80
            for i in stride * 2..<stride * 3 { raw[i] = 0xff }
            let samples = PlaybackPCM.floats(raw, bits: bits)!
            precondition(samples[0] == 0 && samples[1] == -1 && samples[2] < 0 && samples[2] > -0.001,
                         "Signed PCM conversion failed for \(bits)-bit audio")
        }
        precondition(PlaybackPCM.floats(Data([0]), bits: 24) == nil)
        precondition(ClipModel.durationTimecode(frames: 290, fps: 23.976) == "00:00:12:02")
        precondition(ClipModel.durationTimecode(frames: 25 * 3661 + 7, fps: 25) == "01:01:01:07")
        precondition(ClipModel.durationTimecode(frames: 0, fps: 24) == "00:00:00:00")
        precondition(ClipModel.durationTimecode(frames: 1, fps: 0) == "--:--:--:--")
        try checkMetalPixels()

        precondition(CommandLine.arguments.count >= 2, "Pass a BRAW fixture")
        let suite = "braw-playback-test-\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let project = ProjectModel(preferences: preferences)
        precondition(project.playbackResolution == .full, "Playback should default to full resolution")
        for resolution in PlaybackResolution.allCases {
            project.playbackResolution = resolution
            precondition(ProjectModel(preferences: preferences).playbackResolution == resolution,
                         "Playback resolution did not survive project recreation")
        }
        preferences.set("unknown", forKey: "playbackResolution")
        precondition(ProjectModel(preferences: preferences).playbackResolution == .full,
                     "Invalid saved resolution did not fall back to Full")
        project.playbackResolution = .full
        project.playbackLoopEnabled = true
        precondition(ProjectModel(preferences: preferences).playbackLoopEnabled, "Loop preference was not saved")
        project.playbackLoopEnabled = false
        _ = project.importClip(path: CommandLine.arguments[1])
        func wait(_ label: String, timeout: Double = 30, until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                precondition(Date() < deadline, "Timed out: \(label)")
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        try await wait("import") { !project.isImporting }
        let clip = project.selectedClip!
        try await wait("preview") { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        clip.zoomIn()
        precondition(clip.previewZoom > 1)
        clip.zoomOut()
        precondition(abs(clip.previewZoom - 1) < 0.001)
        clip.zoomPreview(by: 100)
        precondition(clip.previewZoom == 8)
        clip.zoomPreview(by: 0.0001)
        precondition(clip.previewZoom == 0.25)
        clip.resetZoom()
        precondition(clip.previewZoom == 1)
        try checkSelectAllKeyboard(project: project)
        try checkPreviewNavigation(clip: clip)
        if clip.frameCount < 2 {
            clip.startPlayback()
            try await wait("single-frame playback") { !clip.isPlaying }
            precondition(clip.currentFrame == 0 && clip.previewError == nil)
            print("PASS: fractional FPS forward/reverse clock, PCM conversion, Metal pixels, saved controls and single-frame playback")
            return
        }
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 850),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ContentView(project: project))
        previewWindow.contentView = host
        previewWindow.orderFront(nil)
        defer { previewWindow.orderOut(nil) }
        clip.startPlayback()
        try await wait("continuous playback") { clip.currentFrame >= 12 || clip.previewError != nil }
        precondition(clip.previewError == nil, clip.previewError ?? "")
        precondition(clip.playbackFrame!.width == clip.renderDimensions.width &&
                     clip.playbackFrame!.height == clip.renderDimensions.height,
                     "Full resolution playback reduced the image")
        precondition(clip.playbackUsesMetal == (ProcessInfo.processInfo.environment["BRAW_DECODE_PIPELINE"] != "cpu"), "Requested decoder pipeline was not used")
        let audio = braw_clip_get_audio_info(braw_project_get_clip(project.projectHandle, 0))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let wheel = descendants(host).compactMap { $0 as? PreviewNavigation.Anchor }.first!
        precondition(wheel.bounds.width > 300 && wheel.bounds.height > 100, "Wheel target did not fill the preview")
        let center = wheel.convert(NSPoint(x: wheel.bounds.midX, y: wheel.bounds.midY), to: nil)
        precondition(wheel.handleScroll(deltaX: 0, deltaY: 3, precise: false, location: center, eventWindow: previewWindow))
        precondition(clip.previewZoom > 1 && clip.isPlaying, "Wheel zoom paused playback")
        let zoom = clip.previewZoom
        precondition(!wheel.handleScroll(deltaX: 0, deltaY: 3, precise: false, location: NSPoint(x: -100, y: -100), eventWindow: previewWindow) &&
                     clip.previewZoom == zoom, "Scrolling outside the preview changed zoom")
        clip.resetZoom()
        let renderer = descendants(host).compactMap { $0 as? MTKView }.first?.delegate as? MetalPlaybackView.Renderer
        precondition(renderer != nil, "Actual preview did not create its Metal renderer")
        let submittedBefore = renderer!.submittedFrames
        let retainedPixels = clip.playbackFrame!.data
        let retainedSignature = Array(retainedPixels.prefix(512))
        let duration = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 1
        let playbackDeadline = Date().addingTimeInterval(duration)
        var maximumDrift = 0.0
        var presentations = 0
        var previousFrame = clip.currentFrame
        let memoryBefore = braw_get_resident_memory()
        var peakMemory = memoryBefore
        var skipped = 0
        while Date() < playbackDeadline && clip.isPlaying {
            try await Task.sleep(for: .milliseconds(20))
            precondition(clip.previewError == nil, clip.previewError ?? "")
            if clip.currentFrame != previousFrame {
                skipped += Int(clip.currentFrame - previousFrame - 1)
                presentations += 1
                previousFrame = clip.currentFrame
            }
            peakMemory = max(peakMemory, braw_get_resident_memory())
            if audio.samples > 0, let audioTime = clip.playbackAudioElapsed {
                maximumDrift = max(maximumDrift, abs(Double(clip.currentFrame) / Double(clip.frameRate) - audioTime))
            }
        }
        precondition(maximumDrift < 0.25, "Sustained audio/video drift: \(maximumDrift)")
        print("Sustained playback: \(presentations) observed frame updates / \(duration)s; max A/V difference \(maximumDrift)s")
        let submitted = renderer!.submittedFrames - submittedBefore
        precondition(submitted > 0, "Actual preview never submitted frames to Metal")
        print("Actual window Metal submissions: \(submitted) / \(duration)s")
        print("Observed skipped frames: \(skipped); app memory growth: \((peakMemory - memoryBefore) / 1048576) MiB")
        let nativeFrameBytes = Int64(clip.renderDimensions.width) * Int64(clip.renderDimensions.height) * 4
        precondition(peakMemory - memoryBefore < max(512 * 1048576, nativeFrameBytes * 12),
                     "Playback frame storage grew beyond the bounded queue and texture pool")
        if audio.samples > 0 {
            precondition(clip.playbackAudioIsPlaying && clip.playbackAudioElapsed != nil, "Audio did not start with video")
            let videoTime = Double(clip.currentFrame) / Double(clip.frameRate)
            let audioTime = clip.playbackAudioElapsed!
            precondition(abs(videoTime - audioTime) < 0.25, "Audio and video drifted apart")
            print("A/V difference: \(abs(videoTime - audioTime)) seconds")
        }
        let frame = clip.currentFrame
        clip.stopPlayback()
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying)
        try await wait("full-resolution pause") { !clip.isLoadingPreview }
        precondition(clip.currentFrame == frame && clip.playbackFrame == nil)
        let image = clip.preview!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        precondition(image.width == clip.renderDimensions.width && image.height == clip.renderDimensions.height)
        clip.startPlayback()
        try await wait("resume") { clip.currentFrame > frame }
        if let elapsed = clip.playbackAudioElapsed {
            precondition(abs(Double(clip.currentFrame - frame) / Double(clip.frameRate) - elapsed) < 0.25,
                         "Resume did not align audio to the selected frame")
        }
        clip.exposure = 1
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying, "Adjustment did not safely pause playback")
        try await wait("adjustments") { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        clip.exposure = 0
        try await wait("restore exposure") { !clip.isLoadingPreview && !clip.isLoadingThumbnail }
        clip.startPlayback()
        try await wait("resume after adjustment") { clip.currentFrame > frame + 1 }
        clip.currentFrame = 2
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying, "Scrubbing did not stop playback")
        try await wait("seek") { !clip.isLoadingPreview }
        for resolution in PlaybackResolution.allCases {
            project.playbackResolution = resolution
            clip.startPlayback()
            try await wait("resolution \(resolution)") {
                guard let pixels = clip.playbackFrame else { return false }
                return abs(Double(pixels.width) - Double(clip.renderDimensions.width) * Double(resolution.scale)) <= 8
            }
            precondition(clip.isPlaying && clip.playbackResolution == resolution)
        }
        project.playbackResolution = .full
        clip.stopPlayback()
        try await wait("pause after resolution change") { !clip.isLoadingPreview }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = PlaybackKeyboardShortcuts.Anchor()
        anchor.project = project
        window.contentView = anchor
        window.orderFront(nil)
        func space(repeating: Bool = false, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: " ",
                            charactersIgnoringModifiers: " ", isARepeat: repeating, keyCode: 49)!
        }
        precondition(anchor.handle(space()) == nil && clip.isPlaying, "Space did not play")
        precondition(anchor.handle(space(repeating: true)) == nil && clip.isPlaying, "Held Space toggled repeatedly")
        precondition(anchor.handle(space()) == nil && !clip.isPlaying, "Space did not pause")
        precondition(anchor.handle(space(modifiers: .command)) != nil && !clip.isPlaying,
                     "Modified Space was intercepted")
        func zoomKey(_ key: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: key,
                            charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "z" ? 6 : 24)!
        }
        precondition(anchor.handle(zoomKey("+", modifiers: [.command, .shift])) == nil && clip.previewZoom > 1)
        precondition(anchor.handle(zoomKey("-", modifiers: .command)) == nil && abs(clip.previewZoom - 1) < 0.001)
        clip.zoomIn()
        precondition(anchor.handle(zoomKey("z")) == nil && clip.previewZoom == 1, "Z did not reset zoom")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        anchor.addSubview(editor)
        precondition(window.makeFirstResponder(editor))
        precondition(anchor.handle(space()) != nil && !clip.isPlaying, "Space interrupted text editing")
        precondition(anchor.handle(zoomKey("z")) != nil && anchor.handle(zoomKey("+", modifiers: .command)) != nil &&
                     clip.previewZoom == 1, "Zoom shortcuts interrupted text editing")
        anchor.removeMonitor()
        window.orderOut(nil)
        try await wait("pause after keyboard check") { !clip.isLoadingPreview }
        clip.startPlayback()
        try await wait("play before export") { clip.currentFrame > 3 }
        project.releaseDecoders()
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying, "Export suspension left playback running")
        precondition(Array(retainedPixels.prefix(512)) == retainedSignature,
                     "Later decoding or decoder teardown overwrote retained frame pixels")
        clip.loadPreviewFrame()
        try await wait("restore") { !clip.isLoadingPreview }
        clip.startPlayback()
        _ = project.importClip(path: "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Media/sample.braw")
        try await wait("selection change") { !project.isImporting }
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying, "Selection change left previous clip playing")
        project.selectClip(0)
        try await wait("reselect") { !clip.isLoadingPreview }
        clip.currentFrame = clip.frameCount - 3
        try await wait("seek near end") { !clip.isLoadingPreview }
        clip.startPlayback(direction: .forward)
        try await wait("automatic next clip") { project.selectedIndex == 1 }
        precondition(!clip.isPlaying && !clip.playbackAudioIsPlaying, "Old clip remained playing after advancing")
        try await wait("last clip stops") { project.selectedClip?.isPlaying == false }
        project.navigatePlaybackClip(by: -1)
        precondition(project.selectedIndex == 0 && clip.currentFrame == 0 && !clip.isPlaying,
                     "Previous clip transport did not select the first clip")
        project.navigatePlaybackClip(by: 1)
        precondition(project.selectedIndex == 1, "Next clip transport failed")
        project.navigatePlaybackClip(by: -1)
        project.playbackLoopEnabled = true
        clip.currentFrame = clip.frameCount - 3
        try await wait("loop seek") { !clip.isLoadingPreview }
        clip.startPlayback(direction: .forward)
        try await wait("loop wraps") { clip.currentFrame < 12 && clip.isPlaying }
        precondition(project.selectedIndex == 0, "Loop advanced to another clip")
        project.stopAndRewindPlayback()
        precondition(!clip.isPlaying && clip.currentFrame == 0, "Stop did not pause and rewind")
        project.playbackLoopEnabled = false
        clip.currentFrame = 24
        try await wait("reverse seek") { !clip.isLoadingPreview }
        clip.startPlayback(direction: .reverse)
        try await wait("reverse playback") { clip.currentFrame < 20 }
        precondition(clip.isPlaying && clip.playbackDirection == .reverse)
        if audio.samples > 0 { precondition(clip.playbackAudioIsPlaying, "Reverse playback has no audio") }
        clip.stopPlayback()
        clip.currentFrame = 2
        try await wait("reverse boundary seek") { !clip.isLoadingPreview }
        clip.startPlayback(direction: .reverse)
        try await wait("reverse stops at first clip") { !clip.isPlaying }
        precondition(project.selectedIndex == 0 && clip.currentFrame == 0)
        project.selectClip(1)
        project.selectedClip!.startPlayback(direction: .reverse)
        try await wait("reverse automatically selects previous clip") { project.selectedIndex == 0 && clip.isPlaying }
        precondition(clip.playbackDirection == .reverse)
        project.stopAndRewindPlayback()
        print("PASS: real BRAW playback/audio, all transport controls, looping, forward/reverse clip advance and boundaries")
    }
}
