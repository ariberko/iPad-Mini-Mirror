import Foundation
import Network
import Observation
import UniformTypeIdentifiers
import UIKit

struct FileTransfer: Identifiable, Equatable {
    enum State: Equatable {
        case sending
        case done
        case failed
    }

    let id: UUID
    let name: String
    var progress: Double
    var state: State
}

struct PairPrompt: Identifiable, Equatable {
    let id = UUID()
    let deviceName: String
    let kind: DeviceKind
}

/// Makes this device visible to the other one and shows its screen when it starts sharing.
@Observable
final class ReceiverService {
    enum Phase: Equatable {
        case idle
        case connecting
        case mirroring
        case ended(String)
    }

    private(set) var isAdvertising = false
    private(set) var localNetworkDenied = false
    private(set) var phase: Phase = .idle
    private(set) var peerName = ""
    private(set) var peerKind: DeviceKind = .iPhone
    private(set) var videoSize: CGSize = .zero
    private(set) var hasVideo = false
    private(set) var stats = StreamStats()
    private(set) var isPictureInPictureActive = false
    private(set) var transfers: [FileTransfer] = []
    private(set) var isMuted = false

    // Called on the main queue.
    @ObservationIgnored var onSessionStarted: (() -> Void)?
    @ObservationIgnored var onSessionEnded: (() -> Void)?
    @ObservationIgnored var onPairRequest: ((PairPrompt) -> Void)?
    @ObservationIgnored var onPaired: ((String) -> Void)?
    @ObservationIgnored var onRestoreFromPictureInPicture: (() -> Void)?

    @ObservationIgnored let renderer = VideoRenderer()
    @ObservationIgnored private let audio = AudioStreamPlayer()
    @ObservationIgnored private let store = SharedStore.shared
    @ObservationIgnored private let queue = DispatchQueue(label: "mirror.receiver", qos: .userInteractive)

    // Only touched on `queue`.
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var pairListener: NWListener?
    @ObservationIgnored private var activeSession: ViewerSession?
    @ObservationIgnored private var pendingSessions: [ObjectIdentifier: ViewerSession] = [:]
    @ObservationIgnored private var wantsRunning = false

    // Only touched on the main queue.
    @ObservationIgnored private var transferFiles: [UUID: URL] = [:]

    init() {
        renderer.onPictureInPictureChange = { [weak self] active in
            self?.isPictureInPictureActive = active
        }
        renderer.onRestoreUserInterface = { [weak self] in
            self?.onRestoreFromPictureInPicture?()
        }
    }

    var isMirroring: Bool {
        phase == .connecting || phase == .mirroring
    }

    // MARK: Advertising

    func start() {
        queue.async {
            self.wantsRunning = true
            self.startListenersIfNeeded()
        }
    }

    func stop() {
        queue.async {
            self.wantsRunning = false
            self.listener?.cancel()
            self.pairListener?.cancel()
            self.listener = nil
            self.pairListener = nil
            DispatchQueue.main.async { self.isAdvertising = false }
        }
    }

    /// Re-announces the device after a name or pairing code change.
    func restart() {
        queue.async {
            self.listener?.cancel()
            self.pairListener?.cancel()
            self.listener = nil
            self.pairListener = nil
            self.startListenersIfNeeded()
        }
    }

    private func startListenersIfNeeded() {
        guard wantsRunning else { return }
        if listener == nil { startMainListener() }
        if pairListener == nil { startPairListener() }
    }

    private func txtRecord() -> NWTXTRecord {
        var record = NWTXTRecord()
        record["id"] = store.deviceID
        record["kind"] = DeviceKind.current.rawValue
        record["v"] = String(MirrorConfig.protocolVersion)
        return record
    }

