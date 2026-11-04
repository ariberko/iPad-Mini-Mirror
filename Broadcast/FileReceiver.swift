import Foundation
import UserNotifications

/// Receives files dropped onto the mirror on the other device and saves them to the shared Inbox.
/// Files are written straight to disk in small pieces, so big videos never fill memory.
final class FileReceiver {
    private struct Incoming {
        let name: String
        let expectedSize: UInt64
        var receivedSize: UInt64
        let handle: FileHandle
        let partialURL: URL
    }

    private let peerName: String
    private let store = SharedStore.shared
    private var incoming: [UUID: Incoming] = [:]

    init(peerName: String) {
        self.peerName = peerName
    }

    func handle(_ type: MessageType, _ data: Data, reply: (MessageType, Data) -> Void) {
        switch type {
        case .fileStart:
            guard let message = FileStartMessage(data) else { return }
            begin(message)

        case .fileChunk:
            guard let message = FileChunkMessage(data), var file = incoming[message.id] else { return }
            do {
                try file.handle.write(contentsOf: message.data)
                file.receivedSize += UInt64(message.data.count)
                incoming[message.id] = file
            } catch {
                discard(message.id)
            }

        case .fileEnd:
            guard let message = FileIDMessage(data) else { return }
            if finish(message.id) {
                reply(.fileReceived, FileIDMessage(id: message.id).encoded())
            }

        case .fileCancel:
            guard let message = FileIDMessage(data) else { return }
            discard(message.id)

        default:
            break
        }
    }

    func cancelAll() {
        for id in incoming.keys { discard(id) }
    }

    // MARK: Private

    private func begin(_ message: FileStartMessage) {
        let partialURL = store.partialFilesURL.appendingPathComponent(message.id.uuidString)
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partialURL) else { return }
        incoming[message.id] = Incoming(
            name: Self.safeName(message.name),
            expectedSize: message.size,
            receivedSize: 0,
            handle: handle,
            partialURL: partialURL)
    }

    private func finish(_ id: UUID) -> Bool {
        guard let file = incoming.removeValue(forKey: id) else { return false }
        try? file.handle.close()

        let destination = Self.uniqueURL(for: file.name, in: store.inboxURL)
        do {
            try FileManager.default.moveItem(at: file.partialURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: file.partialURL)
            return false
        }

        store.unseenInboxCount += 1
        DarwinNotifier.post(MirrorConfig.inboxNotification)
        notify(fileName: destination.lastPathComponent)
        return true
    }

    private func discard(_ id: UUID) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        try? file.handle.close()
        try? FileManager.default.removeItem(at: file.partialURL)
    }

    private func notify(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "From \(peerName)"
        content.body = fileName
        content.sound = .default
        content.threadIdentifier = "mirror-inbox"
        content.userInfo = ["open": "inbox"]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func safeName(_ name: String) -> String {
        let cleaned = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "File" : cleaned
    }

    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(newName)
            counter += 1
        }
        return candidate
    }
}
