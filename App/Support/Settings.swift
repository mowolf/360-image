import SwiftUI

enum Settings {
    static let autoSaveToPhotos = "autoSaveToPhotos"
    static let hdrBracketing = "hdrBracketing"
    static let onboardingSeen = "onboardingSeen"
    static let keepCaptureData = "keepCaptureData"
}

struct SettingsView: View {
    @AppStorage(Settings.autoSaveToPhotos) private var autoSave = false
    @AppStorage(Settings.hdrBracketing) private var hdr = true
    @AppStorage(Settings.onboardingSeen) private var onboardingSeen = true
    @AppStorage(Settings.keepCaptureData) private var keepCaptures = false
    @State private var storedBytes: Int64 = CaptureStore.totalSize()
    @State private var confirmDelete = false
    @Environment(PanoramaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Save to Photos automatically", isOn: $autoSave)
                        .tint(.green)
                } footer: {
                    Text("New panoramas are added to the \u{201C}\(PhotoSaver.albumName)\u{201D} album with their 360° metadata.")
                }
                Section {
                    Toggle("HDR capture", isOn: $hdr)
                        .tint(.green)
                } footer: {
                    Text("Takes an extra darker frame at every dot so bright lamps and windows keep their detail. Turn off for slightly faster capture.")
                }
                Section {
                    Toggle("Keep capture data", isOn: $keepCaptures)
                        .tint(.green)
                    if storedBytes > 0 {
                        Button("Delete stored capture data (\(ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)))",
                               role: .destructive) {
                            confirmDelete = true
                        }
                        .confirmationDialog("Delete stored capture data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete capture data", role: .destructive) {
                                CaptureStore.deleteAll()
                                library.reload()
                                storedBytes = CaptureStore.totalSize()
                            }
                        } message: {
                            Text("Your panoramas are kept, but they can no longer be re-stitched or exported.")
                        }
                    }
                } footer: {
                    Text("Keeps the original photos of new panoramas (about 50 MB each) so they can be re-stitched or exported later.")
                }
                Section {
                    Button("Show introduction again") {
                        onboardingSeen = false
                        dismiss()
                    }
                }
                Section {
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
