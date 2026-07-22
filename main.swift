import Cocoa

// DontSleepMac — menu-bar control for macOS sleep.
//
// Two modes, set from the right-click menu:
//   • Keep display on        → caffeinate -d  (screen stays awake)
//   • Display off, stay awake → caffeinate -i  (screen may sleep, machine keeps working)
//
// The icon reflects the REAL system state, polled every 5s. If any other app
// (an external `caffeinate`, Amphetamine, etc.) is keeping the Mac awake, the
// icon shows it too — one glance tells you the truth, whoever caused it.
//
//   grey  eye-slash → nothing preventing sleep (normal)
//   red   eye       → display staying on
//   amber moon      → display off / free to sleep, but machine stays awake
//
// caffeinate is launched with `-w <our pid>` so it can never outlive this app.

enum AwakeState { case normal, displayOn, screenOffAwake }

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var task: Process?          // our own caffeinate, if we started one
    private var ourMode: AwakeState = .normal
    private var timer: Timer?

    private let displayItem = NSMenuItem(title: "Keep display on", action: #selector(toggleDisplayOn), keyEquivalent: "")
    private let screenOffItem = NSMenuItem(title: "Display off, stay awake", action: #selector(toggleScreenOff), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        displayItem.target = self
        screenOffItem.target = self
        menu.addItem(displayItem)
        menu.addItem(screenOffItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DontSleepMac", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu

        refresh()
        // Poll real system state every 5s so external tools are reflected.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Menu actions (mutually exclusive; clicking the active one turns it off)

    @objc private func toggleDisplayOn() {
        let wasOn = (ourMode == .displayOn)
        wasOn ? stopOurCaffeinate() : startOurCaffeinate(flag: "-d", mode: .displayOn)
        refresh()
        if wasOn { warnIfStillHeld() }
    }

    @objc private func toggleScreenOff() {
        let wasOn = (ourMode == .screenOffAwake)
        wasOn ? stopOurCaffeinate() : startOurCaffeinate(flag: "-i", mode: .screenOffAwake)
        refresh()
        if wasOn { warnIfStillHeld() }
    }

    /// After we release our own hold, if the Mac is STILL being kept awake by
    /// something else, tell the user who — so a "nothing happened" icon makes sense.
    private func warnIfStillHeld() {
        let holders = externalHolders()
        guard systemState() != .normal, !holders.isEmpty else { return }
        let list = holders.map { "• \($0)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Turned off, but your Mac is still awake"
        alert.informativeText = "These are still preventing sleep:\n\n\(list)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startOurCaffeinate(flag: String, mode: AwakeState) {
        stopOurCaffeinate()  // only one of our own at a time
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w <pid>: auto-exit when this app exits, so we never orphan.
        p.arguments = [flag, "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                if self?.task != nil { self?.task = nil; self?.ourMode = .normal; self?.refresh() }
            }
        }
        do {
            try p.run()
            task = p
            ourMode = mode
        } catch {
            task = nil
            ourMode = .normal
            NSSound.beep()
        }
    }

    private func stopOurCaffeinate() {
        task?.terminate()
        task = nil
        ourMode = .normal
    }

    // MARK: - Reality: read the actual system sleep assertions

    /// Returns the true current state by inspecting pmset assertions, so external
    /// caffeinate / Amphetamine / etc. are reflected — not just our own toggles.
    private func systemState() -> AwakeState {
        guard let out = runPmsetAssertions() else { return ourMode }

        // Overall assertion levels (last summary value wins).
        let displayPrevented = assertionLevel(in: out, key: "PreventUserIdleDisplaySleep") == 1

        // For "machine awake" we must ignore the incidental powerd assertion that
        // exists only because the display is currently on. Count a real keep-awake
        // source only if a non-powerd process owns a system/display sleep assertion.
        let systemHeldByRealSource = out
            .split(separator: "\n")
            .contains { line in
                line.contains("pid ") &&
                (line.contains("PreventUserIdleSystemSleep") || line.contains("PreventSystemSleep")) &&
                !line.contains("powerd") && !line.contains("coreaudiod")
            }

        if displayPrevented { return .displayOn }
        if systemHeldByRealSource { return .screenOffAwake }
        return .normal
    }

    /// Human-readable names of external processes currently preventing sleep
    /// (excludes our own caffeinate and the incidental powerd/coreaudiod holders).
    private func externalHolders() -> [String] {
        guard let out = runPmsetAssertions() else { return [] }
        let ourPid = task?.processIdentifier
        var names: [String] = []
        for line in out.split(separator: "\n") {
            guard line.contains("pid "),
                  line.contains("PreventUserIdleDisplaySleep")
                    || line.contains("PreventUserIdleSystemSleep")
                    || line.contains("PreventSystemSleep") else { continue }
            if line.contains("powerd") || line.contains("coreaudiod") { continue }
            // Extract "pid 1234(procname)"
            guard let r = line.range(of: #"pid (\d+)\(([^)]+)\)"#, options: .regularExpression) else { continue }
            let frag = String(line[r])
            let pidStr = frag.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
            if let ourPid, Int(pidStr) == Int(ourPid) { continue }  // skip our own
            if let np = frag.firstIndex(of: "("), let ep = frag.firstIndex(of: ")") {
                let name = String(frag[frag.index(after: np)..<ep])
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    private func runPmsetAssertions() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Parse the top summary block value, e.g. "   PreventUserIdleDisplaySleep    1".
    private func assertionLevel(in text: String, key: String) -> Int {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key) {
                return t.hasSuffix("1") ? 1 : 0
            }
        }
        return 0
    }

    // MARK: - Render

    private func refresh() {
        let state = systemState()
        updateIcon(for: state)
        // Keep our menu checkmarks honest with what's actually happening.
        displayItem.state = (state == .displayOn) ? .on : .off
        screenOffItem.state = (state == .screenOffAwake) ? .on : .off
    }

    private func updateIcon(for state: AwakeState) {
        guard let button = statusItem.button else { return }
        let tip: String
        switch state {
        case .normal:          tip = "Normal — Mac sleeps per your settings"
        case .displayOn:       tip = "Display staying on"
        case .screenOffAwake:  tip = "Display off — machine staying awake"
        }
        button.image = Self.eyeIcon(for: state)   // custom-drawn glyph
        button.toolTip = tip
    }

    /// Custom menu-bar glyphs (drawn in code, crisp at any scale):
    ///   .displayOn      → open red eye
    ///   .screenOffAwake → half-shut red eye (still awake, screen dark)
    ///   .normal         → grey closed eye
    private static func eyeIcon(for state: AwakeState) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let red = NSColor.systemRed
        let grey = NSColor.secondaryLabelColor
        let c = NSPoint(x: side/2, y: side/2)
        let hw: CGFloat = 7.5   // half-width of eye
        let lw: CGFloat = 1.6

        func stroke(_ p: NSBezierPath, _ color: NSColor) {
            color.setStroke(); p.lineWidth = lw; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
        }

        switch state {
        case .displayOn:
            // open eye: two symmetric arcs + iris
            let e = NSBezierPath()
            e.move(to: NSPoint(x: c.x-hw, y: c.y))
            e.curve(to: NSPoint(x: c.x+hw, y: c.y), controlPoint1: NSPoint(x: c.x-2, y: c.y+6), controlPoint2: NSPoint(x: c.x+2, y: c.y+6))
            e.curve(to: NSPoint(x: c.x-hw, y: c.y), controlPoint1: NSPoint(x: c.x+2, y: c.y-6), controlPoint2: NSPoint(x: c.x-2, y: c.y-6))
            stroke(e, red)
            let iris = NSBezierPath(ovalIn: NSRect(x: c.x-2.6, y: c.y-2.6, width: 5.2, height: 5.2))
            red.setFill(); iris.fill()

        case .screenOffAwake:
            // half-shut eye: flat upper lid + bottom arc, half iris peeking
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: c.x-hw, y: c.y+0.5)); lid.line(to: NSPoint(x: c.x+hw, y: c.y+0.5))
            stroke(lid, red)
            let bot = NSBezierPath()
            bot.move(to: NSPoint(x: c.x-hw, y: c.y+0.5))
            bot.curve(to: NSPoint(x: c.x+hw, y: c.y+0.5), controlPoint1: NSPoint(x: c.x-2, y: c.y-5), controlPoint2: NSPoint(x: c.x+2, y: c.y-5))
            stroke(bot, red)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: c.x-hw, y: c.y-5, width: hw*2, height: 5.4)).addClip()
            let iris = NSBezierPath(ovalIn: NSRect(x: c.x-2.4, y: c.y-3, width: 4.8, height: 4.8))
            red.setFill(); iris.fill()
            NSGraphicsContext.restoreGraphicsState()

        case .normal:
            // closed eye: gentle downward lid + small lashes
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: c.x-hw, y: c.y+0.5))
            lid.curve(to: NSPoint(x: c.x+hw, y: c.y+0.5), controlPoint1: NSPoint(x: c.x-2, y: c.y-4), controlPoint2: NSPoint(x: c.x+2, y: c.y-4))
            stroke(lid, grey)
            for dx in [-5.0, -1.5, 2.0, 5.5] {
                let l = NSBezierPath()
                l.move(to: NSPoint(x: c.x+CGFloat(dx), y: c.y-2))
                l.line(to: NSPoint(x: c.x+CGFloat(dx)-0.8, y: c.y-4.5))
                l.lineWidth = 1.2; grey.setStroke(); l.lineCapStyle = .round; l.stroke()
            }
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    @objc private func quit() {
        stopOurCaffeinate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
