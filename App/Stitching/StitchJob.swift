import BackgroundTasks
import Foundation
import Observation
import PanoramaCore
import UIKit
import os

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
    /// Called on the main actor when a new (not re-stitched) panorama was created.
    @ObservationIgnored var onNewPanorama: (@MainActor () -> Void)?

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
    /// Picks the largest width whose estimated peak memory fits comfortably into what iOS
    /// currently allows this app (less in the background than in the foreground).
    static var outputWidth: Int {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let deviceMax = gb >= 7.5 ? 8192 : (gb >= 5.5 ? 6144 : 4096)
        let available = Double(os_proc_available_memory())
        guard available > 0 else { return deviceMax }
        // Blender pyramids ~10.7 bytes/px² of width² plus tiles, photos and headroom.
        func estimate(_ w: Int) -> Double { Double(w) * Double(w) * 16 + 350_000_000 }
        for w in [8192, 6144, 4096] where w <= deviceMax && estimate(w) < available * 0.8 {
            return w
        }
        return 3072
    }

    /// Set when the job continues after being paused / stopped in the background.
    var wasPaused: Bool { origin == .resume || resumedAfterInterruption }
    @ObservationIgnored private var resumedAfterInterruption = false

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
                if origin != .restitch {
                    CaptureStore.markPending(folder)
                    // Counted *before* the work: a crash cannot be caught, so a capture that
                    // keeps crashing the stitcher must not be retried forever.
                    if CaptureStore.recordAttempt(folder) > 3 { throw StitchJobError.tooManyAttempts }
                }
                guard let stored = CaptureStore.load(folder: folder) else { throw CocoaError(.fileReadCorruptFile) }

                var options = options
                let sources: [StitchSource]
                if let hdr = Self.hdrToneMapping(stored.shots) {
                    // HDR capture: every shot's radiance on one brightness scale (via its auto
                    // exposure), then one exposure + highlight curve for the whole panorama.
                    sources = stored.shots.map { shot in
                        let scale = hdr.gain * Float(hdr.reference / (shot.exposureValue ?? hdr.reference))
                        return StitchSource(intrinsics: shot.intrinsics, rotation: shot.rotation, position: shot.position,
                                            depth: shot.depthURL.flatMap(DepthIO.read),
                                            relativeDepth: shot.relativeDepthURL.flatMap(DepthIO.readRelative)) {
                            guard let url = shot.hdrURL, let enc = ImageSupport.read16BitPNG(url) else {
                                guard let cg = ImageSupport.loadCGImage(shot.url) else { throw CocoaError(.fileReadCorruptFile) }
                                return ImageSupport.floatImage(from: cg)
                            }
                            let radiance = HDRRadiance.decode(enc.values, width: enc.width, height: enc.height)
                            return HDRRadiance.toDisplay(radiance, gain: scale, curve: hdr.curve)
                        }
                    }
                    options.hdrEncoding = nil
                } else {
                    sources = stored.shots.map { shot in
                        StitchSource(intrinsics: shot.intrinsics, rotation: shot.rotation, position: shot.position,
                                     depth: shot.depthURL.flatMap(DepthIO.read),
                                     relativeDepth: shot.relativeDepthURL.flatMap(DepthIO.readRelative)) {
                            guard let cg = ImageSupport.loadCGImage(shot.url) else { throw CocoaError(.fileReadCorruptFile) }
                            return ImageSupport.floatImage(from: cg)
                        }
                    }
                    // Older captures: shots encoded with the fixed curve -> re-tone-map at the end.
                    let merged = stored.shots.contains { shot in
                        FileManager.default.fileExists(atPath: shot.url.deletingPathExtension().appendingPathExtension("merge.json").path)
                    }
                    options.hdrEncoding = merged ? .standard : nil
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
                    if origin != .restitch { self?.onNewPanorama?() }
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
                    // Don't retry automatically after an error; keep the data only if the user keeps captures.
                    CaptureStore.clearPending(folder)
                    if !UserDefaults.standard.bool(forKey: Settings.keepCaptureData) { CaptureStore.delete(folder: folder) }
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
        resumedAfterInterruption = true
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
            guard let self else { return }
            // The assertion must be ended *synchronously* here, otherwise iOS terminates the app.
            UIApplication.shared.endBackgroundTask(self.backgroundTask)
            self.backgroundTask = .invalid
            // Only stop the work if no continued-processing task keeps the app running;
            // the capture stays pending and is finished when the app is active again.
            if self.continued == nil { self.expired = true }
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

    /// The continued-processing task is ending: stop promptly (checked per photo pair /
    /// per photo), keep the capture pending and finish it when the app is active again.
    private func expire() {
        expired = true
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

enum StitchJobError: LocalizedError {
    case tooManyAttempts
    var errorDescription: String? {
        "This panorama could not be finished after several attempts. Please try capturing it again."
    }
}

extension StitchJob {
    struct HDRToneMapping {
        let reference: Double      // exposure value (duration × ISO) of the first shot
        let gain: Float
        let curve: HighlightCurve
    }

    /// Panorama-wide exposure and highlight curve, if all shots have HDR data.
    static func hdrToneMapping(_ shots: [CapturedShot]) -> HDRToneMapping? {
        guard let ref = shots.first?.exposureValue, ref > 0,
              shots.allSatisfy({ $0.hdrURL != nil && ($0.exposureValue ?? 0) > 0 }) else { return nil }
        var stats: [(median: Double, p999: Double)] = []
        for shot in shots {
            let json = shot.url.deletingPathExtension().appendingPathExtension("merge.json")
            guard let data = try? Data(contentsOf: json),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let median = obj["radianceMedian"] as? Double, let p999 = obj["radianceP999"] as? Double,
                  let e = shot.exposureValue else { return nil }
            let s = ref / e
            stats.append((median * s, p999 * s))
        }
        let (gain, curve) = HDRRadiance.panoramaToneMapping(shots: stats)
        return HDRToneMapping(reference: ref, gain: gain, curve: curve)
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
