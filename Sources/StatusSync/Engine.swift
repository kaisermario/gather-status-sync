import Foundation

/// What the menu bar shows.
struct Snapshot {
    enum Mode { case idle, gatherCall, teamsCall, paused }

    var mode: Mode = .idle
    var headline = "Startet …"
    var gatherInfo = "Gather: –"
    var teamsInfo = "Teams: –"
    var problem: String?
}

/// Polls both apps and mirrors a call in one into "Nicht stören"/"Busy" in the other.
actor Engine {
    static let teamsMessage = "🍇 In einem Gather-Call"
    static let gatherStatusText = "Im Teams-Call"
    static let gatherStatusEmoji = "📞"

    private let pollInterval: UInt64 = 3_000_000_000
    private let startAfter: TimeInterval = 5   // a call must last this long before we react
    private let endAfter: TimeInterval = 15    // and be gone this long before we undo

    private let teams = Teams()
    private let gather = Gather()
    private let onUpdate: @Sendable (Snapshot) -> Void
    private let defaults = UserDefaults.standard

    private var paused = false
    private var gatherCall = CallTracker()
    private var teamsCall = CallTracker()
    private var restartedGatherPIDs = Set<pid_t>()

    // What we changed, persisted so a crash or restart can still undo it.
    private var teamsApplied: TeamsApplied? {
        get { decode("teamsApplied") }
        set { encode(newValue, "teamsApplied") }
    }
    private var gatherApplied: Gather.Applied? {
        get { decode("gatherApplied") }
        set { encode(newValue, "gatherApplied") }
    }

    struct TeamsApplied: Codable {
        let message: String?
    }

    init(onUpdate: @escaping @Sendable (Snapshot) -> Void) {
        self.onUpdate = onUpdate
    }

    func run() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: pollInterval)
        }
    }

    func setPaused(_ value: Bool) async {
        paused = value
        await tick()
    }

    /// Undo everything we changed (pause / quit).
    func revertAll() async {
        var problems: [String] = []
        await revertTeams(&problems)
        await revertGather(&problems)
    }

    func restartGather() async {
        await gather.restartWithDebugPort()
        await tick()
    }

    private func tick() async {
        var snapshot = Snapshot()
        var problems: [String] = []
        let now = Date()

        if paused {
            await revertTeams(&problems)
            await revertGather(&problems)
            snapshot.mode = .paused
            snapshot.headline = "Pausiert"
            snapshot.problem = problems.first
            onUpdate(snapshot)
            return
        }

        let mics = Mic.activeInputBundleIDs()
        let teamsMicActive = mics.contains { $0.hasPrefix(Teams.bundlePrefix) }

        var gatherState: Gather.State?
        if gather.runningApp != nil {
            do {
                gatherState = try await gather.state()
            } catch {
                await maybeRestartGather(gatherMicActive: mics.contains { $0.hasPrefix(Gather.bundleID) })
                problems.append("\(error)")
            }
        }

        let inGatherCall = gatherCall.update(active: gatherState?.inConversation ?? false, now: now,
                                             startAfter: startAfter, endAfter: endAfter)
        let inTeamsCall = teamsCall.update(active: teamsMicActive, now: now,
                                           startAfter: startAfter, endAfter: endAfter)

        // Gather conversation → Teams "Nicht stören". In a Teams call Teams shows "Im Anruf" anyway.
        if inGatherCall && !inTeamsCall {
            if teamsApplied == nil { applyTeams(&problems) }
        } else {
            await revertTeams(&problems)
        }

        // Teams call → Gather "Busy".
        if inTeamsCall {
            if gatherApplied == nil && gatherState != nil { await applyGather(&problems) }
        } else {
            await revertGather(&problems)
        }

        snapshot.gatherInfo = gatherState.map {
            "Gather: \($0.availability ?? "?")\($0.inConversation ? ", im Gespräch" : "")"
        } ?? (gather.runningApp == nil ? "Gather: läuft nicht" : "Gather: nicht steuerbar")
        snapshot.teamsInfo = "Teams: \(teams.isRunning ? (teamsMicActive ? "im Call" : "kein Call") : "läuft nicht")"

        if teamsApplied != nil {
            snapshot.mode = .gatherCall
            snapshot.headline = "Gather-Gespräch → Teams: Nicht stören"
        } else if gatherApplied != nil {
            snapshot.mode = .teamsCall
            snapshot.headline = "Teams-Call → Gather: Busy"
        } else {
            snapshot.headline = "Aktiv, kein Call"
        }
        snapshot.problem = problems.first
        onUpdate(snapshot)
    }

    private func applyTeams(_ problems: inout [String]) {
        do {
            guard try !teams.isDoNotDisturb() else { return } // set by the user
            let messageSet = try teams.setDoNotDisturb(message: Engine.teamsMessage)
            teamsApplied = TeamsApplied(message: messageSet ? Engine.teamsMessage : nil)
            log("Teams: Nicht stören gesetzt (Statusmeldung: \(messageSet))")
        } catch {
            problems.append("\(error)")
        }
    }

    private func revertTeams(_ problems: inout [String]) async {
        guard let applied = teamsApplied else { return }
        do {
            try teams.reset(message: applied.message)
            teamsApplied = nil
            log("Teams: zurückgesetzt")
        } catch TeamsError.notRunning {
            teamsApplied = nil
        } catch {
            problems.append("\(error)")
        }
    }

    private func applyGather(_ problems: inout [String]) async {
        do {
            gatherApplied = try await gather.setBusy(text: Engine.gatherStatusText, emoji: Engine.gatherStatusEmoji)
            log("Gather: Busy gesetzt")
        } catch {
            problems.append("\(error)")
        }
    }

    private func revertGather(_ problems: inout [String]) async {
        guard let applied = gatherApplied else { return }
        guard gather.runningApp != nil else { gatherApplied = nil; return }
        do {
            try await gather.restore(applied)
            gatherApplied = nil
            log("Gather: zurückgesetzt")
        } catch {
            problems.append("\(error)")
        }
    }

    /// Gather started without the debug port (e.g. by its own login item): restart it once,
    /// but never in the middle of a conversation.
    private func maybeRestartGather(gatherMicActive: Bool) async {
        guard let app = gather.runningApp, !gatherMicActive,
              !restartedGatherPIDs.contains(app.processIdentifier) else { return }
        restartedGatherPIDs.insert(app.processIdentifier)
        log("Gather ohne Debug-Port gefunden, starte neu")
        await gather.restartWithDebugPort()
        if let restarted = gather.runningApp { restartedGatherPIDs.insert(restarted.processIdentifier) }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func log(_ message: String) {
        NSLog("StatusSync: %@", message)
    }
}

/// Debounces a raw "is in a call" signal.
struct CallTracker {
    private var since: Date?
    private var lastSeen: Date?
    private(set) var active = false

    mutating func update(active raw: Bool, now: Date, startAfter: TimeInterval, endAfter: TimeInterval) -> Bool {
        if raw {
            since = since ?? now
            lastSeen = now
            if now.timeIntervalSince(since!) >= startAfter { active = true }
        } else {
            if !active { since = nil }
            if active, let lastSeen, now.timeIntervalSince(lastSeen) >= endAfter {
                active = false
                since = nil
            }
        }
        return active
    }
}
