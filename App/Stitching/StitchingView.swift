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
                Text(job.origin == .resume ? "Finishing your panorama" : "Creating your panorama").font(.title3.bold())
                Text(job.stage.title).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: job.stage)
                Text("\(job.shots.count) photos").font(.footnote).foregroundStyle(.tertiary)
                Text(job.wasPaused
                     ? "Your panorama was paused while Pano 360 was in the background – it continues now. Keep the app open to finish it."
                     : "Keep Pano 360 open until your panorama is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 10)
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

    private var overallProgress: Double { job.overallProgress }
}
