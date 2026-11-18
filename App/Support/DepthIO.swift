import ARKit
import Foundation
import PanoramaCore

/// Saves / loads LiDAR depth maps as a tiny binary file:
/// Int32 width, Int32 height, then width*height Float32 z-depth values (0 = unknown).
enum DepthIO {
    static func write(_ data: ARDepthData, to url: URL) -> Bool {
        let map = data.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32,
              let base = CVPixelBufferGetBaseAddress(map) else { return false }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)

        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        if let conf = data.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(conf)
            confRow = CVPixelBufferGetBytesPerRow(conf)
        }
        defer { if let conf = data.confidenceMap { CVPixelBufferUnlockBaseAddress(conf, .readOnly) } }

        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<w {
                var d = row[x]
                if let confBase {
                    let c = confBase.advanced(by: y * confRow).assumingMemoryBound(to: UInt8.self)[x]
                    // Low confidence happens at silhouettes and beyond LiDAR range: keep far
                    // readings (they are far either way), drop unreliable near ones.
                    if Int(c) == ARConfidenceLevel.low.rawValue && d < 3 { d = 0 }
                }
                values[y * w + x] = d.isFinite ? d : 0
            }
        }
        var out = Data()
        var w32 = Int32(w), h32 = Int32(h)
        withUnsafeBytes(of: &w32) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &h32) { out.append(contentsOf: $0) }
        values.withUnsafeBytes { out.append(contentsOf: $0) }
        return (try? out.write(to: url)) != nil
    }

    static func read(_ url: URL) -> DepthMap? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) })
        let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) })
        guard w > 0, h > 0, data.count == 8 + w * h * 4 else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<data.count) }
        return DepthMap(width: w, height: h, depth: values)
    }

    static func writeRelative(_ values: [Float], width w: Int, height h: Int, to url: URL) {
        var out = Data()
        var w32 = Int32(w), h32 = Int32(h)
        withUnsafeBytes(of: &w32) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &h32) { out.append(contentsOf: $0) }
        values.withUnsafeBytes { out.append(contentsOf: $0) }
        try? out.write(to: url)
    }

    static func readRelative(_ url: URL) -> RelativeDepth? {
        guard let data = try? Data(contentsOf: url), data.count >= 8 else { return nil }
        let w = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) })
        let h = Int(data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self) })
        guard w > 0, h > 0, data.count == 8 + w * h * 4 else { return nil }
        var values = [Float](repeating: 0, count: w * h)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 8..<data.count) }
        return RelativeDepth(width: w, height: h, values: values)
    }
}
