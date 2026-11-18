import CoreGraphics
import Foundation
import Observation
import Photos

struct PanoramaItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let thumbnailURL: URL
    let date: Date
}

/// Finished panoramas live in Documents/Panoramas as Photo-Sphere JPEGs (+ a small thumbnail).
@Observable
final class PanoramaLibrary {
    private(set) var items: [PanoramaItem] = []

    @ObservationIgnored let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Panoramas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        items = files
            .filter { $0.pathExtension == "jpg" && !$0.lastPathComponent.hasSuffix("_thumb.jpg") }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return PanoramaItem(id: id, url: url, thumbnailURL: directory.appendingPathComponent("\(id)_thumb.jpg"), date: date)
            }
            .sorted { $0.date > $1.date }
    }

    func save(panorama: CGImage, sourceCount: Int) async throws -> PanoramaItem {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = "PANO_\(formatter.string(from: Date()))"
        let url = directory.appendingPathComponent("\(id).jpg")
        let thumbURL = directory.appendingPathComponent("\(id)_thumb.jpg")
        let meta = ImageSupport.photoSphereMetadata(width: panorama.width, height: panorama.height, imageCount: sourceCount)
        guard ImageSupport.writeJPEG(panorama, to: url, quality: 0.9, metadata: meta) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let thumb = ImageSupport.downscaled(panorama, maxLongSide: 768) {
            ImageSupport.writeJPEG(thumb, to: thumbURL, quality: 0.8)
        }
        let item = PanoramaItem(id: id, url: url, thumbnailURL: thumbURL, date: Date())
        await MainActor.run { self.reload() }
        return item
    }

    func delete(_ item: PanoramaItem) {
        try? FileManager.default.removeItem(at: item.url)
        try? FileManager.default.removeItem(at: item.thumbnailURL)
        reload()
    }

    /// Saves the original JPEG (with its Photo-Sphere metadata intact) to the Photos library.
    static func saveToPhotos(_ item: PanoramaItem) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Pano360", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photos access was denied."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: item.url, options: nil)
        }
    }
}
