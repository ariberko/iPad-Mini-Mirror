import CoreMedia
import Foundation
import Network

struct StreamStats: Equatable {
    var framesPerSecond = 0
    var megabitsPerSecond = 0.0
    var latencyMilliseconds: Int?
    var resolution: CGSize = .zero
    var codec = ""
}

/// One incoming connection from a device that wants to share its screen (or pair).
/// Everything here runs on the receiver's network queue.
final class ViewerSession {
    let connection: MirrorConnection
    let fileSender: FileSender
    private(set) var hello: HelloMessage?

    /// Only the active session may draw to the screen.
    var isActive = false

    var onHello: ((ViewerSession, HelloMessage) -> Void)?
    var onClosed: ((ViewerSession, String?) -> Void)?
    var onFirstFrame: ((ViewerSession) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onStats: ((StreamStats) -> Void)?

    private let renderer: VideoRenderer
    private let audio: AudioStreamPlayer
    private let queue: DispatchQueue

    private var format: CMVideoFormatDescription?
    private var codec: VideoCodec = .hevc
    private var awaitingKeyFrame = true
    private var hasShownFirstFrame = false
    private var lastKeyFrameRequest = Date.distantPast
    private var goodbyeReason: String?

    private var frameCount = 0
    private var byteCount = 0
    private var latency: Int?
    private var videoSize: CGSize = .zero
    private var statsTimer: DispatchSourceTimer?

    init(connection: MirrorConnection, renderer: VideoRenderer, audio: AudioStreamPlayer, queue: DispatchQueue) {
        self.connection = connection
        self.renderer = renderer
        self.audio = audio
        self.queue = queue
        self.fileSender = FileSender(connection: connection, queue: queue)
    }

    var peerName: String { hello?.deviceName ?? "Device" }

    func start() {
        connection.onMessage = { [weak self] type, data in
            self?.handle(type, data)
        }
        connection.onClose = { [weak self] reason in
            guard let self else { return }
            self.stopStatsTimer()
            self.fileSender.cancelAll()
            self.onClosed?(self, self.goodbyeReason ?? reason.message)
        }
        connection.start()

        // Anything that doesn't introduce itself quickly is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.hello == nil else { return }
            self.connection.cancel()
        }
    }

    func reply(accepted: Bool, reason: String? = nil) {
        let store = SharedStore.shared
        let ack = HelloAckMessage(accepted: accepted, deviceName: store.deviceName, kind: .current, reason: reason)
        connection.send(.helloAck, ack.jsonData())
    }

    func activate() {
        isActive = true
        awaitingKeyFrame = true
        reply(accepted: true)
        requestKeyFrame(force: true)
        startStatsTimer()
    }

    /// Ends the session. With a reason, the other device is told why.
    func end(reason: String?) {
        isActive = false
        connection.send(.goodbye, GoodbyeMessage(reason: reason).jsonData())
        let connection = self.connection
        queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
    }

    // MARK: Messages

    private func handle(_ type: MessageType, _ data: Data) {
        switch type {
        case .hello:
            guard let hello = HelloMessage.fromJSON(data) else {
                connection.cancel()
                return
            }
            self.hello = hello
            onHello?(self, hello)

        case .videoFormat:
            guard isActive, let message = VideoFormatMessage(data),
                  let newFormat = CodecSupport.makeFormatDescription(codec: message.codec, parameterSets: message.parameterSets) else { return }
            codec = message.codec
            if let format, CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) { return }
            format = newFormat
            let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
            videoSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            onVideoSize?(videoSize)

        case .videoFrame:
            guard isActive, let frame = VideoFrameMessage(data) else { return }
            frameCount += 1
            byteCount += data.count

            if awaitingKeyFrame && !frame.isKeyFrame {
                requestKeyFrame(force: false)
                return
            }
            guard let format, let sampleBuffer = CodecSupport.makeSampleBuffer(frame.data, format: format) else {
                awaitingKeyFrame = true
                requestKeyFrame(force: false)
                return
            }
            if renderer.enqueue(sampleBuffer) {
                awaitingKeyFrame = false
                if !hasShownFirstFrame {
                    hasShownFirstFrame = true
                    onFirstFrame?(self)
                }
            } else {
                awaitingKeyFrame = true
                requestKeyFrame(force: true)
            }

        case .audioPacket:
            guard isActive, let packet = AudioPacketMessage(data) else { return }
            byteCount += data.count
            audio.enqueue(packet)

        case .pong:
            guard let ping = PingMessage(data) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            if now > ping.nanoseconds {
                latency = Int((now - ping.nanoseconds) / 2_000_000)
            }

        case .goodbye:
            let reason = GoodbyeMessage.fromJSON(data)?.reason
            goodbyeReason = reason ?? "\(peerName) stopped sharing."
            connection.cancel()

        case .fileReceived:
            guard let message = FileIDMessage(data) else { return }
            fileSender.confirm(message.id)

        default:
            break
        }
    }

    private func requestKeyFrame(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastKeyFrameRequest) > 0.5 else { return }
        lastKeyFrameRequest = now
        connection.send(.requestKeyFrame, Data([1]))
    }

    // MARK: Stats

    private func startStatsTimer() {
        stopStatsTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        statsTimer = timer
    }

    private func stopStatsTimer() {
        statsTimer?.cancel()
        statsTimer = nil
    }

    private func tick() {
        let stats = StreamStats(
            framesPerSecond: frameCount,
            megabitsPerSecond: Double(byteCount * 8) / 1_000_000,
            latencyMilliseconds: latency,
            resolution: videoSize,
            codec: codec.name)
        frameCount = 0
        byteCount = 0
        onStats?(stats)
        connection.send(.ping, PingMessage(nanoseconds: DispatchTime.now().uptimeNanoseconds).encoded())
    }
}
