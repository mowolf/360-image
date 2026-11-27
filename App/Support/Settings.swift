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
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isUnlimited {
                        Label("Pano 360 Unlimited is unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        LabeledContent("Free panoramas left", value: "\(store.freeRemaining) of \(Store.freeLimit)")
                        Button {
                            Task { await store.purchase() }
                        } label: {
                            HStack {
                                Text("Unlock unlimited panoramas")
                                Spacer()
                                if store.isPurchasing { ProgressView() } else { Text(store.displayPrice).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(store.isPurchasing)
                    }
                    Button("Restore purchases") { Task { await store.restore() } }
                } header: {
                    Text("Pano 360 Unlimited")
                } footer: {
                    if let message = store.message { Text(message) }
                    else if !store.isUnlimited { Text("One-time purchase, no subscription. The first \(Store.freeLimit) panoramas are free.") }
                }
                Section {
                    Toggle("Save to Photos automatically", isOn: $autoSave)
                        .tint(.green)
                } footer: {
                    Text("New panoramas are added to the \u{201C}\(PhotoSaver.albumName)\u{201D} album with their 360° metadata. To create the album, iOS asks for access to your photo library – Pano 360 never reads or uploads your other photos. Without it, panoramas are still saved to Recents.")
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
