import SwiftUI

struct GalleryView: View {
    @Environment(PanoramaLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if library.items.isEmpty {
                    ContentUnavailableView("No panoramas yet",
                                           systemImage: "globe",
                                           description: Text("Capture your first 360° panorama with the camera."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(library.items) { item in
                                NavigationLink(value: item) {
                                    GalleryCell(item: item)
                                }
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete(item) }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Panoramas")
            .navigationDestination(for: PanoramaItem.self) { item in
                PanoramaDetailView(item: item, isFreshCapture: false)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { library.reload() }
        }
    }
}

private struct GalleryCell: View {
    let item: PanoramaItem
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.gray.opacity(0.2))
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .aspectRatio(2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.date, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            image = await Task.detached { UIImage(contentsOfFile: item.thumbnailURL.path) }.value
        }
    }
}
