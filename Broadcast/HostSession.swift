import CoreMedia
import Foundation
import ImageIO
import Network
import ReplayKit

/// Streams the screen to one paired device.
///
/// Threads:
/// - ReplayKit calls `handleVideo` / `handleAudio` on its own queue.
/// - Networking runs on `networkQueue`.
/// - The encoder calls back on a VideoToolbox thread.
final class HostSession {
    var onFatalError: ((String) -> Void)?

    private let target: BroadcastTarget
    private let passcode: String
    private let store = SharedStore.shared
    private let quality: StreamQuality
    private let shareAudio: Bool

    private let networkQueue = DispatchQueue(label: "mirror.host.network", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Void>()
    private let encoder: VideoEncoder
    private let processor = FrameProcessor()
    private let audio = AudioPacketizer()
    private let files: FileReceiver

    /// If more than this is still waiting to go out, new frames are skipped
    /// (not encoded) so the picture never falls behind.
    private let maxBytesInFlight = 3 * 1024 * 1024

    // Guarded by `lock`.
    private let lock = NSLock()
    private var _connection: MirrorConnection?
    private var _isStreaming = false
    private var _isPaused = false
    private var _lastFrame: CVPixelBuffer?

    // Only touched on the ReplayKit queue.
    private var lastFrameTime = CMTime.invalid

    // Only touched on `networkQueue`.
    private var isFinished = false
    private var everConnected = false
    private var disconnectedSince: Date?
    private var connectionGeneration = 0
    private var startedAt: Date?

    init(target: BroadcastTarget, passcode: String) {
        self.target = target
        self.passcode = passcode
        self.quality = SharedStore.shared.quality
        self.shareAudio = SharedStore.shared.shareAudio
        self.encoder = VideoEncoder(bitRate: quality.bitRate, frameRate: quality.frameRate)
        self.files = FileReceiver(peerName: target.displayName)

        encoder.onEncodedFrame = { [weak self] frame in
            self?.sendEncoded(frame)
        }
    }

    // MARK: Thread-safe state

    private var connection: MirrorConnection? {
        get { lock.withLock { _connection } }
        set { lock.withLock { _connection = newValue } }
    }

    private var isStreaming: Bool {
        get { lock.withLock { _isStreaming } }
        set { lock.withLock { _isStreaming = newValue } }
    }

    private var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set { lock.withLock { _isPaused = newValue } }
    }

    private var lastFrame: CVPixelBuffer? {
        get { lock.withLock { _lastFrame } }
        set { lock.withLock { _lastFrame = newValue } }
    }

    // MARK: Lifecycle

