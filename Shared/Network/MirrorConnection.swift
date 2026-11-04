import Foundation
import Network

/// A thin, message-based wrapper around `NWConnection`.
/// All callbacks run on the queue passed in at creation.
final class MirrorConnection {
    enum CloseReason: Equatable {
        case cancelled
        case wrongCode
        case failed(String)

        var message: String? {
            switch self {
            case .cancelled: return nil
            case .wrongCode: return "The pairing code didn't match."
            case .failed(let message): return message
            }
        }
    }

    let connection: NWConnection
    let queue: DispatchQueue

    var onReady: (() -> Void)?
    var onMessage: ((MessageType, Data) -> Void)?
    var onClose: ((CloseReason) -> Void)?

    private let lock = NSLock()
    private var _bytesInFlight = 0
    private var isClosed = false

    /// Bytes handed to `send` that the network stack has not taken yet.
    /// Used to skip video frames when Wi-Fi can't keep up, so latency stays low.
    var bytesInFlight: Int { lock.withLock { _bytesInFlight } }

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    convenience init(endpoint: NWEndpoint, passcode: String?, queue: DispatchQueue) {
        self.init(connection: NWConnection(to: endpoint, using: .mirror(passcode: passcode)), queue: queue)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.stateChanged(state)
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ type: MessageType, _ data: Data, completion: ((Bool) -> Void)? = nil) {
        // Zero-length messages are avoided so every message carries a payload.
        let payload = data.isEmpty ? Data([0]) : data
        let message = NWProtocolFramer.Message(mirrorMessageType: type)
        let context = NWConnection.ContentContext(identifier: "mirror", metadata: [message])
        let size = payload.count
        lock.withLock { _bytesInFlight += size }
        connection.send(content: payload, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if let self {
                self.lock.withLock { self._bytesInFlight -= size }
            }
            completion?(error == nil)
        })
    }

    // MARK: Private

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onReady?()
            receiveNext()
        case .waiting(let error):
            if case .tls = error { close(.wrongCode) }
        case .failed(let error):
            if case .tls = error {
                close(.wrongCode)
            } else {
                close(.failed(error.localizedDescription))
            }
        case .cancelled:
            close(.cancelled)
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let message = context?.protocolMetadata(definition: MirrorFramer.definition) as? NWProtocolFramer.Message {
                self.onMessage?(message.mirrorMessageType, content ?? Data())
            }
            if let error {
                if case .tls = error {
                    self.close(.wrongCode)
                } else {
                    self.close(.failed(error.localizedDescription))
                }
                return
            }
            if content == nil, isComplete, context?.isFinal ?? true {
                self.close(.cancelled)
                return
            }
            self.receiveNext()
        }
    }

    private func close(_ reason: CloseReason) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        let handler = onClose
        onReady = nil
        onMessage = nil
        onClose = nil
        handler?(reason)
    }
}
