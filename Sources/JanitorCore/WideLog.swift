import Foundation

public final class WideLog {
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "aj.widelog")
    private var bytesWritten: UInt64 = 0
    private static let maxBytes: UInt64 = 5 * 1_048_576
    private static let iso = ISO8601DateFormatter()

    public init() {
        Paths.ensure()
        openHandle()
    }

    private func openHandle() {
        if !FileManager.default.fileExists(atPath: Paths.eventLog.path) {
            FileManager.default.createFile(atPath: Paths.eventLog.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: Paths.eventLog)
        bytesWritten = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotateIfNeeded() {
        guard bytesWritten >= Self.maxBytes else { return }
        try? handle?.close()
        let rotated = Paths.eventLog.deletingPathExtension().appendingPathExtension("jsonl.1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: Paths.eventLog, to: rotated)
        openHandle()
    }

    public func emit(_ kind: String, _ fields: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            var event: [String: Any] = fields
            event["ts"] = Self.iso.string(from: Date())
            event["event"] = kind
            guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            self.handle?.write(data)
            self.handle?.write(Data([0x0a]))
            self.bytesWritten += UInt64(data.count) + 1
            self.rotateIfNeeded()
        }
    }
}
