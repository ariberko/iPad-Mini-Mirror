import CryptoKit
import Foundation
import Network
import Security

extension NWParameters {
    /// Parameters for a Mirror connection.
    ///
    /// - With a passcode, the connection is encrypted with TLS using a key derived
    ///   from the 6-digit pairing code. A device with the wrong code cannot connect.
    /// - Without a passcode, it is plain TCP. Only used to ask a device to show its code.
    ///
    /// Peer-to-peer Wi-Fi is enabled, so devices find each other even when they
    /// are not on the same Wi-Fi network.
    static func mirror(passcode: String?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 4
        tcp.connectionTimeout = 8

        let parameters: NWParameters
        if let passcode {
            parameters = NWParameters(tls: tlsOptions(passcode: passcode), tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo

        let framer = NWProtocolFramer.Options(definition: MirrorFramer.definition)
        parameters.defaultProtocolStack.applicationProtocols.insert(framer, at: 0)
        return parameters
    }

    private static func tlsOptions(passcode: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()

        let key = SymmetricKey(data: Data(passcode.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: Data(MirrorConfig.pskIdentity.utf8), using: key)
        let pskData = authenticationCode.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(MirrorConfig.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            options.securityProtocolOptions,
            pskData as __DispatchData,
            identityData as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        return options
    }
}

extension NWEndpoint {
    static func mirrorService(named name: String) -> NWEndpoint {
        .service(name: name, type: MirrorConfig.serviceType, domain: "local.", interface: nil)
    }

    static func mirrorPairService(named name: String) -> NWEndpoint {
        .service(name: name, type: MirrorConfig.pairServiceType, domain: "local.", interface: nil)
    }
}
