import SwiftUI

struct RGBWaveformView: View {
    @ObservedObject var clip: ClipModel

    private var scopeImage: CGImage? {
        guard let waveform = clip.waveform,
              let provider = CGDataProvider(data: waveform.imageData as CFData) else { return nil }
        return CGImage(width: waveform.columns, height: RGBWaveform.levels,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: waveform.columns * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RGB Waveform").font(.system(size: 11, weight: .semibold))
                Spacer()
                if clip.isLoadingPreview {
                    Text("Updating…").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 5) {
                VStack(spacing: 0) {
                    ForEach([100, 75, 50, 25, 0], id: \.self) { level in
                        Text("\(level)").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if level != 0 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: 24)
                GeometryReader { geometry in
                    ZStack {
                        Color.black
                        if let image = scopeImage {
                            Image(decorative: image, scale: 1)
                                .resizable().interpolation(.none)
                                .opacity(clip.isLoadingPreview ? 0.5 : 1)
                        }
                        Path { path in
                            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                                let y = fraction * (geometry.size.height - 1)
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.22), lineWidth: 0.5)
                        if clip.waveform == nil {
                            Text(clip.previewError == nil ? "Waiting for preview" : "Preview unavailable")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                .clipped()
            }
            .frame(height: 150)
            if let waveform = clip.waveform, !clip.isLoadingPreview {
                HStack(spacing: 8) {
                    Text("Peak").foregroundStyle(.secondary)
                    ForEach(0..<3, id: \.self) { channel in
                        Text("\(["R", "G", "B"][channel]) \(Double(waveform.peaks[channel]) / 255 * 100, specifier: "%.1f")")
                            .foregroundStyle([Color.red, Color.green, Color.blue][channel])
                    }
                }
                .font(.system(size: 9, design: .monospaced))
                if waveform.saturatedPixels.contains(where: { $0 > 0 }) {
                    Text("At 100: " + (0..<3).map { channel in
                        let percent = Double(waveform.saturatedPixels[channel]) / Double(waveform.pixelCount) * 100
                        if percent > 0 && percent < 0.01 {
                            return "\(["R", "G", "B"][channel]) <0.01%"
                        }
                        return String(format: "%@ %.2f%%", ["R", "G", "B"][channel], percent)
                    }.joined(separator: "  "))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.orange)
                }
            }
            Text(clip.previewLUT ? "Preview signal · includes LUT" : "Preview signal · LUT off")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .help("RGB preview levels from 0 to 100. The horizontal axis follows image position. Values at 100 indicate preview saturation; raw sensor clipping and export levels may differ, particularly with a preview LUT.")
    }
}
