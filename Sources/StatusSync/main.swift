import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var snapshot = Snapshot()
    private var paused = false
    private var engine: Engine!
    private var engineTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        promptForAccessibility()
        engine = Engine { [weak self] snapshot in
            DispatchQueue.main.async { self?.show(snapshot) }
        }
        show(snapshot)
        engineTask = Task { await engine.run() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        engineTask?.cancel()
        Task {
            await engine.revertAll()
            await MainActor.run { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    private func show(_ snapshot: Snapshot) {
        let summary = [snapshot.headline, snapshot.gatherInfo, snapshot.teamsInfo, snapshot.problem ?? ""]
        let previous = [self.snapshot.headline, self.snapshot.gatherInfo, self.snapshot.teamsInfo, self.snapshot.problem ?? ""]
        if summary != previous { NSLog("StatusSync: %@", summary.filter { !$0.isEmpty }.joined(separator: " · ")) }
        self.snapshot = snapshot
        statusItem.button?.image = Icon.image(for: snapshot.mode, problem: snapshot.problem != nil)
        statusItem.button?.toolTip = "StatusSync – \(snapshot.headline)"
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(info(snapshot.headline))
        menu.addItem(info(snapshot.gatherInfo))
        menu.addItem(info(snapshot.teamsInfo))
        if let problem = snapshot.problem { menu.addItem(info("⚠️ \(problem)")) }
        if !AXIsProcessTrusted() { menu.addItem(info("⚠️ Bedienungshilfen-Berechtigung fehlt")) }
        menu.addItem(.separator())

        menu.addItem(item(paused ? "Fortsetzen" : "Pausieren", #selector(togglePause)))
        menu.addItem(item("Gather mit Debug-Port neu starten", #selector(restartGather)))
        let login = item("Beim Login starten", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("StatusSync beenden", #selector(quit)))
        return menu
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func togglePause() {
        paused.toggle()
        let value = paused
        Task { await engine.setPaused(value) }
    }

    @objc private func restartGather() {
        Task { await engine.restartGather() }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("StatusSync: Login-Item: %@", "\(error)")
        }
        statusItem.menu = buildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icons" {
    try Icon.render(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-app-icon" {
    try Icon.renderAppIcon(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
