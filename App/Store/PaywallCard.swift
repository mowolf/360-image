import SwiftUI

/// Shown on the camera screen once the free panoramas are used up.
struct PaywallCard: View {
    /// true: shown as the content of a sheet (no own card background).
    var inSheet = false
    @Environment(Store.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Unlock unlimited panoramas")
                    .font(.title2.bold())
                Text(store.freeRemaining > 0
                     ? "You have \(store.freeRemaining) of \(Store.freeLimit) free panoramas left. Unlock Pano 360 to capture as many as you like."
                     : "You've created your \(Store.freeLimit) free panoramas. Unlock Pano 360 to capture as many as you like.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            feature("infinity", "Unlimited 360° panoramas")
            feature("sparkles", "All features: HDR, depth correction, smart seams")
            feature("creditcard", "One-time purchase – no subscription")
            Button {
                Task { await store.purchase() }
            } label: {
                Group {
                    if store.isPurchasing { ProgressView().tint(.black) }
                    else { Text("Unlock for \(store.displayPrice)") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.black)
            }
            .disabled(store.isPurchasing)
            Button("Restore purchase") {
                Task { await store.restore() }
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            if let message = store.message {
                Text(message).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            Text("Your panoramas in the gallery stay available.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background {
            if !inSheet { RoundedRectangle(cornerRadius: 28).fill(.regularMaterial) }
        }
        .padding(.horizontal, inSheet ? 0 : 20)
        .environment(\.colorScheme, .dark)
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.headline).frame(width: 26).foregroundStyle(.orange)
            Text(text).font(.subheadline)
        }
    }
}
