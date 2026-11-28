import SwiftUI

/// The app opens straight into the camera. Finishing a capture starts stitching; the
/// result opens in the 360° viewer. The gallery is reachable from the camera screen.
struct RootView: View {
    @Environment(PanoramaLibrary.self) private var library
    @Environment(Store.self) private var store
    @State private var job: StitchJob?
    @State private var showGallery = false
    @State private var captureID = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        captureScreen
    }

    /// A capture whose stitching was interrupted (app stopped by iOS) is finished first.
    private func resumePendingCapture() {
        guard job == nil, let folder = CaptureStore.pendingFolders().first,
              let capture = CaptureStore.load(folder: folder) else { return }
        let job = StitchJob(capture: capture, library: library, existingCaptureFolder: folder, origin: .resume)
        job.onNewPanorama = { store.recordPanoramaCreated() }
        self.job = job
    }

    private var captureScreen: some View {
        CaptureView(
            onFinish: { result in
                let job = StitchJob(capture: result, library: library)
                job.onNewPanorama = { store.recordPanoramaCreated() }
                self.job = job
            },
            onOpenGallery: { showGallery = true },
            suspended: job != nil
        )
        .id(captureID)
        .fullScreenCover(item: $job, onDismiss: { captureID = UUID() }) { job in
            StitchingView(job: job)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
        .task { resumePendingCapture() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            if let job { job.resumeIfInterrupted() } else { resumePendingCapture() }
        }
    }
}
