import AVFoundation

/// Plays the other device's sound with as little delay as possible.
final class AudioStreamPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let lock = NSLock()
    private var queuedFrames: Int = 0
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?

    /// Anything beyond this is dropped so sound never lags behind the picture.
    private let maxQueuedFrames = 48_000 / 4

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterRouteChange()
        }
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isMuted: Bool = false {
        didSet { player.volume = isMuted ? 0 : 1 }
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)

        do {
            try engine.start()
            player.play()
            isRunning = true
            queuedFrames = 0
        } catch {
            isRunning = false
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        queuedFrames = 0
    }

    func enqueue(_ packet: AudioPacketMessage) {
        let channels = Int(packet.channels)
        guard channels > 0 else { return }
        let frames = packet.samples.count / (MemoryLayout<Int16>.size * channels)
        guard frames > 0 else { return }

        lock.lock()
        let running = isRunning
        let backlog = queuedFrames
        lock.unlock()
        guard running, backlog < maxQueuedFrames else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let output = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)

        let left = output[0]
        let right = output[1]
        packet.samples.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                let l = Float(Int16(littleEndian: samples[frame * channels])) / 32_768
                left[frame] = l
                right[frame] = channels > 1 ? Float(Int16(littleEndian: samples[frame * channels + 1])) / 32_768 : l
            }
        }

        lock.withLock { queuedFrames += frames }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queuedFrames = max(0, self.queuedFrames - frames) }
        }
    }

    private func restartAfterRouteChange() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        lock.unlock()
        if wasRunning { start() }
    }
}
