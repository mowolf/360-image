import PanoramaCore
import SwiftUI

struct StitchingView: View {
    let job: StitchJob
    @Environment(\.dismiss) private var dismiss
    @State private var spin = false

    var body: some View {
        Group {
            if let item = job.result {
                PanoramaDetailView(item: item, isFreshCapture: true)
            } else if let error = job.errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 44))
                    Text("Stitching failed").font(.title2.bold())
                    Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Back to camera") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                progressView
            }
        }
        .onAppear {
            // Stay awake while stitching (it can take a while for large captures).
            ScreenKeeper.hold()
            job.start()
        }
        .onDisappear { ScreenKeeper.release() }
    }

    private var progressView: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: overallProgress)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: overallProgress)
                Image(systemName: "camera.aperture")
                    .font(.system(size: 58, weight: .light))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 6).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            }
            .frame(width: 150, height: 150)
            VStack(spacing: 6) {
                Text("Creating your panorama").font(.title3.bold())
                Text(job.stage.title).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: job.stage)
                LoadingQuip(stage: job.stage)
                    .padding(.top, 6)
                Text("\(job.shots.count) photos").font(.footnote).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                job.cancel()
                dismiss()
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
    }

    /// Maps stage-local progress to one overall bar.
    private var overallProgress: Double {
        let p = job.progress
        switch job.stage {
        case .preparing: return 0.10 * p
        case .aligning: return 0.10 + 0.35 * p
        case .optimizing: return 0.45 + 0.05 * p
        case .depth: return 0.40 + 0.05 * p
        case .refining: return 0.45 + 0.05 * p
        case .exposure: return 0.50 + 0.03 * p
        case .seams: return 0.53 + 0.07 * p
        case .blending: return 0.60 + 0.35 * p
        case .finishing: return 0.95 + 0.05 * p
        }
    }
}

/// Sims-style rotating status lines: what the stitcher is really doing, with the odd
/// silly one mixed in.
struct LoadingQuip: View {
    let stage: StitchStage
    @State private var index = 0
    private let timer = Timer.publish(every: 2.2, on: .main, in: .common).autoconnect()

    var body: some View {
        let lines = Self.lines(for: stage)
        Text(lines[index % lines.count] + "…")
            .font(.callout.italic())
            .foregroundStyle(.white.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .id("\(stage.rawValue)-\(index)")
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .animation(.easeInOut(duration: 0.35), value: index)
            .frame(height: 44)
            .clipped()
            .onReceive(timer) { _ in index += 1 }
            .onChange(of: stage) { _, _ in index = 0 }
    }

    static func lines(for stage: StitchStage) -> [String] {
        switch stage {
        case .preparing:
            return ["Unpacking photons", "Developing photos", "Merging exposures",
                    "Denoising shadows", "Rescuing highlights", "Polishing pixels"]
        case .aligning:
            return ["Matching features", "Finding corners", "Comparing overlaps",
                    "Counting ceiling tiles", "Lining up the horizon", "Asking neighbours for directions"]
        case .optimizing:
            return ["Adjusting bundles", "Minimizing reprojection error", "Untangling rotations",
                    "Negotiating with gravity", "Reticulating spheres"]
        case .depth:
            return ["Estimating depth", "Triangulating corners", "Measuring the room",
                    "Teaching pixels about distance", "Correcting parallax", "Consulting the neural engine"]
        case .refining:
            return ["Refining alignment", "Second-guessing the first guess", "Nudging photos by a pixel",
                    "Double-checking the seams"]
        case .exposure:
            return ["Balancing exposure", "Removing vignetting", "Evening out the sky",
                    "Matching white balance", "Dimming the lamps a little"]
        case .seams:
            return ["Finding seams", "Cutting around people", "Avoiding the chairs",
                    "Solving max-flow", "Hiding the stitches"]
        case .blending:
            return ["Blending bands", "Merging images", "Smoothing transitions",
                    "Building pyramids", "Feathering edges", "Wrapping the world"]
        case .finishing:
            return ["Writing 360° metadata", "Tagging the location", "Rolling up the sphere",
                    "Almost there"]
        }
    }
}
