import Foundation
import UIKit

enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case best
    case balanced
    case batterySaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .best: return "Best"
        case .balanced: return "Balanced"
        case .batterySaver: return "Battery Saver"
        }
    }

    var detail: String {
        switch self {
        case .best: return "Full resolution at up to 60 frames per second. Sharpest text."
        case .balanced: return "A little softer, but smooth even on busy Wi-Fi."
        case .batterySaver: return "Lower resolution at 30 frames per second. Uses the least battery."
        }
    }

    /// Longest side of the streamed picture, in pixels.
    var maxLongSide: Int {
        switch self {
        case .best: return 4096
        case .balanced: return 1920
        case .batterySaver: return 1280
        }
    }

    var bitRate: Int {
        switch self {
        case .best: return 14_000_000
        case .balanced: return 8_000_000
        case .batterySaver: return 3_500_000
        }
    }

    var frameRate: Int { self == .batterySaver ? 30 : 60 }
}

/// The device the broadcast extension should stream to.
struct BroadcastTarget: Codable, Equatable {
    var deviceID: String
    var serviceName: String
    var displayName: String
    var kind: DeviceKind
}

struct BroadcastStatus: Codable, Equatable {
    enum State: String, Codable {
        case idle
        case connecting
        case live
        case reconnecting
    }

    var state: State
    var peerName: String?
    var peerKind: DeviceKind?
    var startedAt: Date?
    var updatedAt: Date

    static var idle: BroadcastStatus {
        BroadcastStatus(state: .idle, peerName: nil, peerKind: nil, startedAt: nil, updatedAt: Date())
    }
}

/// Settings and state shared between the app and the broadcast extension through the App Group.
final class SharedStore {
    static let shared = SharedStore()

    let defaults: UserDefaults

    private enum Key {
        static let deviceID = "deviceID"
        static let deviceName = "deviceName"
        static let pairingCode = "pairingCode"
        static let pairings = "pairings"
        static let target = "broadcastTarget"
        static let quality = "streamQuality"
        static let shareAudio = "shareAudio"
        static let status = "broadcastStatus"
        static let showStats = "showStats"
        static let unseenInbox = "unseenInboxCount"
        static let didOnboard = "didOnboard"
    }

    private init() {
        defaults = UserDefaults(suiteName: MirrorConfig.appGroupID) ?? .standard
    }

    // MARK: Identity

    var deviceID: String {
        if let id = defaults.string(forKey: Key.deviceID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.deviceID)
        return id
    }

    var deviceName: String {
        get {
            let saved = defaults.string(forKey: Key.deviceName)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let saved, !saved.isEmpty { return saved }
            return DeviceKind.current == .iPad ? "My iPad" : "My iPhone"
        }
        set {
            let trimmed = String(newValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Key.deviceName)
        }
    }

    var hasCustomName: Bool { defaults.string(forKey: Key.deviceName) != nil }

    // MARK: Pairing

    /// The code other devices must enter to mirror to this device.
    var pairingCode: String {
        if let code = defaults.string(forKey: Key.pairingCode), code.count == 6 { return code }
        return resetPairingCode()
    }

    @discardableResult
    func resetPairingCode() -> String {
        let code = String(format: "%06d", Int.random(in: 0...999_999))
        defaults.set(code, forKey: Key.pairingCode)
        return code
    }

    private var pairings: [String: String] {
        get { defaults.dictionary(forKey: Key.pairings) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Key.pairings) }
    }

    func pairingCode(for deviceID: String) -> String? { pairings[deviceID] }

    func savePairing(code: String, for deviceID: String) {
        var all = pairings
        all[deviceID] = code
        pairings = all
    }

    func removePairing(for deviceID: String) {
        var all = pairings
        all[deviceID] = nil
        pairings = all
    }

    func forgetAllPairings() { pairings = [:] }

    var pairedDeviceCount: Int { pairings.count }

    // MARK: Streaming

    var target: BroadcastTarget? {
        get { decode(BroadcastTarget.self, forKey: Key.target) }
        set { encode(newValue, forKey: Key.target) }
    }

    var quality: StreamQuality {
        get { StreamQuality(rawValue: defaults.string(forKey: Key.quality) ?? "") ?? .best }
        set { defaults.set(newValue.rawValue, forKey: Key.quality) }
    }

    var shareAudio: Bool {
        get { defaults.object(forKey: Key.shareAudio) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.shareAudio) }
    }

    var showStats: Bool {
        get { defaults.bool(forKey: Key.showStats) }
        set { defaults.set(newValue, forKey: Key.showStats) }
    }

    var didOnboard: Bool {
        get { defaults.bool(forKey: Key.didOnboard) }
        set { defaults.set(newValue, forKey: Key.didOnboard) }
    }

    var broadcastStatus: BroadcastStatus {
        get { decode(BroadcastStatus.self, forKey: Key.status) ?? .idle }
        set {
            encode(newValue, forKey: Key.status)
            DarwinNotifier.post(MirrorConfig.statusNotification)
        }
    }

    // MARK: Inbox

    var unseenInboxCount: Int {
        get { defaults.integer(forKey: Key.unseenInbox) }
        set { defaults.set(max(0, newValue), forKey: Key.unseenInbox) }
    }

    var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: MirrorConfig.appGroupID)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var inboxURL: URL {
        let url = containerURL.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var partialFilesURL: URL {
        let url = containerURL.appendingPathComponent("Partial", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Helpers

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
