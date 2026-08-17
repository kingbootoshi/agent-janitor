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
            button.image = Self.booIcon(alert: pending != 0)
            button.imagePosition = .imageLeft
            let count = pending > 0 ? " \(pending)" : (pending < 0 ? " ?" : "")
            button.attributedTitle = NSAttributedString(string: count, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .baselineOffset: 0.5
            ])
        }
    }

    static func booIcon(alert: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            let body = NSBezierPath()
            body.move(to: NSPoint(x: 2.2, y: 3.6))
            body.line(to: NSPoint(x: 2.2, y: 9.5))
            body.appendArc(withCenter: NSPoint(x: 9, y: 9.5), radius: 6.8,
                           startAngle: 180, endAngle: 0, clockwise: false)
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
                                startAngle: 180, endAngle: 360, clockwise: true)
                mouth.lineWidth = 1.1
                mouth.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = daemonRequest(["cmd": "summary"])
        let flagReply = daemonRequest(["cmd": "flags"])
        flags = flagReply?["flags"] as? [[String: Any]] ?? []

        if let s = summary {
            let mode = s["mode"] as? String ?? "?"
            let selfMB = String(format: "%.0f", s["self_footprint_mb"] as? Double ?? 0)
            let header = NSMenuItem(title: "mode \(mode) · tracking \(s["tracked"] ?? 0) · self \(selfMB)MB", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let pressure = NSMenuItem(title: "pressure \(s["pressure"] ?? "?") · swap \(Int(s["swap_mb"] as? Double ?? 0))MB", action: nil, keyEquivalent: "")
            pressure.isEnabled = false
            menu.addItem(pressure)
        } else {
            let dead = NSMenuItem(title: "daemon unreachable", action: nil, keyEquivalent: "")
            dead.isEnabled = false
            menu.addItem(dead)
        }
        menu.addItem(.separator())

        if flags.isEmpty {
            let clean = NSMenuItem(title: "nothing flagged - all clean", action: nil, keyEquivalent: "")
            clean.isEnabled = false
            menu.addItem(clean)
        }

        for (i, f) in flags.enumerated() {
            let sig = f["signature"] as? String ?? "?"
            let project = f["project"] as? String ?? ""
            let age = f["ageSeconds"] as? Int ?? 0
            let fp = (f["footprint"] as? NSNumber)?.uint64Value ?? 0
            let ageStr = age > 86400 ? String(format: "%.1fd", Double(age) / 86400) : String(format: "%.1fh", Double(age) / 3600)
            let fpStr = fp > 1_073_741_824
                ? String(format: "%.1fGiB", Double(fp) / 1_073_741_824)
                : String(format: "%.0fMiB", Double(fp) / 1_048_576)
            let title = "\(sig)\(project.isEmpty ? "" : " · \(project)") · \(ageStr) · \(fpStr)"

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()

            let reason = NSMenuItem(title: f["reason"] as? String ?? "", action: nil, keyEquivalent: "")
            reason.isEnabled = false
            sub.addItem(reason)
            if let lv = f["lunaVerdict"] as? String {
                let luna = NSMenuItem(title: "luna: \(lv) - \(f["lunaReason"] as? String ?? "")", action: nil, keyEquivalent: "")
                luna.isEnabled = false
                sub.addItem(luna)
            }
            let cmdLine = NSMenuItem(title: String((f["command"] as? String ?? "").prefix(80)), action: nil, keyEquivalent: "")
            cmdLine.isEnabled = false
            sub.addItem(cmdLine)
            sub.addItem(.separator())

            sub.addItem(action("Keep (this instance)", #selector(keepInstance(_:)), i))
            sub.addItem(action("Keep for this project (30d)", #selector(keepProject(_:)), i))
            sub.addItem(action("Terminate", #selector(killOne(_:)), i))
            sub.addItem(action("Force Kill", #selector(forceKill(_:)), i))
            sub.addItem(action("Dismiss", #selector(dismissOne(_:)), i))

            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let modeToggle = NSMenuItem(title: (summary?["mode"] as? String == "audit") ? "Enable enforce mode" : "Switch to audit mode",
                                    action: #selector(toggleMode(_:)), keyEquivalent: "")
        modeToggle.target = self
        menu.addItem(modeToggle)
        let quit = NSMenuItem(title: "Quit Menu (daemon keeps running)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func action(_ title: String, _ sel: Selector, _ tag: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private func key(_ tag: Int) -> String? {
        guard tag < flags.count else { return nil }
        return flags[tag]["keyId"] as? String
    }

    @objc func keepInstance(_ sender: NSMenuItem) {
        guard let k = key(sender.tag) else { return }
        _ = daemonRequest(["cmd": "keep", "key": k, "scope": "instance"])
        refreshIcon()
    }

    @objc func keepProject(_ sender: NSMenuItem) {
        guard let k = key(sender.tag) else { return }
        _ = daemonRequest(["cmd": "keep", "key": k, "scope": "project"])
        refreshIcon()
    }

    @objc func killOne(_ sender: NSMenuItem) {
        guard let k = key(sender.tag) else { return }
        _ = daemonRequest(["cmd": "kill", "key": k, "force": false])
        refreshIcon()
    }

    @objc func forceKill(_ sender: NSMenuItem) {
        guard let k = key(sender.tag) else { return }
        let alert = NSAlert()
        alert.messageText = "Force kill this process?"
        alert.informativeText = flags[sender.tag]["command"] as? String ?? ""
        alert.addButton(withTitle: "SIGKILL")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = daemonRequest(["cmd": "kill", "key": k, "force": true])
        refreshIcon()
    }

    @objc func dismissOne(_ sender: NSMenuItem) {
        guard let k = key(sender.tag) else { return }
        _ = daemonRequest(["cmd": "dismiss", "key": k])
        refreshIcon()
    }

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
