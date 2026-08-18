import Foundation

public final class SocketServer {
    private let monitor: Monitor
    private var fd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "aj.socket", attributes: .concurrent)

    public init(monitor: Monitor) {
        self.monitor = monitor
    }

    public func start() {
        Paths.ensure()
        unlink(Paths.socket.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Paths.socket.path.withCString { cs in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), cs, raw.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, size)
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { return }
        chmod(Paths.socket.path, 0o600)
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while fd >= 0 {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EBADF { break }
                usleep(200_000)
                continue
            }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            acceptQueue.async { [weak self] in
                self?.handle(client)
                close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(client, &buf, buf.count)
        guard n > 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return }

        let reply = dispatch(cmd, obj)
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = write(client, raw.baseAddress! + off, raw.count - off)
                if w <= 0 { break }
                off += w
            }
        }
    }

    private func dispatch(_ cmd: String, _ obj: [String: Any]) -> [String: Any] {
        switch cmd {
        case "summary":
            let s = monitor.sync { $0.summary() }
            return ["ok": true, "mode": s.mode, "pending": s.pending, "tracked": s.tracked,
                    "self_footprint_mb": s.selfFootprintMB, "pressure": s.pressure,
                    "swap_mb": s.swapUsedMB, "uptime_s": s.uptimeSeconds]
        case "flags":
            let flags = monitor.sync { $0.flagList() }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            guard let data = try? enc.encode(flags),
                  let arr = try? JSONSerialization.jsonObject(with: data) else { return ["ok": false] }
            return ["ok": true, "flags": arr]
        case "top":
            let limit = obj["n"] as? Int ?? 8
            let (groups, otherBytes, otherCount) = monitor.sync { $0.topConsumers(limit: limit) }
            var reply: [String: Any] = ["ok": true]
            reply["groups"] = groups.map { ["sig": $0.signature, "count": $0.count, "bytes": $0.bytes] }
            reply["other_bytes"] = otherBytes
            reply["other_count"] = otherCount
            if let vm = Probe.vmBreakdown() {
                reply["vm"] = ["physical": vm.physical, "app": vm.appBytes, "wired": vm.wiredBytes,
                               "compressed": vm.compressedBytes, "cached": vm.cachedBytes,
                               "used": vm.usedBytes, "swap_mb": Probe.swapUsedMB()]
            }
            return reply
        case "keep":
            guard let keyId = obj["key"] as? String else { return ["ok": false, "error": "key required"] }
            let scope = obj["scope"] as? String ?? "instance"
            let result = monitor.sync { $0.keep(keyId: keyId, scope: scope, note: obj["note"] as? String ?? "") }
            return ["ok": true, "result": result]
        case "kill":
            guard let keyId = obj["key"] as? String else { return ["ok": false, "error": "key required"] }
            let force = obj["force"] as? Bool ?? false
            if let refusal = monitor.sync({ $0.signalKill(keyId: keyId, by: "user") }) {
                return ["ok": true, "result": refusal]
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                usleep(200_000)
                if monitor.sync({ $0.confirmDead(keyId: keyId) }) {
                    return ["ok": true, "result": "terminated"]
                }
            }
            if force {
                let r = monitor.sync { $0.forceKillNow(keyId: keyId) }
                usleep(400_000)
                let dead = monitor.sync { $0.confirmDead(keyId: keyId) }
                return ["ok": true, "result": dead ? "force killed" : r]
            }
            return ["ok": true, "result": "sigterm sent - still shutting down, recheck flags"]
        case "dismiss":
            guard let keyId = obj["key"] as? String else { return ["ok": false, "error": "key required"] }
            monitor.sync { $0.store.setFlagState(keyId, "dismissed") }
            return ["ok": true, "result": "dismissed"]
        case "log":
            let n = obj["n"] as? Int ?? 50
            return ["ok": true, "lines": monitor.sync { $0.store.recentDecisions(n) }]
        case "mode":
            guard let mode = obj["value"] as? String, ["audit", "enforce"].contains(mode) else {
                return ["ok": false, "error": "value must be audit|enforce"]
            }
            monitor.sync {
                $0.config.mode = mode
                $0.config.save()
                $0.log.emit("mode_change", ["mode": mode])
            }
            return ["ok": true, "result": mode]
        case "register":
            guard let id = obj["id"] as? String, let kind = obj["kind"] as? String,
                  let rootKey = obj["root_key"] as? String else { return ["ok": false] }
            monitor.sync {
                $0.store.registerSession(id: id, kind: kind, rootKey: rootKey,
                                         project: obj["project"] as? String ?? "",
                                         cwd: obj["cwd"] as? String ?? "",
                                         tty: obj["tty"] as? String ?? "")
                $0.log.emit("session_registered", ["id": id, "kind": kind, "root": rootKey])
            }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown cmd"]
        }
    }
}

public enum SocketClient {
    public static func request(_ payload: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Paths.socket.path.withCString { cs in
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                _ = strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), cs, raw.count)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        guard ok == 0, let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 1_048_576)
        var collected = Data()
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
            if let obj = try? JSONSerialization.jsonObject(with: collected) as? [String: Any] { return obj }
        }
        return (try? JSONSerialization.jsonObject(with: collected)) as? [String: Any]
    }
}
