import Foundation

enum PreviewMode: String, CaseIterable, Identifiable {
    case embeddedLUT = "Preview embedded LUT"
    case log = "Log"
    var id: Self { self }
}

/// Blackmagic-style bands over the active preview signal from 0 to 100.
/// These indicate rendered signal levels, not camera-specific sensor clipping.
struct FalseColor {
    struct RGB: Equatable { let r, g, b: UInt8 }
    static let purple = RGB(r: 129, g: 44, b: 179)
    static let blue = RGB(r: 36, g: 78, b: 225)
    static let green = RGB(r: 73, g: 190, b: 87)
    static let pink = RGB(r: 239, g: 143, b: 174)
    static let yellow = RGB(r: 255, g: 229, b: 0)
    static let red = RGB(r: 239, g: 38, b: 30)

    static func color(signal: Double) -> RGB {
        let level = min(1, max(0, signal))
        if level < 0.02 { return purple }
        if level < 0.04 { return blue }
        if (0.38...0.42).contains(level) { return green }
        if (0.52...0.56).contains(level) { return pink }
        if level >= 0.95 { return red }
        if level >= 0.80 { return yellow }
        let v = UInt8((level * 255).rounded())
        return RGB(r: v, g: v, b: v)
    }

    static func render(bgra: Data, width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, width <= Int.max / height,
              width * height <= Int.max / 4, bgra.count == width * height * 4 else { return nil }
        var output = Data(count: bgra.count)
        // Reuse the palette for each encoded signal level.
        let palette = (0...255).map { color(signal: Double($0) / 255) }
        output.withUnsafeMutableBytes { destination in
            bgra.withUnsafeBytes { source in
                let src = source.bindMemory(to: UInt8.self)
                let dst = destination.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: src.count, by: 4) {
                    // Measure the active preview's encoded signal directly,
                    // matching waveform levels: no log/linear or gamut transform.
                    let r = Double(src[i+2]) * 0.2126
                    let g = Double(src[i+1]) * 0.7152
                    let b = Double(src[i]) * 0.0722
                    let level = Int((r + g + b).rounded())
                    let c = palette[level]
                    dst[i] = c.b; dst[i+1] = c.g; dst[i+2] = c.r; dst[i+3] = 255
                }
            }
        }
        return output
    }
}
