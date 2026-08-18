import AppKit
import JanitorCore

final class MenuController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var timer: Timer?
    var flags: [[String: Any]] = []

    func start() {
        menu.delegate = self
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

    static func booIcon(alert: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 2.2, y: 3.6))
            body.line(to: NSPoint(x: 2.2, y: 9.5))
            body.appendArc(withCenter: NSPoint(x: 9, y: 9.5), radius: 6.8,
                           startAngle: 180, endAngle: 0, clockwise: true)
            body.line(to: NSPoint(x: 15.8, y: 3.6))
            body.curve(to: NSPoint(x: 13.5, y: 3.6),
                       controlPoint1: NSPoint(x: 15.0, y: 1.7), controlPoint2: NSPoint(x: 14.3, y: 1.7))
            body.curve(to: NSPoint(x: 11.25, y: 3.6),
                       controlPoint1: NSPoint(x: 12.75, y: 5.4), controlPoint2: NSPoint(x: 12.0, y: 5.4))
            body.curve(to: NSPoint(x: 9, y: 3.6),
                       controlPoint1: NSPoint(x: 10.5, y: 1.7), controlPoint2: NSPoint(x: 9.75, y: 1.7))
            body.curve(to: NSPoint(x: 6.75, y: 3.6),
                       controlPoint1: NSPoint(x: 8.25, y: 5.4), controlPoint2: NSPoint(x: 7.5, y: 5.4))
            body.curve(to: NSPoint(x: 4.5, y: 3.6),
                       controlPoint1: NSPoint(x: 6.0, y: 1.7), controlPoint2: NSPoint(x: 5.25, y: 1.7))
            body.curve(to: NSPoint(x: 2.2, y: 3.6),
                       controlPoint1: NSPoint(x: 3.75, y: 5.4), controlPoint2: NSPoint(x: 3.0, y: 5.4))
            body.close()
            NSColor.black.setFill()
            body.fill()

            NSGraphicsContext.current?.compositingOperation = .destinationOut
            let leftEye = NSBezierPath(ovalIn: NSRect(x: 5.4, y: 8.3, width: 2.4, height: alert ? 3.4 : 2.4))
            let rightEye = NSBezierPath(ovalIn: NSRect(x: 10.2, y: 8.3, width: 2.4, height: alert ? 3.4 : 2.4))
            leftEye.fill()
            rightEye.fill()
            if !alert {
                let mouth = NSBezierPath()
                mouth.move(to: NSPoint(x: 7.2, y: 6.4))
                mouth.appendArc(withCenter: NSPoint(x: 9, y: 6.4), radius: 1.8,
                                startAngle: 180, endAngle: 360, clockwise: false)
                mouth.lineWidth = 1.1
                mouth.stroke()
            }
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
        var lunaVerdict: String?
        var lunaReason: String?
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
                command: f["command"] as? String ?? "",
                lunaVerdict: f["lunaVerdict"] as? String,
                lunaReason: f["lunaReason"] as? String)
        }

        if let s = summary {
            let selfMB = String(format: "%.0f", s["self_footprint_mb"] as? Double ?? 0)
            addInfo(menu, "\(s["mode"] ?? "?") mode · \(s["tracked"] ?? 0) tracked · janitor \(selfMB)MB · pressure \(s["pressure"] ?? "?")")
        } else {
            addInfo(menu, "daemon unreachable")
        }
        menu.addItem(.separator())

        if let top = daemonRequest(["cmd": "top", "n": 8]), let vm = top["vm"] as? [String: Any] {
            let gb = { (k: String) in Double((vm[k] as? NSNumber)?.uint64Value ?? 0) / 1_073_741_824 }
            addMono(menu, String(format: "memory used  %5.1f / %.0f GB", gb("used"), gb("physical")))
            addMono(menu, String(format: "app %.1f · wired %.1f · compressed %.1f", gb("app"), gb("wired"), gb("compressed")))
            addMono(menu, String(format: "cached files %.1f (frees itself)", gb("cached")))
            menu.addItem(.separator())
            let groups = top["groups"] as? [[String: Any]] ?? []
            var yoursTotal: UInt64 = 0
            for g in groups {
                let bytes = (g["bytes"] as? NSNumber)?.uint64Value ?? 0
                yoursTotal += bytes
                let count = g["count"] as? Int ?? 0
                let sig = String((g["sig"] as? String ?? "?").prefix(22))
                addMono(menu, String(format: "%7@  %@%@", fmtBytes(bytes) as NSString, sig, count > 1 ? " ×\(count)" : ""))
            }
            let otherBytes = (top["other_bytes"] as? NSNumber)?.uint64Value ?? 0
            let otherCount = top["other_count"] as? Int ?? 0
            yoursTotal += otherBytes
            addMono(menu, String(format: "%7@  %d smaller processes", fmtBytes(otherBytes) as NSString, otherCount))
            let systemBytes = max(0, Int64((vm["app"] as? NSNumber)?.int64Value ?? 0) - Int64(yoursTotal))
            addMono(menu, String(format: "%7@  system + other users", fmtBytes(UInt64(systemBytes)) as NSString))
            menu.addItem(.separator())
        }

        if rows.isEmpty {
            addInfo(menu, "all clean - nothing flagged")
        }

        var groups: [String: [Row]] = [:]
        for r in rows { groups[r.signature + "|" + r.project, default: []].append(r) }
        let ordered = groups.values.sorted {
            $0.reduce(0) { $1.footprint > 100_000_000 ? $0 + $1.footprint : $0 + $1.footprint } >
            $1.reduce(0) { $1.footprint > 100_000_000 ? $0 + $1.footprint : $0 + $1.footprint }
        }

        for group in ordered {
            if group.count == 1 {
                menu.addItem(flagItem(group[0]))
            } else {
                let total = group.reduce(UInt64(0)) { $0 + $1.footprint }
                let ages = group.map(\.age)
                let first = group[0]
                let title = "\(glyph(group)) \(group.count)× \(first.signature)\(first.project.isEmpty ? "" : " · \(first.project)") · \(fmtAge(ages.min() ?? 0))-\(fmtAge(ages.max() ?? 0)) · \(fmtBytes(total))"
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
        let modeToggle = NSMenuItem(title: (summary?["mode"] as? String == "audit") ? "Enable enforce mode" : "Switch to audit mode",
                                    action: #selector(toggleMode(_:)), keyEquivalent: "")
        modeToggle.target = self
        menu.addItem(modeToggle)
        let quit = NSMenuItem(title: "Quit Menu (daemon keeps running)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func glyph(_ group: [Row]) -> String {
        let verdicts = Set(group.compactMap(\.lunaVerdict))
        if verdicts == ["dead"] { return "✕" }
        if verdicts == ["active"] { return "●" }
        if verdicts.isEmpty { return "•" }
        return "?"
    }

    private func flagItem(_ r: Row, compact: Bool = false) -> NSMenuItem {
        let title = compact
            ? "pid \(r.keyId.split(separator: ".").first.map(String.init) ?? "?") · \(fmtAge(r.age)) · \(fmtBytes(r.footprint))"
            : "\(glyph([r])) \(r.signature)\(r.project.isEmpty ? "" : " · \(r.project)") · \(fmtAge(r.age)) · \(fmtBytes(r.footprint))"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for line in wrap(r.reason, 46) { addInfo(sub, line) }
        if let lv = r.lunaVerdict {
            for line in wrap("luna \(lv): \(r.lunaReason ?? "")", 46) { addInfo(sub, line) }
        }
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
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
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

    @objc func killOne(_ sender: NSMenuItem) {
        for k in keys(sender) { _ = daemonRequest(["cmd": "kill", "key": k, "force": false]) }
        refreshIcon()
    }

    @objc func killMany(_ sender: NSMenuItem) {
        let list = keys(sender)
        let alert = NSAlert()
        alert.messageText = "Terminate \(list.count) processes?"
        alert.informativeText = "Each gets identity revalidation and SIGTERM. Survivors stay flagged."
        alert.addButton(withTitle: "Terminate All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for k in list { _ = daemonRequest(["cmd": "kill", "key": k, "force": false]) }
        refreshIcon()
    }

    @objc func forceKill(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Force kill (SIGKILL)?"
        alert.informativeText = "No cleanup, no state flush. Only for processes that ignored Terminate."
        alert.addButton(withTitle: "SIGKILL")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for k in keys(sender) { _ = daemonRequest(["cmd": "kill", "key": k, "force": true]) }
        refreshIcon()
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
