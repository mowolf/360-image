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

    // Tuning
    private let alignTolerance = 3.5.radians
    private let rollTolerance = 15.0.radians
    private let maxAngularSpeed = 12.0.radians   // per second
    private let holdDuration = 0.45               // seconds
    private let photoMaxLongSide = 2048

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
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        UIApplication.shared.isIdleTimerDisabled = true
        haptics.prepare()
    }

    func stop() {
        arView.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func discardFiles() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }

    func undoLast() {
        guard let last = shots.popLast() else { return }
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
        capturedTargets.removeAll()
        plan = nil
        phase = .starting
        unlockExposure()
        start()
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
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
            guard let p = arView.project(camPos + dir.simd * 2) else { return nil }
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
        isAligned = angleError < alignTolerance && rollOK

        if isCapturingPhoto {
            hint = "Hold still…"
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

    private func capture(target: CaptureTarget, fallbackFrame: ARFrame) {
        isCapturingPhoto = true
        let fallbackPose = fallbackFrame.camera.transform
        let fallbackK = fallbackFrame.camera.intrinsics
        let fallbackRes = fallbackFrame.camera.imageResolution
        let fallbackBuffer = fallbackFrame.capturedImage
        arView.session.captureHighResolutionFrame { [weak self] hiRes, _ in
            guard let self else { return }
            let pose = hiRes?.camera.transform ?? fallbackPose
            let k = hiRes?.camera.intrinsics ?? fallbackK
            let res = hiRes?.camera.imageResolution ?? fallbackRes
            let buffer = hiRes?.capturedImage ?? fallbackBuffer
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.process(buffer: buffer, intrinsics: k, resolution: res, pose: pose, target: target)
                DispatchQueue.main.async { self.finishCapture(result) }
            }
        }
    }

    private struct ProcessedShot {
        let shot: CapturedShot
        let preview: CGImage
        let position: SIMD3<Float>
    }

    private func process(buffer: CVPixelBuffer, intrinsics k: simd_float3x3, resolution: CGSize,
                         pose: simd_float4x4, target: CaptureTarget) -> ProcessedShot? {
        guard let image = ImageSupport.cgImage(from: buffer, maxLongSide: photoMaxLongSide) else { return nil }
        let bufW = CVPixelBufferGetWidth(buffer), bufH = CVPixelBufferGetHeight(buffer)
        // ARKit intrinsics refer to camera.imageResolution; rescale to the pixel buffer, then to the saved image.
        var K = Intrinsics(k, width: Int(resolution.width), height: Int(resolution.height))
        if K.width != bufW || K.height != bufH { K = K.scaled(toWidth: bufW, height: bufH) }
        K = K.scaled(toWidth: image.width, height: image.height)
        let id = UUID()
        let url = sessionDirectory.appendingPathComponent("\(id.uuidString).jpg")
        guard ImageSupport.writeJPEG(image, to: url, quality: 0.93) else { return nil }
        let preview = ImageSupport.downscaled(image, maxLongSide: 512) ?? image
        let shot = CapturedShot(id: id, targetID: target.id, url: url, intrinsics: K, rotation: Mat3(pose))
        let pos = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        return ProcessedShot(shot: shot, preview: preview, position: pos)
    }

    private func finishCapture(_ result: ProcessedShot?) {
        isCapturingPhoto = false
        holdProgress = 0
        guard let result, phase == .capturing else { return }
        shots.append(result.shot)
        capturedTargets.insert(result.shot.targetID)
        haptics.impactOccurred()
        lockExposureIfNeeded()
        let radius = Float(1.6) - Float(shots.count) * 0.006
        Task { @MainActor in
            if let anchor = await ShotPreviewMesh.makeAnchor(shot: result.shot, preview: result.preview,
                                                             cameraPosition: result.position, radius: radius) {
                // The shot may have been undone while the texture loaded.
                guard self.shots.contains(where: { $0.id == result.shot.id }) else { return }
                self.arView.scene.addAnchor(anchor)
                self.previewAnchors[result.shot.id] = anchor
            }
        }
    }

    // MARK: Exposure

    /// Locks exposure, white balance and focus after the first photo so all photos match.
    private func lockExposureIfNeeded() {
        guard !exposureLocked, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            device.unlockForConfiguration()
            exposureLocked = true
        } catch {}
    }

    private func unlockExposure() {
        guard exposureLocked, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
            exposureLocked = false
        } catch {}
    }
}
