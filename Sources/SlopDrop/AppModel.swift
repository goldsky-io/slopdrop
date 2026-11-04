import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Attachment: Equatable {
        case idle
        case connecting
        case attached(Int)
        case restarting
        case needsRestart
        case slackNotRunning
        case failed(String)

        var isAttached: Bool { if case .attached = self { return true }; return false }
        var isBusy: Bool { self == .restarting || self == .connecting }
    }

    @Published private(set) var attachment: Attachment = .idle
    /// Set when macOS had no room for the status item.
    @Published var menuBarFull = false

    /// Dock icon visibility. Forced on when the menu bar won't take the item.
    @Published var showInDock: Bool = UserDefaults.standard.bool(forKey: Keys.showInDock) {
        didSet { UserDefaults.standard.set(showInDock, forKey: Keys.showInDock) }
    }
    @Published private(set) var stats = AgentStats()
    @Published private(set) var styles: [StyleDescriptor] = []
    @Published private(set) var rules: [Rule] = RuleStore.loadOrSeed()
    @Published var revealed = false { didSet { schedulePush() } }
    @Published var pickMode = false { didSet { schedulePush() } }

    /// Installed Slack apps, refreshed from the renderer every couple of minutes.
    @Published private(set) var catalog: [CatalogApp] = []
    @Published private(set) var seen = SeenStore.load()
    /// Apps-page row ids in the order the user dragged them. Rows not in it
    /// follow, newest settings first, then by how likely they are to be AI.
    @Published private(set) var entryOrder: [String] = UserDefaults.standard.stringArray(forKey: Keys.appOrder) ?? []

    /// The style every rule uses unless it picks its own. Changing it restyles
    /// Slack immediately.
    @Published var defaultStyle: String = UserDefaults.standard.string(forKey: Keys.defaultStyle) ?? StyleDescriptor.defaultID {
        didSet {
            UserDefaults.standard.set(defaultStyle, forKey: Keys.defaultStyle)
            schedulePush()
        }
    }

    private var catalogFetchedAt = Date.distantPast
    private var seenSavedAt = Date.distantPast
    private var seenDirty = false

    /// Slack reads `--remote-debugging-port` only at launch, so staying attached
    /// across updates and relaunches means restarting it when it comes back
    /// without the flag.
    @Published var autoReconnect: Bool = UserDefaults.standard.object(forKey: Keys.autoReconnect) as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: Keys.autoReconnect) }
    }

    private enum Keys {
        static let autoReconnect = "autoReconnect"
        static let showInDock = "showInDock"
        static let appOrder = "appOrder"
        static let defaultStyle = "defaultStyle"
        static let stylesFollowDefault = "rulesFollowDefaultStyle"
    }

    /// How long Slack may sit running without the port before we step in.
    private let settleDelay: TimeInterval = 4
    /// Delay before each retry after a failed restart.
    private let retryDelays: [TimeInterval] = [5, 15, 60, 300]

    private var mismatchSince: Date?
    private var nextRestartAllowed = Date.distantPast
    private var restartFailures = 0
    private var pipelineFailures = 0
    private var isRestarting = false

    static let shared = AppModel()

    let port: Int
    private let bridge: SlackBridge
    private var loop: Task<Void, Never>?
    private var pushTask: Task<Void, Never>?
    private var needsPush = true

    init(port: Int = 9333) {
        self.port = port
        self.bridge = SlackBridge(port: port)
        NSLog("SlopDrop: agent source is \(bridge.agentSource.isEmpty ? "MISSING" : "loaded")")
        migrateRulesToDefaultStyle()
    }

    /// Before styles could follow the default, every rule was saved with an
    /// explicit style: Fold, the built-in default then, unless changed on the
    /// Rules page. Those, and any matching the current default, were never a
    /// deliberate per-rule choice, so they follow the default from now on.
    private func migrateRulesToDefaultStyle() {
        guard !UserDefaults.standard.bool(forKey: Keys.stylesFollowDefault) else { return }
        UserDefaults.standard.set(true, forKey: Keys.stylesFollowDefault)
        var changed = false
        for index in rules.indices
        where rules[index].style == defaultStyle || rules[index].style == "accordion" {
            rules[index].style = nil
            changed = true
        }
        if changed { RuleStore.save(rules) }
    }

    /// A rule without its own style takes the "All apps and bots" style when
    /// that row reaches it, else the default from General.
    func effectiveStyle(of rule: Rule) -> String {
        if let style = rule.style { return style }
        if !rule.match.anyApp, rule.reachedByAllApps, let style = allAppsRule?.style { return style }
        return defaultStyle
    }

    /// Rules as the renderer sees them, first match wins: every app's own
    /// setting in the order shown on the Apps page, then "All apps and bots".
    /// An app switched off while All apps is on goes out as an allow rule
    /// ("none"), so it stops the catch-all without muting anything.
    private var resolvedRules: [Rule] {
        let rank = Dictionary(entryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let allOn = allAppsMuted
        let specific = rules.enumerated()
            .filter { !$0.element.match.anyApp }
            .sorted { (rank[$0.element.entryID] ?? .max, $0.offset) < (rank[$1.element.entryID] ?? .max, $1.offset) }
        var out: [Rule] = []
        for (_, rule) in specific {
            var resolved = rule
            if rule.enabled {
                resolved.style = effectiveStyle(of: rule)
            } else if allOn && rule.reachedByAllApps {
                resolved.enabled = true
                resolved.style = "none"
            } else {
                continue
            }
            out.append(resolved)
        }
        if let all = allAppsRule, all.enabled {
            var resolved = all
            resolved.style = effectiveStyle(of: all)
            out.append(resolved)
        }
        return out
    }

    var activeCount: Int { rules.filter(\.enabled).count }
    var muted: Bool { !revealed }

    func loadResource(_ url: String) async -> Data? {
        await bridge.loadResource(url)
    }

    /// The agent's registry when attached, the bundled mirror otherwise.
    var availableStyles: [StyleDescriptor] { styles.isEmpty ? StyleDescriptor.builtIn : styles }

    var suggestions: [Suggestion] {
        SuggestionEngine.build(catalog: catalog, seen: seen.tallies)
    }

    /// Apps-page rows, in the user's order: everything with a setting, plus
    /// apps that look like AI or were seen posting.
    var appEntries: [AppEntry] { buildEntries().shown }
    /// Installed apps with no sign of AI and no posts seen, listed on request.
    var quietApps: [AppEntry] { buildEntries().quiet }

    private func buildEntries() -> (shown: [AppEntry], quiet: [AppEntry]) {
        let suggestions = self.suggestions
        let byID = Dictionary(suggestions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rank = Dictionary(entryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var shown: [AppEntry] = []
        var quiet: [AppEntry] = []
        var used = Set<String>()
        for rule in rules.reversed() where !rule.match.anyApp {
            let id = rule.entryID
            guard used.insert(id).inserted else { continue }
            shown.append(AppEntry(rule: rule, suggestion: byID[id]))
        }
        for suggestion in suggestions where used.insert(suggestion.id).inserted {
            let entry = AppEntry(rule: nil, suggestion: suggestion)
            if suggestion.likelyAI || suggestion.seen > 0 || rank[suggestion.id] != nil {
                shown.append(entry)
            } else {
                quiet.append(entry)
            }
        }
        let natural = Dictionary(shown.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        shown.sort { (rank[$0.id] ?? .max, natural[$0.id] ?? 0) < (rank[$1.id] ?? .max, natural[$1.id] ?? 0) }
        return (shown, quiet)
    }

    /// One- or two-word status for tight spots like the sidebar.
    var shortStatus: String {
        switch attachment {
        case .idle: return "Waiting for Slack"
        case .connecting: return "Connecting…"
        case .attached(let n): return n == 1 ? "Attached" : "Attached · \(n) windows"
        case .restarting: return "Restarting Slack…"
        case .needsRestart: return "Needs a Slack restart"
        case .slackNotRunning: return "Slack isn't running"
        case .failed: return "Connection problem"
        }
    }

    var statusText: String {
        switch attachment {
        case .idle: return "Waiting for Slack"
        case .connecting: return "Connecting…"
        case .attached(let n): return n == 1 ? "Attached to 1 Slack window" : "Attached to \(n) Slack windows"
        case .restarting: return "Restarting Slack with the control port…"
        case .needsRestart: return "Slack is running without the control port"
        case .slackNotRunning: return "Slack is not running"
        case .failed(let message): return message
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - Connection

    private func tick() async {
        guard await SlackBridge.isPortOpen(port) else {
            await handleDisconnected()
            return
        }

        mismatchSince = nil
        restartFailures = 0
        nextRestartAllowed = .distantPast

        do {
            let windows = try await bridge.attach()
            if !attachment.isAttached {
                needsPush = true
                NSLog("SlopDrop: attached to \(windows) Slack window(s)")
            }
            attachment = .attached(windows)

            if let snapshot = await bridge.sample() {
                stats = snapshot.stats
                if styles.isEmpty, !snapshot.styles.isEmpty { styles = snapshot.styles }
                if let picked = snapshot.picked { adopt(picked) }
                // A window that reloaded comes back with an empty rule set.
                if snapshot.ruleCount == 0 && !rules.isEmpty { needsPush = true }
                if !snapshot.observations.isEmpty, seen.ingest(snapshot.observations) { seenDirty = true }
            } else {
                needsPush = true
            }

            if catalog.isEmpty || Date().timeIntervalSince(catalogFetchedAt) > 120,
               let apps = await bridge.catalog(), !apps.isEmpty {
                catalog = apps
                catalogFetchedAt = Date()
            }
            if seenDirty && Date().timeIntervalSince(seenSavedAt) > 15 { flushSeen() }

            if needsPush && windows > 0 {
                try await bridge.push(rules: resolvedRules, revealed: revealed, pick: pickMode)
                needsPush = false
            }
            pipelineFailures = 0
        } catch {
            // Right after a restart the page is still booting; only surface an
            // error once retrying has actually failed a few times.
            pipelineFailures += 1
            NSLog("SlopDrop: pipeline error (\(pipelineFailures)) — \(error.localizedDescription)")
            attachment = pipelineFailures >= 3
                ? .failed(error.localizedDescription)
                : .connecting
        }
    }

    /// Slack is up but not talking to us. Give it a moment to finish booting,
    /// then restart it with the control port unless the user opted out.
    private func handleDisconnected() async {
        if attachment.isAttached { attachment = .idle }

        guard SlackLauncher.isRunning else {
            attachment = .slackNotRunning
            mismatchSince = nil
            restartFailures = 0
            nextRestartAllowed = .distantPast
            return
        }

        let now = Date()
        if mismatchSince == nil { mismatchSince = now }
        let settled = now.timeIntervalSince(mismatchSince ?? now) >= settleDelay

        guard autoReconnect else {
            attachment = .needsRestart
            return
        }
        if now < nextRestartAllowed {
            attachment = .failed("Couldn't restart Slack. Retrying in \(Int(nextRestartAllowed.timeIntervalSince(now)))s")
            return
        }
        guard settled, !isRestarting else {
            attachment = .needsRestart
            return
        }

        await restartSlack()
    }

    /// Quits Slack and starts it again with the debugging port, then attaches.
    private func restartSlack() async {
        guard !isRestarting else { return }
        isRestarting = true
        attachment = .restarting
        NSLog("SlopDrop: restarting Slack to open the control port")
        defer { isRestarting = false }

        do {
            try await SlackLauncher.relaunch(port: port)
            restartFailures = 0
            nextRestartAllowed = .distantPast
            mismatchSince = nil
            needsPush = true
            await tick()
        } catch {
            restartFailures += 1
            let delay = retryDelays[min(restartFailures, retryDelays.count) - 1]
            nextRestartAllowed = Date().addingTimeInterval(delay)
            mismatchSince = Date()
            NSLog("SlopDrop: restart failed — \(error.localizedDescription); retrying in \(Int(delay))s")
            attachment = .failed("Couldn't restart Slack. Retrying in \(Int(delay))s")
        }
    }

    /// Manual override from Settings or the menu: skip the settle delay and backoff.
    func connect() {
        guard !isRestarting else { return }
        attachment = .connecting
        Task {
            if await SlackBridge.isPortOpen(port) {
                await tick()
                return
            }
            mismatchSince = Date().addingTimeInterval(-settleDelay)
            nextRestartAllowed = .distantPast
            restartFailures = 0
            await restartSlack()
        }
    }

    // MARK: - Apps

    /// The catch-all rule behind the "All apps and bots" row.
    var allAppsRule: Rule? { rules.first { $0.match.anyApp } }
    var allAppsMuted: Bool { allAppsRule?.enabled == true }

    func isMuted(_ entry: AppEntry) -> Bool {
        if let rule = entry.rule { return rule.enabled }
        return entry.followsAllApps && allAppsMuted
    }

    /// What "Default" means for a row: the All apps style for apps it
    /// reaches, the General default for everything else.
    func inheritedStyle(of entry: AppEntry) -> String {
        if entry.followsAllApps, let style = allAppsRule?.style { return style }
        return defaultStyle
    }

    func setMuted(_ muted: Bool, _ entry: AppEntry) {
        update(entry) { $0.enabled = muted }
    }

    /// `nil` makes the row follow the default style again.
    func setStyle(_ style: String?, _ entry: AppEntry) {
        let muted = isMuted(entry)
        update(entry) { rule in
            rule.style = style
            rule.enabled = muted
        }
    }

    /// Drops the row's own setting: an app goes back to following All apps,
    /// a picked person or hand-written rule disappears.
    func reset(_ entry: AppEntry) {
        guard let rule = entry.rule else { return }
        rules.removeAll { $0.id == rule.id }
        persist()
    }

    func setAllAppsMuted(_ muted: Bool) {
        updateAllApps { $0.enabled = muted }
    }

    func setAllAppsStyle(_ style: String?) {
        updateAllApps { $0.style = style }
    }

    /// Moves a row to where another one is. The order is the rules' priority.
    func move(_ id: String, to target: String) {
        var order = appEntries.map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target), from != to else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveOrder(order)
    }

    func move(_ id: String, by offset: Int) {
        let order = appEntries.map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        move(id, to: order[to])
    }

    private func saveOrder(_ order: [String]) {
        entryOrder = order
        UserDefaults.standard.set(order, forKey: Keys.appOrder)
        schedulePush()
    }

    private func update(_ entry: AppEntry, _ change: (inout Rule) -> Void) {
        if let rule = entry.rule, let index = rules.firstIndex(where: { $0.id == rule.id }) {
            change(&rules[index])
        } else {
            var rule = entry.makeRule()
            rule.enabled = isMuted(entry)
            change(&rule)
            rules.append(rule)
        }
        persist()
    }

    private func updateAllApps(_ change: (inout Rule) -> Void) {
        if let index = rules.firstIndex(where: { $0.match.anyApp }) {
            change(&rules[index])
        } else {
            var rule = Rule()
            rule.name = "All apps and bots"
            rule.match.anyApp = true
            change(&rule)
            rules.append(rule)
        }
        persist()
    }

    func beginPicking() {
        pickMode = true
    }

    func cancelPicking() {
        pickMode = false
        Task { await bridge.clearPick() }
    }

    /// A picked message mutes its sender, and their row moves to the top.
    private func adopt(_ picked: PickedMessage) {
        let rule = picked.makeRule(style: nil)
        if rule.match.anyApp {
            updateAllApps { $0.enabled = true }
        } else if let index = rules.firstIndex(where: { $0.entryID == rule.entryID || $0.match == rule.match }) {
            rules[index].enabled = true
            saveOrder([rules[index].entryID] + appEntries.map(\.id).filter { $0 != rules[index].entryID })
        } else {
            rules.append(rule)
            saveOrder([rule.entryID] + appEntries.map(\.id).filter { $0 != rule.entryID })
        }
        pickMode = false
        persist()
        Task { await bridge.clearPick() }
    }

    func flushSeen() {
        guard seenDirty else { return }
        seen.save()
        seenDirty = false
        seenSavedAt = Date()
    }

    private func persist() {
        RuleStore.save(rules)
        schedulePush()
    }

    private func schedulePush() {
        needsPush = true
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            guard let self else { return }
            guard await SlackBridge.isPortOpen(self.port) else { return }
            try? await self.bridge.push(rules: self.resolvedRules, revealed: self.revealed, pick: self.pickMode)
            self.needsPush = false
        }
    }

    func styleTitle(_ id: String) -> String {
        availableStyles.first { $0.id == id }?.title ?? id.capitalized
    }
}
