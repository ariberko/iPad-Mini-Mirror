import Foundation

/// Sends files to the device that is sharing its screen, one after another,
/// in small pieces so the live picture stays smooth.
final class FileSender {
    struct Item {
        let id: UUID
        let url: URL
        let name: String
        let typeIdentifier: String
    }

    var onProgress: ((UUID, Double) -> Void)?
    var onFinished: ((UUID, Bool) -> Void)?

    private let connection: MirrorConnection
    private let queue: DispatchQueue
    private let chunkSize = 256 * 1024

    private var pending: [Item] = []
    private var current: (item: Item, handle: FileHandle, size: UInt64, sent: UInt64)?
    private var awaitingConfirmation: Set<UUID> = []

    init(connection: MirrorConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func enqueue(_ item: Item) {
        queue.async {
            self.pending.append(item)
            self.pump()
        }
    }

    /// The other device saved the file.
    func confirm(_ id: UUID) {
        queue.async {
            guard self.awaitingConfirmation.remove(id) != nil else { return }
            self.onFinished?(id, true)
        }
    }

    func cancelAll() {
        queue.async {
            if let current = self.current {
                try? current.handle.close()
                self.onFinished?(current.item.id, false)
            }
            self.current = nil
            for item in self.pending { self.onFinished?(item.id, false) }
            self.pending.removeAll()
            for id in self.awaitingConfirmation { self.onFinished?(id, false) }
            self.awaitingConfirmation.removeAll()
        }
    }

    // MARK: Private (on queue)

    private func pump() {
        guard current == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()

        guard let handle = try? FileHandle(forReadingFrom: item.url) else {
            onFinished?(item.id, false)
            pump()
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: item.url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        current = (item, handle, size, 0)

        let start = FileStartMessage(id: item.id, size: size, name: item.name, typeIdentifier: item.typeIdentifier)
        connection.send(.fileStart, start.encoded())
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard let current else { return }

        let data: Data
        do {
            data = try current.handle.read(upToCount: chunkSize) ?? Data()
        } catch {
            connection.send(.fileCancel, FileIDMessage(id: current.item.id).encoded())
            try? current.handle.close()
            onFinished?(current.item.id, false)
            self.current = nil
            pump()
            return
        }

        if data.isEmpty {
            try? current.handle.close()
            connection.send(.fileEnd, FileIDMessage(id: current.item.id).encoded())
            awaitingConfirmation.insert(current.item.id)
            onProgress?(current.item.id, 1)
            self.current = nil
            pump()
            return
        }

        let id = current.item.id
        connection.send(.fileChunk, FileChunkMessage(id: id, data: data).encoded()) { [weak self] success in
            guard let self else { return }
            self.queue.async {
                guard success, var active = self.current, active.item.id == id else { return }
                active.sent += UInt64(data.count)
                self.current = active
                if active.size > 0 {
                    self.onProgress?(id, min(0.99, Double(active.sent) / Double(active.size)))
                }
                self.sendNextChunk()
            }
        }
    }
}
