import Foundation
import Dispatch

public final class Monitor {
    public let store = Store()
    public let log = WideLog()
    public var config = Config.load()

    private let queue = DispatchQueue(label: "aj.monitor")
    private var tracked: [Int32: ProcInfo] = [:]
    private var lastSampleAt = Date.distantPast
    private var lastLunaAt = Date.distantPast
    private var lastNotifyAt = Date.distantPast
    private var lastPruneAt = Date()
    private var bigNotified: Set<String> = []
    private var pressureState = "normal"
    private var pressureSource: DispatchSourceMemoryPressure?
    private var timer: DispatchSourceTimer?
    private let startedAt = Date()
    private let myUid = getuid()
    private let myPid = getpid()

    public init() {}

    public func start() {
        watchPressure()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .seconds(config.scanIntervalSeconds))
        t.setEventHandler { [weak self] in self?.tick() }
        t.activate()
        timer = t
        log.emit("daemon_start", ["pid": Int(myPid), "mode": config.mode])
    }

    public func sync<T>(_ work: @escaping (Monitor) -> T) -> T {
        queue.sync { work(self) }
    }

    private func watchPressure() {
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let e = src.data
            let state = e.contains(.critical) ? "critical" : e.contains(.warning) ? "warning" : "normal"
            if state != self.pressureState {
                self.pressureState = state
                self.log.emit("pressure_transition", ["state": state, "swap_mb": Probe.swapUsedMB()])
                if state != "normal" {
                    self.notify("memory pressure \(state)", "swap \(Int(Probe.swapUsedMB()))MB - open Agent Janitor to review", force: state == "critical")
                }
            }
        }
        src.activate()
        pressureSource = src
    }

    private func tick() {
        let pids = Probe.allPids()
        var seen = Set<Int32>()

        for pid in pids {
            guard let raw = Probe.bsdInfo(pid), raw.uid == myUid, pid != myPid else { continue }
            seen.insert(pid)
            if var known = tracked[pid] {
                if known.key == raw.key {
                    if known.reparentedAt == nil && raw.ppid == 1 && known.birthPpid != 1 {
                        known.reparentedAt = Date()
                        tracked[pid] = known
                        store.markReparented(known.key)
                        log.emit("reparented", ["key": known.key.id, "sig": known.signature, "birth_ppid": Int(known.birthPpid)])
                    }
                    continue
                }
                store.markExited(known.key.id)
                tracked[pid] = nil
            }
            let exe = Probe.path(pid)
            let argv = Probe.argv(pid)
            let cwd = Probe.cwd(pid)
            let info = ProcInfo(
                key: raw.key, ppid: raw.ppid, pgid: raw.pgid, uid: raw.uid,
                ttyDev: raw.ttyDev, status: raw.status,
                exePath: exe, argv: argv, cwd: cwd,
                signature: Signature.derive(exePath: exe, argv: argv),
                project: Project.resolve(cwd: cwd),
                birthPpid: raw.ppid, reparentedAt: raw.ppid == 1 ? Date.distantPast : nil,
                firstSeen: Date(), footprint: 0, resident: 0, cpuNs: 0, diskR: 0, diskW: 0)
            tracked[pid] = info
            store.upsertProcess(info)
        }

        for (pid, info) in tracked where !seen.contains(pid) {
            store.markExited(info.key.id)
            tracked[pid] = nil
            log.emit("exited", ["key": info.key.id, "sig": info.signature])
        }

        if Date().timeIntervalSince(lastSampleAt) >= Double(config.sampleIntervalSeconds) {
            lastSampleAt = Date()
            sampleAndEvaluate()
        }
        if Date().timeIntervalSince(lastPruneAt) >= 86400 {
            lastPruneAt = Date()
            store.prune()
        }
    }

    private func sampleAndEvaluate() {
        let floorBytes = UInt64(config.sampleFootprintFloorMB) * 1_048_576
        var flaggedNew = false

        for (pid, var info) in tracked {
            guard let ru = Probe.rusage(pid) else { continue }
            info.footprint = ru.footprint
            info.resident = ru.resident
            info.cpuNs = ru.cpuNs
            tracked[pid] = info
            if ru.footprint >= floorBytes || isCandidateClass(info.signature) {
                store.addSample(info.key.id, ru)
            }
            evaluateRules(info, ru, &flaggedNew)
        }

        let selfRu = Probe.rusage(myPid)
        store.addSystemSample(pressure: pressureState, swapMB: Probe.swapUsedMB(),
                              selfFootprint: selfRu?.footprint ?? 0, tracked: tracked.count)

        if flaggedNew { maybeNotifyPending() }
        maybeRunLuna()
    }

    private func isCandidateClass(_ sig: String) -> Bool {
        ["python-http-server", "vite", "bun-watch", "bun-dev", "claude", "codex", "ssh-oneshot", "node", "next"].contains(sig)
    }

    private func parentDead(_ info: ProcInfo) -> Bool {
        if info.reparentedAt != nil { return true }
        guard let cur = Probe.bsdInfo(info.key.pid) else { return true }
        return cur.ppid == 1 && info.birthPpid != 1
    }

    private func evaluateRules(_ info: ProcInfo, _ ru: RusageFact, _ flaggedNew: inout Bool) {
        let age = Date().timeIntervalSince(Date(timeIntervalSince1970: Double(info.key.startSec)))
        let keyId = info.key.id
        guard !store.keepMatch(keyId: keyId, signature: info.signature, project: info.project) else { return }
        let gib = Double(ru.footprint) / 1_073_741_824.0

        if info.signature == "python-http-server",
           age > Double(config.httpServerMinAgeHours) * 3600,
           parentDead(info), info.ttyDev <= 0 {
            let reason = "http.server orphan, age \(hrs(age)), parent dead"
            raiseFlag(info, rule: "httpServerOrphan", reason: reason, new: &flaggedNew)
            attemptAutoReap(info)
            return
        }

        if ["vite", "bun-watch", "bun-dev", "node", "next"].contains(info.signature),
           age > Double(config.devToolStaleHours) * 3600,
           parentDead(info), info.ttyDev <= 0 {
            let idle = idleOverWindow(keyId, seconds: 1800)
            let reason = "dev server orphan, age \(hrs(age)), \(idle ? "idle 30m" : "recent activity")"
            raiseFlag(info, rule: "devToolStale", reason: reason, new: &flaggedNew)
            return
        }

        if info.signature == "ssh-oneshot",
           age > Double(config.sshOneShotMaxHours) * 3600,
           parentDead(info) {
            raiseFlag(info, rule: "sshOneShot", reason: "one-shot ssh alive \(hrs(age))", new: &flaggedNew)
            return
        }

        if ["claude", "codex"].contains(info.signature),
           age > Double(config.agentStaleHours) * 3600,
           idleOverWindow(keyId, seconds: 3600) {
            raiseFlag(info, rule: "staleAgent",
                      reason: "\(info.signature) session \(hrs(age)) old, idle 1h+, \(String(format: "%.1f", gib))GiB - still using?",
                      new: &flaggedNew)
            return
        }

        if gib >= config.bigProcGiB, !bigNotified.contains(keyId) {
            if let d = store.sampleDeltas(keyId, windowSeconds: 360), d.growth >= 0 {
                bigNotified.insert(keyId)
                raiseFlag(info, rule: "bigProc",
                          reason: "footprint \(String(format: "%.2f", gib))GiB sustained 5m+",
                          new: &flaggedNew)
                return
            }
        }

        if let d = store.sampleDeltas(keyId, windowSeconds: 900),
           Double(d.growth) / 1_048_576.0 >= config.growthMiBPer15Min {
            raiseFlag(info, rule: "rapidGrowth",
                      reason: "grew \(d.growth / 1_048_576)MiB in 15m to \(String(format: "%.2f", gib))GiB",
                      new: &flaggedNew)
        }
    }

    private func raiseFlag(_ info: ProcInfo, rule: String, reason: String, new: inout Bool) {
        if store.upsertFlag(info.key.id, rule: rule, reason: reason) {
            new = true
            log.emit("flagged", ["key": info.key.id, "pid": Int(info.key.pid), "rule": rule,
                                 "sig": info.signature, "project": info.project, "reason": reason,
                                 "footprint_mb": Int(info.footprint / 1_048_576)])
        }
    }

    private func idleOverWindow(_ keyId: String, seconds: Double) -> Bool {
        guard let d = store.sampleDeltas(keyId, windowSeconds: seconds) else { return false }
        let cpuPct = Double(d.cpuNs) / (seconds * 1_000_000_000) * 100
        return cpuPct < 0.1 && d.diskBytes < 1_048_576
    }

    private func attemptAutoReap(_ info: ProcInfo) {
        let keyId = info.key.id
        let sock = Probe.sockets(info.key.pid)
        var gates: [String: Bool] = [:]
        gates["loopback_only"] = sock.loopbackOnly
        gates["no_established"] = sock.established == 0
        gates["idle_30m"] = idleOverWindow(keyId, seconds: 1800)
        gates["no_tty"] = info.ttyDev <= 0
        gates["no_children"] = childPids(of: info.key.pid).isEmpty
        gates["no_live_pipe_peer"] = !hasLiveSessionPipePeer(info.key.pid)
        let pass = gates.values.allSatisfy { $0 }
        let detail = gates.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")

        if config.mode == "enforce" && pass {
            let result = kill(keyId: keyId, force: false, by: "automatic")
            log.emit("auto_reap", ["key": keyId, "result": result, "gates": detail])
        } else {
            store.logDecision(keyId, decision: pass ? "would_reap" : "would_hold",
                              detail: detail, by: "audit")
            log.emit(pass ? "would_reap" : "would_hold", ["key": keyId, "gates": detail, "mode": config.mode])
        }
    }

    private func childPids(of pid: Int32) -> [Int32] {
        tracked.compactMap { $1.ppid == pid ? $0 : nil }
    }

    private func hasLiveSessionPipePeer(_ pid: Int32) -> Bool {
        let mine = Set(Probe.pipePeerHandles(pid))
        guard !mine.isEmpty else { return false }
        for (otherPid, info) in tracked where otherPid != pid {
            guard ["claude", "codex", "zsh", "bash", "sh", "fish", "tmux"].contains(info.signature)
                  || info.signature.hasPrefix("ssh") else { continue }
            let theirs = Probe.pipePeerHandles(otherPid)
            if theirs.contains(where: { mine.contains($0) }) { return true }
        }
        return false
    }

    public func kill(keyId: String, force: Bool, by: String) -> String {
        guard let row = store.processRow(keyId) else { return "unknown key" }
        let pid = row.pid
        guard let raw = Probe.bsdInfo(pid), raw.key.id == keyId else {
            store.setFlagState(keyId, "gone")
            return "identity mismatch or already exited"
        }
        guard raw.uid == myUid else { return "refused: not our uid" }
        guard pid > 1 else { return "refused: system pid" }
        let exe = row.exePath
        if exe.hasPrefix("/System/") || exe.hasPrefix("/usr/libexec/") || exe.hasPrefix("/sbin/") {
            return "refused: system executable"
        }
        if by == "automatic" && store.keepMatch(keyId: keyId, signature: row.signature, project: row.project) {
            return "refused: keep policy"
        }

        Darwin.kill(pid, SIGTERM)
        store.logDecision(keyId, decision: "sigterm", detail: row.argv, by: by)
        log.emit("sigterm", ["key": keyId, "pid": Int(pid), "by": by, "cmd": row.argv])

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            usleep(250_000)
            guard let check = Probe.bsdInfo(pid), check.key.id == keyId else {
                store.setFlagState(keyId, "reaped")
                store.markExited(keyId)
                log.emit("reaped", ["key": keyId, "by": by])
                return "terminated"
            }
        }
        if force && by != "automatic" {
            Darwin.kill(pid, SIGKILL)
            store.logDecision(keyId, decision: "sigkill", detail: row.argv, by: by)
            log.emit("sigkill", ["key": keyId, "by": by])
            usleep(300_000)
            if Probe.bsdInfo(pid)?.key.id != keyId {
                store.setFlagState(keyId, "reaped")
                store.markExited(keyId)
                return "force killed"
            }
            return "survived SIGKILL"
        }
        return "survived SIGTERM - use force for SIGKILL"
    }

    public func keep(keyId: String, scope: String, note: String) -> String {
        guard let row = store.processRow(keyId) else { return "unknown key" }
        let ttl: Int? = scope == "project" ? 30 : nil
        store.addPolicy(action: "keep", scope: scope, signature: row.signature,
                        project: row.project, keyId: keyId, note: note, ttlDays: ttl)
        store.setFlagState(keyId, "kept")
        store.logDecision(keyId, decision: "keep_\(scope)", detail: row.argv, by: "user")
        log.emit("keep", ["key": keyId, "scope": scope, "sig": row.signature, "project": row.project])
        return "kept (\(scope))"
    }

    public func summary() -> SummaryReply {
        let selfRu = Probe.rusage(myPid)
        return SummaryReply(
            mode: config.mode,
            pending: store.pendingFlags().count,
            tracked: tracked.count,
            selfFootprintMB: Double(selfRu?.footprint ?? 0) / 1_048_576.0,
            pressure: pressureState,
            swapUsedMB: Probe.swapUsedMB(),
            uptimeSeconds: Int(Date().timeIntervalSince(startedAt)))
    }

    public func flagList() -> [FlagRecord] {
        store.pendingFlags().compactMap { f in
            guard let row = store.processRow(f.keyId) else { return nil }
            let alive = Probe.bsdInfo(row.pid)?.key.id == f.keyId
            if !alive {
                store.setFlagState(f.keyId, "gone")
                return nil
            }
            let ru = Probe.rusage(row.pid)
            return FlagRecord(
                keyId: f.keyId, pid: row.pid, rule: f.rule, signature: row.signature,
                project: row.project,
                command: String(row.argv.prefix(120)),
                ageSeconds: Int(Date().timeIntervalSince1970 - (Double(f.keyId.split(separator: ".").dropFirst().first ?? "0") ?? row.firstSeen)),
                footprint: ru?.footprint ?? 0,
                reason: f.reason, lunaVerdict: f.lunaVerdict, lunaReason: f.lunaReason,
                state: "pending", firstFlagged: Date(timeIntervalSince1970: f.firstFlagged))
        }
    }

    private func maybeNotifyPending() {
        guard Date().timeIntervalSince(lastNotifyAt) > Double(config.notifyCooldownMinutes) * 60 else { return }
        let pending = store.pendingFlags().count
        guard pending > 0 else { return }
        lastNotifyAt = Date()
        notify("\(pending) process\(pending == 1 ? "" : "es") flagged", "open the Agent Janitor menu to review", force: false)
    }

    private func notify(_ title: String, _ body: String, force: Bool) {
        let script = "display notification \"\(body)\" with title \"Agent Janitor\" subtitle \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    private func maybeRunLuna() {
        guard config.lunaEnabled,
              Luna.apiKey != nil,
              Date().timeIntervalSince(lastLunaAt) > Double(config.lunaIntervalMinutes) * 60 else { return }
        let flags = flagList().filter { $0.lunaVerdict == nil }
        guard !flags.isEmpty else { return }
        lastLunaAt = Date()
        Luna.triage(flags: flags, model: config.lunaModel) { [weak self] verdicts in
            guard let self else { return }
            self.queue.async {
                for v in verdicts {
                    self.store.setLuna(v.keyId, verdict: v.verdict, reason: v.reason)
                    self.log.emit("luna_verdict", ["key": v.keyId, "verdict": v.verdict, "reason": v.reason])
                }
            }
        }
    }

    private func hrs(_ s: TimeInterval) -> String {
        s > 86400 ? String(format: "%.1fd", s / 86400) : String(format: "%.1fh", s / 3600)
    }
}
