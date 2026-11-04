import UIKit

enum DeviceKind: String, Codable, Hashable {
    case iPhone
    case iPad

    /// Resolved once so it can be read safely from any thread later.
    static let current: DeviceKind = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone

    var symbolName: String { self == .iPad ? "ipad" : "iphone" }
    var landscapeSymbolName: String { self == .iPad ? "ipad.landscape" : "iphone.landscape" }
    var displayName: String { rawValue }

    /// Roughly how round the physical screen corners are, relative to the short side.
    /// Used to draw the mirrored screen with the same soft corners as the real device.
    var screenCornerFraction: CGFloat { self == .iPad ? 0.032 : 0.14 }
}
