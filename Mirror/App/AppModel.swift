import Foundation
import Observation
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let mirrorOpenInbox = Notification.Name("MirrorOpenInbox")
}

/// The app's single source of truth. Lives on the main thread.
@Observable
final class AppModel {
    let receiver = ReceiverService()
    let browser = DeviceBrowser()
    let broadcast = BroadcastMonitor()

    // Navigation
    var selectedDevice: NearbyDevice?
    var showSettings = false
    var showInbox = false
    var showMirror = false
    var pairPrompt: PairPrompt?
    var toast: Toast?

    // Settings mirrored from the shared store
    private(set) var deviceName: String
    private(set) var pairingCode: String
    private(set) var unseenInboxCount: Int
    private(set) var inboxVersion = 0
    private(set) var pairingsVersion = 0
    var showOnboarding: Bool

    var quality: StreamQuality {
        didSet { store.quality = quality }
    }
    var shareAudio: Bool {
        didSet { store.shareAudio = shareAudio }
    }
    var showStats: Bool {
        didSet { store.showStats = showStats }
    }

    @ObservationIgnored private let store = SharedStore.shared
    @ObservationIgnored private var inboxObserver: DarwinObserver?
    @ObservationIgnored private var openInboxObserver: NSObjectProtocol?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let symbol: String
        let title: String
    }

    init() {
        DemoMode.prepareStore()
        deviceName = store.deviceName
        pairingCode = store.pairingCode
        unseenInboxCount = store.unseenInboxCount
        quality = store.quality
        shareAudio = store.shareAudio
        showStats = store.showStats
        showOnboarding = !store.didOnboard

        receiver.onSessionStarted = { [weak self] in
            self?.presentMirror()
        }
        receiver.onSessionEnded = { [weak self] in
            guard let self else { return }
            // Let the "stopped sharing" message show for a moment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if case .ended = self.receiver.phase {
                    self.showMirror = false
                    self.receiver.resetAfterEnd()
                }
            }
        }
        receiver.onPairRequest = { [weak self] prompt in
            self?.presentPairPrompt(prompt)
        }
        receiver.onPaired = { [weak self] name in
            guard let self else { return }
            self.pairPrompt = nil
            self.showToast(symbol: "checkmark.circle.fill", title: "Paired with \(name)")
        }
        receiver.onRestoreFromPictureInPicture = { [weak self] in
            guard let self, self.receiver.isMirroring else { return }
            self.showMirror = true
        }

        inboxObserver = DarwinObserver(name: MirrorConfig.inboxNotification) { [weak self] in
            self?.refreshInbox()
        }
        openInboxObserver = NotificationCenter.default.addObserver(forName: .mirrorOpenInbox, object: nil, queue: .main) { [weak self] _ in
            self?.openInbox()
        }

        DemoDriver.start(with: self)
    }

    // MARK: Lifecycle

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            receiver.start()
            browser.start()
            broadcast.refresh()
            refreshInbox()
        case .background:
            // Keep the connection while showing a screen (Picture in Picture keeps the app running).
            if !receiver.isMirroring {
                receiver.stop()
                browser.stop()
            }
        default:
            break
        }
    }

    func finishOnboarding() {
        store.didOnboard = true
        showOnboarding = false
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: Devices

    func isPaired(_ device: NearbyDevice) -> Bool {
        _ = pairingsVersion
        return store.pairingCode(for: device.id) != nil
    }

    func savedCode(for device: NearbyDevice) -> String? {
        store.pairingCode(for: device.id)
    }

    func savePairing(_ code: String, for device: NearbyDevice) {
        store.savePairing(code: code, for: device.id)
        pairingsVersion += 1
    }

    func removePairing(for device: NearbyDevice) {
        store.removePairing(for: device.id)
        pairingsVersion += 1
    }

    func forgetAllPairings() {
        store.forgetAllPairings()
        pairingsVersion += 1
        showToast(symbol: "trash", title: "Forgot all devices")
    }

    var pairedDeviceCount: Int {
        _ = pairingsVersion
        return store.pairedDeviceCount
    }

    /// Remembers where the broadcast extension should stream to.
    func prepareBroadcast(to device: NearbyDevice) {
        store.target = BroadcastTarget(
            deviceID: device.id,
            serviceName: device.serviceName,
            displayName: device.serviceName,
            kind: device.kind)
    }

    func isSharing(to device: NearbyDevice) -> Bool {
        broadcast.isActive && store.target?.deviceID == device.id
    }

    // MARK: Settings

    func rename(to name: String) {
        store.deviceName = name
        deviceName = store.deviceName
        receiver.restart()
    }

    func changePairingCode() {
        pairingCode = store.resetPairingCode()
        receiver.restart()
        showToast(symbol: "number.circle.fill", title: "New code \(Self.format(code: pairingCode))")
    }

    static func format(code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    // MARK: Inbox

    func refreshInbox() {
        unseenInboxCount = store.unseenInboxCount
        inboxVersion += 1
    }

    func markInboxSeen() {
        store.unseenInboxCount = 0
        unseenInboxCount = 0
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    func openInbox() {
        dismissSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showInbox = true }
    }

    // MARK: Presentation

    private func dismissSheets() {
        selectedDevice = nil
        showSettings = false
        showInbox = false
        pairPrompt = nil
    }

    private func presentMirror() {
        dismissSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if self.receiver.isMirroring { self.showMirror = true }
        }
    }

    private func presentPairPrompt(_ prompt: PairPrompt) {
        guard !showMirror else { return }
        dismissSheets()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.pairPrompt = prompt }
    }

    func showToast(symbol: String, title: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.4)) { toast = Toast(symbol: symbol, title: title) }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
        }
    }
}
