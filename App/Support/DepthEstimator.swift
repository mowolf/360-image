import CoreML
import CoreVideo
import Foundation
import PanoramaCore
import Vision

/// Monocular depth with Apple's Core ML build of Depth Anything V2 (Small, FP16), running
/// on the Neural Engine. The output is relative inverse depth (larger = closer) with an
/// unknown scale and shift; the stitcher fits it to metric ARKit points per photo.
///
/// The model (~50 MB) is downloaded by CI at build time (see `scripts/fetch-models.sh`).
/// Without it the app still works, using ARKit points / LiDAR only.
final class DepthEstimator: @unchecked Sendable {
    static let shared = DepthEstimator()
    private static let modelName = "DepthAnythingV2SmallF16"

    private let lock = NSLock()
    private var vnModel: VNCoreMLModel?
    private var loadAttempted = false

    var isAvailable: Bool {
        Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: Self.modelName, withExtension: "mlpackage") != nil
    }

    private func model() -> VNCoreMLModel? {
        lock.lock(); defer { lock.unlock() }
        if loadAttempted { return vnModel }
        loadAttempted = true
        do {
            var url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc")
            if url == nil, let pkg = Bundle.main.url(forResource: Self.modelName, withExtension: "mlpackage") {
                // Shipped uncompiled: compile once and cache.
                let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("\(Self.modelName).mlmodelc")
                if !FileManager.default.fileExists(atPath: cache.path) {
                    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let compiled = try MLModel.compileModel(at: pkg)
                    try? FileManager.default.removeItem(at: cache)
                    try FileManager.default.moveItem(at: compiled, to: cache)
                }
                url = cache
            }
            guard let url else { return nil }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            vnModel = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: config))
        } catch {
            vnModel = nil
        }
        return vnModel
    }

    /// Runs the network on a photo (sensor orientation) and saves the relative depth map.
    func estimate(_ image: CGImage, saveTo url: URL) {
        guard let model = model() else { return }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return }
        guard let obs = request.results?.first as? VNPixelBufferObservation,
              let values = Self.read(obs.pixelBuffer) else { return }
        DepthIO.writeRelative(values.values, width: values.width, height: values.height, to: url)
    }

    private static func read(_ pb: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let row = CVPixelBufferGetBytesPerRow(pb)
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let p = base.advanced(by: y * row).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { out[y * w + x] = Float(p[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<h {
                let p = base.advanced(by: y * row).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = p[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let p = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(p[x]) / 255 }
            }
        default:
            return nil
        }
        return (out, w, h)
    }
}
