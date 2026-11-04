import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Full-screen view of the other device's screen.
struct MirrorScreen: View {
    @Environment(AppModel.self) private var model

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isDropTargeted = false
    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []

    private var receiver: ReceiverService { model.receiver }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MirrorVideoView(
                renderer: receiver.renderer,
                videoSize: receiver.videoSize,
                cornerFraction: receiver.peerKind.screenCornerFraction)
                .padding(6)
                .opacity(receiver.hasVideo ? 1 : 0)
                .animation(.easeOut(duration: 0.35), value: receiver.hasVideo)
                .accessibilityLabel("Screen of \(receiver.peerName)")

            if !receiver.hasVideo {
                statusOverlay
                    .transition(.opacity)
            }

            if isDropTargeted {
                dropOverlay
                    .transition(.opacity)
            }

            VStack {
                if controlsVisible {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                bottomArea
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .onDrop(of: [.item], isTargeted: $isDropTargeted) { providers in
            receiver.send(providers: providers)
            showControlsBriefly()
            return true
        }
        .animation(.snappy(duration: 0.3), value: controlsVisible)
        .animation(.easeOut(duration: 0.2), value: isDropTargeted)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .preferredColorScheme(.dark)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            showControlsBriefly()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            hideTask?.cancel()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if let copy = ReceiverService.makeTemporaryCopy(of: url, suggestedName: nil, typeIdentifier: nil) {
                    receiver.sendFile(at: copy)
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelection, maxSelectionCount: 20, matching: .any(of: [.images, .videos]))
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            photoSelection = []
            for item in items {
                Task {
                    if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                        receiver.sendFile(at: picked.url)
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private var statusOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: receiver.peerKind.symbolName)
                .font(.system(size: 60, weight: .ultraLight))
                .symbolEffect(.pulse, options: .repeating, isActive: receiver.phase == .connecting)
            switch receiver.phase {
            case .ended(let message):
                Text(message)
                    .font(.headline)
                    .multilineTextAlignment(.center)
            default:
                Text("Connecting to \(receiver.peerName)…")
                    .font(.headline)
                ProgressView()
                    .tint(.white)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(32)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .foregroundStyle(.tint)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                Label("Drop to send to \(receiver.peerName)", systemImage: "arrow.down.doc.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(16)
            .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                receiver.disconnect()
                model.showMirror = false
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop Mirroring")

            HStack(spacing: 8) {
                Image(systemName: receiver.peerKind.symbolName)
                Text(receiver.peerName)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 6)

            Spacer(minLength: 0)

            Button {
                receiver.setMuted(!receiver.isMuted)
                showControlsBriefly()
            } label: {
                Image(systemName: receiver.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(receiver.isMuted ? "Unmute" : "Mute")

            if receiver.renderer.pipController != nil {
                Button {
                    receiver.togglePictureInPicture()
                } label: {
                    Image(systemName: receiver.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Picture in Picture")
            }

            Menu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photos & Videos", systemImage: "photo.on.rectangle")
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label("Files", systemImage: "folder")
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Send to \(receiver.peerName)")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 560)
    }

    @ViewBuilder
    private var bottomArea: some View {
        VStack(spacing: 8) {
            ForEach(receiver.transfers) { transfer in
                TransferPill(transfer: transfer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.showStats, receiver.hasVideo, controlsVisible {
                StatsPill(stats: receiver.stats)
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: receiver.transfers)
    }

    // MARK: Controls visibility

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            controlsVisible = false
        } else {
            showControlsBriefly()
        }
    }

    private func showControlsBriefly() {
        controlsVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, receiver.hasVideo else { return }
            controlsVisible = false
        }
    }
}

// MARK: - Pills

private struct TransferPill: View {
    let transfer: FileTransfer

    var body: some View {
        HStack(spacing: 10) {
            switch transfer.state {
            case .sending:
                ProgressView(value: transfer.progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
            Text(transfer.state == .failed ? "Couldn't send \(transfer.name)" : transfer.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 420)
    }
}

private struct StatsPill: View {
    let stats: StreamStats

    var body: some View {
        HStack(spacing: 14) {
            Text("\(Int(stats.resolution.width))×\(Int(stats.resolution.height))")
            Text("\(stats.framesPerSecond) fps")
            Text(String(format: "%.1f Mbps", stats.megabitsPerSecond))
            if let latency = stats.latencyMilliseconds {
                Text("\(latency) ms")
            }
            Text(stats.codec)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }
}

// MARK: - Video view

struct MirrorVideoView: UIViewRepresentable {
    let renderer: VideoRenderer
    let videoSize: CGSize
    let cornerFraction: CGFloat

    func makeUIView(context: Context) -> VideoContainerView {
        let view = VideoContainerView()
        view.attach(renderer.displayLayer)
        return view
    }

    func updateUIView(_ view: VideoContainerView, context: Context) {
        if view.videoSize != videoSize || view.cornerFraction != cornerFraction {
            view.videoSize = videoSize
            view.cornerFraction = cornerFraction
            view.setNeedsLayout()
        }
    }
}

final class VideoContainerView: UIView {
    var videoSize: CGSize = .zero
    var cornerFraction: CGFloat = 0.1
    private weak var displayLayer: CALayer?

    func attach(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        self.layer.addSublayer(layer)
        displayLayer = layer
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let displayLayer else { return }
        let rect: CGRect
        if videoSize.width > 0, videoSize.height > 0 {
            rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds).integral
        } else {
            rect = bounds
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = rect
        displayLayer.cornerRadius = min(rect.width, rect.height) * cornerFraction
        displayLayer.cornerCurve = .continuous
        displayLayer.masksToBounds = true
        displayLayer.borderWidth = 0.5
        displayLayer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        CATransaction.commit()
    }
}

// MARK: - Photos

/// A photo or video from the picker, copied to a private temporary file.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile(url: copy(received.file))
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile(url: copy(received.file))
        }
        FileRepresentation(importedContentType: .data) { received in
            try PickedFile(url: copy(received.file))
        }
    }

    private static func copy(_ url: URL) throws -> URL {
        guard let copy = ReceiverService.makeTemporaryCopy(of: url, suggestedName: nil, typeIdentifier: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return copy
    }
}
