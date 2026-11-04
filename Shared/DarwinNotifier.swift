import Foundation

/// Tiny cross-process signal used between the app and the broadcast extension.
enum DarwinNotifier {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }
}

/// Observes a Darwin notification for as long as the object is alive.
final class DarwinObserver {
    private let name: String
    private let queue: DispatchQueue
    private let handler: () -> Void

    init(name: String, queue: DispatchQueue = .main, handler: @escaping () -> Void) {
        self.name = name
        self.queue = queue
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                me.queue.async { me.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