    private func startMainListener() {
        do {
            let listener = try NWListener(using: .mirror(passcode: store.pairingCode))
            listener.service = NWListener.Service(name: store.deviceName, type: MirrorConfig.serviceType, domain: nil, txtRecord: txtRecord())
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    DispatchQueue.main.async {
                        self.isAdvertising = true
                        self.localNetworkDenied = false
                    }
                case .waiting(let error):
                    let denied = Self.isPolicyDenied(error)
                    DispatchQueue.main.async {
                        self.isAdvertising = false
                        self.localNetworkDenied = denied
                    }
                case .failed:
                    DispatchQueue.main.async { self.isAdvertising = false }
                    listener?.cancel()
                    if self.listener === listener { self.listener = nil }
                    self.queue.asyncAfter(deadline: .now() + 1.5) { self.startListenersIfNeeded() }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            queue.asyncAfter(deadline: .now() + 2) { self.startListenersIfNeeded() }
        }
    }

    private func startPairListener() {
        do {
            let listener = try NWListener(using: .mirror(passcode: nil))
            listener.service = NWListener.Service(name: store.deviceName, type: MirrorConfig.pairServiceType, domain: nil, txtRecord: txtRecord())
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                if case .failed = state {
                    listener?.cancel()
                    if self.pairListener === listener { self.pairListener = nil }
                    self.queue.asyncAfter(deadline: .now() + 1.5) { self.startListenersIfNeeded() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.acceptPairRequest(connection)
            }
            listener.start(queue: queue)
            pairListener = listener
        } catch {
            queue.asyncAfter(deadline: .now() + 2) { self.startListenersIfNeeded() }
        }
    }

    private static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error, code == -65570 { return true } // kDNSServiceErr_PolicyDenied
        return false
    }

    // MARK: Connections (on queue)

    private func acceptPairRequest(_ connection: NWConnection) {
        let mirrorConnection = MirrorConnection(connection: connection, queue: queue)
        var keepAlive: MirrorConnection? = mirrorConnection
        mirrorConnection.onMessage = { [weak self] type, data in
            guard type == .pairRequest, let request = PairRequestMessage.fromJSON(data) else { return }
            DispatchQueue.main.async {
                self?.onPairRequest?(PairPrompt(deviceName: request.deviceName, kind: request.kind))
            }
            keepAlive?.cancel()
        }
        mirrorConnection.onClose = { _ in keepAlive = nil }
        mirrorConnection.start()
        queue.asyncAfter(deadline: .now() + 5) { keepAlive?.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let mirrorConnection = MirrorConnection(connection: connection, queue: queue)
        let session = ViewerSession(connection: mirrorConnection, renderer: renderer, audio: audio, queue: queue)
        let key = ObjectIdentifier(session)
        pendingSessions[key] = session

        session.onHello = { [weak self] session, hello in
            self?.handleHello(session, hello)
        }
        session.onClosed = { [weak self] session, reason in
            self?.sessionClosed(session, reason: reason)
        }
        session.start()
    }

    private func handleHello(_ session: ViewerSession, _ hello: HelloMessage) {
        switch hello.purpose {
        case .probe, .pair:
            session.reply(accepted: true)
            if hello.purpose == .pair {
                DispatchQueue.main.async { self.onPaired?(hello.deviceName) }
            }
            let connection = session.connection
            queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }

        case .mirror:
            guard hello.protocolVersion == MirrorConfig.protocolVersion else {
                session.reply(accepted: false, reason: "Update Mirror on both devices to the same version.")
                return
            }
            // A newer request takes over from an older one, like AirPlay.
            if let previous = activeSession, previous !== session {
                previous.isActive = false
                previous.end(reason: "\(store.deviceName) is now showing another device.")
            }
            activeSession = session
            wire(session)
            session.activate()
            DispatchQueue.main.async {
                self.peerName = hello.deviceName
                self.peerKind = hello.kind
                self.hasVideo = false
                self.videoSize = .zero
                self.stats = StreamStats()
                self.phase = .connecting
                self.audio.start()
                self.onSessionStarted?()
            }
        }
    }

