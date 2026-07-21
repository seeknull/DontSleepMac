import Cocoa

// DontSleepMac — menu-bar toggle to prevent display sleep.
// Grey icon = normal (Mac sleeps per settings). Red icon = staying awake.
// Uses `caffeinate -d` (display assertion) — no admin password required.
// Left-click: toggle.  Right-click: menu (Quit).

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var task: Process?
    private var menu: NSMenu!

    private var isAwake: Bool { task != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit DontSleepMac", action: #selector(quit), keyEquivalent: "q"))

        if let button = statusItem.button {
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            isAwake ? stopAwake() : startAwake()
            updateIcon()
        }
    }

    private func startAwake() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-d"]  // -d = prevent DISPLAY sleep
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.task = nil
                self?.updateIcon()
            }
        }
        try? p.run()
        task = p
    }

    private func stopAwake() {
        task?.terminate()
        task = nil
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = isAwake ? "eye.fill" : "eye.slash"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "DontSleep")
        let color: NSColor = isAwake ? .systemRed : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        button.image = img?.withSymbolConfiguration(config)
        button.image?.isTemplate = false
        button.toolTip = isAwake ? "Awake — display won't sleep (click to stop)"
                                 : "Normal — sleeps per settings (click to keep awake)"
    }

    @objc private func quit() {
        stopAwake()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
