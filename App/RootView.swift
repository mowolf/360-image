import SwiftUI

/// The app opens straight into the camera. Finishing a capture starts stitching; the
/// result opens in the 360° viewer. The gallery is reachable from the camera screen.
struct RootView: View {
    @Environment(PanoramaLibrary.self) private var library
    @State private var job: StitchJob?
    @State private var showGallery = false
    @State private var captureID = UUID()

    var body: some View {
        CaptureView(
            onFinish: { result in
                job = StitchJob(capture: result, library: library)
            },
            onOpenGallery: { showGallery = true }
        )
        .id(captureID)
        .fullScreenCover(item: $job, onDismiss: { captureID = UUID() }) { job in
            StitchingView(job: job)
        }
        .sheet(isPresented: $showGallery) {
            GalleryView()
        }
    }
}
