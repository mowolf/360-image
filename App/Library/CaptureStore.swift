import Foundation
import PanoramaCore

/// Keeps the raw data of every capture (merged photos, poses, depth, ARKit points) so a
/// panorama can be re-stitched with newer versions of the stitcher, and so the data can
/// be exported for debugging alignment on real scenes.
///
/// Layout: Documents/Captures/<capture-id>/{manifest.json, report.json, *.jpg, *.depth, *.rel}
/// A panorama links to its capture via Documents/Panoramas/<pano-id>.capture.
enum CaptureStore {
    static let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    struct ShotRecord: Codable {
        var id: UUID
        var targetID: Int
        var image: String
        var intrinsics: Intrinsics
        var rotation: [Double]   // row-major 3x3, camera-to-world (ARKit)
        var position: [Double]   // ARKit world, metres
        var depth: String?
        var relativeDepth: String?
    }

    struct Manifest: Codable {
        var version = 1
        var appVersion: String
        var created: Date
        var shots: [ShotRecord]
        /// ARKit feature points, flattened x,y,z.
        var scenePoints: [Float]
    }

    /// Moves a finished capture session into permanent storage and writes its manifest.
    /// Returns the capture folder name.
    static func persist(_ capture: CaptureResult) throws -> String {
        let name = capture.sessionDirectory.lastPathComponent
        let dest = root.appendingPathComponent(name, isDirectory: true)
        if capture.sessionDirectory.standardizedFileURL != dest.standardizedFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: capture.sessionDirectory, to: dest)
        }
        let manifest = Manifest(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            created: Date(),
            shots: capture.shots.map { s in
                ShotRecord(id: s.id, targetID: s.targetID, image: s.url.lastPathComponent, intrinsics: s.intrinsics,
                           rotation: (0..<9).map { s.rotation[$0 / 3, $0 % 3] },
                           position: [s.position.x, s.position.y, s.position.z],
                           depth: s.depthURL?.lastPathComponent, relativeDepth: s.relativeDepthURL?.lastPathComponent)
            },
            scenePoints: capture.scenePoints.flatMap { [Float($0.x), Float($0.y), Float($0.z)] })
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(manifest).write(to: dest.appendingPathComponent("manifest.json"))
        return name
    }

    static func load(folder: String) -> CaptureResult? {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let m = try? dec.decode(Manifest.self, from: data) else { return nil }
        let fm = FileManager.default
        func file(_ name: String?) -> URL? {
            guard let name else { return nil }
            let url = dir.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let shots = m.shots.compactMap { r -> CapturedShot? in
            guard let img = file(r.image), r.rotation.count == 9, r.position.count == 3 else { return nil }
            let R = Mat3(r.rotation[0], r.rotation[1], r.rotation[2], r.rotation[3], r.rotation[4],
                         r.rotation[5], r.rotation[6], r.rotation[7], r.rotation[8])
            return CapturedShot(id: r.id, targetID: r.targetID, url: img, intrinsics: r.intrinsics, rotation: R,
                                position: Vec3(r.position[0], r.position[1], r.position[2]),
                                depthURL: file(r.depth), relativeDepthURL: file(r.relativeDepth))
        }
        var points: [Vec3] = []
        points.reserveCapacity(m.scenePoints.count / 3)
        for i in stride(from: 0, to: m.scenePoints.count - 2, by: 3) {
            points.append(Vec3(Double(m.scenePoints[i]), Double(m.scenePoints[i + 1]), Double(m.scenePoints[i + 2])))
        }
        return CaptureResult(shots: shots, sessionDirectory: dir, scenePoints: points, waitForProcessing: {})
    }

    /// Stitch diagnostics stored next to the capture (and included in exports).
    static func writeReport(_ r: StitchReport, folder: String, panorama: String) {
        let dict: [String: Any] = [
            "panorama": panorama,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            "pairsTried": r.pairsTried, "pairsAligned": r.pairsAligned, "matches": r.matches,
            "residualSensor": r.rmsBefore, "residualRotationOnly": r.residualRotationOnly,
            "residualDepth": r.residualDepth, "residualFinal": r.rmsAfter,
            "depthModelUsed": r.depthModelUsed, "depthSources": r.depthSources,
            "depthDroppedPhotos": r.depthDroppedPhotos, "parallaxCompensated": r.parallaxCompensated,
            "vignette": [r.vignette.a, r.vignette.b], "coverage": r.coverage, "seconds": r.seconds,
            "gains": r.gains.map { $0.map(Double.init) },
        ]
        let url = root.appendingPathComponent(folder).appendingPathComponent("report-\(panorama).json")
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    /// Zips a capture folder for sharing.
    static func exportZip(folder: String) throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        var coordError: NSError?
        var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pano-capture-\(folder).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zip, to: dest)
                result = .success(dest)
            } catch {
                result = .failure(error)
            }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    static func delete(folder: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(folder, isDirectory: true))
    }
}
