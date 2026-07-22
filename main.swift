import Cocoa

// DontSleepMac — menu-bar control for macOS sleep.
//
// Two modes, set from the right-click menu:
//   • Stay Awake — Display On  → caffeinate -d  (screen stays awake)
//   • Stay Awake — Display Off → caffeinate -i  (screen may sleep, machine keeps working)
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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var task: Process?          // our own caffeinate, if we started one
    private var ourMode: AwakeState = .normal
    private var lastMode: AwakeState = .displayOn   // what a plain left-click toggles
    private var timer: Timer?
    private var menu: NSMenu!

    private let displayItem = NSMenuItem(title: "Stay Awake — Display On", action: #selector(toggleDisplayOn), keyEquivalent: "")
    private let screenOffItem = NSMenuItem(title: "Stay Awake — Display Off", action: #selector(toggleScreenOff), keyEquivalent: "")
    private let infoItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let showProcessesItem = NSMenuItem(title: "Show what's keeping Mac awake…", action: #selector(showAwakeProcesses), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safety net: reap any caffeinate we may have orphaned in a past crash
        // before -w bindings existed. (Current runs can't orphan — see startOurCaffeinate.)
        reapOrphanedCaffeinate()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu = NSMenu()
        menu.delegate = self          // refresh the info line each time the menu opens
        displayItem.target = self
        screenOffItem.target = self
        displayItem.image = Self.eyeIcon(for: .displayOn)       // open red eye
        screenOffItem.image = Self.eyeIcon(for: .screenOffAwake) // half-shut red eye
        menu.addItem(displayItem)
        menu.addItem(screenOffItem)
        menu.addItem(.separator())
        infoItem.isEnabled = false    // header/status line, not clickable
        menu.addItem(infoItem)
        showProcessesItem.target = self
        menu.addItem(showProcessesItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit DontSleepMac", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // Left-click toggles the last-used mode; right-click opens the menu.
        if let button = statusItem.button {
            button.action = #selector(statusClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        refresh()
        // Poll real system state every 5s so external tools are reflected.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Status-item click routing

    /// Left-click: toggle the last-used mode on/off. Right-click: open the menu.
    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil          // detach so left-click keeps toggling
        } else {
            lastMode == .screenOffAwake ? toggleScreenOff() : toggleDisplayOn()
        }
    }

    // MARK: - Menu actions (mutually exclusive; clicking the active one turns it off)

    @objc private func toggleDisplayOn() {
        if ourMode == .displayOn {
            let killed = stopOurCaffeinate()
            refresh()
            warnIfStillHeld(excludingPid: killed)
        } else {
            lastMode = .displayOn
            startOurCaffeinate(flag: "-d", mode: .displayOn)
            refresh()
        }
    }

    @objc private func toggleScreenOff() {
        if ourMode == .screenOffAwake {
            let killed = stopOurCaffeinate()
            refresh()
            warnIfStillHeld(excludingPid: killed)
        } else {
            lastMode = .screenOffAwake
            startOurCaffeinate(flag: "-i", mode: .screenOffAwake)
            refresh()
        }
    }

    /// After we release our own hold, if the Mac is STILL being kept awake by
    /// something else, tell the user who — so a "nothing happened" icon makes sense.
    /// `excludingPid` is our just-killed caffeinate, so we never blame ourselves.
    private func warnIfStillHeld(excludingPid: Int32?) {
        let holders = externalHolders(excludingPid: excludingPid)
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

    /// Terminate our caffeinate and WAIT for it to actually exit (so its sleep
    /// assertion is gone before anyone reads pmset). Returns the pid we killed.
    @discardableResult
    private func stopOurCaffeinate() -> Int32? {
        guard let p = task else { ourMode = .normal; return nil }
        let pid = p.processIdentifier
        task = nil
        ourMode = .normal
        p.terminationHandler = nil   // we handle teardown synchronously here
        p.terminate()
        p.waitUntilExit()            // block until the assertion is truly released
        return pid
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
    /// `excludingPid` is our just-terminated caffeinate — excluded so we never
    /// list ourselves right after toggling off.
    private func externalHolders(excludingPid: Int32? = nil) -> [String] {
        guard let out = runPmsetAssertions() else { return [] }
        let skipPids: Set<Int> = [task?.processIdentifier, excludingPid]
            .compactMap { $0 }.map { Int($0) }.reduce(into: Set<Int>()) { $0.insert($1) }
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
            if let pid = Int(pidStr), skipPids.contains(pid) { continue }  // skip our own
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
        case .displayOn:       tip = "Stay Awake — Display On"
        case .screenOffAwake:  tip = "Stay Awake — Display Off"
        }
        button.image = Self.eyeIcon(for: state)   // custom-drawn glyph
        button.toolTip = tip
    }

    /// Menu-bar glyphs:
    ///   .normal         → grey slashed eye (SF Symbol eye.slash)
    ///   .displayOn      → open red eye (custom)
    ///   .screenOffAwake → half-shut red eye (custom — still awake, screen dark)
    private static func eyeIcon(for state: AwakeState) -> NSImage {
        // Off / normal uses the crisp built-in slashed eye.
        if state == .normal {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [.secondaryLabelColor]))
            let img = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "DontSleepMac")?
                .withSymbolConfiguration(cfg) ?? NSImage()
            img.isTemplate = false
            return img
        }

        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high

        let red = NSColor.systemRed
        let c = NSPoint(x: side/2, y: side/2)
        let hw: CGFloat = 7.5   // half-width of eye
        let lw: CGFloat = 1.6

        func stroke(_ p: NSBezierPath, _ color: NSColor) {
            color.setStroke(); p.lineWidth = lw; p.lineJoinStyle = .round; p.lineCapStyle = .round; p.stroke()
        }

        switch state {
        case .normal:
            break  // handled above
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
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - Caffeinate process inventory & cleanup

    /// All running caffeinate processes as (pid, full command) pairs.
    private func caffeinateProcesses() -> [(pid: Int, command: String)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        var result: [(Int, String)] = []
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.contains("/usr/bin/caffeinate") || t.hasSuffix("caffeinate")
                    || t.contains(" caffeinate") else { continue }
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pid = Int(parts.first ?? "") else { continue }
            let cmd = parts.count > 1 ? String(parts[1]) : "caffeinate"
            // Skip the `ps`/grep line itself if any.
            if cmd.contains("-axo") { continue }
            result.append((pid, cmd))
        }
        return result
    }

    /// Kill any caffeinate that is bound to a NO-LONGER-EXISTING pid via `-w`,
    /// i.e. an orphan from a prior crash. Never touches a user's own caffeinate
    /// or one bound to a live process.
    private func reapOrphanedCaffeinate() {
        for proc in caffeinateProcesses() {
            // Look for "-w <pid>" and check whether that pid is still alive.
            let tokens = proc.command.split(separator: " ").map(String.init)
            guard let wIdx = tokens.firstIndex(of: "-w"), wIdx + 1 < tokens.count,
                  let watched = Int32(tokens[wIdx + 1]) else { continue }
            // kill(pid, 0) == -1 with ESRCH means the watched process is gone → orphan.
            if kill(watched, 0) != 0 {
                kill(Int32(proc.pid), SIGTERM)
            }
        }
    }

    /// Info dialog: show every process currently keeping the Mac awake,
    /// plus any caffeinate processes running (so strays are visible).
    @objc private func showAwakeProcesses() {
        let holders = externalHolders()
        let caffs = caffeinateProcesses()
        let ourPid = Int(task?.processIdentifier ?? -1)

        var body = ""
        if holders.isEmpty {
            body += "Nothing is preventing sleep.\n"
        } else {
            body += "Preventing sleep:\n" + holders.map { "  • \($0)" }.joined(separator: "\n") + "\n"
        }
        body += "\ncaffeinate processes:\n"
        if caffs.isEmpty {
            body += "  (none)"
        } else {
            body += caffs.map { c in
                let mine = (c.pid == ourPid) ? "  ← this app" : ""
                return "  • pid \(c.pid): \(c.command)\(mine)"
            }.joined(separator: "\n")
        }

        let alert = NSAlert()
        alert.messageText = "What's keeping your Mac awake"
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Refresh the info line every time the menu is opened.
    func menuWillOpen(_ menu: NSMenu) {
        let holders = externalHolders()
        let caffCount = caffeinateProcesses().count
        if holders.isEmpty {
            infoItem.title = caffCount == 0 ? "Sleeping normally" : "Awake"
        } else {
            infoItem.title = "Kept awake by: " + holders.joined(separator: ", ")
        }
    }

    @objc private func quit() {
        stopOurCaffeinate()          // waits for our caffeinate to fully exit
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
