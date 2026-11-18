import SwiftUI

@main
struct PanoramaApp: App {
    @State private var library = PanoramaLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}
