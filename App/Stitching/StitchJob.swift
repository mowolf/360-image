import BackgroundTasks
import Foundation
import Observation
import PanoramaCore
import UIKit

/// Runs the stitcher off the main thread and saves the finished panorama to the library.
///
/// Robust against leaving the app: the capture is moved to permanent storage (marked
/// "pending") *before* stitching starts, the work continues in the background as an iOS
/// continued-processing task (with system progress UI), and if iOS stops it anyway the
/// pending capture is stitched again when the app returns or is launched next time.
@Observable
final class StitchJob: Identifiable {
    enum Origin { case newCapture, resume, restitch }

    let id = UUID()
    let shots: [CapturedShot]
    let origin: Origin

    var stage: StitchStage = .preparing
    var progress: Double = 0
    var result: PanoramaItem?
    var errorMessage: String?
    var report: StitchReport?
    /// The background time ran out; the job restarts when the app is active again.
    var interrupted = false

    @ObservationIgnored private let library: PanoramaLibrary
    @ObservationIgnored private let capture: CaptureResult
    @ObservationIgnored private var captureFolder: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let stitcher = Stitcher()
    @ObservationIgnored private var userCancelled = false
    @ObservationIgnored private var expired = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var continued: BGContinuedProcessingTask?

    init(capture: CaptureResult, library: PanoramaLibrary, existingCaptureFolder: String? = nil, origin: Origin? = nil) {
        self.capture = capture
        self.captureFolder = existingCaptureFolder
        self.origin = origin ?? (existingCaptureFolder == nil ? .newCapture : .restitch)
        self.shots = capture.shots
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

    /// Stage-local progress mapped to one overall 0...1 value.
    var overallProgress: Double {
        let p = progress
        switch stage {
        case .preparing: return 0.10 * p
        case .aligning: return 0.10 + 0.30 * p
        case .optimizing, .depth: return 0.40 + 0.05 * p
        case .refining: return 0.45 + 0.05 * p
        case .exposure: return 0.50 + 0.03 * p
        case .seams: return 0.53 + 0.07 * p
        case .blending: return 0.60 + 0.35 * p
        case .finishing: return 0.95 + 0.05 * p
        }
    }

    @MainActor
    func start() {
        guard task == nil else { return }
        interrupted = false
        expired = false
        userCancelled = false
        var options = StitchOptions()
        options.outputWidth = Self.outputWidth
        stitcher.isCancelled = { [weak self] in
            guard let self else { return true }
            return self.userCancelled || self.expired
        }
        beginBackgroundTime()
        BackgroundStitching.submit(self)

        let capture = self.capture
        let origin = self.origin
        let knownFolder = captureFolder
        task = Task.detached(priority: .userInitiated) { [weak self, stitcher, library] in
            var folder = knownFolder
            do {
                // Shots are merged/written in the background during capture; wait for the last ones,
                // then move the capture to permanent storage before doing anything expensive.
                await capture.waitForProcessing()
                if folder == nil { folder = try CaptureStore.persist(capture) }
                guard let folder else { throw CocoaError(.fileNoSuchFile) }
                await MainActor.run { self?.captureFolder = folder }
                if origin != .restitch { CaptureStore.markPending(folder) }
                guard let stored = CaptureStore.load(folder: folder) else { throw CocoaError(.fileReadCorruptFile) }

                let sources = stored.shots.map { shot in
                    StitchSource(intrinsics: shot.intrinsics, rotation: shot.rotation, position: shot.position,
                                 depth: shot.depthURL.flatMap(DepthIO.read),
                                 relativeDepth: shot.relativeDepthURL.flatMap(DepthIO.readRelative)) {
                        guard let cg = ImageSupport.loadCGImage(shot.url) else { throw CocoaError(.fileReadCorruptFile) }
                        return ImageSupport.floatImage(from: cg)
                    }
                }
                let res = try stitcher.stitch(sources, scenePoints: stored.scenePoints, options: options) { stage, p in
                    Task { @MainActor in
                        self?.stage = stage
                        self?.progress = p
                        self?.reportBackgroundProgress()
                    }
                }
                guard let cg = ImageSupport.cgImage(from: res.panorama) else { throw CocoaError(.fileWriteUnknown) }
                // Location of the panorama = the most accurate GPS fix among its photos;
                // heading = direction of the first photo (the panorama's centre).
                let location = stored.shots.compactMap(\.location).min { $0.horizontalAccuracy < $1.horizontalAccuracy }
                let heading = stored.shots.first?.location?.heading
                let item = try await library.save(panorama: cg, sourceCount: stored.shots.count,
                                                  location: location, heading: heading)
                if UserDefaults.standard.bool(forKey: Settings.autoSaveToPhotos) {
                    try? await PhotoSaver.save(item)
                }
                // Keep the raw capture for re-stitching / export only if enabled in Settings.
                let keep = origin == .restitch || UserDefaults.standard.bool(forKey: Settings.keepCaptureData)
                CaptureStore.clearPending(folder)
                if keep {
                    library.link(item, captureFolder: folder)
                    CaptureStore.writeReport(res.report, folder: folder, panorama: item.id)
                } else {
                    CaptureStore.delete(folder: folder)
                }
                await MainActor.run {
                    self?.report = res.report
                    self?.result = item
                    self?.finishBackground(success: true)
                }
            } catch StitchError.cancelled {
                let expired = await MainActor.run { self?.expired ?? false }
                if expired {
                    // iOS stopped us in the background: keep the pending capture and retry later.
                    await MainActor.run {
                        self?.task = nil
                        self?.interrupted = true
                        self?.finishBackground(success: false)
                    }
                } else {
                    if origin != .restitch, let folder { CaptureStore.delete(folder: folder) }
                    if folder == nil { try? FileManager.default.removeItem(at: capture.sessionDirectory) }
                    await MainActor.run { self?.finishBackground(success: false) }
                }
            } catch {
                if let folder, origin != .restitch {
                    // Give up on this capture after repeated failures so it cannot loop forever.
                    if CaptureStore.recordFailure(folder) >= 2 {
                        CaptureStore.clearPending(folder)
                        if !UserDefaults.standard.bool(forKey: Settings.keepCaptureData) { CaptureStore.delete(folder: folder) }
                    }
                }
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                    self?.finishBackground(success: false)
                }
            }
        }
    }

