import Foundation

public struct ProcessKey: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startSec: UInt64
    public let startUsec: UInt64

    public init(pid: Int32, startSec: UInt64, startUsec: UInt64) {
        self.pid = pid
        self.startSec = startSec
        self.startUsec = startUsec
    }

    public var id: String { "\(pid).\(startSec).\(startUsec)" }
}

public struct ProcInfo: Sendable {
    public var key: ProcessKey
    public var ppid: Int32
    public var pgid: Int32
    public var uid: UInt32
    public var ttyDev: Int32
    public var status: UInt32
    public var exePath: String
    public var argv: [String]
    public var cwd: String
    public var signature: String
    public var project: String
    public var birthPpid: Int32
    public var reparentedAt: Date?
    public var firstSeen: Date
    public var footprint: UInt64
    public var resident: UInt64
    public var cpuNs: UInt64
    public var diskR: UInt64
    public var diskW: UInt64
}

public struct SocketFact: Codable, Sendable {
    public var listeners: [UInt16]
    public var loopbackOnly: Bool
    public var established: Int
}

public struct FlagRecord: Codable, Sendable {
    public var keyId: String
    public var pid: Int32
    public var rule: String
    public var signature: String
    public var project: String
    public var command: String
    public var ageSeconds: Int
    public var footprint: UInt64
    public var reason: String
    public var lunaVerdict: String?
    public var lunaReason: String?
    public var state: String
    public var firstFlagged: Date
}

public struct SummaryReply: Codable, Sendable {
    public var mode: String
    public var pending: Int
    public var tracked: Int
    public var selfFootprintMB: Double
    public var pressure: String
    public var swapUsedMB: Double
    public var uptimeSeconds: Int
}

public enum Signature {
    public static func derive(exePath: String, argv: [String]) -> String {
        let exe = (exePath as NSString).lastPathComponent.lowercased()
        let joined = argv.dropFirst().joined(separator: " ")
        if exe.hasPrefix("python") {
            if joined.contains("-m http.server") { return "python-http-server" }
            return "python"
        }
        if exe == "claude" || argv.first.map({ ($0 as NSString).lastPathComponent == "claude" }) == true { return "claude" }
        if exe == "codex" || joined.contains("/codex") { return "codex" }
        if exe == "bun" {
            if joined.contains("--watch") { return "bun-watch" }
            if joined.hasPrefix("run dev") || joined.contains(" dev") { return "bun-dev" }
            return "bun"
        }
        if exe == "node" {
            if joined.contains("/vite") || joined.hasSuffix("vite") || joined.contains("vite ") { return "vite" }
            if joined.contains("/codex") { return "codex" }
            if joined.contains("next") { return "next" }
            return "node"
        }
        if exe == "ssh" {
            let flags: Set<Character> = ["N", "L", "R", "D"]
            let hasTunnel = argv.contains { $0.hasPrefix("-") && $0.dropFirst().contains(where: { flags.contains($0) }) }
            return hasTunnel ? "ssh-tunnel" : "ssh-oneshot"
        }
        return exe
    }
}

public enum Paths {
    public static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentJanitor", isDirectory: true)
    public static var db: URL { supportDir.appendingPathComponent("state.sqlite") }
    public static var socket: URL { supportDir.appendingPathComponent("janitor.sock") }
    public static var config: URL { supportDir.appendingPathComponent("config.json") }
    public static var eventLog: URL { supportDir.appendingPathComponent("events.jsonl") }

    public static func ensure() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}

public struct Config: Codable, Sendable {
    public var mode: String
    public var scanIntervalSeconds: Int
    public var sampleIntervalSeconds: Int
    public var sampleFootprintFloorMB: Int
    public var bigProcGiB: Double
    public var growthMiBPer15Min: Double
    public var devToolStaleHours: Int
    public var httpServerMinAgeHours: Int
    public var agentStaleHours: Int
    public var sshOneShotMaxHours: Int
    public var lunaEnabled: Bool
    public var lunaModel: String
    public var lunaIntervalMinutes: Int
    public var notifyCooldownMinutes: Int

    public static let defaults = Config(
        mode: "audit",
        scanIntervalSeconds: 5,
        sampleIntervalSeconds: 60,
        sampleFootprintFloorMB: 100,
        bigProcGiB: 1.0,
        growthMiBPer15Min: 512,
        devToolStaleHours: 24,
        httpServerMinAgeHours: 4,
        agentStaleHours: 24,
        sshOneShotMaxHours: 6,
        lunaEnabled: true,
        lunaModel: "openai/gpt-5.6-luna",
        lunaIntervalMinutes: 15,
        notifyCooldownMinutes: 30
    )

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            let cfg = Config.defaults
            cfg.save()
            return cfg
        }
        return cfg
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        Paths.ensure()
        try? enc.encode(self).write(to: Paths.config)
    }
}
