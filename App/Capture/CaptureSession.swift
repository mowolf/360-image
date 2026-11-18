import ARKit
import AVFoundation
import Observation
import PanoramaCore
import RealityKit
import SwiftUI
import UIKit

struct CapturedShot: Identifiable, Sendable {
    let id: UUID
    let targetID: Int
    let url: URL
    let intrinsics: Intrinsics
    let rotation: Mat3
    /// Camera position (ARKit world, metres).
    let position: Vec3
    /// LiDAR depth saved next to the photo (Pro models), used for parallax compensation.
    let depthURL: URL?
    /// Monocular relative depth (Depth Anything V2), all devices.
    let relativeDepthURL: URL?
}

/// Drives the guided capture: tracks the phone's orientation with ARKit, decides which
/// target dot to show next, auto-captures when the phone is held steady on the dot,
/// and pins each captured photo into the AR scene so the user sees the sphere fill up.
@Observable
final class CaptureSession: NSObject, ARSessionDelegate {
    // MARK: Published UI state
    enum Phase: Equatable { case starting, capturing, complete, failed(String) }

    var phase: Phase = .starting
    var shots: [CapturedShot] = []
    var totalTargets = 0
    /// Screen position of the active target (nil when off-screen).
    var targetPoint: CGPoint?
    /// Direction (radians, screen space) towards an off-screen target.
    var arrowAngle: Double?
    /// Faint dots for remaining targets that are on-screen.
    var otherPoints: [CGPoint] = []
    var holdProgress: Double = 0
    var isAligned = false
    var hint = "Hold your phone upright"
    var isCapturingPhoto = false
    var trackingMessage: String?
    /// True when the phone has moved away from where the first photos were taken.
    var driftWarning = false

    // MARK: Internals
    @ObservationIgnored let arView: ARView
    @ObservationIgnored private var plan: CapturePlan?
    @ObservationIgnored private var baseYaw: Double = 0
    @ObservationIgnored private var capturedTargets: Set<Int> = []
    @ObservationIgnored private var activeTarget: CaptureTarget?
    @ObservationIgnored private var lastForward: Vec3?
    @ObservationIgnored private var lastTimestamp: TimeInterval = 0
    @ObservationIgnored private var holdTime: Double = 0
    @ObservationIgnored private var previewAnchors: [UUID: AnchorEntity] = [:]
    @ObservationIgnored private var exposureLocked = false
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored let sessionDirectory: URL
    /// Mean position of the photos taken so far (the panorama's centre).
    @ObservationIgnored private var anchorPosition: Vec3?
    @ObservationIgnored private var baseExposure: (CMTime, Float)?
    @ObservationIgnored private var videoFrameWaiter: (Int, CheckedContinuation<ARFrame?, Never>)?
    @ObservationIgnored private var featurePoints: [UInt64: SIMD3<Float>] = [:]
    @ObservationIgnored private var frameCounter = 0
    @ObservationIgnored private let processingQueue = DispatchQueue(label: "pano.shot-processing", qos: .userInitiated)
    @ObservationIgnored private let processingGroup = DispatchGroup()
    /// Exposure bracketing per target (HDR). Can be turned off for faster capture.
    var hdrBracketing = true

    // Tuning
    private let alignTolerance = 3.5.radians
    private let rollTolerance = 15.0.radians
    private let maxAngularSpeed = 12.0.radians   // per second
    private let holdDuration = 0.45               // seconds
    private let photoMaxLongSide = 2048
    private let driftWarnDistance = 0.08
    private let driftBlockDistance = 0.25
    private let maxFeaturePoints = 40_000