    /// Called when the app is active again after the background time ran out.
    @MainActor
    func resumeIfInterrupted() {
        guard interrupted, task == nil else { return }
        start()
    }

    func cancel() {
        userCancelled = true
        task?.cancel()
    }

    // MARK: Background execution

    @MainActor
    private func beginBackgroundTime() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "stitch") { [weak self] in
            // Out of time: stop cleanly (the capture stays pending) instead of being killed.
            self?.expire()
        }
    }

    /// Hands the job to iOS 26+ continued processing (keeps running with system progress UI).
    func attach(_ task: BGContinuedProcessingTask) {
        continued = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = { [weak self] in self?.expire() }
        Task { @MainActor in self.reportBackgroundProgress() }
    }

    @MainActor
    private func reportBackgroundProgress() {
        guard let continued else { return }
        continued.progress.completedUnitCount = Int64(overallProgress * 100)
        continued.updateTitle("Stitching panorama", subtitle: stage.title)
    }

    private func expire() {
        expired = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }

    @MainActor
    private func finishBackground(success: Bool) {
        continued?.setTaskCompleted(success: success)
        continued = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

extension StitchStage {
    var title: String { rawValue }
}

/// Submits iOS continued-processing tasks for stitching.
///
/// Note: iOS does not match a submitted identifier against a handler registered for the
/// wildcard pattern ("No launch handler registered" exception -> crash). The wildcard is
/// therefore only declared in Info.plist (BGTaskSchedulerPermittedIdentifiers), and each
/// concrete identifier is registered right before it is submitted. If registration fails,
/// nothing is submitted: the regular background time + resume-on-launch still protect
/// the capture.
enum BackgroundStitching {
    static let prefix = "com.moritzwolf.pano360.stitch"

    static func submit(_ job: StitchJob) {
        let identifier = "\(prefix).\(job.id.uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak job] task in
            guard let task = task as? BGContinuedProcessingTask, let job else {
                task.setTaskCompleted(success: false)
                return
            }
            job.attach(task)
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Stitching panorama",
                                                       subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Not available right now – fine, see above.
        }
    }
}
