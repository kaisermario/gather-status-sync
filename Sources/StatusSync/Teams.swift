import AppKit
import ApplicationServices

enum TeamsError: Error, CustomStringConvertible {
    case notRunning, noWindow, notFound(String)

    var description: String {
        switch self {
        case .notRunning: return "Teams läuft nicht"
        case .noWindow: return "Teams-Fenster nicht gefunden"
        case .notFound(let what): return "Teams-Element nicht gefunden: \(what)"
        }
    }
}

/// Drives the (German) new-Teams UI through the Accessibility API and key events posted
/// to the Teams process, so Teams never comes to the foreground.
final class Teams {
    static let bundlePrefix = "com.microsoft.teams2"
    static let doNotDisturb = "Nicht stören"

    private struct Node {
        let element: AXUIElement
        let role: String
        let label: String
    }

    var isRunning: Bool { pid != nil }

    private var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.teams2").first?.processIdentifier
    }

    /// The availability shown on the profile button, e.g. "Verfügbar" or "Nicht stören".
    func availability() throws -> String {
        let pid = try requirePID()
        try closeMenu(pid)
        let button = try waitFor("^Ihr Profil, Status", pid)
        guard let range = button.label.range(of: #"Status ([^|]+)"#, options: .regularExpression) else {
            throw TeamsError.notFound("Status im Profil-Button")
        }
        return String(button.label[range].dropFirst("Status ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Sets "Nicht stören" and, if no status message exists yet, `message`.
    /// Returns whether the message was set.
    func setDoNotDisturb(message: String) throws -> Bool {
        let pid = try requirePID()
        try closeMenu(pid)
        defer { try? closeMenu(pid) }

        try press(waitFor("^Ihr Profil, Status", pid))
        _ = try waitFor("Status ändern", pid)
        let hasMessage = !find("^Ihre aktuelle Statusnachricht", pid).isEmpty
        try press(waitFor("Status ändern", pid))
        try press(waitFor("^\(Teams.doNotDisturb)$", pid))
        _ = try waitFor("^\(Teams.doNotDisturb), Status ändern", pid)

        guard !hasMessage else { return false }
        try press(waitFor("^Statusmeldung festlegen", pid))
        try press(waitFor("^Geben Sie .@. ein", pid))
        usleep(300_000)
        Keys.selectAllAndDelete(pid)
        Keys.type(message, pid)
        usleep(300_000)
        try press(waitFor("^Fertig", pid))
        _ = try waitFor("^Ihre aktuelle Statusnachricht", pid)
        return true
    }

    /// Resets the status to automatic if it is still "Nicht stören", and deletes the status
    /// message if it is still `message`.
    func reset(message: String?) throws {
        let pid = try requirePID()
        try closeMenu(pid)
        defer { try? closeMenu(pid) }

        try press(waitFor("^Ihr Profil, Status", pid))
        let statusItem = try waitFor("Status ändern", pid)
        if statusItem.label.hasPrefix(Teams.doNotDisturb) {
            try press(statusItem)
            try press(waitFor("^Status zurücksetzen", pid))
            _ = try waitFor("^(?!\(Teams.doNotDisturb)).*, Status ändern", pid)
        }
        if let message, find("^Ihre aktuelle Statusnachricht: \(NSRegularExpression.escapedPattern(for: message))", pid).first != nil {
            try press(waitFor("^Statusmeldung löschen", pid))
            usleep(500_000)
        }
    }

    // MARK: - Accessibility helpers

    private func requirePID() throws -> pid_t {
        guard let pid else { throw TeamsError.notRunning }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        // Teams rejects AXManualAccessibility; without this its web content drops AXPress.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        if (attribute(app, "AXWindows") as? [AXUIElement] ?? []).isEmpty { throw TeamsError.noWindow }
        return pid
    }

    /// Closes the profile menu (and the status message dialog) if open: focus an item, then Escape.
    private func closeMenu(_ pid: pid_t) throws {
        for _ in 0..<3 {
            guard !find("^Profilmenü", pid).isEmpty else { return }
            if let item = find(".", pid).first(where: { $0.role == "AXMenuItem" || $0.role == "AXButton" }) {
                AXUIElementSetAttributeValue(item.element, "AXFocused" as CFString, kCFBooleanTrue)
            }
            Keys.escape(pid)
            usleep(500_000)
        }
        if !find("^Profilmenü", pid).isEmpty { throw TeamsError.notFound("Profilmenü ließ sich nicht schließen") }
    }

    private func press(_ node: Node) throws {
        let result = AXUIElementPerformAction(node.element, "AXPress" as CFString)
        guard result == .success else { throw TeamsError.notFound("Klick auf \(node.label) (\(result.rawValue))") }
        usleep(400_000)
    }

    private func waitFor(_ pattern: String, _ pid: pid_t, timeout: TimeInterval = 5) throws -> Node {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let node = find(pattern, pid).first { return node }
            usleep(250_000)
        } while Date() < deadline
        throw TeamsError.notFound(pattern)
    }

    private func find(_ pattern: String, _ pid: pid_t) -> [Node] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var hits: [Node] = []
        var visited = 0

        func walk(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard depth < 60, visited < 20_000 else { return }
            let label = ["AXTitle", "AXDescription", "AXHelp", "AXValue"]
                .compactMap { attribute(element, $0) as? String }
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
            if !label.isEmpty, regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil {
                hits.append(Node(element: element, role: attribute(element, "AXRole") as? String ?? "", label: label))
            }
            for child in attribute(element, "AXChildren") as? [AXUIElement] ?? [] {
                walk(child, depth: depth + 1)
            }
        }

        for window in attribute(app, "AXWindows") as? [AXUIElement] ?? [] {
            walk(window, depth: 0)
        }
        return hits
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }
}

/// Keyboard events posted straight to a process; works while it is in the background.
enum Keys {
    static func type(_ text: String, _ pid: pid_t) {
        // One event per UTF-16 unit; Teams drops emoji sent as a single surrogate-pair event.
        for unit in text.utf16 {
            post(0, pid, unicode: [unit])
        }
    }

    static func selectAllAndDelete(_ pid: pid_t) {
        post(0, pid, flags: .maskCommand) // ⌘A
        post(51, pid) // Backspace
    }

    static func escape(_ pid: pid_t) {
        post(53, pid)
    }

    private static func post(_ key: CGKeyCode, _ pid: pid_t, flags: CGEventFlags = [], unicode: [UInt16]? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
            event.flags = flags
            if let unicode {
                event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            event.postToPid(pid)
        }
        usleep(15_000)
    }
}