    override init() {
        arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableCameraGrain, .disableGroundingShadows]
        arView.session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            phase = .failed("This device does not support ARKit world tracking.")
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = []
        config.environmentTexturing = .none
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
        }
        // LiDAR depth lets the stitcher undo parallax of nearby objects.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        haptics.prepare()
    }

    func stop() {
        if let (_, cont) = videoFrameWaiter {
            videoFrameWaiter = nil
            cont.resume(returning: nil)
        }
        arView.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func discardFiles() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    private func updateAnchor() {
        anchorPosition = shots.isEmpty ? nil : shots.map(\.position).reduce(Vec3.zero, +) / Double(shots.count)
    }

    func undoLast() {
        guard let last = shots.popLast() else { return }
        updateAnchor()
        if let d = last.depthURL { try? FileManager.default.removeItem(at: d) }
        if let d = last.relativeDepthURL { try? FileManager.default.removeItem(at: d) }
        capturedTargets.remove(last.targetID)
        if let anchor = previewAnchors.removeValue(forKey: last.id) {
            arView.scene.removeAnchor(anchor)
        }
        try? FileManager.default.removeItem(at: last.url)
        if phase == .complete { phase = .capturing }
        if shots.isEmpty { unlockExposure() }
    }

    func restart() {
        for s in shots { try? FileManager.default.removeItem(at: s.url) }
        for a in previewAnchors.values { arView.scene.removeAnchor(a) }
        previewAnchors.removeAll()
        shots.removeAll()
        anchorPosition = nil
        featurePoints.removeAll()
        capturedTargets.removeAll()
        plan = nil
        phase = .starting
        unlockExposure()
        start()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        if let (skip, cont) = videoFrameWaiter {
            if skip <= 0 {
                videoFrameWaiter = nil
                cont.resume(returning: frame)
            } else {
                videoFrameWaiter = (skip - 1, cont)
            }
        }
        accumulateFeaturePoints(frame)
        update(with: frame)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: trackingMessage = nil
        case .notAvailable: trackingMessage = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: trackingMessage = "Starting… move the phone slightly"
            case .excessiveMotion: trackingMessage = "Slow down"
            case .insufficientFeatures: trackingMessage = "Point at something with more detail"
            default: trackingMessage = "Hold on…"
            }
        @unknown default: trackingMessage = nil
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        phase = .failed(error.localizedDescription)
    }

    // MARK: Per-frame guidance

    private func update(with frame: ARFrame) {
        let R = Mat3(frame.camera.transform)
        let forward = R * Vec3(0, 0, -1)
        let dt = lastTimestamp > 0 ? frame.timestamp - lastTimestamp : 0
        let speed = (dt > 0 && lastForward != nil) ? lastForward!.angle(to: forward) / dt : 0
        lastForward = forward
        lastTimestamp = frame.timestamp

        if plan == nil {
            guard case .normal = frame.camera.trackingState else { return }
            let res = frame.camera.imageResolution
            let K = Intrinsics(frame.camera.intrinsics, width: Int(res.width), height: Int(res.height))
            // Phone held in portrait: the sensor's long side is vertical.
            plan = CapturePlan(horizontalFOV: K.verticalFOV, verticalFOV: K.horizontalFOV)
            totalTargets = plan!.targets.count
            baseYaw = Equirect.lonLat(forward).lon
            phase = .capturing
        }
        guard let plan, phase == .capturing else {
            targetPoint = nil; arrowAngle = nil; otherPoints = []
            return
        }

        activeTarget = plan.nextTarget(captured: capturedTargets, currentDirection: forward, baseYaw: baseYaw)
        guard let target = activeTarget else {
            phase = .complete
            targetPoint = nil; arrowAngle = nil; otherPoints = []
            return
        }

        let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y,
                                  frame.camera.transform.columns.3.z)
        let Rt = R.transposed
        func screenPoint(_ dir: Vec3) -> CGPoint? {
            let c = Rt * dir
            if c.z > -0.05 { return nil }
            guard let p = arView.project(camPos + dir.float3 * 2) else { return nil }
            let b = arView.bounds
            return b.insetBy(dx: -30, dy: -30).contains(p) ? p : nil
        }

        let targetDir = target.direction(baseYaw: baseYaw)
        let p = screenPoint(targetDir)
        let inset = arView.bounds.insetBy(dx: 24, dy: 60)
        if let p, inset.contains(p) {
            targetPoint = p
            arrowAngle = nil
        } else {
            targetPoint = nil
            // Portrait: screen right = camera +y, screen down = camera +x.
            let c = Rt * targetDir
            arrowAngle = atan2(c.x, c.y)
        }
        otherPoints = plan.targets
            .filter { $0.id != target.id && !capturedTargets.contains($0.id) }
            .compactMap { screenPoint($0.direction(baseYaw: baseYaw)) }

        // Alignment + roll + steadiness.
        let angleError = forward.angle(to: targetDir)
        let up = Vec3(0, 1, 0)
        let heldUp = R * Vec3(-1, 0, 0)   // top of the phone in portrait
        let heldRight = R * Vec3(0, 1, 0)
        let roll = atan2(up.dot(heldRight), up.dot(heldUp))
        let rollOK = target.isPole || abs(roll) < rollTolerance
        let steady = speed < maxAngularSpeed
        // Parallax guard: the phone should turn around itself, not around the user.
        let position = Vec3(Double(camPos.x), Double(camPos.y), Double(camPos.z))
        let drift = anchorPosition.map { (position - $0).length } ?? 0
        driftWarning = drift > driftWarnDistance
        let positionOK = drift < driftBlockDistance
        isAligned = angleError < alignTolerance && rollOK && positionOK

        if isCapturingPhoto {
            hint = "Hold still…"
        } else if !positionOK {
            hint = "Move the phone back – turn around the phone, not yourself"
        } else if driftWarning && angleError > alignTolerance {
            hint = "Keep the phone in one spot and turn around it"
        } else if trackingMessage != nil {
            hint = trackingMessage!
        } else if angleError < alignTolerance * 2.5 && !rollOK {
            hint = roll > 0 ? "Rotate the phone clockwise" : "Rotate the phone counter-clockwise"
        } else if isAligned && !steady {
            hint = "Hold still"
        } else if isAligned {
            hint = "Hold still…"
        } else {
            hint = shots.isEmpty ? "Point the circle at the dot" : "Move to the next dot"
        }

        if isAligned && steady && !isCapturingPhoto, case .normal = frame.camera.trackingState {
            holdTime += dt
            holdProgress = min(1, holdTime / holdDuration)
            if holdTime >= holdDuration {
                holdTime = 0
                capture(target: target, fallbackFrame: frame)
            }
        } else if !isCapturingPhoto {
            holdTime = max(0, holdTime - dt * 2)
            holdProgress = min(1, holdTime / holdDuration)
        }
    }

    // MARK: Capture

    /// One grabbed camera frame (pixel buffer released as soon as it is converted).
    private struct GrabbedFrame {
        let image: CGImage
        let intrinsics: Intrinsics
        let pose: simd_float4x4
        let exposure: Double
        let depth: ARDepthData?
    }

    /// Captures the burst for one target: two full-resolution frames at the locked exposure
    /// (the sharper one becomes the reference, the other averages out noise) plus a −2 EV
    /// video frame that keeps lamps and windows from blowing out. Files are merged and
    /// written on a background queue so the user can move on immediately.
    private func capture(target: CaptureTarget, fallbackFrame: ARFrame) {
        isCapturingPhoto = true
        lockExposureIfNeeded()
        Task { @MainActor in
            var frames: [GrabbedFrame] = []
            for _ in 0..<2 {
                if let f = await self.grabHighResolution() { frames.append(f) }
            }
            if frames.isEmpty, let f = self.convert(fallbackFrame, exposure: 1) { frames.append(f) }
            if self.hdrBracketing, !frames.isEmpty, await self.setExposure(ev: -2) {
                if let dark = await self.grabVideoFrame(skip: 2, exposure: 0.25) { frames.append(dark) }
                _ = await self.setExposure(ev: 0)
            }
            guard let first = frames.first else {
                self.isCapturingPhoto = false
                return
            }
            self.finishCapture(target: target, frames: frames, preview: first)
        }
    }

    private func grabHighResolution() async -> GrabbedFrame? {
        await withCheckedContinuation { cont in
            arView.session.captureHighResolutionFrame { [weak self] frame, _ in
                guard let self, let frame else { cont.resume(returning: nil); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: self.convert(frame, exposure: 1))
                }
            }
        }
    }

    /// Waits for a later video frame (after an exposure change has taken effect).
    private func grabVideoFrame(skip: Int, exposure: Double) async -> GrabbedFrame? {
        let frame: ARFrame? = await withCheckedContinuation { cont in
            videoFrameWaiter = (skip, cont)
        }
        guard let frame else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: self.convert(frame, exposure: exposure))
            }
        }
    }

    private func convert(_ frame: ARFrame, exposure: Double) -> GrabbedFrame? {
        let buffer = frame.capturedImage
        guard let image = ImageSupport.cgImage(from: buffer, maxLongSide: photoMaxLongSide) else { return nil }
        let res = frame.camera.imageResolution
        var K = Intrinsics(frame.camera.intrinsics, width: Int(res.width), height: Int(res.height))
        let bufW = CVPixelBufferGetWidth(buffer), bufH = CVPixelBufferGetHeight(buffer)
        if K.width != bufW || K.height != bufH { K = K.scaled(toWidth: bufW, height: bufH) }
        K = K.scaled(toWidth: image.width, height: image.height)
        return GrabbedFrame(image: image, intrinsics: K, pose: frame.camera.transform, exposure: exposure,
                            depth: frame.smoothedSceneDepth ?? frame.sceneDepth)
    }

    private func finishCapture(target: CaptureTarget, frames: [GrabbedFrame], preview first: GrabbedFrame) {
        isCapturingPhoto = false
        holdProgress = 0
        guard phase == .capturing else { return }
        let id = UUID()
        let url = sessionDirectory.appendingPathComponent("\(id.uuidString).jpg")
        let depthURL = first.depth != nil ? sessionDirectory.appendingPathComponent("\(id.uuidString).depth") : nil
        let relURL = DepthEstimator.shared.isAvailable ? sessionDirectory.appendingPathComponent("\(id.uuidString).rel") : nil
        let pose = first.pose
        let pos = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        let shot = CapturedShot(id: id, targetID: target.id, url: url, intrinsics: first.intrinsics,
                                rotation: Mat3(pose), position: Vec3(pos), depthURL: depthURL,
                                relativeDepthURL: relURL)
        shots.append(shot)
        capturedTargets.insert(target.id)
        updateAnchor()
        haptics.impactOccurred()

        // Merge + save in the background (serially, to bound memory).
        processingGroup.enter()
        processingQueue.async { [processingGroup] in
            defer { processingGroup.leave() }
            let merged = Self.merge(frames)
            ImageSupport.writeJPEG(merged, to: url, quality: 0.93)
            if let depthURL, let d = first.depth { _ = DepthIO.write(d, to: depthURL) }
            if let relURL { DepthEstimator.shared.estimate(merged, saveTo: relURL) }
        }

        let preview = ImageSupport.downscaled(first.image, maxLongSide: 512) ?? first.image
        let radius = Float(1.6) - Float(shots.count) * 0.006
        Task { @MainActor in
            if let anchor = await ShotPreviewMesh.makeAnchor(shot: shot, preview: preview,
                                                             cameraPosition: pos, radius: radius) {
                // The shot may have been undone while the texture loaded.
                guard self.shots.contains(where: { $0.id == shot.id }) else { return }
                self.arView.scene.addAnchor(anchor)
                self.previewAnchors[shot.id] = anchor
            }
        }
    }

    /// Exposure-fuses the burst onto the first frame's geometry.
    private static func merge(_ frames: [GrabbedFrame]) -> CGImage {
        guard frames.count > 1 else { return frames[0].image }
        let burst = frames.map {
            BurstFrame(image: ImageSupport.floatImage(from: $0.image), intrinsics: $0.intrinsics,
                       rotation: Mat3($0.pose), exposure: $0.exposure)
        }
        let (fused, _) = ShotMerger.merge(burst, reference: 0)
        return ImageSupport.cgImage(from: fused) ?? frames[0].image
    }

    /// Resolves once every captured shot has been merged and written to disk.
    func waitForProcessing() async {
        await withCheckedContinuation { cont in
            processingGroup.notify(queue: .main) { cont.resume() }
        }
    }

    /// ARKit's tracked 3D feature points, accumulated over the session (world coordinates).
    var scenePoints: [Vec3] {
        featurePoints.values.map { Vec3(Double($0.x), Double($0.y), Double($0.z)) }
    }

    private func accumulateFeaturePoints(_ frame: ARFrame) {
        frameCounter += 1
        guard frameCounter % 6 == 0, let cloud = frame.rawFeaturePoints else { return }
        for (id, p) in zip(cloud.identifiers, cloud.points) {
            if featurePoints[id] != nil || featurePoints.count < maxFeaturePoints {
                featurePoints[id] = p
            }
        }
    }

    // MARK: Exposure

    /// Locks exposure and white balance before the first photo so all photos match. Focus
    /// stays automatic: near walls and tables must stay sharp.
    private func lockExposureIfNeeded() {
        guard !exposureLocked, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            baseExposure = (device.exposureDuration, device.iso)
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            device.unlockForConfiguration()
            exposureLocked = true
        } catch {}
    }

    /// Sets a custom exposure `ev` stops relative to the locked base exposure.
    private func setExposure(ev: Double) async -> Bool {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              let base = baseExposure, device.isExposureModeSupported(.custom) else { return false }
        let format = device.activeFormat
        let minD = CMTimeGetSeconds(format.minExposureDuration)
        let maxD = min(CMTimeGetSeconds(format.maxExposureDuration), 1.0 / 15)
        let target = CMTimeGetSeconds(base.0) * Double(base.1) * pow(2, ev) // duration × ISO
        var duration = max(minD, min(maxD, CMTimeGetSeconds(base.0) * pow(2, ev)))
        var iso = Float(target / duration)
        iso = max(format.minISO, min(format.maxISO, iso))
        duration = max(minD, min(maxD, target / Double(iso)))
        do { try device.lockForConfiguration() } catch { return false }
        return await withCheckedContinuation { cont in
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000), iso: iso) { _ in
                cont.resume(returning: true)
            }
            device.unlockForConfiguration()
        }
    }

    private func unlockExposure() {
        guard exposureLocked, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            device.unlockForConfiguration()
            exposureLocked = false
            baseExposure = nil
        } catch {}
    }
}
