import SwiftUI

/// First-launch explanation of the capture flow.
struct OnboardingCard: View {
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Capture a 360° photo")
                    .font(.title2.bold())
                Text("Pano 360 guides you around the whole sphere and stitches everything on your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            step("scope", "Aim the circle at the dot",
                 "Hold still for a moment – the photo is taken automatically.")
            step("circle.dotted", "Follow the dots",
                 "Each new dot overlaps what you already have. Tap Done whenever you like.")
            step("arrow.triangle.2.circlepath", "Turn around the phone",
                 "Keep the phone in one spot and rotate it, not yourself. The app shows you if you drift.")
            step("globe", "Share in 360°",
                 "Panoramas keep their 360° metadata for Google Photos, Facebook and other viewers.")
            Button(action: onDone) {
                Text("Get started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .padding(.horizontal, 20)
        .environment(\.colorScheme, .dark)
    }

    private func step(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
