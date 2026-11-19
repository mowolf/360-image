import Foundation
import Observation
import PanoramaCore
import UIKit

/// Runs the stitcher off the main thread and saves the finished panorama to the library.
@Observable
final class StitchJob: Identifiable {
    let id = UUID()
    let shots: [CapturedShot]
    let sessionDirectory: URL
    @ObservationIgnored private let library: PanoramaLibrary

    var stage: StitchStage = .preparing
    var progress: Double = 0
    var result: PanoramaItem?
    var errorMessage: String?
    var report: StitchReport?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let stitcher = Stitcher()
    @ObservationIgnored private var cancelled = false

    @ObservationIgnored private let capture: CaptureResult
    /// Set when re-stitching a capture that is already in the CaptureStore.
    @ObservationIgnored private let existingCaptureFolder: String?

    init(capture: CaptureResult, library: PanoramaLibrary, existingCaptureFolder: String? = nil) {
        self.capture = capture
        self.existingCaptureFolder = existingCaptureFolder
        self.shots = capture.shots
        self.sessionDirectory = capture.sessionDirectory
        self.library = library
    }

    /// Output width chosen from the device's memory (the multi-band blender keeps a float
    /// pyramid of the whole panorama in memory).
    static var outputWidth: Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gb >= 7.5 { return 8192 }
        if gb >= 5.5 { return 6144 }
        return 4096
    }

    func start() {
        guard task == nil else { return }
        let shots = self.shots
        let capture = self.capture
        let existingFolder = existingCaptureFolder
        var options = StitchOptions()
        options.outputWidth = Self.outputWidth
        stitcher.isCancelled = { [weak self] in self?.cancelled ?? true }

        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "stitch")
        task = Task.detached(priority: .userInitiated) { [weak self, stitcher, library, sessionDirectory] in
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) } }
            do {
                // Shots are merged/written in the background during capture; wait for the last ones.
                await capture.waitForProcessing()
                let sources = shots.map { shot in
                    StitchSource(intrinsics: shot.intrinsics, rotation: shot.rotation, position: shot.position,
                                 depth: shot.depthURL.flatMap(DepthIO.read),
                                 relativeDepth: shot.relativeDepthURL.flatMap(DepthIO.readRelative)) {
                        guard let cg = ImageSupport.loadCGImage(shot.url) else { throw CocoaError(.fileReadCorruptFile) }
                        return ImageSupport.floatImage(from: cg)
                    }
                }
                let res = try stitcher.stitch(sources, scenePoints: capture.scenePoints, options: options) { stage, p in
                    Task { @MainActor in
                        self?.stage = stage
                        self?.progress = p
                    }
                }
                guard let cg = ImageSupport.cgImage(from: res.panorama) else { throw CocoaError(.fileWriteUnknown) }
                // Location of the panorama = the most accurate GPS fix among its photos;
                // heading = direction of the first photo (the panorama's centre).
                let location = shots.compactMap(\.location).min { $0.horizontalAccuracy < $1.horizontalAccuracy }
                let heading = shots.first?.location?.heading
                let item = try await library.save(panorama: cg, sourceCount: shots.count,
                                                  location: location, heading: heading)
                if UserDefaults.standard.bool(forKey: Settings.autoSaveToPhotos) {
                    try? await PhotoSaver.save(item)
                }
                // Keep the raw capture for re-stitching / export.
                if let folder = existingFolder ?? (try? CaptureStore.persist(capture)) {
                    library.link(item, captureFolder: folder)
                    CaptureStore.writeReport(res.report, folder: folder, panorama: item.id)
                } else {
                    try? FileManager.default.removeItem(at: sessionDirectory)
                }
                await MainActor.run {
                    self?.report = res.report
                    self?.result = item
                }
            } catch StitchError.cancelled {
                if existingFolder == nil { try? FileManager.default.removeItem(at: sessionDirectory) }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
    }
}

extension StitchStage {
    var title: String { rawValue }
}
