import Foundation

/// Display-referred RGB signal, measured from the same adjusted BGRA pixels as
/// the preview. This measures preview saturation, not raw sensor clipping.
struct RGBWaveform: Sendable {
    let columns: Int
    let imageData: Data
    let peaks: [UInt8] // R, G, B
    let saturatedPixels: [Int]
    let pixelCount: Int
    static let levels = 256

    static func analyze(bgra: Data, width: Int, height: Int) -> RGBWaveform? {
        guard width > 0, height > 0, width <= Int.max / height else { return nil }
        let pixelCount = width * height
        guard pixelCount <= Int.max / 4, bgra.count == pixelCount * 4 else { return nil }
        let columns = min(width, 256)
        var counts = [UInt32](repeating: 0, count: columns * levels * 3)
        var peaks = [UInt8](repeating: 0, count: 3)
        var saturated = [Int](repeating: 0, count: 3)
        // Examine every pixel so narrow clipped highlights cannot be missed by
        // downsampling. Aggregate horizontally; signal level is the vertical axis.
        bgra.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let column = x * columns / width
                    for channel in 0..<3 {
                        let value = bytes[offset + 2 - channel]
                        peaks[channel] = max(peaks[channel], value)
                        if value == 255 { saturated[channel] += 1 }
                        let row = 255 - Int(value)
                        counts[(row * columns + column) * 3 + channel] += 1
                    }
                }
            }
        }
        let maximum = counts.max() ?? 1
        let normalization = log1p(Double(maximum))
        var rgba = Data(count: columns * levels * 4)
        rgba.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for cell in 0..<(columns * levels) {
                for channel in 0..<3 {
                    let density = log1p(Double(counts[cell * 3 + channel])) / normalization
                    bytes[cell * 4 + channel] = UInt8(min(255, (density * 255).rounded()))
                }
                bytes[cell * 4 + 3] = 255
            }
        }
        return RGBWaveform(columns: columns, imageData: rgba, peaks: peaks,
                           saturatedPixels: saturated, pixelCount: pixelCount)
    }
}
