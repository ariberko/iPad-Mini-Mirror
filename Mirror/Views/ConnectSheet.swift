import SwiftUI

/// Pair (if needed) and start sharing this screen to one device.
struct ConnectSheet: View {
    let device: NearbyDevice

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable {
        case checking
        case enterCode
        case verifying
        case ready
        case unreachable
    }

    @State private var step: Step = .checking
    @State private var code = ""
    @State private var wrongCodeAttempts: CGFloat = 0
    @State private var showWrongCode = false
    @State private var pairedTrigger = false
    @FocusState private var codeFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    content
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 32)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .background(alignment: .bottomTrailing) {
                // The system broadcast picker lives here, invisible. Our own button triggers it.
                BroadcastPickerHost()
                    .frame(width: 1, height: 1)
                    .opacity(0.011)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.success, trigger: pairedTrigger)
        .sensoryFeedback(.error, trigger: wrongCodeAttempts)
        .task { await check() }
        .onChange(of: model.broadcast.status.state) { _, state in
            if state == .live, model.isSharing(to: device) {
                dismiss()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: device.kind.symbolName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: step == .ready)
                .accessibilityHidden(true)
            Text(device.serviceName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .checking:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

        case .enterCode, .verifying:
            codeEntry

        case .ready:
            ready

        case .unreachable:
            VStack(spacing: 16) {
                Text("Can't reach \(device.serviceName)")
                    .font(.headline)
                Text("Make sure Mirror is open on it, and that Wi-Fi and Bluetooth are on for both devices.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await check() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var codeEntry: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Enter Pairing Code")
                    .font(.headline)
                Text("Type the code shown on \(device.serviceName).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                HStack(spacing: 8) {
                    ForEach(0..<6, id: \.self) { index in
                        digitBox(at: index)
                        if index == 2 { Spacer().frame(width: 6) }
                    }
                }
                .modifier(ShakeEffect(animatableData: wrongCodeAttempts))

                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($codeFieldFocused)
                    .opacity(0.02)
                    .frame(width: 1, height: 1)
                    .accessibilityLabel("Pairing code")
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFieldFocused = true }
            .onChange(of: code) { _, newValue in
                let digits = String(newValue.filter(\.isNumber).prefix(6))
                if digits != newValue { code = digits }
                if !digits.isEmpty { showWrongCode = false }
                if digits.count == 6 { Task { await verify(digits) } }
            }

            Group {
                if step == .verifying {
                    ProgressView()
                } else if showWrongCode {
                    Text("That code didn't work. Try again.")
                        .foregroundStyle(.red)
                } else {
                    Button("Show Code Again") {
                        PairingService.requestCode(from: device)
                    }
                    .font(.subheadline)
                }
            }
            .frame(height: 24)
        }
        .onAppear { codeFieldFocused = true }
    }

    private func digitBox(at index: Int) -> some View {
        let characters = Array(code)
        let digit = index < characters.count ? String(characters[index]) : ""
        let isCurrent = index == characters.count && codeFieldFocused
        return Text(digit)
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 44, height: 56)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isCurrent ? Color.accentColor : (showWrongCode ? .red : .clear), lineWidth: 2)
            }
            .animation(.snappy(duration: 0.15), value: code)
    }

    private var ready: some View {
        let isSharingHere = model.isSharing(to: device)
        return VStack(spacing: 24) {
            Button {
                if isSharingHere {
                    model.broadcast.stop()
                } else {
                    model.prepareBroadcast(to: device)
                    BroadcastLauncher.shared.launch()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill((isSharingHere ? Color.red : Color.accentColor).gradient)
                        .frame(width: 120, height: 120)
                        .shadow(color: (isSharingHere ? Color.red : Color.accentColor).opacity(0.35), radius: 18, y: 8)
                    Image(systemName: isSharingHere ? "stop.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSharingHere ? "Stop Mirroring" : "Start Mirroring")

            VStack(spacing: 6) {
                Text(isSharingHere ? "Mirroring" : "Start Mirroring")
                    .font(.title3.weight(.semibold))
                Text(isSharingHere
                     ? "Your screen is showing on \(device.serviceName)."
                     : "Then tap \u{201C}Start Broadcast\u{201D}. Your screen will appear on \(device.serviceName) in a moment.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                TipRow(symbol: "moon.fill", tint: .indigo,
                       text: "Turn on Do Not Disturb to keep notifications private while you share.")
                TipRow(symbol: model.shareAudio ? "speaker.wave.2.fill" : "speaker.slash.fill", tint: .pink,
                       text: model.shareAudio ? "Sound is shared too. You can turn it off in Settings." : "Sound is not shared. You can turn it on in Settings.")
                TipRow(symbol: "lock.fill", tint: .gray,
                       text: "Mirroring pauses when this \(DeviceKind.current.displayName) locks. Apps that protect their content show black.")
            }
            .padding(16)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: Logic

    private func check() async {
        step = .checking
        guard let saved = model.savedCode(for: device) else {
            PairingService.requestCode(from: device)
            withAnimation { step = .enterCode }
            return
        }
        switch await PairingService.verify(device: device, code: saved, purpose: .probe) {
        case .success:
            withAnimation(.snappy) { step = .ready }
        case .wrongCode:
            model.removePairing(for: device)
            PairingService.requestCode(from: device)
            withAnimation { step = .enterCode }
        case .unreachable:
            withAnimation { step = .unreachable }
        }
    }

    private func verify(_ candidate: String) async {
        guard step == .enterCode else { return }
        step = .verifying
        let result = await PairingService.verify(device: device, code: candidate, purpose: .pair)
        switch result {
        case .success:
            model.savePairing(candidate, for: device)
            pairedTrigger.toggle()
            codeFieldFocused = false
            withAnimation(.snappy) { step = .ready }
        case .wrongCode:
            step = .enterCode
            code = ""
            showWrongCode = true
            withAnimation(.linear(duration: 0.4)) { wrongCodeAttempts += 1 }
        case .unreachable:
            withAnimation { step = .unreachable }
        }
    }
}

private struct TipRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hosts the system broadcast picker so it can be triggered from our own button.
struct BroadcastPickerHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        let picker = BroadcastLauncher.shared.pickerView
        picker.removeFromSuperview()
        picker.frame = container.bounds
        container.addSubview(picker)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
