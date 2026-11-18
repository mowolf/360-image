import SwiftUI

struct PanoramaDetailView: View {
    let item: PanoramaItem
    var isFreshCapture: Bool

    @Environment(\.dismiss) private var dismiss
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
        .alert("Could not save", isPresented: Binding(
            get: { if case .failed = saveState { return true } else { return false } },
            set: { if !$0 { saveState = .idle } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let msg) = saveState { Text(msg) }
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
