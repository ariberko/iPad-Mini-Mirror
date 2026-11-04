import Observation
import ReplayKit
import UIKit

/// Tracks whether this device is currently sharing its screen.
@Observable
final class BroadcastMonitor {
    private(set) var status: BroadcastStatus = .idle
    private(set) var isCaptured = false

    @ObservationIgnored private var statusObserver: DarwinObserver?
    @ObservationIgnored private var captureObserver: NSObjectProtocol?

    init() {
        refresh()
        statusObserver = DarwinObserver(name: MirrorConfig.statusNotification) { [weak self] in
            self?.refresh()
        }
        captureObserver = NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        if let captureObserver { NotificationCenter.default.removeObserver(captureObserver) }
    }

    /// True while the extension is connecting to or streaming to another device.
    var isActive: Bool {
        status.state != .idle && isCaptured
    }

    var isLive: Bool { isActive && status.state == .live }

    func refresh() {
        status = SharedStore.shared.broadcastStatus
        isCaptured = UIScreen.main.isCaptured
    }

    func stop() {
        DarwinNotifier.post(MirrorConfig.stopNotification)
    }
}

/// Opens the system "Start Broadcast" sheet with Mirror already selected.
final class BroadcastLauncher {
    static let shared = BroadcastLauncher()

    let pickerView: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".broadcast"
        picker.showsMicrophoneButton = false
        return picker
    }()

    func launch() {
        if let button = Self.findButton(in: pickerView) {
            button.sendActions(for: .allTouchEvents)
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }
}
