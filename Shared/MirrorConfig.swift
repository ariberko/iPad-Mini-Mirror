import Foundation

/// App-wide constants shared by the app and the broadcast extension.
enum MirrorConfig {
    /// Bonjour service used for the encrypted mirroring connection.
    static let serviceType = "_ipmirror._tcp"
    /// Bonjour service used only to ask a device to show its pairing code.
    static let pairServiceType = "_ipmirror-pair._tcp"
    static let protocolVersion = 1
    static let pskIdentity = "MirrorPairing.v1"

    /// The App Group shared by the app and the broadcast extension.
    /// Injected through Info.plist from the `APP_GROUP_ID` build setting.
    static let appGroupID: String = {
        if let id = Bundle.main.object(forInfoDictionaryKey: "MirrorAppGroupID") as? String,
           !id.isEmpty, !id.contains("$(") {
            return id
        }
        return "group.com.example.mirror"
    }()

    static var statusNotification: String { appGroupID + ".broadcast-status" }
    static var stopNotification: String { appGroupID + ".broadcast-stop" }
    static var inboxNotification: String { appGroupID + ".inbox" }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
