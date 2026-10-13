import Foundation
import AVFoundation

struct PlaybackAudioFormat: Sendable {
    let rate: UInt32
    let channels: UInt32
    let bits: UInt32
    let samples: UInt64
}

enum PlaybackPCM {
    /// Camera PCM is signed little-endian, interleaved in source channel order.
    static func floats(_ bytes: Data, bits: UInt32) -> [Float]? {
        guard [16, 24, 32].contains(bits), bytes.count % Int(bits / 8) == 0 else { return nil }
        let stride = Int(bits / 8)
        let divisor = pow(2.0, Double(bits - 1))
        return bytes.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            return Swift.stride(from: 0, to: source.count, by: stride).map { offset in
                var value: UInt32 = 0
                for byte in 0..<stride { value |= UInt32(source[offset + byte]) << (8 * byte) }
                let shift = 32 - bits
                let signed = Int32(bitPattern: value << shift) >> shift
                return Float(Double(signed) / divisor)
            }
        }
    }
}

/// Audio is the playback clock. At most about one second is scheduled at once.
@MainActor final class PlaybackAudio {
    let source: PlaybackAudioFormat
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private(set) var nextSample: UInt64
    private var scheduledSamples: UInt64 = 0
    private var hasStarted = false
    private let direction: PlaybackDirection

    init(source: PlaybackAudioFormat, firstFrame: UInt64, fps: Double, direction: PlaybackDirection = .forward) throws {
        guard source.rate > 0, (1...32).contains(source.channels), [16, 24, 32].contains(source.bits),
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(source.rate), channels: source.channels) else {
            throw AudioError.invalidFormat
        }
        self.source = source
        self.format = format
        self.direction = direction
        let position = direction == .forward ? firstFrame : firstFrame + 1
        nextSample = min(source.samples, UInt64(Double(position) / fps * Double(source.rate)))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    var elapsed: Double? {
        guard hasStarted, let renderTime = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: renderTime), time.sampleRate > 0 else { return nil }
        return max(0, Double(time.sampleTime) / time.sampleRate - player.outputPresentationLatency)
    }
    var needsBuffer: Bool {
        hasMoreSamples && Double(scheduledSamples) / Double(source.rate) - (elapsed ?? 0) < 0.75
    }
    private var hasMoreSamples: Bool { direction == .forward ? nextSample < source.samples : nextSample > 0 }
    var nextCount: UInt32 {
        let remaining = direction == .forward ? source.samples - nextSample : nextSample
        return UInt32(min(65536, min(UInt64(source.rate / 4), remaining)))
    }
    var readStart: UInt64 { direction == .forward ? nextSample : nextSample - UInt64(nextCount) }
    var isPlaying: Bool { player.isPlaying }
    var interruption: AudioError? {
        guard hasStarted else { return nil }
        if !engine.isRunning { return .deviceChanged }
        if hasMoreSamples, let elapsed,
           elapsed > Double(scheduledSamples) / Double(source.rate) + 0.01 { return .bufferingInterrupted }
        return nil
    }

    func schedule(_ samples: [Float]) throws {
        let channels = Int(source.channels)
        guard !samples.isEmpty, samples.count % channels == 0 else { throw AudioError.invalidSamples }
        let frames = samples.count / channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)),
              let output = buffer.floatChannelData else { throw AudioError.invalidSamples }
        buffer.frameLength = UInt32(frames)
        for channel in 0..<channels {
            for frame in 0..<frames {
                let sourceFrame = direction == .forward ? frame : frames - 1 - frame
                output[channel][frame] = samples[sourceFrame * channels + channel]
            }
        }
        player.scheduleBuffer(buffer)
        if direction == .forward { nextSample += UInt64(frames) } else { nextSample -= UInt64(frames) }
        scheduledSamples += UInt64(frames)
    }
    func play() { hasStarted = true; player.play() }
    func stop() { player.stop(); engine.stop(); hasStarted = false }

    enum AudioError: LocalizedError {
        case invalidFormat, invalidSamples, readFailed, bufferingInterrupted, deviceChanged
        var errorDescription: String? {
            switch self {
            case .invalidFormat: "This clip's audio format cannot be played."
            case .invalidSamples: "The decoder returned invalid audio samples."
            case .readFailed: "Could not buffer playback audio."
            case .bufferingInterrupted: "Playback paused because audio buffering could not keep up. Press Play to retry."
            case .deviceChanged: "Playback paused because the audio device changed. Press Play to resume."
            }
        }
    }
}
