import Cocoa

// DontSleepMac — menu-bar control for macOS sleep.
//
// Two modes, set from the right-click menu:
//   • Stay Awake — Display On  → caffeinate -d  (screen stays awake)
//   • Stay Awake — Display Off → caffeinate -i  (screen may sleep, machine keeps working)
//
// The icon reflects the REAL system state, polled every 5s. If any other app
// (an external `caffeinate`, Chrome playing video, Amphetamine, etc.) is keeping
// the Mac awake, the icon shows it too — one glance tells you the truth, whoever
// caused it. Clicking a mode that is already ON always means "turn it off": if
// the hold isn't ours, we say who owns it instead of silently doing nothing.
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

    /// Left-click: if the Mac is being kept awake (by us or anyone), turn it off;
    /// otherwise start the last-used mode. Right-click: open the menu.
    @objc private func statusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil          // detach so left-click keeps toggling
        } else if systemState() == .normal {
            toggle(to: lastMode)
        } else {
            turnOff()
        }
    }

    // MARK: - Menu actions (mutually exclusive; clicking the active one turns it off)

    @objc private func toggleDisplayOn() { toggle(to: .displayOn) }
    @objc private func toggleScreenOff() { toggle(to: .screenOffAwake) }

    /// Clicking a mode that is *shown* as on means "turn it off" — the checkmark
    /// tracks the real system state, so it can be on because of another app.
    /// In that case we release whatever we hold and then name the real owner,
    /// instead of arming a fresh caffeinate and looking like nothing happened.
    private func toggle(to mode: AwakeState) {
        if ourMode == mode || systemState() == mode {
            turnOff()
            return
        }
        lastMode = mode
        startOurCaffeinate(flag: mode == .displayOn ? "-d" : "-i", mode: mode)
        refresh()
    }

    private func turnOff() {
        let killed = stopOurCaffeinate()
        refresh()
        explainIfStillAwake(weReleased: killed != nil, excludingPid: killed)
    }

    /// After a turn-off, if the Mac is STILL awake, say exactly who is holding it —
    /// so a "nothing happened" icon always comes with an explanation.
    /// `excludingPid` is our just-killed caffeinate, so we never blame ourselves.
    private func explainIfStillAwake(weReleased: Bool, excludingPid: Int32?) {
        guard systemState() != .normal else { return }
        let holders = externalHolders(excludingPid: excludingPid)

        var body = weReleased ? ""
            : "DontSleepMac isn't holding your Mac awake right now, so there was nothing for it to switch off.\n\n"
        if holders.isEmpty {
            body += "Something is still preventing sleep but isn't reporting a process name. "
                  + "Run `pmset -g assertions` in Terminal to see the raw list."
        } else {
            body += "Still preventing sleep:\n\n"
                  + holders.map { "• \($0.full)" }.joined(separator: "\n")
                  + "\n\nQuit or stop these to let your Mac sleep."
        }

        let alert = NSAlert()
        alert.messageText = weReleased ? "Turned off — but your Mac is still awake"
                                       : "Something else is keeping your Mac awake"
        alert.informativeText = body
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

    /// One sleep assertion held by one process, as reported by `pmset -g assertions`.
    private struct Holder {
        let pid: Int
        let proc: String        // process name pmset prints, e.g. "caffeinate"
        let type: String        // assertion type, e.g. "NoDisplaySleepAssertion"
        let detail: String      // the `named: "..."` text, e.g. "Video Wake Lock"
        var behalfPid: Int?     // the process it is asserting FOR, if it says so
    }

    // Assertion types that keep the DISPLAY on. Apple prints both the modern
    // "Prevent*" names and the older "No*Assertion" aliases, depending on which
    // API the process used — matching only the first set misses Chrome, Zoom, etc.
    private static let displayTypes: Set<String> = [
        "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "PreventDisplayIdleSleep",
    ]
    // Assertion types that keep the MACHINE awake with the display free to sleep.
    private static let systemTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "InternalPreventSleep",
    ]

    // "   pid 6103(Google Chrome): [0x000…] 00:04:29 NoDisplaySleepAssertion named: "Video Wake Lock""
    private static let assertionRe = try! NSRegularExpression(
        pattern: #"pid (\d+)\(([^)]*)\):\s*\[[^\]]*\]\s*\S+\s+(\w+)\s+named:\s*"([^"]*)""#)
    // Continuation lines: "Created for PID: 743." / "asserting on behalf of Process ID 743"
    private static let behalfRe = try! NSRegularExpression(
        pattern: #"(?:Created for PID:|on behalf of Process ID)\s*(\d+)"#)

    /// Every assertion currently keeping the Mac awake, ours included.
    /// Returns nil if pmset could not be read at all (caller keeps its last state).
    private func currentHolders() -> [Holder]? {
        guard let out = runPmsetAssertions() else { return nil }
        var holders: [Holder] = []
        var attachTo: Int? = nil    // index the next "Created for PID:" line belongs to

        for raw in out.split(separator: "\n") {
            let line = String(raw)
            let ns = line as NSString
            let whole = NSRange(location: 0, length: ns.length)

            if let m = Self.assertionRe.firstMatch(in: line, range: whole) {
                let pid = Int(ns.substring(with: m.range(at: 1))) ?? -1
                let proc = ns.substring(with: m.range(at: 2))
                let type = ns.substring(with: m.range(at: 3))
                let detail = ns.substring(with: m.range(at: 4))
                // Ignore assertions that aren't really a keep-awake source:
                //   powerd    — exists only because the display happens to be on
                //   coreaudiod— duplicates the assertion the playing app holds itself
                let relevant = (Self.displayTypes.contains(type) || Self.systemTypes.contains(type))
                    && proc != "powerd" && proc != "coreaudiod"
                if relevant {
                    holders.append(Holder(pid: pid, proc: proc, type: type, detail: detail))
                    attachTo = holders.count - 1
                } else {
                    attachTo = nil   // don't let a skipped block's detail lines leak upward
                }
            } else if let i = attachTo, holders[i].behalfPid == nil,
                      let m = Self.behalfRe.firstMatch(in: line, range: whole) {
                holders[i].behalfPid = Int(ns.substring(with: m.range(at: 1)))
            }
        }
        return holders
    }

    /// Returns the true current state by inspecting pmset assertions, so external
    /// caffeinate / Chrome / Amphetamine / etc. are reflected — not just our own toggles.
    private func systemState() -> AwakeState {
        guard let holders = currentHolders() else { return ourMode }
        if holders.contains(where: { Self.displayTypes.contains($0.type) }) { return .displayOn }
        if holders.contains(where: { Self.systemTypes.contains($0.type) }) { return .screenOffAwake }
        return .normal
    }

    /// Processes currently preventing sleep, excluding our own caffeinate.
    /// `short` is a bare name for the menu line; `full` adds pid and reason.
    /// `excludingPid` is our just-terminated caffeinate — excluded so we never
    /// list ourselves right after toggling off.
    private func externalHolders(excludingPid: Int32? = nil) -> [(short: String, full: String)] {
        guard let holders = currentHolders() else { return [] }
        let table = processTable()
        let ourPid = Int(ProcessInfo.processInfo.processIdentifier)
        var skip = Set<Int>()
        if let t = task?.processIdentifier { skip.insert(Int(t)) }
        if let e = excludingPid { skip.insert(Int(e)) }

        var out: [(short: String, full: String)] = []
        for h in holders {
            if skip.contains(h.pid) { continue }
            // Any caffeinate asserting for us is ours, even if `task` was already cleared.
            if h.proc == "caffeinate" && h.behalfPid == ourPid { continue }
            let d = describe(h, table: table)
            if !out.contains(where: { $0.full == d.full }) { out.append(d) }
        }
        return out
    }

    /// Turn one assertion into human text, naming the *real* culprit where possible:
    ///   "Google Chrome (pid 6103) — Video Wake Lock"
    ///   "node (pid 743) — via caffeinate"     ← a bare `caffeinate` says little; its
    ///                                            owner is the process you'd actually quit
    private func describe(_ h: Holder, table: ProcessTable) -> (short: String, full: String) {
        var who = table.names[h.pid] ?? h.proc   // pmset truncates long names; ps has the real one
        var pid = h.pid
        var why = h.detail

        // Helper processes (caffeinate, and anything asserting "on behalf of") are
        // only proxies — resolve to the process that asked for the assertion.
        if let bp = h.behalfPid, bp != h.pid, let owner = table.names[bp] {
            if h.proc == "caffeinate" {
                who = owner; pid = bp; why = "via caffeinate"
            } else {
                who = owner; pid = bp; why = why.isEmpty ? "via \(h.proc)" : "\(why) (via \(h.proc))"
            }
        } else if h.proc == "caffeinate", let bp = h.behalfPid {
            // Owner has exited but caffeinate is still running (a stray).
            who = "caffeinate"; why = "started for pid \(bp), which is gone"
        } else if h.proc == "caffeinate" {
            // A hand-run `caffeinate` names nobody — fall back to whoever launched it
            // (a Terminal, a script, an agent), which is the process you'd go look at.
            who = "caffeinate"
            if let pp = table.parents[h.pid], let parent = table.names[pp] {
                why = "started by \(parent) (pid \(pp))"
            } else {
                why = "command-line tool"
            }
        }

        let full = why.isEmpty ? "\(who) (pid \(pid))" : "\(who) (pid \(pid)) — \(why)"
        return (who, full)
    }

    /// Every running process: pid → executable name (6103 → "Google Chrome") and pid → parent pid.
    private struct ProcessTable { var names: [Int: String] = [:]; var parents: [Int: Int] = [:] }

    private func processTable() -> ProcessTable {
        var t = ProcessTable()
        guard let out = runCommand("/bin/ps", ["-axo", "pid=,ppid=,comm="]) else { return t }
        for line in out.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            let parts = s.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            t.names[pid] = (String(parts[2]) as NSString).lastPathComponent
            t.parents[pid] = ppid
        }
        return t
    }

    private func runPmsetAssertions() -> String? {
        runCommand("/usr/bin/pmset", ["-g", "assertions"])
    }

    private func runCommand(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
        guard let out = runCommand("/bin/ps", ["-axo", "pid=,command="]) else { return [] }
        var result: [(Int, String)] = []
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pid = Int(parts.first ?? ""), parts.count > 1 else { continue }
            let cmd = String(parts[1])
            // Match on the EXECUTABLE only — a shell command that merely mentions
            // "caffeinate" (an echo, a grep) is not a caffeinate process.
            let exe = (String(cmd.split(separator: " ").first ?? "") as NSString).lastPathComponent
            guard exe == "caffeinate" else { continue }
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
        let names = processTable().names
        let ourPid = Int(task?.processIdentifier ?? -1)

        // Our own hold belongs in the list too — saying "nothing is preventing sleep"
        // while this app holds a caffeinate is the confusing part.
        var entries = holders.map { $0.full }
        if ourMode != .normal {
            let mode = ourMode == .displayOn ? "Stay Awake — Display On" : "Stay Awake — Display Off"
            entries.insert("DontSleepMac — \(mode)  ← this app", at: 0)
        }

        var body = entries.isEmpty
            ? "Nothing is preventing sleep.\n"
            : "Preventing sleep:\n" + entries.map { "  • \($0)" }.joined(separator: "\n") + "\n"
        body += "\ncaffeinate processes:\n"
        if caffs.isEmpty {
            body += "  (none)"
        } else {
            body += caffs.map { c in
                var line = "  • pid \(c.pid): \(c.command)"
                if c.pid == ourPid { line += "  ← this app" }
                // Name the process it was started for, so "caffeinate -w 743" means something.
                else if let owner = watchedOwner(of: c.command, names: names) { line += "  ← for \(owner)" }
                return line
            }.joined(separator: "\n")
        }

        let alert = NSAlert()
        alert.messageText = "What's keeping your Mac awake"
        alert.informativeText = body
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// "caffeinate -i -w 743" → "node (pid 743)", if 743 is still alive.
    private func watchedOwner(of command: String, names: [Int: String]) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        guard let i = tokens.firstIndex(of: "-w"), i + 1 < tokens.count,
              let pid = Int(tokens[i + 1]) else { return nil }
        guard let name = names[pid] else { return "pid \(pid) (already gone)" }
        return "\(name) (pid \(pid))"
    }

    /// Plain-text version of the info dialog, for `DontSleepMac --diagnose` in a
    /// terminal — same parsing the menu uses, so what you see there is what the app sees.
    func diagnosticReport() -> String {
        let holders = externalHolders()
        let names = processTable().names
        var entries = holders.map { $0.full }
        if ourMode != .normal {
            entries.insert("DontSleepMac (this app) — \(ourMode == .displayOn ? "Display On" : "Display Off")", at: 0)
        }
        var lines = ["State: \(systemState())"]
        lines.append(entries.isEmpty ? "Preventing sleep: (nothing)"
                                     : "Preventing sleep:\n" + entries.map { "  • \($0)" }.joined(separator: "\n"))
        let caffs = caffeinateProcesses()
        lines.append(caffs.isEmpty ? "caffeinate processes: (none)"
                                   : "caffeinate processes:\n" + caffs.map { c in
                                        let owner = watchedOwner(of: c.command, names: names).map { "  ← for \($0)" } ?? ""
                                        return "  • pid \(c.pid): \(c.command)\(owner)"
                                     }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    // Refresh the info line every time the menu is opened.
    func menuWillOpen(_ menu: NSMenu) {
        var who = externalHolders().map { $0.short }
        if ourMode != .normal { who.insert("DontSleepMac", at: 0) }
        infoItem.title = who.isEmpty ? "Sleeping normally"
                                     : "Kept awake by: " + who.joined(separator: ", ")
    }

    @objc private func quit() {
        stopOurCaffeinate()          // waits for our caffeinate to fully exit
        NSApp.terminate(nil)
    }
}

// `DontSleepMac --diagnose` prints what's keeping the Mac awake and exits —
// no menu bar, no assertions taken.
if CommandLine.arguments.contains("--diagnose") {
    print(AppDelegate().diagnosticReport())
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
