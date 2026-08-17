import Foundation

public final class WideLog {
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "aj.widelog")

    public init() {
        Paths.ensure()
        if !FileManager.default.fileExists(atPath: Paths.eventLog.path) {
            FileManager.default.createFile(atPath: Paths.eventLog.path, contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        handle = try? FileHandle(forWritingTo: Paths.eventLog)
        _ = try? handle?.seekToEnd()
    }

    public func emit(_ kind: String, _ fields: [String: Any]) {
        queue.async { [handle] in
            var event: [String: Any] = fields
            event["ts"] = ISO8601DateFormatter().string(from: Date())
            event["event"] = kind
            guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
            handle?.write(data)
            handle?.write(Data([0x0a]))
        }
    }
}
