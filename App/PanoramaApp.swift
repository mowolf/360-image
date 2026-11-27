import SwiftUI

@main
struct PanoramaApp: App {
    @State private var library = PanoramaLibrary()

    init() {
        // Continued-processing tasks must be registered before launch completes.
        BackgroundStitching.register()
        // No capture session exists yet at launch, so anything left in tmp is from an
        // interrupted session (crash / force quit) or an old export.
        CaptureStore.cleanUpTemporaryFiles()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}
