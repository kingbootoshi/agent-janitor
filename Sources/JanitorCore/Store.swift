import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class Store {
    private var db: OpaquePointer?

    public init() {
        Paths.ensure()
        sqlite3_open(Paths.db.path, &db)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        migrate()
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.db.path)
    }

    deinit { sqlite3_close(db) }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS process_instance (
            key_id TEXT PRIMARY KEY,
            pid INTEGER, start_sec INTEGER, start_usec INTEGER,
            uid INTEGER, exe_path TEXT, argv TEXT, cwd TEXT, project TEXT, signature TEXT,
            birth_ppid INTEGER, birth_parent_key TEXT,
            pgid INTEGER, tty_dev INTEGER,
            first_seen REAL, last_seen REAL, exited_at REAL, reparented_at REAL
        );
        CREATE TABLE IF NOT EXISTS sample (
            ts REAL, key_id TEXT, footprint INTEGER, resident INTEGER,
            cpu_ns INTEGER, disk_r INTEGER, disk_w INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_sample_key ON sample(key_id, ts);
        CREATE TABLE IF NOT EXISTS system_sample (
            ts REAL, pressure TEXT, swap_mb REAL, self_footprint INTEGER, tracked INTEGER
        );
        CREATE TABLE IF NOT EXISTS flag (
            key_id TEXT PRIMARY KEY,
            rule TEXT, reason TEXT, state TEXT,
            first_flagged REAL, luna_verdict TEXT, luna_reason TEXT, resolved_at REAL
        );
        CREATE TABLE IF NOT EXISTS policy (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            action TEXT, scope TEXT, signature TEXT, project TEXT, key_id TEXT,
            created_at REAL, expires_at REAL, note TEXT
        );
        CREATE TABLE IF NOT EXISTS decision_log (
            ts REAL, key_id TEXT, decision TEXT, detail TEXT, initiated_by TEXT
        );
        CREATE TABLE IF NOT EXISTS session (
            id TEXT PRIMARY KEY, kind TEXT, root_key TEXT, project TEXT,
            cwd TEXT, tty TEXT, started_at REAL, ended_at REAL
        );
        """)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ binds: [Any?]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        sqlite3_step(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Any?]) {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            case let n as UInt64: sqlite3_bind_int64(stmt, idx, Int64(bitPattern: n))
            case let n as UInt32: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let d as Date: sqlite3_bind_double(stmt, idx, d.timeIntervalSince1970)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
    }

    private func query(_ sql: String, _ binds: [Any?] = [], _ row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt!) }
    }

    private func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    public func upsertProcess(_ p: ProcInfo) {
        run("""
        INSERT INTO process_instance
        (key_id,pid,start_sec,start_usec,uid,exe_path,argv,cwd,project,signature,birth_ppid,birth_parent_key,pgid,tty_dev,first_seen,last_seen)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(key_id) DO UPDATE SET last_seen=excluded.last_seen
        """, [p.key.id, p.key.pid, p.key.startSec, p.key.startUsec, p.uid, p.exePath,
              p.argv.joined(separator: "\u{1f}"), p.cwd, p.project, p.signature,
              p.birthPpid, "", p.pgid, p.ttyDev, p.firstSeen, Date()])
    }

    public func markReparented(_ key: ProcessKey) {
        run("UPDATE process_instance SET reparented_at=? WHERE key_id=? AND reparented_at IS NULL", [Date(), key.id])
    }

    public func markExited(_ keyId: String) {
        run("UPDATE process_instance SET exited_at=? WHERE key_id=? AND exited_at IS NULL", [Date(), keyId])
    }

    public func addSample(_ keyId: String, _ ru: RusageFact) {
        run("INSERT INTO sample (ts,key_id,footprint,resident,cpu_ns,disk_r,disk_w) VALUES (?,?,?,?,?,?,?)",
            [Date(), keyId, ru.footprint, ru.resident, ru.cpuNs, ru.diskR, ru.diskW])
    }

    public func addSystemSample(pressure: String, swapMB: Double, selfFootprint: UInt64, tracked: Int) {
        run("INSERT INTO system_sample (ts,pressure,swap_mb,self_footprint,tracked) VALUES (?,?,?,?,?)",
            [Date(), pressure, swapMB, selfFootprint, tracked])
    }

    public func sampleDeltas(_ keyId: String, windowSeconds: Double) -> (cpuNs: UInt64, diskBytes: UInt64, growth: Int64)? {
        var rows: [(ts: Double, cpu: Int64, disk: Int64, fp: Int64)] = []
        query("SELECT ts,cpu_ns,disk_r+disk_w,footprint FROM sample WHERE key_id=? AND ts>=? ORDER BY ts",
              [keyId, Date().timeIntervalSince1970 - windowSeconds]) { s in
            rows.append((sqlite3_column_double(s, 0), sqlite3_column_int64(s, 1),
                         sqlite3_column_int64(s, 2), sqlite3_column_int64(s, 3)))
        }
        guard let first = rows.first, let last = rows.last, rows.count >= 2 else { return nil }
        return (UInt64(max(0, last.cpu - first.cpu)), UInt64(max(0, last.disk - first.disk)), last.fp - first.fp)
    }

    public func upsertFlag(_ keyId: String, rule: String, reason: String) -> Bool {
        var exists = false
        query("SELECT state FROM flag WHERE key_id=?", [keyId]) { _ in exists = true }
        if exists {
            run("UPDATE flag SET reason=? WHERE key_id=? AND state='pending'", [reason, keyId])
            return false
        }
        run("INSERT INTO flag (key_id,rule,reason,state,first_flagged) VALUES (?,?,?,'pending',?)",
            [keyId, rule, reason, Date()])
        return true
    }

    public func setFlagState(_ keyId: String, _ state: String) {
        run("UPDATE flag SET state=?, resolved_at=? WHERE key_id=?", [state, Date(), keyId])
    }

    public func setLuna(_ keyId: String, verdict: String, reason: String) {
        run("UPDATE flag SET luna_verdict=?, luna_reason=? WHERE key_id=?", [verdict, reason, keyId])
    }

    public func pendingFlags() -> [(keyId: String, rule: String, reason: String, firstFlagged: Double, lunaVerdict: String?, lunaReason: String?)] {
        var out: [(String, String, String, Double, String?, String?)] = []
        query("SELECT key_id,rule,reason,first_flagged,luna_verdict,luna_reason FROM flag WHERE state='pending' ORDER BY first_flagged") { s in
            let lv = sqlite3_column_text(s, 4).map { String(cString: $0) }
            let lr = sqlite3_column_text(s, 5).map { String(cString: $0) }
            out.append((self.text(s, 0), self.text(s, 1), self.text(s, 2), sqlite3_column_double(s, 3), lv, lr))
        }
        return out
    }

    public func addPolicy(action: String, scope: String, signature: String, project: String, keyId: String, note: String, ttlDays: Int?) {
        let expires = ttlDays.map { Date().addingTimeInterval(Double($0) * 86400) }
        run("INSERT INTO policy (action,scope,signature,project,key_id,created_at,expires_at,note) VALUES (?,?,?,?,?,?,?,?)",
            [action, scope, signature, project, keyId, Date(), expires, note])
    }

    public func keepMatch(keyId: String, signature: String, project: String) -> Bool {
        var matched = false
        let now = Date().timeIntervalSince1970
        query("""
        SELECT 1 FROM policy WHERE action='keep'
        AND (expires_at IS NULL OR expires_at > ?)
        AND ((scope='instance' AND key_id=?)
          OR (scope='project' AND signature=? AND project=?)
          OR (scope='global' AND signature=?))
        LIMIT 1
        """, [now, keyId, signature, project, signature]) { _ in matched = true }
        return matched
    }

    public func logDecision(_ keyId: String, decision: String, detail: String, by: String) {
        run("INSERT INTO decision_log (ts,key_id,decision,detail,initiated_by) VALUES (?,?,?,?,?)",
            [Date(), keyId, decision, detail, by])
    }

    public func recentDecisions(_ n: Int) -> [String] {
        var out: [String] = []
        query("SELECT ts,key_id,decision,detail,initiated_by FROM decision_log ORDER BY ts DESC LIMIT ?", [n]) { s in
            let ts = Date(timeIntervalSince1970: sqlite3_column_double(s, 0))
            let f = ISO8601DateFormatter()
            out.append("\(f.string(from: ts)) [\(self.text(s, 4))] \(self.text(s, 2)) \(self.text(s, 1)) \(self.text(s, 3))")
        }
        return out
    }

    public func registerSession(id: String, kind: String, rootKey: String, project: String, cwd: String, tty: String) {
        run("INSERT OR REPLACE INTO session (id,kind,root_key,project,cwd,tty,started_at) VALUES (?,?,?,?,?,?,?)",
            [id, kind, rootKey, project, cwd, tty, Date()])
    }

    public func processRow(_ keyId: String) -> (pid: Int32, signature: String, project: String, argv: String, cwd: String, firstSeen: Double, exePath: String)? {
        var out: (Int32, String, String, String, String, Double, String)?
        query("SELECT pid,signature,project,argv,cwd,first_seen,exe_path FROM process_instance WHERE key_id=?", [keyId]) { s in
            out = (Int32(sqlite3_column_int64(s, 0)), self.text(s, 1), self.text(s, 2),
                   self.text(s, 3).replacingOccurrences(of: "\u{1f}", with: " "),
                   self.text(s, 4), sqlite3_column_double(s, 5), self.text(s, 6))
        }
        return out
    }

    public func prune() {
        let now = Date().timeIntervalSince1970
        run("DELETE FROM sample WHERE ts < ?", [now - 14 * 86400])
        run("DELETE FROM system_sample WHERE ts < ?", [now - 30 * 86400])
        run("DELETE FROM decision_log WHERE ts < ?", [now - 60 * 86400])
        run("DELETE FROM flag WHERE state != 'pending' AND resolved_at < ?", [now - 30 * 86400])
        run("DELETE FROM process_instance WHERE exited_at IS NOT NULL AND exited_at < ?", [now - 30 * 86400])
        run("DELETE FROM policy WHERE expires_at IS NOT NULL AND expires_at < ?", [now])
    }
}
