import Foundation
import Photos

/// Saves panoramas (with their Photo Sphere metadata intact) to the photo library.
/// Uses add-only access: the app never reads the user's library.
enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Pano 360 is not allowed to add photos. You can allow it in Settings." }
    }

    static func save(_ item: PanoramaItem) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: item.url, options: nil)
        }
    }
}
