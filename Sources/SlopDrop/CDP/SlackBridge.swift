import Foundation

struct SlackTarget: Hashable {
    let id: String
    let title: String
    let url: URL
    let webSocketURL: URL
}

/// Owns the DevTools connections to Slack's renderer processes and the agent's
/// public API. Everything Slack-side is driven through `window.__slop`.
@MainActor
final class SlackBridge {
    let port: Int
    private var connections: [String: CDPConnection] = [:]
    let agentSource: String

    init(port: Int) {
        self.port = port
        self.agentSource = Self.loadAgentSource()
    }

    var windowCount: Int { connections.count }

    private static func loadAgentSource() -> String {
        if let url = Bundle.module.url(forResource: "slop-agent", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            return source
        }
        NSLog("SlopDrop: slop-agent.js missing from the app bundle")
        return ""
    }

    // MARK: - Discovery

    /// True when Slack was started with `--remote-debugging-port`.
    static func isPortOpen(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func listTargets() async throws -> [SlackTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        return entries.compactMap { entry in
            guard entry["type"] as? String == "page",
                  let raw = entry["url"] as? String, raw.contains("app.slack.com"),
                  let id = entry["id"] as? String,
                  let socketString = entry["webSocketDebuggerUrl"] as? String,
                  let socketURL = URL(string: socketString),
                  let pageURL = URL(string: raw)
            else { return nil }
            return SlackTarget(
                id: id,
                title: entry["title"] as? String ?? "Slack",
                url: pageURL,
                webSocketURL: socketURL
            )
        }
    }

    // MARK: - Attachment

    /// Connects to every Slack window and installs the agent. Returns the number
    /// of windows currently under control. A connection whose window closed,
    /// or whose socket dropped, is let go here and the window reconnected.
    @discardableResult
    func attach() async throws -> Int {
        let targets = try await listTargets()
        let live = Set(targets.map(\.id))

        for (id, connection) in connections {
            let open = await connection.isOpen
            guard !live.contains(id) || !open else { continue }
            await connection.close()
            connections[id] = nil
        }

        for target in targets where connections[target.id] == nil {
            let connection = CDPConnection(url: target.webSocketURL)
            do {
                try await connection.open()
                _ = try await connection.send("Page.addScriptToEvaluateOnNewDocument", ["source": agentSource])
                _ = try await connection.evaluate(agentSource)
                connections[target.id] = connection
            } catch {
                await connection.close()
            }
        }
        return connections.count
    }

    func detach() async {
        for connection in connections.values { await connection.close() }
        connections.removeAll()
    }

    // MARK: - Commands

    func push(rules: [Rule], revealed: Bool, pick: Bool) async throws {
        guard !connections.isEmpty else { throw CDPError(message: "not attached") }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(rules),
              let json = String(data: data, encoding: .utf8) else { return }

        let script = """
        (() => {
          if (!window.__slop) return 'missing';
          window.__slop.setRules(\(json));
          window.__slop.configure({ revealed: \(revealed), pick: \(pick) });
          return 'ok';
        })()
        """

        var failures = 0
        for connection in connections.values {
            do {
                let outcome = try await connection.evaluate(script) as? String
                if outcome != "ok" { throw CDPError(message: "agent not ready") }
            } catch {
                // The page may have kept an older agent (or none); replace it.
                do {
                    _ = try await connection.evaluate(agentSource)
                    _ = try await connection.evaluate(script)
                } catch {
                    failures += 1
                }
            }
        }
        if failures == connections.count { throw CDPError(message: "agent unreachable") }
    }

    struct Sample {
        var stats: AgentStats
        var picked: PickedMessage?
        var styles: [StyleDescriptor]
        var ruleCount: Int
        var observations: [Observation]
    }

    /// Reads stats from every window, re-installing the agent if a window was
    /// reloaded underneath us. Returns `nil` when nothing is reachable.
    func sample() async -> Sample? {
        var totals = AgentStats()
        var picked: PickedMessage?
        var styles: [StyleDescriptor] = []
        var observations: [Observation] = []
        var ruleCount = 0
        var reachable = 0

        for connection in connections.values {
            do {
                guard let raw = try await connection.evaluateJSON("window.__slop && window.__slop.getStats()"),
                      let json = raw as? [String: Any] else {
                    _ = try? await connection.evaluate(agentSource)
                    continue
                }
                reachable += 1
                let windowStats = AgentStats(json: json)
                totals.messages += windowStats.messages
                totals.matched += windowStats.matched
                ruleCount = max(ruleCount, json["rules"] as? Int ?? 0)

                if picked == nil,
                   let pick = json["picked"] as? [String: Any],
                   let data = try? JSONSerialization.data(withJSONObject: pick),
                   let decoded = try? JSONDecoder().decode(PickedMessage.self, from: data) {
                    picked = decoded
                }

                if styles.isEmpty,
                   let list = try await connection.evaluateJSON("window.__slop.styles") as? [[String: Any]],
                   let data = try? JSONSerialization.data(withJSONObject: list) {
                    styles = (try? JSONDecoder().decode([StyleDescriptor].self, from: data)) ?? []
                }

                if let list = try await connection.evaluateJSON("window.__slop.takeSeen ? window.__slop.takeSeen() : []") as? [[String: Any]],
                   !list.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: list) {
                    observations += (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
                }
            } catch {
                continue
            }
        }

        guard reachable > 0 else { return nil }
        return Sample(stats: totals, picked: picked, styles: styles, ruleCount: ruleCount, observations: observations)
    }

    /// Installed apps that can post, from the first window that answers.
    func catalog() async -> [CatalogApp]? {
        for connection in connections.values {
            guard let list = try? await connection.evaluateJSON("window.__slop && window.__slop.catalog ? window.__slop.catalog() : null") as? [[String: Any]],
                  let data = try? JSONSerialization.data(withJSONObject: list),
                  let apps = try? JSONDecoder().decode([CatalogApp].self, from: data)
            else { continue }
            return apps
        }
        return nil
    }

    /// Bytes for a Slack-hosted image, fetched by Slack itself.
    func loadResource(_ url: String) async -> Data? {
        for connection in connections.values {
            if let data = try? await connection.loadResource(url), !data.isEmpty { return data }
        }
        return nil
    }

    func clearPick() async {
        for connection in connections.values {
            _ = try? await connection.evaluate("window.__slop && (window.__slop.picked = null, window.__slop.configure({ pick: false }))")
        }
    }
}
