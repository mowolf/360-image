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
    @Environment(PanoramaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Save to Photos automatically", isOn: $autoSave)
                } footer: {
                    Text("New panoramas are added to the \u{201C}\(PhotoSaver.albumName)\u{201D} album with their 360° metadata.")
                }
                Section {
                    Toggle("HDR capture", isOn: $hdr)
                } footer: {
                    Text("Takes an extra darker frame at every dot so bright lamps and windows keep their detail. Turn off for slightly faster capture.")
                }
                Section {
                    Toggle("Keep capture data", isOn: $keepCaptures)
                    if storedBytes > 0 {
                        Button("Delete stored capture data (\(ByteCountFormatter.string(fromByteCount: storedBytes, countStyle: .file)))",
                               role: .destructive) {
                            CaptureStore.deleteAll()
                            library.reload()
                            storedBytes = CaptureStore.totalSize()
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
