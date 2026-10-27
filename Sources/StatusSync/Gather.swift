import AppKit

enum GatherError: Error, CustomStringConvertible {
    case unreachable, timeout, script(String)

    var description: String {
        switch self {
        case .unreachable: return "Gather nicht steuerbar (ohne Debug-Port gestartet?)"
        case .timeout: return "Gather antwortet nicht"
        case .script(let message): return "Gather-Fehler: \(message)"
        }
    }
}

/// Talks to the Gather V2 web app through the Chrome DevTools Protocol. Gather has to be
/// started with `--remote-debugging-port`; the app's own `gatherDev.Repos` do the work.
final class Gather {
    static let bundleID = "com.gather.GatherV2"
    static let debugPort = 9333

    struct State {
        let availability: String?
        let inConversation: Bool
    }

    struct Applied: Codable {
        let previousAvailability: String?
        let statusText: String?
    }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Gather.bundleID).first
    }

    func state() async throws -> State {
        let value = try await evaluate("""
            (() => {
              const R = gatherDev.Repos, u = R.gameSpace.currentSpaceUser;
              return { availability: u.availability?.value ?? null,
                       inConversation: !!R.avConnections.hasStrongConnections };
            })()
            """) as? [String: Any]
        return State(availability: value?["availability"] as? String,
                     inConversation: value?["inConversation"] as? Bool ?? false)
    }

    /// Sets "Busy" and, unless a status is already set, the custom status (auto-clears after 4 h).
    func setBusy(text: String, emoji: String) async throws -> Applied {
        let value = try await evaluate("""
            (async (text, emoji) => {
              const u = gatherDev.Repos.gameSpace.currentSpaceUser;
              const previous = u.availability?.value ?? null;
              let statusSet = false;
              if (previous !== "Busy") await u.setAvailability({ availability: "Busy" });
              if (!u.activeCustomStatus) {
                await u.setCustomStatus({ text, emoji,
                  clearCondition: { type: "DateTime", clearAt: new Date(Date.now() + 4 * 3600e3) } });
                statusSet = true;
              }
              return { previous: previous === "Busy" ? null : previous, statusSet };
            })(\(json(text)), \(json(emoji)))
            """) as? [String: Any]
        return Applied(previousAvailability: value?["previous"] as? String,
                       statusText: value?["statusSet"] as? Bool == true ? text : nil)
    }

    /// Undoes `applied`, but only where the user has not changed things in the meantime.
    func restore(_ applied: Applied) async throws {
        _ = try await evaluate("""
            (async (previous, text) => {
              const u = gatherDev.Repos.gameSpace.currentSpaceUser;
              if (previous && u.availability?.value === "Busy") await u.setAvailability({ availability: previous });
              if (text && u.activeCustomStatus?.text === text) await u.clearCustomStatus();
              return true;
            })(\(json(applied.previousAvailability)), \(json(applied.statusText)))
            """)
    }

    /// Quits Gather and starts it again, in the background, with the debug port.
    func restartWithDebugPort() async {
        if let app = runningApp {
            app.terminate()
            for _ in 0..<40 where !app.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Gather.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.arguments = ["--remote-debugging-port=\(Gather.debugPort)"]
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: - DevTools protocol

    private func evaluate(_ expression: String) async throws -> Any? {
        let socketURL = try await pageSocketURL()
        return try await withTimeout(seconds: 8) {
            let task = URLSession.shared.webSocketTask(with: socketURL)
            task.resume()
            defer { task.cancel(with: .normalClosure, reason: nil) }

            let request: [String: Any] = [
                "id": 1,
                "method": "Runtime.evaluate",
                "params": ["expression": expression, "awaitPromise": true, "returnByValue": true],
            ]
            let data = try JSONSerialization.data(withJSONObject: request)
            try await task.send(.string(String(decoding: data, as: UTF8.self)))

            while true {
                guard case .string(let text) = try await task.receive(),
                      let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      message["id"] as? Int == 1 else { continue }
                let result = message["result"] as? [String: Any]
                if let exception = result?["exceptionDetails"] as? [String: Any] {
                    let detail = (exception["exception"] as? [String: Any])?["description"] as? String
                    throw GatherError.script(detail ?? "\(exception)")
                }
                return (result?["result"] as? [String: Any])?["value"]
            }
        }
    }

    private func pageSocketURL() async throws -> URL {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Gather.debugPort)/json")!)
        request.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = targets.first(where: {
                  $0["type"] as? String == "page" && ($0["url"] as? String ?? "").contains("app.v2.gather.town")
              }),
              let socket = page["webSocketDebuggerUrl"] as? String,
              let url = URL(string: socket)
        else { throw GatherError.unreachable }
        return url
    }

    private func json(_ value: String?) -> String {
        guard let value else { return "null" }
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

private func withTimeout<T>(seconds: Double, _ body: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GatherError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
