import Foundation
import Photos

/// Saves panoramas (with their Photo Sphere metadata intact) to the photo library, into
/// a "Pano 360" album when full library access is granted, otherwise to Recents.
enum PhotoSaver {
    static let albumName = "Pano 360"

    enum SaveError: LocalizedError {
        case denied
        var errorDescription: String? { "Access to Photos was denied. You can allow it in Settings." }
    }

    static func save(_ item: PanoramaItem) async throws {
        // Full access is needed to find/create the album; "add only" still saves the photo.
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if status == .authorized {
            let album = try await albumCollection()
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: item.url, options: nil)
                if let album, let placeholder = request.placeholderForCreatedAsset,
                   let change = PHAssetCollectionChangeRequest(for: album) {
                    change.addAssets([placeholder] as NSArray)
                }
            }
            return
        }
        var addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if addOnly == .notDetermined {
            addOnly = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard addOnly == .authorized || addOnly == .limited || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: item.url, options: nil)
        }
    }

    /// Finds or creates the app's album.
    private static func albumCollection() async throws -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", albumName)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options).firstObject {
            return existing
        }
        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            placeholderID = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject
    }
}
