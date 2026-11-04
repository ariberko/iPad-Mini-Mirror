import Foundation
import Network
import Observation

struct NearbyDevice: Identifiable, Hashable {
    /// Stable ID that survives renames.
    let id: String
    /// Current Bonjour name, used to connect.
    let serviceName: String
    let kind: DeviceKind
}

/// Finds other devices running Mirror nearby.
@Observable
final class DeviceBrowser {
    private(set) var devices: [NearbyDevice] = []
    private(set) var localNetworkDenied = false

    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MirrorConfig.serviceType, domain: nil), using: parameters)
        let myID = SharedStore.shared.deviceID

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> NearbyDevice? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                var id = name
                var kind = DeviceKind.iPad
                if case let .bonjour(record) = result.metadata {
                    id = record["id"] ?? name
                    kind = DeviceKind(rawValue: record["kind"] ?? "") ?? .iPad
                }
                guard id != myID else { return nil }
                return NearbyDevice(id: id, serviceName: name, kind: kind)
            }
            // The same device can show up once per network interface.
            var unique: [String: NearbyDevice] = [:]
            for device in found { unique[device.id] = device }
            let sorted = unique.values.sorted { $0.serviceName.localizedCaseInsensitiveCompare($1.serviceName) == .orderedAscending }
            self?.devices = sorted
        }

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.localNetworkDenied = false
            case .waiting(let error):
                if case .dns(let code) = error, code == -65570 { self.localNetworkDenied = true }
            case .failed:
                browser?.cancel()
                self.browser = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.start() }
            default:
                break
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
