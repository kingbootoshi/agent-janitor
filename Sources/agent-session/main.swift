import Foundation
import JanitorCore
import CProbe

let args = CommandLine.arguments
guard let sep = args.firstIndex(of: "--"), sep + 1 < args.count else {
    FileHandle.standardError.write(Data("usage: agent-session --kind <claude|codex|other> -- <command> [args...]\n".utf8))
    exit(64)
}
var kind = "unknown"
if let ki = args.firstIndex(of: "--kind"), ki + 1 < sep { kind = args[ki + 1] }
let command = Array(args[(sep + 1)...])

let pid = getpid()
if let raw = Probe.bsdInfo(pid) {
    let cwd = FileManager.default.currentDirectoryPath
    let sessionId = UUID().uuidString
    _ = SocketClient.request([
        "cmd": "register",
        "id": sessionId,
        "kind": kind,
        "root_key": raw.key.id,
        "project": Project.resolve(cwd: cwd),
        "cwd": cwd,
        "tty": ttyname(0).map { String(cString: $0) } ?? ""
    ])
    setenv("AGENT_SESSION_ID", sessionId, 1)
}

let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
execvp(command[0], argv)
FileHandle.standardError.write(Data("agent-session: exec failed for \(command[0])\n".utf8))
exit(127)
