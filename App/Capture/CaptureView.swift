import AVFoundation
import PanoramaCore
import RealityKit
import SwiftUI

/// Everything the stitcher needs from a capture session.
struct CaptureResult {
    let shots: [CapturedShot]
    let sessionDirectory: URL
    /// ARKit feature points (world coordinates) for metric depth.
    let scenePoints: [Vec3]
    /// Resolves when all shots are merged and written to disk.
    let waitForProcessing: () async -> Void
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Camera screen: live AR camera, captured photos pinned in place, a fixed aiming
/// circle in the middle and the target dot to move it onto.
struct CaptureView: View {
    var onFinish: (CaptureResult) -> Void
    var onOpenGallery: () -> Void

    @State private var session = CaptureSession()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Settings.onboardingSeen) private var onboardingSeen = false
    @State private var cameraDenied = false
    @State private var confirmRestart = false
    @State private var handedOff = false

    var body: some View {
        ZStack {
            ARViewContainer(arView: session.arView)
                .ignoresSafeArea()

            GeometryReader { geo in
                overlay(size: geo.size)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if !onboardingSeen {
                Color.black.opacity(0.45).ignoresSafeArea()
                OnboardingCard { withAnimation { onboardingSeen = true } }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }

            if cameraDenied {
                permissionView
            } else if case .failed(let message) = session.phase {
                errorView(message)
            }
        }
        .background(Color.black)
        .task {
            await requestCameraAndStart()
        }
        .onDisappear {
            session.stop()
            if !handedOff { session.discardFiles() }
        }
        .onAppear { session.guidancePaused = !onboardingSeen }
        .onChange(of: onboardingSeen) { _, seen in session.guidancePaused = !seen }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                ScreenKeeper.reassert()
                if !cameraDenied && !handedOff { ScreenKeeper.pinBrightness() }
            default:
                ScreenKeeper.unpinBrightness()
            }
        }
        .onChange(of: session.phase) { _, phase in
            if phase == .complete { finish() }
        }
        .confirmationDialog("Start over?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Discard \(session.shots.count) photos", role: .destructive) { session.restart() }
        }
    }

    // MARK: Overlay

    @ViewBuilder
    private func overlay(size: CGSize) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        ZStack {
            ForEach(Array(session.otherPoints.enumerated()), id: \.offset) { _, p in
                Circle()
                    .fill(.white.opacity(0.35))
                    .frame(width: 10, height: 10)
                    .position(p)
            }

            if let p = session.targetPoint {
                TargetDot(aligned: session.isAligned)
                    .position(p)
            }

            if let angle = session.arrowAngle {
                let radius = min(size.width, size.height) / 2 - 56
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.orange)
                    .shadow(radius: 4)
                    .rotationEffect(.radians(angle))
                    .position(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }

            AimingReticle(progress: session.holdProgress, aligned: session.isAligned,
                          capturing: session.isCapturingPhoto)
                .position(center)

            if let d = session.driftOffset {
                DriftIndicator(offset: d)
                    .position(x: center.x, y: center.y + 110)
            }
        }
        .animation(.easeOut(duration: 0.12), value: session.isAligned)
    }

    // MARK: Bars

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                if !session.shots.isEmpty {
                    Button { confirmRestart = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Start over")
                }
            }
            Text(session.hint)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .contentTransition(.opacity)
                .animation(.default, value: session.hint)
        }
        .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button(action: onOpenGallery) {
                Image(systemName: "square.grid.2x2")
                    .font(.title3.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Gallery")

            Spacer()

            Button(action: finish) {
                let done = session.shots.count, total = max(session.totalTargets, 1)
                HStack(spacing: 10) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.3), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: CGFloat(done) / CGFloat(total))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                    Text(session.totalTargets > 0 ? "\(done)/\(session.totalTargets)" : "0")
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                    if done >= 2 {
                        Image(systemName: "checkmark").font(.subheadline.weight(.bold))
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(done >= 2 ? Color.orange : Color.gray.opacity(0.4), in: Capsule())
                .animation(.default, value: done)
            }
            .disabled(session.shots.count < 2)
            .accessibilityLabel("Finish panorama, \(session.shots.count) of \(session.totalTargets) photos")

            Spacer()

            Button { session.undoLast() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3.weight(.semibold))
                    .frame(width: 54, height: 54)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .disabled(session.shots.isEmpty)
            .opacity(session.shots.isEmpty ? 0.4 : 1)
            .accessibilityLabel("Undo last photo")
        }
        .foregroundStyle(.white)
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.largeTitle)
            Text("Camera access is needed to capture panoramas.")
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
            Text(message).multilineTextAlignment(.center)
            Button("Try again") { session.restart() }.buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .padding()
    }

    // MARK: Actions

    private func requestCameraAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .video)) { cameraDenied = true; return }
        default:
            cameraDenied = true; return
        }
        session.start()
    }

    private func finish() {
        guard session.shots.count >= 2, !handedOff else { return }
        handedOff = true
        session.stop()
        let session = self.session
        onFinish(CaptureResult(shots: session.shots, sessionDirectory: session.sessionDirectory,
                               scenePoints: session.scenePoints,
                               waitForProcessing: { await session.waitForProcessing() }))
    }
}

/// The dot the user aims at.
struct TargetDot: View {
    var aligned: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.orange.opacity(0.6), lineWidth: 2)
                .frame(width: 58, height: 58)
                .scaleEffect(pulse ? 1.25 : 0.9)
                .opacity(pulse ? 0 : 1)
            Circle()
                .fill(aligned ? Color.white : Color.orange)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.4), radius: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// Fixed circle in the middle of the screen; fills while the phone is held on target.
struct AimingReticle: View {
    var progress: Double
    var aligned: Bool
    var capturing: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 3)
                .frame(width: 78, height: 78)
                .shadow(color: .black.opacity(0.5), radius: 3)
            Circle()
                .trim(from: 0, to: capturing ? 1 : progress)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 78, height: 78)
            if capturing {
                Circle().fill(.white.opacity(0.85)).frame(width: 24, height: 24)
            }
        }
        .scaleEffect(aligned ? 1.08 : 1)
    }
}

/// Bird's-eye guide back to the phone's spot: the ring is the spot, the dot is the phone
/// (seen from above: left/right and closer/further), with the distance below.
struct DriftIndicator: View {
    var offset: SIMD3<Double>

    var body: some View {
        let scale = 120.0 // points per metre
        let x = max(-26, min(26, offset.x * scale))
        let y = max(-26, min(26, offset.z * scale)) // away from the user = up on screen
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.black.opacity(0.35)).frame(width: 64, height: 64)
                Circle().stroke(.white.opacity(0.9), lineWidth: 2).frame(width: 18, height: 18)
                Path { p in
                    p.move(to: CGPoint(x: 32 + x, y: 32 - y))
                    p.addLine(to: CGPoint(x: 32, y: 32))
                }
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: 64, height: 64)
                Circle().fill(Color.orange).frame(width: 12, height: 12).offset(x: x, y: -y)
            }
            Text("\(Int((offset.x * offset.x + offset.y * offset.y + offset.z * offset.z).squareRoot() * 100)) cm from spot")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .foregroundStyle(.white)
    }
}
