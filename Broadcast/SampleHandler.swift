import ReplayKit

/// Entry point of the broadcast extension. iOS hands it every frame of the
/// screen (and app audio) while the user is sharing.
final class SampleHandler: RPBroadcastSampleHandler {
    private var session: HostSession?
    private var stopObserver: DarwinObserver?
    private let controlQueue = DispatchQueue(label: "mirror.broadcast.control")

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let store = SharedStore.shared

        guard let target = store.target else {
            finish("Open Mirror and choose the device you want to share your screen with.")
            return
        }
        guard let code = store.pairingCode(for: target.deviceID) else {
            finish("Open Mirror and pair with \(target.displayName) first.")
            return
        }

        let session = HostSession(target: target, passcode: code)
        session.onFatalError = { [weak self] message in
            self?.finish(message)
        }
        self.session = session

        stopObserver = DarwinObserver(name: MirrorConfig.stopNotification, queue: controlQueue) { [weak self] in
            self?.session?.stop(sendGoodbye: true)
            self?.finish("Mirroring stopped.")
        }

        session.start()
    }

    override func broadcastPaused() {
        session?.setPaused(true)
    }

    override func broadcastResumed() {
        session?.setPaused(false)
    }

    override func broadcastFinished() {
        session?.stop(sendGoodbye: true)
        session = nil
        stopObserver = nil
        SharedStore.shared.broadcastStatus = .idle
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            session?.handleVideo(sampleBuffer)
        case .audioApp:
            session?.handleAudio(sampleBuffer)
        case .audioMic:
            break
        @unknown default:
            break
        }
    }

    private func finish(_ message: String) {
        SharedStore.shared.broadcastStatus = .idle
        let error = NSError(domain: "Mirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(error)
    }
}
