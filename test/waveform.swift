import Foundation

@main
struct WaveformTests {
    static func main() {
        func require(_ condition: Bool, _ message: String) {
            if !condition { fatalError(message) }
        }
        func value(_ scope: RGBWaveform, _ column: Int, _ signal: Int, _ channel: Int) -> UInt8 {
            scope.imageData[((255 - signal) * scope.columns + column) * 4 + channel]
        }
        // Two horizontal positions: full red, then mid green/full blue.
        let scope = RGBWaveform.analyze(bgra: Data([0, 0, 255, 255, 255, 128, 0, 255]), width: 2, height: 1)!
        require(scope.peaks == [255, 128, 255], "BGRA channel order is incorrect")
        require(scope.saturatedPixels == [1, 0, 1], "Saturation counts are incorrect")
        require(value(scope, 0, 255, 0) == 255 && value(scope, 0, 0, 1) == 255, "0/100 endpoints or vertical orientation are incorrect")
        require(value(scope, 1, 128, 1) == 255 && value(scope, 1, 255, 2) == 255, "Horizontal positions or intermediate levels are incorrect")
        require(value(scope, 1, 255, 0) == 0, "Red leaked into another position")
        let black = RGBWaveform.analyze(bgra: Data([0, 0, 0, 255]), width: 1, height: 1)!
        require(black.peaks == [0, 0, 0] && black.saturatedPixels == [0, 0, 0], "Black is reported as highlight saturation")
        var pixels = Data(repeating: 0, count: 1024 * 2 * 4)
        for index in 0..<(1024 * 2) { pixels[index * 4 + 3] = 255 }
        // A single bright pixel must survive horizontal aggregation.
        pixels[(1024 + 1023) * 4 + 2] = 255
        let narrow = RGBWaveform.analyze(bgra: pixels, width: 1024, height: 2)!
        require(narrow.columns == 256 && narrow.pixelCount == 2048, "Unexpected aggregation dimensions")
        require(narrow.saturatedPixels == [1, 0, 0] && value(narrow, 255, 255, 0) > 0, "Narrow clipped highlight was missed")
        require(RGBWaveform.analyze(bgra: Data(), width: 0, height: 1) == nil, "Empty dimensions accepted")
        require(RGBWaveform.analyze(bgra: Data([0]), width: 1, height: 1) == nil, "Truncated frame accepted")
        require(RGBWaveform.analyze(bgra: Data(), width: Int.max, height: 2) == nil, "Overflowing dimensions accepted")
        print("PASS: RGB order, 0/100 endpoints, spatial position, peaks, saturation, narrow highlights, invalid frames")
    }
}
