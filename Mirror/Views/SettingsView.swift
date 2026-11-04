import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var confirmForget = false
    @State private var confirmNewCode = false

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $name)
                            .multilineTextAlignment(.trailing)
                            .submitLabel(.done)
                            .onSubmit(saveName)
                    }
                } header: {
                    Text("This \(DeviceKind.current.displayName)")
                } footer: {
                    Text("This is how this \(DeviceKind.current.displayName) appears on your other devices.")
                }

                Section {
                    Picker("Quality", selection: $model.quality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    Toggle("Share Sound", isOn: $model.shareAudio)
                } header: {
                    Text("When Sharing This Screen")
                } footer: {
                    Text("\(model.quality.detail) Changes apply the next time you start mirroring.")
                }

                Section {
                    LabeledContent("Pairing Code") {
                        Text(AppModel.format(code: model.pairingCode))
                            .monospacedDigit()
                            .font(.body.weight(.semibold))
                    }
                    Button("Change Pairing Code") { confirmNewCode = true }
                    Button("Forget Paired Devices", role: .destructive) { confirmForget = true }
                        .disabled(model.pairedDeviceCount == 0)
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Changing the code means your other devices need to pair again before they can show their screen here.")
                }

                Section {
                    Toggle("Show Connection Info", isOn: $model.showStats)
                } header: {
                    Text("When Showing Another Screen")
                } footer: {
                    Text("Shows resolution, frame rate, speed and delay while mirroring.")
                }

                Section {
                    NavigationLink("How Mirror Works") { HowItWorksView() }
                    LabeledContent("Version", value: MirrorConfig.appVersion)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveName()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Change your pairing code?", isPresented: $confirmNewCode, titleVisibility: .visible) {
                Button("Change Code", role: .destructive) { model.changePairingCode() }
            } message: {
                Text("Devices that paired with the old code will need the new one.")
            }
            .confirmationDialog("Forget all paired devices?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget Devices", role: .destructive) { model.forgetAllPairings() }
            }
        }
        .onAppear { name = model.deviceName }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != model.deviceName else {
            name = model.deviceName
            return
        }
        model.rename(to: trimmed)
        name = model.deviceName
    }
}

struct HowItWorksView: View {
    var body: some View {
        List {
            Section {
                InfoRow(symbol: "dot.radiowaves.left.and.right", tint: .blue,
                        title: "Nearby, private, direct",
                        text: "Your devices talk to each other directly over Wi-Fi. Nothing goes through the internet or any server.")
                InfoRow(symbol: "lock.fill", tint: .green,
                        title: "Encrypted with your code",
                        text: "The 6-digit pairing code becomes an encryption key. A device without it can't connect or see anything.")
                InfoRow(symbol: "rectangle.on.rectangle", tint: .indigo,
                        title: "Sharing a screen",
                        text: "iOS lets an app share the whole screen only through Screen Broadcast. That's why you tap Start Broadcast, and why a red pill shows at the top while you share.")
                InfoRow(symbol: "speaker.wave.2.fill", tint: .pink,
                        title: "Sound",
                        text: "Sound from apps on the shared screen plays on the other device too. Calls and the microphone are never shared.")
                InfoRow(symbol: "arrow.down.doc.fill", tint: .orange,
                        title: "Drag and drop",
                        text: "Drop photos and files onto the mirror to send them to that device. They show up in its Inbox, and it gets a notification.")
                InfoRow(symbol: "pip", tint: .teal,
                        title: "Picture in Picture",
                        text: "Swipe home while mirroring, and the screen keeps playing in a small window you can move anywhere.")
            }

            Section {
                InfoRow(symbol: "hand.tap", tint: .gray,
                        title: "Why can't I tap on the other screen?",
                        text: "iOS doesn't let any app control another iPhone or iPad. To control a device, use FaceTime screen sharing (iOS 18 or later), which can ask for remote control.")
            }
        }
        .navigationTitle("How Mirror Works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InfoRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
