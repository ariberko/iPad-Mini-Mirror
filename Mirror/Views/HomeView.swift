import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model

        NavigationStack {
            List {
                Section {
                    HeroHeader(isSharing: model.broadcast.isActive)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if model.broadcast.isActive {
                    Section {
                        LiveSharingCard()
                    }
                }

                if model.browser.localNetworkDenied || model.receiver.localNetworkDenied {
                    Section {
                        LocalNetworkWarning {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }

                Section {
                    if model.browser.devices.isEmpty {
                        SearchingRow()
                    } else {
                        ForEach(model.browser.devices) { device in
                            Button {
                                model.selectedDevice = device
                            } label: {
                                DeviceRow(
                                    device: device,
                                    isPaired: model.isPaired(device),
                                    isSharing: model.isSharing(to: device))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Share This Screen")
                } footer: {
                    Text("Open Mirror on your other iPhone or iPad. Keep Wi-Fi and Bluetooth on for both. They don't need to be on the same network.")
                }

                Section {
                    ReceiveStatusRow()
                } header: {
                    Text("Show Another Screen Here")
                } footer: {
                    Text("While Mirror is open, your other devices can show their screen on this \(DeviceKind.current.displayName).")
                }
            }
            .listStyle(.insetGrouped)
            .readableWidth()
            .navigationTitle("Mirror")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.showInbox = true
                    } label: {
                        Image(systemName: model.unseenInboxCount > 0 ? "tray.full.fill" : "tray")
                            .overlay(alignment: .topTrailing) {
                                if model.unseenInboxCount > 0 {
                                    Text("\(min(model.unseenInboxCount, 99))")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.red, in: Capsule())
                                        .offset(x: 10, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel(model.unseenInboxCount > 0 ? "Inbox, \(model.unseenInboxCount) new" : "Inbox")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $model.selectedDevice) { device in
                ConnectSheet(device: device)
                    .environment(model)
            }
            .sheet(isPresented: $model.showSettings) {
                SettingsView()
                    .environment(model)
            }
            .sheet(isPresented: $model.showInbox) {
                InboxView()
                    .environment(model)
            }
        }
    }
}

// MARK: - Header

private struct HeroHeader: View {
    let isSharing: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 64, weight: .thin))
                    .offset(x: -18, y: -4)
                Image(systemName: "iphone")
                    .font(.system(size: 44, weight: .light))
                    .offset(x: 38, y: 14)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.systemGroupedBackground))
                            .frame(width: 26, height: 46)
                            .offset(x: 38, y: 14)
                    }
            }
            .foregroundStyle(.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: isSharing)
            .frame(height: 86)
            .accessibilityHidden(true)

            Text("Your screens, together.")
                .font(.title3.weight(.semibold))
            Text("Show your iPhone on your iPad, or your iPad on your iPhone. With sound, and drag-and-drop.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Rows

private struct DeviceRow: View {
    let device: NearbyDevice
    let isPaired: Bool
    let isSharing: Bool

    var body: some View {
        HStack(spacing: 14) {
            DeviceTile(kind: device.kind, tint: isSharing ? .green : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.serviceName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Group {
                    if isSharing {
                        Text("Showing your screen")
                            .foregroundStyle(.green)
                    } else if isPaired {
                        Text("Ready")
                    } else {
                        Text("Tap to pair")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Share this screen to \(device.serviceName)")
    }
}

private struct SearchingRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ProgressView()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Looking for devices…")
                    .font(.body.weight(.medium))
                Text("Open Mirror on your other device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct ReceiveStatusRow: View {
    @Environment(AppModel.self) private var model
    @State private var showCode = false

    var body: some View {
        HStack(spacing: 14) {
            DeviceTile(kind: .current, tint: model.receiver.isAdvertising ? .green : .gray)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.deviceName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if model.receiver.isAdvertising {
                        PulsingDot()
                        Text("Visible to your devices")
                    } else {
                        Text("Getting ready…")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.snappy) { showCode.toggle() }
            } label: {
                Text(showCode ? AppModel.format(code: model.pairingCode) : "Code")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.tint.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel(showCode ? "Pairing code \(model.pairingCode)" : "Show pairing code")
        }
        .padding(.vertical, 4)
    }
}

private struct LiveSharingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.broadcast.status
        HStack(spacing: 14) {
            DeviceTile(kind: status.peerKind ?? .iPad, tint: .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: status))
                    .font(.body.weight(.semibold))
                if status.state == .live, let start = status.startedAt {
                    Text(start, style: .timer)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(status.state == .reconnecting ? "Reconnecting…" : "Connecting…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(role: .destructive) {
                model.broadcast.stop()
            } label: {
                Text("Stop")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.vertical, 4)
    }

    private func title(for status: BroadcastStatus) -> String {
        "Sharing to \(status.peerName ?? "your device")"
    }
}

private struct LocalNetworkWarning: View {
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Network is off", systemImage: "wifi.exclamationmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
            Text("Mirror needs Local Network access to find your other device. Turn it on in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: openSettings)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}
