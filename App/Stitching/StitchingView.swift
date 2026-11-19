import PanoramaCore
import SwiftUI

struct StitchingView: View {
    let job: StitchJob
    @Environment(\.dismiss) private var dismiss

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
                Image(systemName: "globe.europe.africa.fill")
                    .font(.system(size: 54))
                    .symbolEffect(.pulse)
            }
            .frame(width: 150, height: 150)
            VStack(spacing: 6) {
                Text("Creating your panorama").font(.title3.bold())
                Text(job.stage.title).foregroundStyle(.secondary)
                Text("\(job.shots.count) photos").font(.footnote).foregroundStyle(.tertiary)
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