    private func wire(_ session: ViewerSession) {
        session.onFirstFrame = { [weak self] _ in
            DispatchQueue.main.async {
                self?.hasVideo = true
                self?.phase = .mirroring
            }
        }
        session.onVideoSize = { [weak self] size in
            DispatchQueue.main.async { self?.videoSize = size }
        }
        session.onStats = { [weak self] stats in
            DispatchQueue.main.async { self?.stats = stats }
        }
        session.fileSender.onProgress = { [weak self] id, progress in
            DispatchQueue.main.async { self?.updateTransfer(id) { $0.progress = progress } }
        }
        session.fileSender.onFinished = { [weak self] id, success in
            DispatchQueue.main.async { self?.finishTransfer(id, success: success) }
        }
    }

    private func sessionClosed(_ session: ViewerSession, reason: String?) {
        pendingSessions[ObjectIdentifier(session)] = nil
        guard session === activeSession else { return }
        activeSession = nil
        let name = session.peerName
        DispatchQueue.main.async {
            self.audio.stop()
            self.renderer.stopPictureInPicture()
            self.phase = .ended(reason ?? "\(name) stopped sharing.")
            self.onSessionEnded?()
        }
    }

    // MARK: Actions (main thread)

    /// Stops mirroring from this side. The other device ends its broadcast.
    func disconnect() {
        queue.async {
            guard let session = self.activeSession else {
                DispatchQueue.main.async { self.phase = .idle }
                return
            }
            session.end(reason: "Mirroring was stopped on \(self.store.deviceName).")
        }
    }

    func resetAfterEnd() {
        if case .ended = phase {
            phase = .idle
            hasVideo = false
            renderer.clear()
            transfers.removeAll()
        }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audio.isMuted = muted
    }

    func togglePictureInPicture() {
        renderer.togglePictureInPicture()
    }

    // MARK: Sending files (main thread)

    func send(providers: [NSItemProvider]) {
        for provider in providers {
            let typeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .data) || type.conforms(to: .package)
            } ?? provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            let suggestedName = provider.suggestedName

            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { [weak self] url, _ in
                guard let self, let url else { return }
                guard let copy = Self.makeTemporaryCopy(of: url, suggestedName: suggestedName, typeIdentifier: typeIdentifier) else { return }
                DispatchQueue.main.async {
                    self.sendFile(at: copy, typeIdentifier: typeIdentifier)
                }
            }
        }
    }

    /// `url` must be a private copy. It is deleted once sent.
    func sendFile(at url: URL, typeIdentifier: String? = nil) {
        let id = UUID()
        let name = url.lastPathComponent
        let type = typeIdentifier ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.data.identifier
        transfers.append(FileTransfer(id: id, name: name, progress: 0, state: .sending))
        transferFiles[id] = url

        queue.async {
            guard let session = self.activeSession else {
                DispatchQueue.main.async { self.finishTransfer(id, success: false) }
                return
            }
            session.fileSender.enqueue(FileSender.Item(id: id, url: url, name: name, typeIdentifier: type))
        }
    }

    static func makeTemporaryCopy(of url: URL, suggestedName: String?, typeIdentifier: String?) -> URL? {
        var name = suggestedName ?? url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension
        if ext.isEmpty, let typeIdentifier, let preferred = UTType(typeIdentifier)?.preferredFilenameExtension {
            ext = preferred
        }
        if name.isEmpty { name = "File" }
        if !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) {
            name += "." + ext
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Outgoing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func updateTransfer(_ id: UUID, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    private func finishTransfer(_ id: UUID, success: Bool) {
        updateTransfer(id) {
            $0.state = success ? .done : .failed
            if success { $0.progress = 1 }
        }
        if let url = transferFiles.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (success ? 2 : 4)) {
            self.transfers.removeAll { $0.id == id }
        }
    }
}
