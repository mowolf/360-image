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

    func save(panorama: CGImage, sourceCount: Int, location: ShotLocation? = nil,
              heading: Double? = nil) async throws -> PanoramaItem {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let id = "PANO_\(formatter.string(from: Date()))"
        let url = directory.appendingPathComponent("\(id).jpg")
        let thumbURL = directory.appendingPathComponent("\(id)_thumb.jpg")
        let meta = ImageSupport.photoSphereMetadata(width: panorama.width, height: panorama.height, imageCount: sourceCount,
                                                    location: location, heading: heading)
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
        if let folder = captureFolder(for: item) {
            try? FileManager.default.removeItem(at: linkURL(item))
            // Remove the raw capture once no panorama refers to it any more.
            let stillUsed = items.contains { $0.id != item.id && captureFolder(for: $0) == folder }
            if !stillUsed { CaptureStore.delete(folder: folder) }
        }
        reload()
    }

    // MARK: Raw captures

    private func linkURL(_ item: PanoramaItem) -> URL {
        directory.appendingPathComponent("\(item.id).capture")
    }

    func link(_ item: PanoramaItem, captureFolder: String) {
        try? captureFolder.write(to: linkURL(item), atomically: true, encoding: .utf8)
    }

    /// Folder in the CaptureStore holding this panorama's raw photos, if kept.
    func captureFolder(for item: PanoramaItem) -> String? {
        guard let s = try? String(contentsOf: linkURL(item), encoding: .utf8) else { return nil }
        let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.fileExists(atPath: CaptureStore.root.appendingPathComponent(name).path) ? name : nil
    }

}
