import Foundation
import Network

/// Splits the TCP byte stream into typed messages:
/// [4 bytes type][4 bytes length][payload]
final class MirrorFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: MirrorFramer.self)
    static var label: String { "Mirror" }

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .ready }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}

    func handleOutput(framer: NWProtocolFramer.Instance,
                      message: NWProtocolFramer.Message,
                      messageLength: Int,
                      isComplete: Bool) {
        let header = MirrorFrameHeader(type: message.mirrorMessageType.rawValue, length: UInt32(messageLength))
        framer.writeOutput(data: header.encodedData)
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            // The connection reports the failure through its state handler.
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var parsedHeader: MirrorFrameHeader?
            let headerSize = MirrorFrameHeader.encodedSize
            let parsed = framer.parseInput(minimumIncompleteLength: headerSize, maximumLength: headerSize) { buffer, _ in
                guard let buffer, buffer.count >= headerSize else { return 0 }
                parsedHeader = MirrorFrameHeader(buffer)
                return headerSize
            }
            guard parsed, let header = parsedHeader else { return headerSize }

            let type = MessageType(rawValue: header.type) ?? .invalid
            let message = NWProtocolFramer.Message(mirrorMessageType: type)
            if !framer.deliverInputNoCopy(length: Int(header.length), message: message, isComplete: true) {
                return 0
            }
        }
    }
}

struct MirrorFrameHeader {
    static let encodedSize = 8

    let type: UInt32
    let length: UInt32

    init(type: UInt32, length: UInt32) {
        self.type = type
        self.length = length
    }

    init(_ buffer: UnsafeMutableRawBufferPointer) {
        var rawType: UInt32 = 0
        var rawLength: UInt32 = 0
        withUnsafeMutableBytes(of: &rawType) {
            $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[0..<4]))
        }
        withUnsafeMutableBytes(of: &rawLength) {
            $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: buffer[4..<8]))
        }
        type = UInt32(bigEndian: rawType)
        length = UInt32(bigEndian: rawLength)
    }

    var encodedData: Data {
        var writer = ByteWriter(capacity: Self.encodedSize)
        writer.write(type)
        writer.write(length)
        return writer.data
    }
}

extension NWProtocolFramer.Message {
    convenience init(mirrorMessageType: MessageType) {
        self.init(definition: MirrorFramer.definition)
        self["MirrorMessageType"] = mirrorMessageType
    }

    var mirrorMessageType: MessageType {
        self["MirrorMessageType"] as? MessageType ?? .invalid
    }
}
