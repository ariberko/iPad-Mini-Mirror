import SwiftUI

/// Shown on the receiving device when another device wants to pair.
struct PairingCodeSheet: View {
    let prompt: PairPrompt

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer(minLength: 0)

                Image(systemName: prompt.kind.symbolName)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Pair with \(prompt.deviceName)")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Enter this code on \(prompt.deviceName).")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                CodeDigitsView(code: model.pairingCode)

                Text("You only need to do this once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
