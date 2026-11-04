import SwiftUI

/// First-launch welcome, in the style of Apple's "What's New" screens.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 60, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("Welcome to Mirror")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 48)

                VStack(alignment: .leading, spacing: 26) {
                    Feature(symbol: "ipad.and.iphone", tint: .blue,
                            title: "See one screen on the other",
                            text: "Show your iPhone on your iPad, or your iPad on your iPhone. Smooth, sharp and in real time.")
                    Feature(symbol: "speaker.wave.2.fill", tint: .pink,
                            title: "With sound",
                            text: "Hear videos, games and music from the shared screen.")
                    Feature(symbol: "arrow.down.doc.fill", tint: .orange,
                            title: "Drag and drop",
                            text: "Drop photos and files onto the mirror to send them across.")
                    Feature(symbol: "lock.fill", tint: .green,
                            title: "Private by design",
                            text: "Devices connect directly and every stream is encrypted with your pairing code.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Name this \(DeviceKind.current.displayName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(DeviceKind.current == .iPad ? "My iPad" : "My iPhone", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .padding(14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { model.rename(to: trimmed) }
                model.finishOnboarding()
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: 420)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .onAppear {
            if SharedStore.shared.hasCustomName { name = model.deviceName }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(tint)
                .frame(width: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
