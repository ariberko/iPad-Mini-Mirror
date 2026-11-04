import Foundation
import Network

/// Checks pairing codes and asks other devices to show theirs.
enum PairingService {
    enum Result {
        case success
        case wrongCode
        case unreachable
    }

    /// Opens an encrypted connection with `code`. It only succeeds if the code matches.
    static func verify(device: NearbyDevice, code: String, purpose: HelloPurpose) async -> Result {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "mirror.pairing")
            let once = ResumeOnce(continuation)
            let connection = MirrorConnection(endpoint: .mirrorService(named: device.serviceName), passcode: code, queue: queue)
            let store = SharedStore.shared

            connection.onReady = { [weak connection] in
                let hello = HelloMessage(
                    deviceID: store.deviceID,
                    deviceName: store.deviceName,
                    kind: .current,
                    purpose: purpose,
                    protocolVersion: MirrorConfig.protocolVersion,
                    appVersion: MirrorConfig.appVersion)
                connection?.send(.hello, hello.jsonData())
            }
            connection.onMessage = { [weak connection] type, data in
                guard type == .helloAck else { return }
                let accepted = HelloAckMessage.fromJSON(data)?.accepted ?? false
                once.resume(accepted ? .success : .unreachable)
                connection?.cancel()
            }
            connection.onClose = { reason in
                once.resume(reason == .wrongCode ? .wrongCode : .unreachable)
            }
            connection.start()

            queue.asyncAfter(deadline: .now() + 8) {
                once.resume(.unreachable)
                connection.cancel()
            }
        }
    }

    /// Asks the other device to show its pairing code on screen.
    static func requestCode(from device: NearbyDevice) {
        let queue = DispatchQueue(label: "mirror.pair-request")
        let connection = MirrorConnection(endpoint: .mirrorPairService(named: device.serviceName), passcode: nil, queue: queue)
        let store = SharedStore.shared
        connection.onReady = { [weak connection] in
            let request = PairRequestMessage(deviceName: store.deviceName, kind: .current)
            connection?.send(.pairRequest, request.jsonData()) { _ in
                queue.asyncAfter(deadline: .now() + 0.5) { connection?.cancel() }
            }
        }
        connection.start()
        queue.asyncAfter(deadline: .now() + 6) { connection.cancel() }
    }
}

private final class ResumeOnce {
    private var continuation: CheckedContinuation<PairingService.Result, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<PairingService.Result, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: PairingService.Result) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