    func start() {
        networkQueue.setSpecific(key: queueKey, value: ())
        networkQueue.async {
            self.updateStatus(.connecting)
            self.disconnectedSince = Date()
            self.connect()
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { requestKeyFrame() }
    }

    func stop(sendGoodbye: Bool) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopOnQueue(sendGoodbye: sendGoodbye)
        } else {
            networkQueue.sync { stopOnQueue(sendGoodbye: sendGoodbye) }
        }
        encoder.invalidate()
        lastFrame = nil
        store.broadcastStatus = .idle
    }

    private func stopOnQueue(sendGoodbye: Bool) {
        guard !isFinished else { return }
        isFinished = true
        isStreaming = false
        if sendGoodbye, let connection {
            connection.send(.goodbye, GoodbyeMessage(reason: nil).jsonData())
            let closing = connection
            networkQueue.asyncAfter(deadline: .now() + 0.3) { closing.cancel() }
        } else {
            connection?.cancel()
        }
        connection = nil
        files.cancelAll()
    }

    // MARK: Samples from ReplayKit

    func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isStreaming, !isPaused,
              let connection,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let minimumInterval = 1.0 / Double(quality.frameRate)
        if lastFrameTime.isValid, presentationTime.isValid,
           CMTimeGetSeconds(CMTimeSubtract(presentationTime, lastFrameTime)) < minimumInterval * 0.75 {
            return
        }

        // Wi-Fi is behind. Skip this frame entirely, so nothing piles up.
        if connection.bytesInFlight > maxBytesInFlight { return }
        lastFrameTime = presentationTime

        var orientation = CGImagePropertyOrientation.up
        if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            orientation = value
        }

        guard let frame = processor.process(pixelBuffer, orientation: orientation, maxLongSide: quality.maxLongSide) else { return }
        lastFrame = frame
        encoder.encode(frame, presentationTime: presentationTime.isValid ? presentationTime : nil)
    }

    func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard shareAudio, isStreaming, !isPaused,
              let connection,
              connection.bytesInFlight < maxBytesInFlight,
              let samples = audio.convert(sampleBuffer) else { return }
        let packet = AudioPacketMessage(
            sampleRate: UInt32(AudioPacketizer.sampleRate),
            channels: UInt8(AudioPacketizer.channels),
            samples: samples)
        connection.send(.audioPacket, packet.encoded())
    }

    // MARK: Networking

    private func connect() {
        guard !isFinished else { return }
        connectionGeneration += 1
        let generation = connectionGeneration

        let connection = MirrorConnection(endpoint: .mirrorService(named: target.serviceName), passcode: passcode, queue: networkQueue)
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            let hello = HelloMessage(
                deviceID: self.store.deviceID,
                deviceName: self.store.deviceName,
                kind: .current,
                purpose: .mirror,
                protocolVersion: MirrorConfig.protocolVersion,
                appVersion: MirrorConfig.appVersion)
            connection.send(.hello, hello.jsonData())
        }
        connection.onMessage = { [weak self] type, data in
            self?.handleMessage(type, data)
        }
        connection.onClose = { [weak self] reason in
            self?.connectionClosed(reason, generation: generation)
        }
        self.connection = connection
        connection.start()

        // Give each attempt a few seconds before trying again.
        networkQueue.asyncAfter(deadline: .now() + 6) { [weak self, weak connection] in
            guard let self, generation == self.connectionGeneration, !self.isStreaming else { return }
            connection?.cancel()
        }
    }

    private func connectionClosed(_ reason: MirrorConnection.CloseReason, generation: Int) {
        guard generation == connectionGeneration, !isFinished else { return }
        isStreaming = false
        connection = nil
        files.cancelAll()

        if reason == .wrongCode {
            store.removePairing(for: target.deviceID)
            fail("The pairing code for \(target.displayName) has changed. Open Mirror to pair again.")
            return
        }

        let since = disconnectedSince ?? Date()
        disconnectedSince = since
        let waited = Date().timeIntervalSince(since)
        let limit: TimeInterval = everConnected ? 25 : 14
        if waited > limit {
            if everConnected {
                fail("Lost connection to \(target.displayName).")
            } else {
                fail("Couldn't reach \(target.displayName). Make sure Mirror is open on it and Wi-Fi is turned on for both devices.")
            }
            return
        }

        updateStatus(everConnected ? .reconnecting : .connecting)
        networkQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connect()
        }
    }

    private func handleMessage(_ type: MessageType, _ data: Data) {
        switch type {
        case .helloAck:
            guard let ack = HelloAckMessage.fromJSON(data) else { return }
            guard ack.accepted else {
                fail(ack.reason ?? "\(target.displayName) declined the connection.")
                return
            }
            everConnected = true
            disconnectedSince = nil
            if startedAt == nil { startedAt = Date() }
            isStreaming = true
            updateStatus(.live)
            requestKeyFrame()

        case .requestKeyFrame:
            requestKeyFrame()

        case .ping:
            connection?.send(.pong, data)

        case .goodbye:
            let reason = GoodbyeMessage.fromJSON(data)?.reason
            fail(reason ?? "Mirroring was stopped on \(target.displayName).")

        case .fileStart, .fileChunk, .fileEnd, .fileCancel:
            files.handle(type, data) { [weak self] replyType, payload in
                self?.connection?.send(replyType, payload)
            }

        default:
            break
        }
    }

    /// The viewer needs a full picture (just joined, or decoding failed).
    /// The screen may be still, so the last frame is encoded again as a key frame.
    private func requestKeyFrame() {
        encoder.forceKeyFrame()
        if let frame = lastFrame {
            encoder.encode(frame, presentationTime: nil)
        }
    }

    private func sendEncoded(_ frame: EncodedFrame) {
        guard isStreaming, let connection else { return }
        if frame.isKeyFrame, let parameterSets = frame.parameterSets, !parameterSets.isEmpty {
            connection.send(.videoFormat, VideoFormatMessage(codec: frame.codec, parameterSets: parameterSets).encoded())
        }
        let message = VideoFrameMessage(isKeyFrame: frame.isKeyFrame, timestampMicros: frame.timestampMicros, data: frame.data)
        connection.send(.videoFrame, message.encoded())
    }

    private func fail(_ message: String) {
        guard !isFinished else { return }
        isFinished = true
        isStreaming = false
        connection?.cancel()
        connection = nil
        store.broadcastStatus = .idle
        onFatalError?(message)
    }

    private func updateStatus(_ state: BroadcastStatus.State) {
        store.broadcastStatus = BroadcastStatus(
            state: state,
            peerName: target.displayName,
            peerKind: target.kind,
            startedAt: state == .live ? (startedAt ?? Date()) : startedAt,
            updatedAt: Date())
    }
}
