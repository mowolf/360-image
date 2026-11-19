import SwiftUI

struct PanoramaDetailView: View {
    let item: PanoramaItem
    var isFreshCapture: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(PanoramaLibrary.self) private var library
    @State private var restitchJob: StitchJob?
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var useMotion = false
    @State private var saveState: SaveState = .idle

    enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    var body: some View {
        ZStack(alignment: .top) {
            PanoramaViewer(url: item.url, useMotion: useMotion)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                if isFreshCapture {
                    Button { dismiss() } label: {
                        Label("New", systemImage: "camera.fill")
                            .font(.headline)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                Spacer()
                Button { useMotion.toggle() } label: {
                    Image(systemName: useMotion ? "gyroscope" : "hand.draw")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel(useMotion ? "Use touch to look around" : "Use motion to look around")
                if let folder = library.captureFolder(for: item) {
                    Menu {
                        Button("Re-stitch with this version", systemImage: "arrow.triangle.2.circlepath") {
                            if let capture = CaptureStore.load(folder: folder) {
                                restitchJob = StitchJob(capture: capture, library: library, existingCaptureFolder: folder)
                            }
                        }
                        Button("Export capture data", systemImage: "doc.zipper") { export(folder) }
                    } label: {
                        Group {
                            if exporting { ProgressView() } else { Image(systemName: "ellipsis") }
                        }
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                    }
                }
                ShareLink(item: item.url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                Button(action: saveToPhotos) {
                    Group {
                        switch saveState {
                        case .saving: ProgressView()
                        case .saved: Image(systemName: "checkmark")
                        default: Image(systemName: "photo.badge.plus")
                        }
                    }
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                }
                .disabled(saveState == .saving || saveState == .saved)
                .accessibilityLabel("Save to Photos")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color.black)
        .toolbarBackground(.hidden, for: .navigationBar)
        .fullScreenCover(item: $restitchJob) { job in
            StitchingView(job: job)
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Could not save", isPresented: Binding(
            get: { if case .failed = saveState { return true } else { return false } },
            set: { if !$0 { saveState = .idle } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let msg) = saveState { Text(msg) }
        }
    }

    private func export(_ folder: String) {
        exporting = true
        Task.detached {
            let url = try? CaptureStore.exportZip(folder: folder)
            await MainActor.run {
                exporting = false
                if let url { exportFile = ExportFile(url: url) }
            }
        }
    }

    private func saveToPhotos() {
        saveState = .saving
        Task {
            do {
                try await PanoramaLibrary.saveToPhotos(item)
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
