import Foundation

// MARK: - Message types

enum MessageType: UInt32 {
    case invalid = 0

    // Session
    case hello = 1
    case helloAck = 2
    case goodbye = 3
    case pairRequest = 5

    // Video
    case videoFormat = 10
    case videoFrame = 11
    case requestKeyFrame = 12

    // Audio
    case audioPacket = 20

    // Files (viewer -> host)
    case fileStart = 30
    case fileChunk = 31
    case fileEnd = 32
    case fileCancel = 33
    case fileReceived = 34

    // Health
    case ping = 40
    case pong = 41
}

enum WireError: Error {
    case truncated
    case invalid
}

// MARK: - Byte helpers

struct ByteWriter {
    private(set) var data = Data()

    init(capacity: Int = 64) {
        data.reserveCapacity(capacity)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    mutating func writeLengthPrefixed(_ bytes: Data) {
        write(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func write(_ string: String) {
        writeLengthPrefixed(Data(string.utf8))
    }

    mutating func write(_ uuid: UUID) {
        var raw = uuid.uuid
        withUnsafeBytes(of: &raw) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { throw WireError.truncated }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { destination in
            _ = data.copyBytes(to: destination, from: offset..<(offset + size))
        }
        offset += size
        return T(bigEndian: value)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw WireError.truncated }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func readLengthPrefixed() throws -> Data {
        let count = Int(try read(UInt32.self))
        return try readData(count: count)
    }

    mutating func readString() throws -> String {
        guard let string = String(data: try readLengthPrefixed(), encoding: .utf8) else { throw WireError.invalid }
        return string
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readData(count: 16)
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }

    mutating func readRest() -> Data {
        let rest = data.subdata(in: offset..<data.endIndex)
        offset = data.endIndex
        return rest
    }
}

// MARK: - JSON messages

enum HelloPurpose: String, Codable {
    /// Start streaming the screen.
    case mirror
    /// First successful pairing. The receiver shows a confirmation.
    case pair
    /// Silent check that the code still works and the device is reachable.
    case probe
}

struct HelloMessage: Codable {
    var deviceID: String
    var deviceName: String
    var kind: DeviceKind
    var purpose: HelloPurpose
    var protocolVersion: Int
    var appVersion: String
}

struct HelloAckMessage: Codable {
    var accepted: Bool
    var deviceName: String
    var kind: DeviceKind
    var reason: String?
}

struct GoodbyeMessage: Codable {
    var reason: String?
}

struct PairRequestMessage: Codable {
    var deviceName: String
    var kind: DeviceKind
}

extension Encodable {
    func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

extension Decodable {
    static func fromJSON(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

// MARK: - Binary messages

enum VideoCodec: UInt8 {
    case h264 = 0
    case hevc = 1

    var name: String { self == .hevc ? "HEVC" : "H.264" }
}

struct VideoFormatMessage {
    var codec: VideoCodec
    var parameterSets: [Data]

    func encoded() -> Data {
        var writer = ByteWriter(capacity: 128)
        writer.write(codec.rawValue)
        writer.write(UInt8(parameterSets.count))
        for set in parameterSets { writer.writeLengthPrefixed(set) }
        return writer.data
    }

    init(codec: VideoCodec, parameterSets: [Data]) {
        self.codec = codec
        self.parameterSets = parameterSets
    }

    init?(_ data: Data) {
        var reader = ByteReader(data)
        guard let rawCodec = try? reader.read(UInt8.self),
              let codec = VideoCodec(rawValue: rawCodec),
              let count = try? reader.read(UInt8.self) else { return nil }
        var sets: [Data] = []
        for _ in 0..<count {
            guard let set = try? reader.readLengthPrefixed() else { return nil }
            sets.append(set)
        }
        self.codec = codec
        self.parameterSets = sets
    }
}

struct VideoFrameMessage {
    var isKeyFrame: Bool
    var timestampMicros: Int64
    /// Length-prefixed (AVCC / HVCC) NAL units, exactly as VideoToolbox produced them.
    var data: Data

    func encoded() -> Data {
        var writer = ByteWriter(capacity: data.count + 16)
        writer.write(UInt8(isKeyFrame ? 1 : 0))
        writer.write(timestampMicros)
        writer.write(data)
        return writer.data
    }

    init(isKeyFrame: Bool, timestampMicros: Int64, data: Data) {
        self.isKeyFrame = isKeyFrame
        self.timestampMicros = timestampMicros
        self.data = data
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let flags = try? reader.read(UInt8.self),
              let timestamp = try? reader.read(Int64.self) else { return nil }
        isKeyFrame = flags & 1 == 1
        timestampMicros = timestamp
        data = reader.readRest()
    }
}

struct AudioPacketMessage {
    var sampleRate: UInt32
    var channels: UInt8
    /// Interleaved, little-endian, signed 16-bit PCM.
    var samples: Data

    func encoded() -> Data {
        var writer = ByteWriter(capacity: samples.count + 8)
        writer.write(sampleRate)
        writer.write(channels)
        writer.write(samples)
        return writer.data
    }

    init(sampleRate: UInt32, channels: UInt8, samples: Data) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let rate = try? reader.read(UInt32.self),
              let channels = try? reader.read(UInt8.self) else { return nil }
        self.sampleRate = rate
        self.channels = channels
        self.samples = reader.readRest()
    }
}

struct FileStartMessage {
    var id: UUID
    var size: UInt64
    var name: String
    var typeIdentifier: String

    func encoded() -> Data {
        var writer = ByteWriter()
        writer.write(id)
        writer.write(size)
        writer.write(name)
        writer.write(typeIdentifier)
        return writer.data
    }

    init(id: UUID, size: UInt64, name: String, typeIdentifier: String) {
        self.id = id
        self.size = size
        self.name = name
        self.typeIdentifier = typeIdentifier
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let id = try? reader.readUUID(),
              let size = try? reader.read(UInt64.self),
              let name = try? reader.readString(),
              let type = try? reader.readString() else { return nil }
        self.id = id
        self.size = size
        self.name = name
        self.typeIdentifier = type
    }
}

struct FileChunkMessage {
    var id: UUID
    var data: Data

    func encoded() -> Data {
        var writer = ByteWriter(capacity: data.count + 16)
        writer.write(id)
        writer.write(data)
        return writer.data
    }

    init(id: UUID, data: Data) {
        self.id = id
        self.data = data
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let id = try? reader.readUUID() else { return nil }
        self.id = id
        self.data = reader.readRest()
    }
}

struct FileIDMessage {
    var id: UUID

    func encoded() -> Data {
        var writer = ByteWriter(capacity: 16)
        writer.write(id)
        return writer.data
    }

    init(id: UUID) {
        self.id = id
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let id = try? reader.readUUID() else { return nil }
        self.id = id
    }
}

struct PingMessage {
    var nanoseconds: UInt64

    func encoded() -> Data {
        var writer = ByteWriter(capacity: 8)
        writer.write(nanoseconds)
        return writer.data
    }

    init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    init?(_ payload: Data) {
        var reader = ByteReader(payload)
        guard let value = try? reader.read(UInt64.self) else { return nil }
        nanoseconds = value
    }
}
