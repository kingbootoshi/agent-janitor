import AppKit
import JanitorCore

final class MenuController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var flags: [[String: Any]] = []

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    func daemonRequest(_ payload: [String: Any]) -> [String: Any]? {
        SocketClient.request(payload)
    }

    func refreshIcon() {
        let summary = daemonRequest(["cmd": "summary"])
        let pending = summary?["pending"] as? Int ?? -1
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            button.image = Self.broomIcon()
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.alphaValue = pending == 0 ? 0.55 : 1.0
            button.toolTip = pending > 0 ? "\(pending) flagged" : "all clean"
        }
    }

    static func broomIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 16.6, y: 16.6))
            handle.line(to: NSPoint(x: 11.6, y: 11.6))
            handle.lineWidth = 1.9
            handle.lineCapStyle = .round
            handle.stroke()

            let fan = NSBezierPath()
            fan.move(to: NSPoint(x: 13.4, y: 9.4))
            fan.line(to: NSPoint(x: 6.2, y: 0.6))
            fan.line(to: NSPoint(x: 3.2, y: 1.2))
            fan.line(to: NSPoint(x: 1.2, y: 3.2))
            fan.line(to: NSPoint(x: 0.6, y: 6.2))
            fan.line(to: NSPoint(x: 9.4, y: 13.4))
            fan.curve(to: NSPoint(x: 13.4, y: 9.4),
                      controlPoint1: NSPoint(x: 12.2, y: 12.2), controlPoint2: NSPoint(x: 12.2, y: 12.2))
            fan.close()
            fan.fill()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let band = NSBezierPath()
            band.move(to: NSPoint(x: 12.4, y: 8.2))
            band.line(to: NSPoint(x: 8.2, y: 12.4))
            band.lineWidth = 1.1
            band.stroke()
            let notch = NSBezierPath()
            notch.move(to: NSPoint(x: 9.2, y: 9.2))
            notch.line(to: NSPoint(x: 2.0, y: 2.0))
            notch.lineWidth = 0.8
            notch.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    struct Row {
        var keyId: String
        var signature: String
        var project: String
        var rule: String
        var age: Int
        var footprint: UInt64
        var reason: String
        var command: String
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = daemonRequest(["cmd": "summary"])
        let flagReply = daemonRequest(["cmd": "flags"])
        flags = flagReply?["flags"] as? [[String: Any]] ?? []
        let rows = flags.map { f in
            Row(keyId: f["keyId"] as? String ?? "",
                signature: f["signature"] as? String ?? "?",
                project: f["project"] as? String ?? "",
                rule: f["rule"] as? String ?? "",
                age: f["ageSeconds"] as? Int ?? 0,
                footprint: (f["footprint"] as? NSNumber)?.uint64Value ?? 0,
                reason: f["reason"] as? String ?? "",
                command: f["command"] as? String ?? "")
        }

        let top = daemonRequest(["cmd": "top", "n": 8])
        if let vm = top?["vm"] as? [String: Any] {
            let gb = { (k: String) in Double((vm[k] as? NSNumber)?.uint64Value ?? 0) / 1_073_741_824 }
            let pressure = summary?["pressure"] as? String ?? "?"
            addMono(menu, String(format: "%.1f / %.0f GB · pressure %@", gb("used"), gb("physical"), pressure as NSString))
        } else if summary == nil {
            addInfo(menu, "daemon unreachable")
        }
        menu.addItem(.separator())

        if rows.isEmpty {
            addInfo(menu, "all clean - nothing flagged")
        }

        var groups: [String: [Row]] = [:]
        for r in rows { groups[r.signature + "|" + r.project, default: []].append(r) }
        let ordered = groups.values.sorted {
            $0.reduce(UInt64(0)) { $0 + $1.footprint } > $1.reduce(UInt64(0)) { $0 + $1.footprint }
        }

        for group in ordered {
            if group.count == 1 {
                menu.addItem(flagItem(group[0]))
            } else {
                let total = group.reduce(UInt64(0)) { $0 + $1.footprint }
                let ages = group.map(\.age)
                let first = group[0]
                let title = "\(group.count)× \(first.signature)\(first.project.isEmpty ? "" : " · \(first.project)") · \(fmtAge(ages.min() ?? 0))-\(fmtAge(ages.max() ?? 0)) · \(fmtBytes(total))"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let keys = group.map(\.keyId)
                sub.addItem(bulk("Terminate all \(group.count)", #selector(killMany(_:)), keys))
                sub.addItem(bulk("Keep all (project, 30d)", #selector(keepMany(_:)), keys))
                sub.addItem(bulk("Dismiss all", #selector(dismissMany(_:)), keys))
                sub.addItem(.separator())
                for r in group.sorted(by: { $0.footprint > $1.footprint }) {
                    sub.addItem(flagItem(r, compact: true))
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if let top, let vm = top["vm"] as? [String: Any] {
            let breakdown = NSMenuItem(title: "Memory Breakdown", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let gb = { (k: String) in Double((vm[k] as? NSNumber)?.uint64Value ?? 0) / 1_073_741_824 }
            addMono(sub, String(format: "app %.1f + wired %.1f + compressed %.1f", gb("app"), gb("wired"), gb("compressed")))
            addMono(sub, String(format: "cached files %.1f (frees itself)", gb("cached")))
            sub.addItem(.separator())
            var yoursTotal: UInt64 = 0
            for g in (top["groups"] as? [[String: Any]] ?? []) {
                let bytes = (g["bytes"] as? NSNumber)?.uint64Value ?? 0
                yoursTotal += bytes
                let count = g["count"] as? Int ?? 0
                let sig = String((g["sig"] as? String ?? "?").prefix(22))
                addMono(sub, String(format: "%7@  %@%@", fmtBytes(bytes) as NSString, sig, count > 1 ? " ×\(count)" : ""))
            }
            let otherBytes = (top["other_bytes"] as? NSNumber)?.uint64Value ?? 0
            yoursTotal += otherBytes
            addMono(sub, String(format: "%7@  %d smaller processes", fmtBytes(otherBytes) as NSString, top["other_count"] as? Int ?? 0))
            let systemBytes = max(0, Int64((vm["app"] as? NSNumber)?.int64Value ?? 0) - Int64(yoursTotal))
            addMono(sub, String(format: "%7@  system + other users", fmtBytes(UInt64(systemBytes)) as NSString))
            if let s = summary {
                sub.addItem(.separator())
                let selfMB = String(format: "%.0f", s["self_footprint_mb"] as? Double ?? 0)
                addMono(sub, "\(s["mode"] ?? "?") mode · \(s["tracked"] ?? 0) tracked · janitor \(selfMB)MB")
            }
            breakdown.submenu = sub
            menu.addItem(breakdown)
        }

        let modeToggle = NSMenuItem(title: (summary?["mode"] as? String == "audit") ? "Enable enforce mode" : "Switch to audit mode",
                                    action: #selector(toggleMode(_:)), keyEquivalent: "")
        modeToggle.target = self
        menu.addItem(modeToggle)
        let quit = NSMenuItem(title: "Quit Menu (daemon keeps running)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func flagItem(_ r: Row, compact: Bool = false) -> NSMenuItem {
        let title = compact
            ? "pid \(r.keyId.split(separator: ".").first.map(String.init) ?? "?") · \(fmtAge(r.age)) · \(fmtBytes(r.footprint))"
            : "\(r.signature)\(r.project.isEmpty ? "" : " · \(r.project)") · \(fmtAge(r.age)) · \(fmtBytes(r.footprint))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for line in wrap(r.reason, 46) { addInfo(sub, line) }
        addInfo(sub, "…" + String(r.command.suffix(44)))
        sub.addItem(.separator())
        sub.addItem(single("Keep this instance", #selector(keepInstance(_:)), r.keyId))
        sub.addItem(single("Keep project 30d", #selector(keepProject(_:)), r.keyId))
        sub.addItem(single("Terminate", #selector(killOne(_:)), r.keyId))
        sub.addItem(single("Force Kill…", #selector(forceKill(_:)), r.keyId))
        sub.addItem(single("Dismiss", #selector(dismissOne(_:)), r.keyId))
        item.submenu = sub
        return item
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addMono(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        item.isEnabled = false
        menu.addItem(item)
    }

    private func wrap(_ text: String, _ width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > width && !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current += current.isEmpty ? String(word) : " \(word)"
            }
            if lines.count == 3 { return lines }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private func fmtAge(_ s: Int) -> String {
        s > 86400 ? String(format: "%.1fd", Double(s) / 86400) : String(format: "%.1fh", Double(s) / 3600)
    }

    private func fmtBytes(_ b: UInt64) -> String {
        b > 1_073_741_824 ? String(format: "%.1fGiB", Double(b) / 1_073_741_824)
                          : String(format: "%.0fMiB", Double(b) / 1_048_576)
    }

    private func single(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = [key]
        return item
    }

    private func bulk(_ title: String, _ sel: Selector, _ keys: [String]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.representedObject = keys
        return item
    }

    private func keys(_ sender: NSMenuItem) -> [String] {
        sender.representedObject as? [String] ?? []
    }

    @objc func keepInstance(_ sender: NSMenuItem) {
        for k in keys(sender) { _ = daemonRequest(["cmd": "keep", "key": k, "scope": "instance"]) }
        refreshIcon()
    }

    @objc func keepProject(_ sender: NSMenuItem) {
        for k in keys(sender) { _ = daemonRequest(["cmd": "keep", "key": k, "scope": "project"]) }
        refreshIcon()
    }

    @objc func keepMany(_ sender: NSMenuItem) { keepProject(sender) }

    private func killAsync(_ list: [String], force: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for k in list { _ = self?.daemonRequest(["cmd": "kill", "key": k, "force": force]) }
            self?.refreshIcon()
        }
    }

    @objc func killOne(_ sender: NSMenuItem) {
        killAsync(keys(sender), force: false)
    }

    @objc func killMany(_ sender: NSMenuItem) {
        let list = keys(sender)
        let alert = NSAlert()
        alert.messageText = "Terminate \(list.count) processes?"
        alert.informativeText = "Each gets identity revalidation and SIGTERM. Survivors stay flagged."
        alert.addButton(withTitle: "Terminate All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        killAsync(list, force: false)
    }

    @objc func forceKill(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Force kill (SIGKILL)?"
        alert.informativeText = "No cleanup, no state flush. Only for processes that ignored Terminate."
        alert.addButton(withTitle: "SIGKILL")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        killAsync(keys(sender), force: true)
    }

    @objc func dismissOne(_ sender: NSMenuItem) {
        for k in keys(sender) { _ = daemonRequest(["cmd": "dismiss", "key": k]) }
        refreshIcon()
    }

    @objc func dismissMany(_ sender: NSMenuItem) { dismissOne(sender) }

    @objc func toggleMode(_ sender: NSMenuItem) {
        let current = daemonRequest(["cmd": "summary"])?["mode"] as? String ?? "audit"
        let next = current == "audit" ? "enforce" : "audit"
        if next == "enforce" {
            let alert = NSAlert()
            alert.messageText = "Enable enforce mode?"
            alert.informativeText = "Auto-reap activates for the http.server orphan class only, with all safety gates. Everything else stays review-only."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        _ = daemonRequest(["cmd": "mode", "value": next])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MenuController()
controller.start()
app.run()
