import Foundation
import UIKit

/// Demo mode is only switched on by launch arguments (used for screenshots and the
/// two-simulator simulation in CI). It never runs in a normal launch.
///
///   -MirrorDemo <home|onboarding|connect|settings|inbox|sender>
///   -MirrorDemoName "Ari's iPhone"     name this device
///   -MirrorDemoCode 482913             this device's pairing code
///   -MirrorDemoPairWith 482913         treat the first device found as paired with this code
///   -MirrorDemoTypeCode 482913         type this code on the pairing screen, like a person would
///   -MirrorDemoSendFile                when showing another screen, send it a photo
///   -MirrorDemoStats                   show connection info on the mirror
enum DemoMode {
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func value(_ key: String) -> String? {
        guard let index = arguments.firstIndex(of: "-" + key), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static let screen: String? = value("MirrorDemo")
    static var isEnabled: Bool { screen != nil }
    static var isSender: Bool { screen == "sender" }
    static let name = value("MirrorDemoName")
    static let code = value("MirrorDemoCode")
    static let pairWith = value("MirrorDemoPairWith")
    static let typeCode = value("MirrorDemoTypeCode")
    static let sendFile = arguments.contains("-MirrorDemoSendFile")
    static let showStats = arguments.contains("-MirrorDemoStats")

    static func log(_ message: String) {
        guard isEnabled else { return }
        print("[MirrorDemo] \(message)")
    }

    /// Puts the shared settings into a known state before anything else reads them.
    static func prepareStore() {
        guard isEnabled else { return }
        let store = SharedStore.shared
        store.didOnboard = screen != "onboarding"
        if let name { store.deviceName = name }
        if let code { store.setPairingCode(code) }
        store.forgetAllPairings()
        store.broadcastStatus = .idle
        store.showStats = showStats
        store.quality = .best
        if screen == "inbox" { makeSampleInbox() }
        log("prepared screen=\(screen ?? "-") name=\(store.deviceName) code=\(store.pairingCode)")
    }

    // MARK: Sample files

    static func makeSampleInbox() {
        let folder = SharedStore.shared.inboxURL
        if let existing = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            existing.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let samples: [(String, UIColor, UIColor, String)] = [
            ("Beach Sunset.jpg", .systemOrange, .systemPink, "sun.horizon.fill"),
            ("Mountain Hike.jpg", .systemTeal, .systemIndigo, "mountain.2.fill"),
            ("Birthday Cake.jpg", .systemPink, .systemPurple, "birthday.cake.fill")
        ]
        for (index, sample) in samples.enumerated() {
            let url = folder.appendingPathComponent(sample.0)
            try? samplePhoto(top: sample.1, bottom: sample.2, symbol: sample.3).write(to: url)
            let date = Date().addingTimeInterval(TimeInterval(-index * 1_800 - 120))
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let notes = folder.appendingPathComponent("Shopping List.txt")
        try? "Milk\nBread\nStrawberries\nNew iPad case".write(to: notes, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: notes.path)
        SharedStore.shared.unseenInboxCount = 0
    }

    static func samplePhoto(top: UIColor, bottom: UIColor, symbol: String) -> Data {
        let size = CGSize(width: 600, height: 450)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let config = UIImage.SymbolConfiguration(pointSize: 150, weight: .regular)
            if let glyph = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(.white.withAlphaComponent(0.9), renderingMode: .alwaysOriginal) {
                let rect = CGRect(x: (size.width - glyph.size.width) / 2, y: (size.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: rect)
            }
        }
        return image.jpegData(compressionQuality: 0.85) ?? Data()
    }
}

/// Drives the app through a demo script once it has launched.
final class DemoDriver {
    static var shared: DemoDriver?

    private weak var model: AppModel?
    private var timer: Timer?
    private var sender: DemoSender?
    private var didHandleDevice = false
    private var didSendFile = false

    static func start(with model: AppModel) {
        guard DemoMode.isEnabled else { return }
        let driver = DemoDriver(model: model)
        shared = driver
        driver.begin()
    }

    private init(model: AppModel) {
        self.model = model
    }

    private func begin() {
        guard let model else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            switch DemoMode.screen {
            case "settings": model.showSettings = true
            case "inbox": model.showInbox = true
            default: break
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let model else { return }

        if !didHandleDevice, DemoMode.screen == "connect" || DemoMode.isSender, let device = model.browser.devices.first {
            didHandleDevice = true
            DemoMode.log("found \(device.serviceName)")
            if let code = DemoMode.pairWith { model.savePairing(code, for: device) }
            if DemoMode.screen == "connect" {
                model.selectedDevice = device
            } else {
                model.prepareBroadcast(to: device)
                let sender = DemoSender(device: device, passcode: DemoMode.pairWith ?? "")
                self.sender = sender
                sender.start()
                model.broadcast.refresh()
            }
        }

        if DemoMode.sendFile, !didSendFile, model.receiver.hasVideo {
            didSendFile = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("Photo from \(DeviceKind.current.displayName).jpg")
                try? DemoMode.samplePhoto(top: .systemBlue, bottom: .systemPurple, symbol: "photo.fill").write(to: url)
                DemoMode.log("sending file \(url.lastPathComponent)")
                model.receiver.sendFile(at: url)
            }
        }
    }
}
