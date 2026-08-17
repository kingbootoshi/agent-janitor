import Foundation
import JanitorCore

let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "status"

func out(_ s: String) { print(s) }

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

func req(_ payload: [String: Any]) -> [String: Any] {
    guard let r = SocketClient.request(payload) else {
        fail("janitord not reachable at \(Paths.socket.path) - is the daemon running?")
    }
    return r
}

func fmtBytes(_ b: UInt64) -> String {
    let mb = Double(b) / 1_048_576
    return mb > 1024 ? String(format: "%.2fGiB", mb / 1024) : String(format: "%.0fMiB", mb)
}

func fmtAge(_ s: Int) -> String {
    s > 86400 ? String(format: "%.1fd", Double(s) / 86400) : String(format: "%.1fh", Double(s) / 3600)
}

switch cmd {
case "status":
    let r = req(["cmd": "summary"])
    out("mode:      \(r["mode"] ?? "?")")
    out("pending:   \(r["pending"] ?? "?")")
    out("tracked:   \(r["tracked"] ?? "?")")
    out("pressure:  \(r["pressure"] ?? "?")")
    out("swap:      \(String(format: "%.0f", r["swap_mb"] as? Double ?? 0))MB")
    out("self:      \(String(format: "%.1f", r["self_footprint_mb"] as? Double ?? 0))MB footprint")
    out("uptime:    \(fmtAge(r["uptime_s"] as? Int ?? 0))")
case "flags":
    let r = req(["cmd": "flags"])
    guard let flags = r["flags"] as? [[String: Any]], !flags.isEmpty else { out("no pending flags"); exit(0) }
    for f in flags {
        let fp = (f["footprint"] as? NSNumber)?.uint64Value ?? 0
        out("\(f["keyId"] ?? "") [\(f["rule"] ?? "")]")
        out("  \(f["command"] ?? "")")
        out("  \(f["project"] ?? "-") · \(fmtAge((f["ageSeconds"] as? Int) ?? 0)) · \(fmtBytes(fp))")
        out("  \(f["reason"] ?? "")")
        if let v = f["lunaVerdict"] as? String { out("  luna: \(v) - \(f["lunaReason"] as? String ?? "")") }
        out("")
    }
case "keep":
    guard args.count > 2 else { fail("usage: janitor keep <key> [instance|project|global]") }
    let scope = args.count > 3 ? args[3] : "instance"
    out("\(req(["cmd": "keep", "key": args[2], "scope": scope])["result"] ?? "?")")
case "kill":
    guard args.count > 2 else { fail("usage: janitor kill <key> [--force]") }
    let force = args.contains("--force")
    out("\(req(["cmd": "kill", "key": args[2], "force": force])["result"] ?? "?")")
case "dismiss":
    guard args.count > 2 else { fail("usage: janitor dismiss <key>") }
    out("\(req(["cmd": "dismiss", "key": args[2]])["result"] ?? "?")")
case "log":
    let n = args.count > 2 ? Int(args[2]) ?? 50 : 50
    for line in (req(["cmd": "log", "n": n])["lines"] as? [String]) ?? [] { out(line) }
case "mode":
    guard args.count > 2 else { fail("usage: janitor mode <audit|enforce>") }
    out("mode set: \(req(["cmd": "mode", "value": args[2]])["result"] ?? "?")")
default:
    out("""
    agent-janitor CLI
      janitor status
      janitor flags
      janitor keep <key> [instance|project|global]
      janitor kill <key> [--force]
      janitor dismiss <key>
      janitor log [n]
      janitor mode <audit|enforce>
    """)
}
