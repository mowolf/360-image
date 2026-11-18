import Foundation

/// Interleaved floating point image (values nominally in 0...1).
public struct FloatImage: Sendable {
    public var width: Int
    public var height: Int
    public var channels: Int
    public var data: [Float]

    public init(width: Int, height: Int, channels: Int, fill: Float = 0) {
        self.width = width
        self.height = height
        self.channels = channels
        self.data = [Float](repeating: fill, count: width * height * channels)
    }

    public init(width: Int, height: Int, channels: Int, data: [Float]) {
        precondition(data.count == width * height * channels)
        self.width = width
        self.height = height
        self.channels = channels
        self.data = data
    }

    /// Creates an RGB float image from 8-bit RGBA/RGB/BGRA bytes.
    public init(rgba8 bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                bytesPerPixel: Int = 4, bgr: Bool = false) {
        self.init(width: width, height: height, channels: 3)
        let ri = bgr ? 2 : 0, bi = bgr ? 0 : 2
        data.withUnsafeMutableBufferPointer { dst in
            let lut: [Float] = (0..<256).map { Float($0) / 255 }
            for y in 0..<height {
                let row = bytes.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                var o = y * width * 3
                for x in 0..<width {
                    let p = row + x * bytesPerPixel
                    dst[o] = lut[Int(p[ri])]
                    dst[o + 1] = lut[Int(p[1])]
                    dst[o + 2] = lut[Int(p[bi])]
                    o += 3
                }
            }
        }
    }

    @inlinable public var pixelCount: Int { width * height }

    /// Converts to 8-bit RGBA (alpha = 255), clamping values to 0...1.
    public func rgba8() -> [UInt8] {
        var out = [UInt8](repeating: 255, count: width * height * 4)
        let c = channels
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                DispatchQueue.concurrentPerform(iterations: height) { y in
                    for x in 0..<width {
                        let s = (y * width + x) * c
                        let d = (y * width + x) * 4
                        for ch in 0..<3 {
                            let v = src[s + (c >= 3 ? ch : 0)]
                            dst[d + ch] = UInt8(max(0, min(255, v * 255 + 0.5)))
                        }
                    }
                }
            }
        }
        return out
    }

    /// Luminance (Rec. 709) single-channel copy.
    public func luminance() -> FloatImage {
        if channels == 1 { return self }
        var out = FloatImage(width: width, height: height, channels: 1)
        let c = channels
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    dst[i] = 0.2126 * src[i * c] + 0.7152 * src[i * c + 1] + 0.0722 * src[i * c + 2]
                }
            }
        }
        return out
    }

    /// Bilinear sample at continuous pixel coordinates (pixel centers at integers).
    /// Coordinates are clamped to the image.
    @inlinable
    public static func sampleBilinear(_ p: UnsafeBufferPointer<Float>, width: Int, height: Int, channels: Int,
                                      x: Double, y: Double, out: UnsafeMutablePointer<Float>) {
        let xf = max(0, min(Double(width - 1), x))
        let yf = max(0, min(Double(height - 1), y))
        let x0 = min(Int(xf), width - 2 < 0 ? 0 : width - 2)
        let y0 = min(Int(yf), height - 2 < 0 ? 0 : height - 2)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = Float(xf - Double(x0)), fy = Float(yf - Double(y0))
        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
        let i00 = (y0 * width + x0) * channels, i10 = (y0 * width + x1) * channels
        let i01 = (y1 * width + x0) * channels, i11 = (y1 * width + x1) * channels
        for c in 0..<channels {
            out[c] = p[i00 + c] * w00 + p[i10 + c] * w10 + p[i01 + c] * w01 + p[i11 + c] * w11
        }
    }
}
