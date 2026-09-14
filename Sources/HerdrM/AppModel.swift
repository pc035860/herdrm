import Foundation
import HerdrKit
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// Agent kinds offered by the picker. Local manifests are filtered through the
/// login-shell search PATH; remote manifests stay server-owned.
enum AgentCatalogState: Equatable {
    case loading
    case loaded(kinds: [String], paths: [String: String] = [:])
    case failed(String)

    var kinds: [String] {
        guard case .loaded(let kinds, _) = self else { return [] }
        return kinds
    }

    var paths: [String: String] {
        guard case .loaded(_, let paths) = self else { return [:] }
        return paths
    }
}

/// Global pane identity: pane ids like "w1:p1" collide across devices.
struct PaneRef: Hashable {
    let deviceID: UUID
    let paneID: String
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

/// Live state for one device's herdr session.
struct DeviceSessionState {
    var connection: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var workspaces: [WorkspaceInfo] = []
    var tabs: [TabInfo] = []
    var panes: [PaneInfo] = []
    var agentCatalog: AgentCatalogState = .loading
    var attachmentCapabilities = AgentAttachmentCapabilityRegistry()
}

struct SSHAuthenticationRequest: Identifiable {
    let deviceID: UUID
    let target: String

    var id: UUID { deviceID }
}

/// vertical = panes side by side with a vertical divider (iTerm2's convention).
enum SplitAxis { case vertical, horizontal }

/// Identifies one of the two panes in the ⌘D split. Used for focus tracking and
/// keyboard-driven resize.
enum SplitSide { case agent, shell }

/// A standalone local or SSH shell shown as its own sidebar entry — app-owned,
/// outside any herdr space (unlike the persistent herdr terminals under
/// TERMINALS) and not the ⌘D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let device: Device
}

/// Per-kind CLI path overrides persisted in user defaults. Empty means automatic
/// lookup on the login-shell search PATH. Invalid paths hide that kind until
/// the user fixes or clears the field — they never silently fall back.
enum AgentBinaryOverrides {
    static let defaultsKey = "agent.binaryOverrides"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[entry.key] = value }
            }
    }

    static func save(_ overrides: [String: String], defaults: UserDefaults = .standard) {
        let trimmed = overrides.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    /// All devices stay connected in parallel; this only filters the sidebar.
    @Published var deviceFilter: UUID? {
        didSet {
            // Persisted so a relaunch restores the last selection (nil = All
            // Devices, which removes the key). Every reset path — removing the
            // filtered device, a notification jump to another device — goes
            // through this property, so the stored value can never go stale.
            UserDefaults.standard.set(deviceFilter?.uuidString, forKey: Self.deviceFilterKey)
        }
    }
    private static let deviceFilterKey = "device.filter"
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef? {
        didSet {
            // Leaving a finished agent marks it viewed. Staying on it while
            // the turn ends must not swallow the unread flag.
            if let old = oldValue, old != selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: old.deviceID, paneID: old.paneID))
            }
            noteSelectedAttachSession()
        }
    }

    /// Kept-alive attaches: every agent/terminal the user has opened stays
    /// mounted (hidden) so switching back preserves its scrollback and running
    /// state instead of re-attaching. Evicted when its pane closes.
    @Published var attachSessions: [AttachedEntry] = []

    /// Keeps the selected pane's attach alive so switching back preserves its content.
    /// Runs synchronously inside the `selectedPane` assignment, so the kept-alive entry
    /// is in `attachSessions` in the same update the selection lands in — a separate
    /// onAppear/onChange would leave a one-frame window with no view for the new pane.
    private func noteSelectedAttachSession() {
        guard let entry = selectedAttachedEntry,
              !attachSessions.contains(where: { $0.id == entry.id })
        else { return }
        attachSessions.append(entry)
    }
    /// Finished agents the user has not opened since they flipped to `done`.
    @Published private(set) var unreadAgents: Set<AgentUnreadKey> = []

    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewTerminal = false
    @Published var showNewSpace = false
    @Published var showSearch = false
    @Published var isFileManagerActive = false
    @Published var shellSplitAxis: SplitAxis? {
        // Every path that clears the axis (⌘W, selection loss, attach exit)
        // funnels the server-side cleanup through here, so the split pane
        // can never be stranded in the workspace.
        didSet {
            if oldValue != nil, shellSplitAxis == nil {
                closeSplitTerminal()
            }
        }
    }
    /// One split pane: a real server-side terminal pane owned by the split
    /// (renamed from SplitTerminal — leaves are panes now, terminals attach
    /// to them). Ephemeral by design: closing the split closes the pane.
    struct SplitPane: Equatable {
        let device: Device
        let paneID: String
        let target: TerminalAttachTarget

        /// Pool identity: pane IDs can collide across devices.
        var poolID: String { "\(device.id.uuidString)/\(paneID)" }
    }
    /// A tree leaf: the agent side (virtual — renders the selected attach
    /// stack, owns no server pane) or one split terminal (owns its pane).
    enum SplitLeaf: Equatable {
        case agent
        case terminal(SplitPane)
    }
    /// Stable identity for focus, tasks, and concealment. Device-scoped:
    /// pane IDs can collide across devices (same key shape as the conceal set).
    enum SplitLeafID: Hashable {
        case agent
        case pane(deviceID: UUID, paneID: String)
    }
    indirect enum SplitNode: Equatable {
        case leaf(SplitLeaf)
        case split(axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)
    }
    /// The split tree. Nil == no split. Source of truth from step 1 on;
    /// the `shellSplitAxis`/`splitTerminal` shims below mirror it until the
    /// canvas (step 2) and menu (step 3) read the tree directly.
    @Published var splitTree: SplitNode?
    /// The leaf holding the keyboard. Default `.agent`; wired to the focus
    /// tracker in step 3 (until then the agent leaf is always the focus).
    @Published var focusedSplitLeaf: SplitLeafID = .agent
    /// Shim for the step-2 rendering, which still reads this. Mirrors the
    /// tree's newest terminal leaf at depth 1; cleared with the tree.
    @Published var splitTerminal: SplitPane?
    /// Pane IDs concealed from the sidebar, search, and auto-selection while
    /// the split owns them. Inserted right after `pane.split` (before the first
    /// refresh can publish the new pane) and removed once the tree takes
    /// over or the pane is cleaned up — so an ephemeral pane never renders a
    /// selectable row anywhere. Best-effort for one hop only: an event-driven
    /// refresh landing between `pane.split` and conceal still flashes it for a
    /// frame, then it self-heals on the next render.
    private var concealedSplitPaneIDs = Set<String>()
    /// In-flight `openSplit` tasks, keyed per leaf. Repeat ⌘D presses on a
    /// leaf hit its own dedup slot instead of stacking up panes, and closing
    /// leaf A never cancels leaf B's in-flight open.
    private var splitOpenTasks: [SplitLeafID: Task<Void, Never>] = [:]

    private static func splitPaneKey(deviceID: UUID, paneID: String) -> String {
        "\(deviceID.uuidString)/\(paneID)"
    }

    /// Whether the pane is the ephemeral ⌘D split pane. Hidden everywhere so
    /// it can never be double-attached: a second `--takeover` attach (from the
    /// sidebar, search, auto-selection, or snapshot focus) would kick the
    /// split's own attach, whose `onExit` then closes the pane the user just
    /// opened. Device-scoped: pane IDs can collide across devices.
    func isSplitPane(deviceID: UUID, paneID: String) -> Bool {
        concealedSplitPaneIDs.contains(Self.splitPaneKey(deviceID: deviceID, paneID: paneID))
            || treeSplitPaneKeys().contains(Self.splitPaneKey(deviceID: deviceID, paneID: paneID))
    }

    /// All terminal leaves' conceal keys, by walking the tree. Every consumer
    /// (sidebar, drag targets, auto-selection, placeholder counts, ⌘K search,
    /// snapshot focus) reads `isSplitPane`, so one predicate covers N panes.
    private func treeSplitPaneKeys() -> Set<String> {
        guard let tree = splitTree else { return [] }
        var out = Set<String>()
        func walk(_ node: SplitNode) {
            switch node {
            case .leaf(.agent): break
            case .leaf(.terminal(let pane)):
                out.insert(Self.splitPaneKey(deviceID: pane.device.id, paneID: pane.paneID))
            case .split(_, _, let first, let second): walk(first); walk(second)
            }
        }
        walk(tree)
        return out
    }

    /// All terminal panes in the tree, pre-order.
    private func terminalSplitPanes() -> [SplitPane] {
        guard let tree = splitTree else { return [] }
        var out: [SplitPane] = []
        func walk(_ node: SplitNode) {
            switch node {
            case .leaf(.agent): break
            case .leaf(.terminal(let pane)): out.append(pane)
            case .split(_, _, let first, let second): walk(first); walk(second)
            }
        }
        walk(tree)
        return out
    }

    /// The pool's contents: every live split attach, mounted exactly once and
    /// keyed by `poolID`. The canvas renders these; the tree only positions them.
    func poolSplitPanes() -> [SplitPane] { terminalSplitPanes() }

    /// Writes a divider-drag ratio into the tree node at `path` (child indices
    /// from the root; empty path = root). Root writes also persist to
    /// `splitRatio`, so the depth-1 drag still restores the user's position.
    func setSplitRatio(_ ratio: Double, at path: [Int]) {
        let clamped = SplitContainerRatioBounds.clamp(ratio)
        if path.isEmpty { splitRatio = clamped }
        updateSplitTree { tree in
            func set(_ node: inout SplitNode, _ path: ArraySlice<Int>) {
                guard case .split(let axis, let current, var first, var second) = node else { return }
                if path.isEmpty {
                    node = .split(axis: axis, ratio: clamped, first: first, second: second)
                } else if path.first == 0 {
                    set(&first, path.dropFirst())
                    node = .split(axis: axis, ratio: current, first: first, second: second)
                } else if path.first == 1 {
                    set(&second, path.dropFirst())
                    node = .split(axis: axis, ratio: current, first: first, second: second)
                }
            }
            guard tree != nil else { return }
            set(&tree!, path[0...])
        }
    }

    /// Whether the tree still contains the pane (close-path reuse guard — a
    /// newer split may own a recycled pane ID).
    private func treeContainsPane(deviceID: UUID, paneID: String) -> Bool {
        treeSplitPaneKeys().contains(Self.splitPaneKey(deviceID: deviceID, paneID: paneID))
    }

    /// The device the tree lives on (any terminal leaf's device). By induction
    /// — the same-device guard keeps agent-leaf splits on-tree, terminal
    /// leaves inherit their pane's device — all leaves always share one
    /// device, so this is well-defined. Used by the step-4 creation path.
    func treeDevice() -> Device? {
        terminalSplitPanes().first?.device
    }

    /// Sole mutation point for `splitTree`. Dropping a terminal leaf here does
    /// NOT close its pane — route every removal through `closeSplitLeaf`, so
    /// the close-pane side effect can't be bypassed (replaces the
    /// axis-didSet funnel once the shims are gone in step 5).
    private func updateSplitTree(_ transform: (inout SplitNode?) -> Void) {
        transform(&splitTree)
    }

    func isSplitPane(_ entry: TerminalEntry) -> Bool {
        isSplitPane(deviceID: entry.device.id, paneID: entry.pane.paneID)
    }
    /// Set by `reveal` when a jump lands while the ⌘D split is open, and consumed once the
    /// main window is key again. Only an actual jump sets it: dismissing the search with
    /// Escape never calls `reveal`, and the sidebar assigns `selectedPane` directly.
    @Published var pendingSplitAgentFocus = false
    /// The pane that currently holds the keyboard within the ⌘D split. Reset to
    /// the agent side whenever the split closes so reopening it is predictable.
    @Published var activeSplitSide: SplitSide = .agent
    /// Persisted divider ratio for the ⌘D split, shared with the resize commands.
    /// Deliberately not `@AppStorage`: that publishes only from inside a View, so the
    /// menu commands would write UserDefaults without ever redrawing the split.
    @Published var splitRatio: Double =
        UserDefaults.standard.object(forKey: AppModel.splitRatioKey) as? Double ?? 0.5
    {
        didSet { UserDefaults.standard.set(splitRatio, forKey: AppModel.splitRatioKey) }
    }
    static let splitRatioKey = "terminal.splitRatio"
    /// Live terminal views of the ⌘D split, used by menu commands to move focus.
    /// The agent side is resolved from the attach registry by the current selection
    /// (kept-alive attach views persist across switches, so a stored ref would go
    /// stale); the shell side stays a weak ref since the split shell is a single view.
    var splitAgentView: LineBreakTerminalView? {
        selectedAttachedEntry.flatMap { AttachViewRegistry.view(for: $0.id) }
    }
    weak var splitShellView: LineBreakTerminalView?
    /// Standalone terminals. Their views stay alive while deselected —
    /// unlike agents, a local shell has no server side to reattach to.
    @Published var shellSessions: [ShellSession] = []
    @Published var selectedShellID: UUID?
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    @Published var agentToRename: AgentEntry?
    @Published var terminalToRename: TerminalEntry?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounceTokens: [UUID: UUID] = [:]
    private var refreshDebouncePending: Set<UUID> = []
    private var snapshotRefreshTasks: [UUID: Task<Bool, Never>] = [:]
    private var snapshotRefreshTokens: [UUID: UUID] = [:]
    private var refreshRequested: Set<UUID> = []
    private var statusGenerations: [UUID: UInt64] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    init() {
        let loaded = DeviceStore().load()
        devices = loaded
        // Restore the device filter only if that device still exists;
        // otherwise fall back to All Devices.
        if let raw = UserDefaults.standard.string(forKey: Self.deviceFilterKey),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            deviceFilter = id
        }
    }

    // MARK: - Derived state

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSessionState {
        sessions[id] ?? DeviceSessionState()
    }

    /// The herdr version the device's server reported on its last successful
    /// ping; the terminal attach uses it to pick a protocol-matching CLI binary.
    func serverVersion(deviceID: UUID) -> String? {
        if case .connected(let version) = session(deviceID).connection { return version }
        return nil
    }

    func attachmentCapabilities(
        deviceID: UUID,
        agentKind: String?
    ) -> AgentAttachmentCapabilities? {
        session(deviceID).attachmentCapabilities.capabilities(for: agentKind)
    }

    var filteredDevice: Device? {
        deviceFilter.flatMap(device)
    }

    private var devicesInScope: [Device] {
        if let filtered = filteredDevice { return [filtered] }
        return devices
    }

    /// Aggregate connection state for the current scope (footer dot, hints).
    var connection: ConnectionState {
        let states = devicesInScope.map { session($0.id).connection }
        if let failed = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failed
        }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ if case .connected = $0 { return true }; return false }) {
            return .connected(version: "")
        }
        return states.isEmpty ? .idle : .connecting
    }

    struct AgentEntry: Identifiable {
        let device: Device
        let agent: AgentInfo
        let tabLabel: String?

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
        var title: String { agent.title(tabLabel: tabLabel) }
    }

    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry {
        AgentEntry(
            device: device,
            agent: agent,
            tabLabel: session(device.id).tabs.first { $0.tabID == agent.tabID }?.customLabel
        )
    }

    struct TerminalEntry: Identifiable {
        let device: Device
        let pane: PaneInfo
        let tab: TabInfo?
        let terminalID: String

        var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }
        var tabID: String? { pane.tabID ?? tab?.tabID }

        var title: String {
            // User tab labels must win or `tab.rename` is invisible behind OSC.
            if let label = tab?.customLabel {
                return label
            }
            if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !terminalTitle.isEmpty {
                return terminalTitle
            }
            if let cwd = pane.cwd, !cwd.isEmpty {
                let basename = URL(fileURLWithPath: cwd).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return String(localized: "Terminal")
        }
    }

    enum AttachedEntry: Identifiable {
        case agent(AgentEntry)
        case terminal(TerminalEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            }
        }

        var device: Device {
            switch self {
            case .agent(let entry): return entry.device
            case .terminal(let entry): return entry.device
            }
        }

        var ref: PaneRef {
            switch self {
            case .agent(let entry): return entry.ref
            case .terminal(let entry): return entry.ref
            }
        }

        var workspaceID: String {
            switch self {
            case .agent(let entry): return entry.agent.workspaceID
            case .terminal(let entry): return entry.pane.workspaceID
            }
        }

        var attachTarget: TerminalAttachTarget {
            switch self {
            case .agent(let entry): return .agent(paneID: entry.agent.paneID)
            case .terminal(let entry): return .terminal(terminalID: entry.terminalID)
            }
        }
    }

    struct SpaceEntry: Identifiable {
        let device: Device
        let workspace: WorkspaceInfo

        var id: String { "\(device.id.uuidString)-\(workspace.workspaceID)" }
        var ref: SpaceRef { SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID) }
    }

    var visibleSpaces: [SpaceEntry] {
        devicesInScope.flatMap { device in
            session(device.id).workspaces.map { SpaceEntry(device: device, workspace: $0) }
        }
    }

    /// Agents across the scope, filtered by selected space, in herdr tab order
    /// (device → workspace → snapshot array) so sidebar drag matches the TUI.
    var visibleAgents: [AgentEntry] {
        var entries = devicesInScope.flatMap { device in
            session(device.id).agents.map { agentEntry(device: device, agent: $0) }
        }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.agent.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.agent.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.agent.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.agent.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.agent.tabID)
        }
    }

    func terminalEntries(for device: Device) -> [TerminalEntry] {
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        return state.panes.compactMap { pane in
            guard let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
    }

    var visibleTerminals: [TerminalEntry] {
        var entries = devicesInScope.flatMap { terminalEntries(for: $0) }
        // The ephemeral split pane is a real tab while open; keep it out of
        // the sidebar (and drag targets, and auto-selection below) so it can
        // never be double-attached — see isSplitPane.
        entries.removeAll(where: { isSplitPane($0) })
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.pane.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.pane.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.pane.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.tabID)
        }
    }

    func isUnread(_ entry: AgentEntry) -> Bool {
        unreadAgents.contains(AgentUnreadKey(deviceID: entry.device.id, paneID: entry.agent.paneID))
    }

    func attention(in entry: SpaceEntry) -> SpaceAttention {
        let agents = session(entry.device.id).agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        }
        return SpaceAttention.rollup(agents.map {
            (
                status: $0.status,
                unreadDone: unreadAgents.contains(
                    AgentUnreadKey(deviceID: entry.device.id, paneID: $0.paneID)
                )
            )
        })
    }

    var scopeAttention: SpaceAttention {
        SpaceAttention.rollup(devicesInScope.flatMap { device in
            session(device.id).agents.map {
                (
                    status: $0.status,
                    unreadDone: unreadAgents.contains(
                        AgentUnreadKey(deviceID: device.id, paneID: $0.paneID)
                    )
                )
            }
        })
    }

    private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {
        session(deviceID).workspaces.firstIndex { $0.workspaceID == workspaceID } ?? Int.max
    }

    private func tabRank(deviceID: UUID, tabID: String?) -> Int {
        guard let tabID else { return Int.max }
        return session(deviceID).tabs.firstIndex { $0.tabID == tabID } ?? Int.max
    }

    private func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
        session(deviceID).tabs
            .filter { $0.workspaceID == workspaceID }
            .map(\.tabID)
    }

    var scopeAgentCount: Int {
        devicesInScope.reduce(0) { $0 + session($1.id).agents.count }
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return agentEntry(device: device, agent: agent)
    }

    var selectedTerminalEntry: TerminalEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        return terminalEntries(for: device).first { $0.pane.paneID == selected.paneID }
    }

    var selectedAttachedEntry: AttachedEntry? {
        if let selectedEntry { return .agent(selectedEntry) }
        if let selectedTerminalEntry { return .terminal(selectedTerminalEntry) }
        return nil
    }

    private var firstVisiblePaneRef: PaneRef? {
        visibleAgents.first?.ref ?? visibleTerminals.first?.ref
    }

    func agentCount(in entry: SpaceEntry) -> Int {
        session(entry.device.id).agents.filter { $0.workspaceID == entry.workspace.workspaceID }.count
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        session(deviceID).workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// Show device badges only when more than one device is configured.
    var showsDeviceBadges: Bool {
        devices.count > 1
    }

    /// Badges on sidebar/titlebar rows are scoped by the device filter: with a
    /// single device selected every row belongs to it, so the badge says
    /// nothing. ⌘K search and the New Agent/Space device pickers stay on
    /// `showsDeviceBadges` — search crosses all devices regardless of the
    /// filter, and the pickers must stay reachable while filtered.
    var showsRowDeviceBadges: Bool {
        devices.count > 1 && deviceFilter == nil
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef?) {
        isFileManagerActive = false
        selectedSpace = ref
        selectedShellID = nil
        if let entry = selectedAttachedEntry {
            if ref == nil { return }
            if entry.device.id == ref!.deviceID && entry.workspaceID == ref!.workspaceID { return }
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    func setDeviceFilter(_ id: UUID?) {
        deviceFilter = id
        if let id, let space = selectedSpace, space.deviceID != id {
            selectedSpace = nil
        }
        if let id, let selected = selectedPane, selected.deviceID != id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    /// When jumping into a space, land on whoever still needs a look — not
    /// merely the first tab.
    private func preferredVisibleAgent() -> AgentEntry? {
        let agents = visibleAgents
        if let blocked = agents.first(where: { $0.agent.status == .blocked }) { return blocked }
        if let unread = agents.first(where: { $0.agent.status == .done && isUnread($0) }) {
            return unread
        }
        if let working = agents.first(where: { $0.agent.status == .working }) { return working }
        return agents.first
    }

    /// Jump target used by the search sheet and by notification clicks.
    func reveal(_ ref: PaneRef) {
        isFileManagerActive = false
        if let filter = deviceFilter, filter != ref.deviceID {
            deviceFilter = nil
        }
        selectedSpace = nil
        selectedPane = ref
        selectedShellID = nil
        // Only the search sheet needs the deferred request: its dismissal restores the
        // parent window's previous responder after the view tree has asked for focus.
        // `showSearch` is still true here — SearchView calls this before dismissing.
        //
        // Notification clicks deliberately do NOT arm it. With the app already frontmost
        // there may be no key-window transition at all, so nothing would consume the flag
        // and a later unrelated activation would cash it in, pulling the keyboard out of
        // the shell. Those clicks get focus from the recreated attach and from the
        // entry-change request instead.
        if shellSplitAxis != nil, showSearch { pendingSplitAgentFocus = true }
    }

    // MARK: - Shell terminals

    func openFileManager() {
        isFileManagerActive = true
        selectedShellID = nil
    }

    func selectAgent(_ ref: PaneRef) {
        isFileManagerActive = false
        selectedPane = ref
        selectedShellID = nil
    }

    var selectedShell: ShellSession? {
        selectedShellID.flatMap { id in shellSessions.first { $0.id == id } }
    }

    /// Every click opens another terminal, like New Agent opens another agent.
    func newShellSession(on device: Device) {
        let n = shellSessions.count + 1
        let session = ShellSession(
            id: UUID(),
            title: String(localized: "Terminal \(n)"),
            device: device
        )
        shellSessions.append(session)
        selectShell(session.id)
    }

    func selectShell(_ id: UUID) {
        isFileManagerActive = false
        selectedShellID = id
        ShellViewRegistry.focus(id)
    }

    func closeShellSession(_ id: UUID) {
        shellSessions.removeAll { $0.id == id }
        if selectedShellID == id {
            selectedShellID = shellSessions.last?.id
            if let remaining = selectedShellID { ShellViewRegistry.focus(remaining) }
        }
    }

    // MARK: - Split terminal (⌘D)

    /// Opens the split as a sibling herdr pane beside the focused leaf.
    /// Step 1: agent-leaf creation only (focus is always `.agent` until the
    /// tracker lands in step 3); re-pressing with a tree open re-aims the
    /// root, preserving depth-1 behavior. Terminal-leaf creation (nesting)
    /// and the same-device guard land in step 4.
    func openSplit(axis: SplitAxis) {
        if splitTree != nil {
            updateSplitTree { tree in
                guard case .split(_, let ratio, let first, let second) = tree else { return }
                tree = .split(axis: axis, ratio: ratio, first: first, second: second)
            }
            shellSplitAxis = axis
            return
        }
        guard focusedSplitLeaf == .agent, splitOpenTasks[.agent] == nil,
              let entry = selectedAttachedEntry
        else { return }
        let device = entry.device
        let entryID = entry.id
        let targetPaneID = entry.ref.paneID
        // herdrm's vertical split (side by side) is herdr's "right"; the
        // horizontal split (stacked) is herdr's "down".
        let direction: PaneSplitDirection = axis == .vertical ? .right : .down
        // Start beside the agent: same working directory, so the split is
        // continuous with whatever it was split from.
        let cwd: String? = switch entry {
        case .agent(let agentEntry): agentEntry.agent.cwd
        case .terminal(let terminalEntry): terminalEntry.pane.cwd
        }
        splitOpenTasks[.agent] = Task {
            // Only the current task may clear its slot: a cancelled task can
            // resume after a close already installed a newer one, and a blind
            // nil-out would drop the dedup guard and orphan panes.
            defer { if !Task.isCancelled { splitOpenTasks[.agent] = nil } }
            let paneID: String
            do {
                // A true sibling split in the SAME tab (not a new tab): the
                // herdr TUI sees the same side-by-side layout herdrm shows.
                paneID = try await service(for: device).splitPane(
                    paneID: targetPaneID,
                    direction: direction,
                    cwd: cwd
                )
            } catch {
                actionError = actionErrorMessage(error, device: device)
                return
            }
            let concealKey = Self.splitPaneKey(deviceID: device.id, paneID: paneID)
            concealedSplitPaneIDs.insert(concealKey)
            defer { concealedSplitPaneIDs.remove(concealKey) }
            // The new pane may miss a coalesced refresh; retry boundedly before
            // giving up, so a transient snapshot gap doesn't silently eat ⌘D.
            var terminal: TerminalEntry?
            for _ in 0..<3 {
                await refresh(device.id)
                if Task.isCancelled {
                    try? await service(for: device).closePane(paneID: paneID)
                    await refresh(device.id)
                    return
                }
                terminal = terminalEntries(for: device).first(where: { $0.pane.paneID == paneID })
                if terminal != nil { break }
            }
            guard
                selectedAttachedEntry?.id == entryID,
                let terminal
            else {
                // The selection moved on mid-flight, or the new tab never
                // appeared: don't strand (or surface) a pane nobody asked for.
                try? await service(for: device).closePane(paneID: paneID)
                await refresh(device.id)
                if terminal == nil {
                    actionError = String(localized: "Could not open the split terminal.")
                }
                return
            }
            let newPane = SplitPane(
                device: device,
                paneID: paneID,
                target: .terminal(terminalID: terminal.terminalID)
            )
            // Root creation seeds the persisted ratio (the user's dragged
            // position survives, as today); deeper nodes seed 0.5 in step 4.
            updateSplitTree { tree in
                tree = .split(axis: axis, ratio: splitRatio, first: .leaf(.agent), second: .leaf(.terminal(newPane)))
            }
            // Shims for the step-2 rendering/menu, which still read these.
            splitTerminal = newPane
            shellSplitAxis = axis
        }
    }

    /// Closes every split pane and clears the tree. Cleanup runs detached from
    /// the UI state change, and pane-close failures are swallowed: a pane may
    /// already be gone (taken over, closed from the sidebar), which is a fine
    /// end state. Deliberately still closes on takeover — an ephemeral pane
    /// has no second life outside the split, so collapsing without closing
    /// would strand it with no UI left to reach it (it is hidden everywhere).
    private func closeSplitTerminal() {
        splitOpenTasks.values.forEach { $0.cancel() }
        splitOpenTasks.removeAll()
        guard splitTree != nil else { return }
        let doomed = terminalSplitPanes()
        coverKeys(for: doomed)
        updateSplitTree { $0 = nil }
        splitTerminal = nil
        focusedSplitLeaf = .agent
        activeSplitSide = .agent
        spawnSplitPaneCloser(doomed)
    }

    /// Prunes one terminal leaf: collapses its parent to the surviving sibling
    /// and closes the leaf's pane. Agent-leaf close goes through the
    /// `shellSplitAxis = nil` funnel (whole-tree collapse above), not here.
    /// Focus follows the nearest surviving leaf; pruning the last terminal
    /// leaf clears the tree (no split left to show).
    func closeSplitLeaf(_ id: SplitLeafID) {
        guard case .pane(let deviceID, let paneID) = id, splitTree != nil else { return }
        splitOpenTasks[id]?.cancel()
        splitOpenTasks[id] = nil
        guard let pruned = pruneTerminalLeaf(deviceID: deviceID, paneID: paneID) else { return }
        coverKeys(for: [pruned.removed])
        if hasTerminalLeaves(pruned.tree) {
            updateSplitTree { $0 = pruned.tree }
            if focusedSplitLeaf == id {
                focusedSplitLeaf = nearestSurvivingLeaf(after: pruned) ?? .agent
            }
        } else {
            // Last terminal leaf gone: nothing left to split around.
            updateSplitTree { $0 = nil }
            splitTerminal = nil
            focusedSplitLeaf = .agent
            activeSplitSide = .agent
        }
        spawnSplitPaneCloser([pruned.removed])
    }

    private func hasTerminalLeaves(_ node: SplitNode?) -> Bool {
        guard let node else { return false }
        switch node {
        case .leaf(.agent): return false
        case .leaf(.terminal): return true
        case .split(_, _, let first, let second): return hasTerminalLeaves(first) || hasTerminalLeaves(second)
        }
    }

    /// The surviving leaf nearest to a removed pane: the extreme leaf of the
    /// promoted sibling, on the side facing the removal. `pruned` carries the
    /// promotion record; falls back to the tree's first leaf.
    private func nearestSurvivingLeaf(after pruned: PrunedLeafRemoval) -> SplitLeafID? {
        if let sibling = pruned.sibling, let axis = pruned.parentAxis {
            _ = axis
            // Removed was first (left/top) → the survivor sits right/below →
            // nearest is its leftmost/topmost leaf; removed second →
            // rightmost/bottommost.
            return extremeLeafID(in: sibling, firstmost: pruned.removedWasFirst)
        }
        return firstLeafID(in: pruned.tree)
    }

    /// Leftmost/topmost (firstmost) or rightmost/bottommost leaf of a subtree.
    /// For vertical splits first == left, for horizontal first == top.
    private func extremeLeafID(in node: SplitNode, firstmost: Bool) -> SplitLeafID? {
        switch node {
        case .leaf(.agent): return .agent
        case .leaf(.terminal(let pane)): return .pane(deviceID: pane.device.id, paneID: pane.paneID)
        case .split(_, _, let first, let second):
            return extremeLeafID(in: firstmost ? first : second, firstmost: firstmost)
        }
    }

    private func firstLeafID(in node: SplitNode?) -> SplitLeafID? {
        guard let node else { return nil }
        return extremeLeafID(in: node, firstmost: true)
    }

    /// Prune record: the post-prune tree plus what the removal promoted.
    /// `sibling` is the promoted sibling subtree (nil when the removed leaf
    /// was the tree's only leaf); `parentAxis` is the collapsed split's axis.
    private struct PrunedLeafRemoval {
        var tree: SplitNode?
        var removed: SplitPane
        var sibling: SplitNode?
        var removedWasFirst: Bool
        var parentAxis: SplitAxis?
    }

    /// Removes the terminal leaf from the tree, collapsing its parent to the
    /// surviving sibling. Returns the prune record, or nil if the pane isn't
    /// in the tree.
    private func pruneTerminalLeaf(deviceID: UUID, paneID: String) -> PrunedLeafRemoval? {
        guard splitTree != nil else { return nil }
        func prune(_ node: SplitNode) -> (SplitNode?, PrunedLeafRemoval?) {
            switch node {
            case .leaf(.agent):
                return (node, nil)
            case .leaf(.terminal(let pane)) where pane.device.id == deviceID && pane.paneID == paneID:
                return (nil, PrunedLeafRemoval(tree: nil, removed: pane, sibling: nil, removedWasFirst: false, parentAxis: nil))
            case .leaf:
                return (node, nil)
            case .split(let axis, let ratio, let first, let second):
                let (firstPruned, firstHit) = prune(first)
                if var hit = firstHit {
                    // A nil replacement means `first` was the removed leaf itself
                    // (deeper removals always leave a collapsed subtree behind),
                    // so the promoted sibling is `second` — unless a deeper
                    // level already recorded one.
                    if firstPruned == nil, hit.sibling == nil {
                        hit.sibling = second
                        hit.removedWasFirst = true
                        hit.parentAxis = axis
                    }
                    hit.tree = firstPruned ?? second
                    return (firstPruned ?? second, hit)
                }
                let (secondPruned, secondHit) = prune(second)
                if var hit = secondHit {
                    if secondPruned == nil, hit.sibling == nil {
                        hit.sibling = first
                        hit.removedWasFirst = false
                        hit.parentAxis = axis
                    }
                    hit.tree = secondPruned ?? first
                    return (secondPruned ?? first, hit)
                }
                return (.split(axis: axis, ratio: ratio, first: first, second: second), nil)
            }
        }
        let (_, hit) = prune(splitTree!)
        return hit
    }

    /// Re-covers panes before unpublishing: without this a dying pane renders
    /// a selectable sidebar row until closePane + refresh land.
    private func coverKeys(for panes: [SplitPane]) {
        for pane in panes {
            concealedSplitPaneIDs.insert(Self.splitPaneKey(deviceID: pane.device.id, paneID: pane.paneID))
        }
    }

    /// Closes panes server-side, then refreshes each device once. Shared by
    /// every close path so no removal can strand a pane.
    private func spawnSplitPaneCloser(_ doomed: [SplitPane]) {
        guard !doomed.isEmpty else { return }
        Task {
            // Keep each conceal key until the post-close refresh lands: the
            // pane still exists server-side for hundreds of ms, and dropping
            // cover early would render a selectable row for a dying pane.
            defer {
                for pane in doomed {
                    // Tree-membership reuse guard: don't drop a newer split's
                    // cover if the server ever recycles this pane ID.
                    if !treeContainsPane(deviceID: pane.device.id, paneID: pane.paneID) {
                        concealedSplitPaneIDs.remove(Self.splitPaneKey(deviceID: pane.device.id, paneID: pane.paneID))
                    }
                }
            }
            var byDevice: [UUID: (device: Device, paneIDs: [String])] = [:]
            for pane in doomed {
                byDevice[pane.device.id, default: (pane.device, [])].paneIDs.append(pane.paneID)
            }
            for (_, group) in byDevice {
                // The device may be gone (removed mid-split): don't resurrect
                // a service — let alone spawn a local server — for a doomed close.
                guard device(group.device.id) != nil else { continue }
                for paneID in group.paneIDs {
                    try? await service(for: group.device).closePane(paneID: paneID)
                }
                await refresh(group.device.id)
            }
        }
    }

    /// Arrow-key direction for focus moves and divider nudges.
    enum SplitDirection {
        case left, right, up, down
    }

    /// Child-index trail from the root to a leaf (0 = first, 1 = second).
    /// Nil when the leaf isn't in the tree.
    private func leafPath(_ id: SplitLeafID) -> [Int]? {
        func find(_ node: SplitNode) -> [Int]? {
            switch node {
            case .leaf(.agent):
                return id == .agent ? [] : nil
            case .leaf(.terminal(let pane)):
                return id == .pane(deviceID: pane.device.id, paneID: pane.paneID) ? [] : nil
            case .split(_, _, let first, let second):
                if let path = find(first) { return [0] + path }
                if let path = find(second) { return [1] + path }
                return nil
            }
        }
        guard let tree = splitTree else { return nil }
        return find(tree)
    }

    /// The leaf adjacent to `id` in `direction`, from tree structure (classic
    /// guillotine neighbor: up from the focused leaf to the first ancestor
    /// split facing that way, then the extreme leaf of the sibling subtree).
    /// No geometry needed — the tree already encodes adjacency.
    func neighbor(of id: SplitLeafID, direction: SplitDirection) -> SplitLeafID? {
        guard let tree = splitTree, let path = leafPath(id), !path.isEmpty else { return nil }
        let wantAxis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        // Ancestor splits from nearest to root, with the taken child index.
        var node = tree
        var ancestors: [(axis: SplitAxis, index: Int, sibling: SplitNode)] = []
        for index in path {
            guard case .split(let axis, _, let first, let second) = node else { return nil }
            ancestors.append((axis, index, index == 0 ? second : first))
            node = index == 0 ? first : second
        }
        for ancestor in ancestors.reversed() {
            guard ancestor.axis == wantAxis else { continue }
            let towardStart = (direction == .left || direction == .up)
            // left/up leaves via the second child; right/down via the first.
            // The nearest leaf of the sibling faces the crossing: the sibling
            // on the far side contributes its firstmost (leftmost/topmost)
            // leaf, the near-side sibling its lastmost.
            guard (ancestor.index == 1) == towardStart else { continue }
            return extremeLeafID(in: ancestor.sibling, firstmost: !towardStart)
        }
        return nil
    }

    /// Moves the keyboard to the neighboring leaf in `direction`. No-op when
    /// there is no neighbor (edge of the layout) or its view isn't ready —
    /// the tracker reports the actual focus, so a failed move changes nothing.
    func focusNeighbor(_ direction: SplitDirection) {
        guard let next = neighbor(of: focusedSplitLeaf, direction: direction) else { return }
        focusSplitLeaf(next)
    }

    /// Puts the keyboard on a leaf's view. Falls back from the registry to the
    /// last-known side views (agent side has no registry entry — its stack is
    /// selection-dependent). The tracker's KVO report is the source of truth
    /// for `focusedSplitLeaf`; this only moves the responder.
    func focusSplitLeaf(_ id: SplitLeafID) {
        let view: NSView? = SplitLeafViewRegistry.view(for: id)
            ?? (id == .agent ? splitAgentView : splitShellView)
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    /// Reads the ratio of the split node at `path` (child indices from root).
    /// Nil when the path doesn't resolve to a split node.
    private func splitRatio(at path: [Int]) -> Double? {
        var node = splitTree
        for index in path {
            guard case .split(_, _, let first, let second) = node else { return nil }
            node = index == 0 ? first : second
        }
        guard case .split(_, let ratio, _, _) = node else { return nil }
        return ratio
    }

    /// Nudges the focused leaf's nearest same-direction ancestor divider by 5%
    /// toward the pressed arrow. No-op when no such divider exists (leaf edge
    /// facing the other axis) — safe by the ⌘D lesson: never gate on
    /// `.disabled()`, just do nothing on unexpected focus.
    func nudgeFocusedLeaf(arrow: SplitDirection) {
        guard splitTree != nil, let path = leafPath(focusedSplitLeaf), !path.isEmpty else { return }
        let wantAxis: SplitAxis = (arrow == .left || arrow == .right) ? .vertical : .horizontal
        // Nearest ancestor split (node path + taken index) with a matching axis.
        var node = splitTree
        var match: (nodePath: [Int], index: Int)?
        var prefix: [Int] = []
        for index in path {
            guard case .split(let axis, _, let first, let second) = node else { return }
            if axis == wantAxis { match = (prefix, index) }
            prefix.append(index)
            node = index == 0 ? first : second
        }
        guard let match, let current = splitRatio(at: match.nodePath) else { return }
        // Right/down arrows expand toward the edge: a first-child focus grows
        // by raising the ratio, a second-child focus by lowering it; left/up
        // arrows mirror.
        let towardEdge = (arrow == .right || arrow == .down)
        let delta = (towardEdge == (match.index == 0)) ? 0.05 : -0.05
        setSplitRatio(current + delta, at: match.nodePath)
    }

    // MARK: - Lifecycle

    func start() {
        NotificationManager.shared.setup(model: self)
        // Finder-launched apps have launchd's PATH. Capture the login +
        // interactive shell environment on a background thread once; New Agent
        // lookup, herdr spawn, and terminal attach all read the same snapshot.
        Task.detached(priority: .utility) {
            _ = await ShellEnvironment.ensure()
        }
        for device in devices {
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Surface any herdr named sessions running now (issue #81).
        refreshNamedSessions()
    }

    func service(for device: Device) -> HerdrService {
        if let service = services[device.id] { return service }
        // Only the built-in Local device (no socket override) may auto-start a
        // herdr server. A named-session device points at an existing session's
        // socket; that server is the user's to run, and auto-start would spawn a
        // default-session server on the wrong socket.
        let service = HerdrService(
            device: device,
            autoStartLocalServer: device.isLocal && device.socketPath == nil
        )
        services[device.id] = service
        return service
    }

    /// Merges live herdr named sessions in as extra Local devices (issue #81)
    /// and drops ones whose session went away. Discovered, never persisted:
    /// named sessions come and go, unlike user-added SSH/tailcat devices.
    func refreshNamedSessions() {
        let discovered = HerdrSessionDiscovery.namedSessions()
            .map(HerdrSessionDiscovery.device(for:))
        let discoveredIDs = Set(discovered.map(\.id))
        // Named-session devices already present, by id.
        let existingIDs = Set(devices.filter(\.isNamedSession).map(\.id))

        for device in discovered where !existingIDs.contains(device.id) {
            devices.append(device)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Remove named-session devices whose session is gone.
        for device in devices where device.isNamedSession && !discoveredIDs.contains(device.id) {
            stopSession(device.id)
            attachSessions.removeAll { $0.device.id == device.id }
            devices.removeAll { $0.id == device.id }
            if deviceFilter == device.id { deviceFilter = nil }
            if selectedSpace?.deviceID == device.id { selectedSpace = nil }
            if selectedPane?.deviceID == device.id {
                selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
            }
        }
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        sessionTasks[device.id]?.cancel()
        if sessions[device.id] == nil { sessions[device.id] = DeviceSessionState() }
        let service = service(for: device)
        sessionTasks[device.id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.sessions[device.id]?.connection = .connecting
                do {
                    let pong = try await service.connect()
                    self.sessions[device.id]?.connection = .connected(version: pong.version)
                    backoff = 1
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    await self.loadAgentCatalog(deviceID: device.id, using: service)
                    eventSubscriptions: while !Task.isCancelled {
                        let subscribedPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                        let stream = try await service.events(statusPaneIDs: subscribedPaneIDs)
                        var needsResubscribe = false
                        var resubscribeDelay: UInt64 = 100_000_000
                        for try await event in stream {
                            guard !Task.isCancelled else { return }
                            if event.kind == HerdrEvent.agentStatusChangedKind {
                                if self.applyAgentStatusEvent(event, deviceID: device.id) {
                                    self.scheduleRefresh(device.id)
                                } else {
                                    _ = await self.refreshImmediately(device.id)
                                }
                            } else if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                if !(await self.refreshImmediately(device.id)) {
                                    needsResubscribe = true
                                    resubscribeDelay = 500_000_000
                                    break
                                }
                            } else {
                                self.scheduleRefresh(device.id)
                            }

                            if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                let currentPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                                if currentPaneIDs != subscribedPaneIDs {
                                    needsResubscribe = true
                                    break
                                }
                            }
                        }
                        if needsResubscribe {
                            try? await Task.sleep(nanoseconds: resubscribeDelay)
                            continue eventSubscriptions
                        }
                        guard !Task.isCancelled else { return }
                        throw HerdrError.connectionFailed("event stream ended")
                    }
                } catch {
                    self.sessions[device.id]?.connection = .failed(error.localizedDescription)
                    // The catalog's initial state is .loading; when connect()
                    // itself fails the load never runs, and without this the
                    // New Agent panel spins on "Checking agents…" forever
                    // while the only hint is the footer indicator (#69).
                    if case .loading = self.sessions[device.id]?.agentCatalog ?? .loading {
                        self.sessions[device.id]?.agentCatalog = .failed(
                            self.actionErrorMessage(error, device: device)
                        )
                    }
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Locally, keeps only advertised CLIs whose binaries are on the login-shell
    /// search PATH (or a Settings override). SSH hosts keep their server-owned
    /// catalog; `agent.start` validates in the target pane instead. Manifests
    /// also feed the attachment-capability registry (paste path vs upload).
    private func loadAgentCatalog(deviceID: UUID, using service: HerdrService) async {
        sessions[deviceID]?.agentCatalog = .loading
        do {
            let manifests = try await service.agentManifests()
            sessions[deviceID]?.attachmentCapabilities =
                AgentAttachmentCapabilityRegistry(manifests: manifests)
            let advertised = manifests.map(\.agent)
            if device(deviceID)?.isLocal == true {
                // Herdr supports OMP through its lifecycle extension, so it has
                // no screen-detection manifest in server.agent_manifests.
                let found = await service.installedAgents(
                    from: advertised,
                    includingIntegrationKinds: ["omp"],
                    overrides: AgentBinaryOverrides.load()
                )
                sessions[deviceID]?.agentCatalog = .loaded(
                    kinds: found.map(\.kind),
                    paths: Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0.path) })
                )
            } else {
                sessions[deviceID]?.agentCatalog = .loaded(kinds: advertised)
            }
        } catch {
            sessions[deviceID]?.agentCatalog = .failed(error.localizedDescription)
        }
    }

    func reloadAgentCatalog(deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { await loadAgentCatalog(deviceID: deviceID, using: service) }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        refreshDebounceTokens[id] = nil
        refreshDebouncePending.remove(id)
        snapshotRefreshTasks[id]?.cancel()
        snapshotRefreshTasks[id] = nil
        snapshotRefreshTokens[id] = nil
        refreshRequested.remove(id)
        statusGenerations[id] = nil
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        Task { await service?.disconnect() }
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        startSession(device)
        probeOSIfNeeded(device)
        setDeviceFilter(device.id)
    }

    /// Adds a tailcat-tunnel device. The token is a bearer credential and goes
    /// straight to the Keychain — devices.json never sees it.
    func addTailcatDevice(name: String, token: String) {
        let device = Device(name: name, kind: .tailcat)
        do {
            try TailcatCredentialStore.setToken(token, for: device.id)
        } catch {
            actionError = error.localizedDescription
            return
        }
        devices.append(device)
        store.save(devices)
        startSession(device)
        setDeviceFilter(device.id)
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again"))
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Reconnect is also the natural moment to pick up a named session that
        // started (or dropped) since launch (issue #81).
        refreshNamedSessions()
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target (e.g. after an IP change).
    func updateDevice(_ id: UUID, name: String, sshTarget: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].isLocal else { return }
        let targetChanged = devices[index].sshTarget != sshTarget
        devices[index].name = name
        if targetChanged {
            removeSSHPassword(for: id)
            devices[index].kind = .ssh(target: sshTarget)
            devices[index].osID = nil
            stopSession(id)
            startSession(devices[index])
            probeOSIfNeeded(devices[index])
        }
        store.save(devices)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        TailcatCredentialStore.removeToken(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        attachSessions.removeAll { $0.device.id == device.id }
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if deviceFilter == device.id { deviceFilter = nil }
        if selectedSpace?.deviceID == device.id { selectedSpace = nil }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(_ deviceID: UUID) async -> Bool {
        refreshRequested.insert(deviceID)
        if let task = snapshotRefreshTasks[deviceID] {
            return await task.value
        }
        let token = UUID()
        snapshotRefreshTokens[deviceID] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var latestSucceeded = false
            while !Task.isCancelled, self.refreshRequested.remove(deviceID) != nil {
                latestSucceeded = await self.performRefresh(deviceID)
            }
            if self.snapshotRefreshTokens[deviceID] == token {
                self.snapshotRefreshTokens[deviceID] = nil
                self.snapshotRefreshTasks[deviceID] = nil
            }
            return latestSucceeded
        }
        snapshotRefreshTasks[deviceID] = task
        return await task.value
    }

    private func performRefresh(_ deviceID: UUID) async -> Bool {
        guard let device = device(deviceID), let service = services[deviceID] else {
            return false
        }
        let statusGeneration = statusGenerations[deviceID, default: 0]
        do {
            let snapshot = try await service.snapshot()
            guard services[deviceID] === service, sessions[deviceID] != nil else {
                return false
            }
            guard statusGenerations[deviceID, default: 0] == statusGeneration else {
                // A direct status event overtook this request on the separate
                // event connection. Discard the older snapshot and let the
                // refresh drain fetch one after that event.
                refreshRequested.insert(deviceID)
                return true
            }
            unreadAgents = AgentUnread.applying(
                previous: previousStatuses[deviceID] ?? [:],
                agents: snapshot.agents,
                unread: unreadAgents,
                deviceID: device.id
            )
            notifyTransitions(
                device: device,
                from: previousStatuses[deviceID] ?? [:],
                to: snapshot.agents,
                workspaces: snapshot.workspaces,
                tabs: snapshot.tabs ?? []
            )
            previousStatuses[deviceID] = Dictionary(
                uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
            )
            sessions[deviceID]?.agents = snapshot.agents
            sessions[deviceID]?.workspaces = snapshot.workspaces
            sessions[deviceID]?.tabs = TabReorder.ordered(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes
            let paneIDs = Set((snapshot.panes ?? []).map(\.paneID))
                .union(snapshot.agents.map(\.paneID))
            // Drop kept-alive attaches whose pane is gone (closed). A pane only taken
            // over by another client still exists, so it stays — its Reconnect overlay
            // needs the kept-alive child to rebuild the attach.
            attachSessions.removeAll { $0.device.id == deviceID && !paneIDs.contains($0.ref.paneID) }
            if let selected = selectedPane, selected.deviceID == deviceID,
               !paneIDs.contains(selected.paneID) {
                selectedPane = nil
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !snapshot.workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedPane == nil {
                if let focusedPaneID = snapshot.focusedPaneID,
                   paneIDs.contains(focusedPaneID),
                   deviceFilter == nil || deviceFilter == deviceID,
                   // Never auto-select the concealed split pane (see isSplitPane).
                   !isSplitPane(deviceID: deviceID, paneID: focusedPaneID) {
                    let focused = PaneRef(deviceID: deviceID, paneID: focusedPaneID)
                    if selectedSpace == nil
                        || selectedAttachedEntry.map({
                            $0.ref == focused && $0.workspaceID == selectedSpace?.workspaceID
                        }) == true {
                        selectedPane = focused
                    }
                }
                if selectedPane == nil {
                    selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
                }
            }
            return true
        } catch {
            // A snapshot is one request on an otherwise live session. The
            // event/connect loop owns connection health and will mark the
            // device failed if the transport itself is gone.
            return false
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        // Coalesce from the leading edge instead of resetting the timer for
        // every event. A busy pane can emit continuously; a trailing debounce
        // would never fire until output stopped, hiding the working state.
        guard refreshDebounces[deviceID] == nil else {
            refreshDebouncePending.insert(deviceID)
            return
        }
        let token = UUID()
        refreshDebounceTokens[deviceID] = token
        refreshDebounces[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled,
                  self.refreshDebounceTokens[deviceID] == token
            else { return }
            await self.refresh(deviceID)
            if self.refreshDebounceTokens[deviceID] == token {
                let needsTrailing = self.refreshDebouncePending.remove(deviceID) != nil
                self.refreshDebounceTokens[deviceID] = nil
                self.refreshDebounces[deviceID] = nil
                if needsTrailing {
                    self.scheduleRefresh(deviceID)
                }
            }
        }
    }

    private func refreshImmediately(_ deviceID: UUID) async -> Bool {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = nil
        refreshDebounceTokens[deviceID] = nil
        refreshDebouncePending.remove(deviceID)
        return await refresh(deviceID)
    }

    @discardableResult
    private func applyAgentStatusEvent(_ event: HerdrEvent, deviceID: UUID) -> Bool {
        guard let paneID = event.payload["data"]?["pane_id"]?.stringValue,
              let statusRaw = event.payload["data"]?["agent_status"]?.stringValue,
              let device = device(deviceID),
              var state = sessions[deviceID],
              let index = state.agents.firstIndex(where: { $0.paneID == paneID })
        else { return false }

        let status = AgentStatus(wire: statusRaw)
        guard state.agents[index].status != status else { return true }
        let previous = previousStatuses[deviceID] ?? [:]
        state.agents[index] = state.agents[index].updatingStatus(status)
        unreadAgents = AgentUnread.applying(
            previous: previous,
            agents: state.agents,
            unread: unreadAgents,
            deviceID: deviceID
        )
        notifyTransitions(
            device: device,
            from: previous,
            to: state.agents,
            workspaces: state.workspaces,
            tabs: state.tabs
        )
        var nextStatuses = previous
        nextStatuses[paneID] = status
        previousStatuses[deviceID] = nextStatuses
        statusGenerations[deviceID, default: 0] &+= 1
        sessions[deviceID] = state
        return true
    }

    private func statusSubscriptionPaneIDs(_ deviceID: UUID) -> [String] {
        Array(Set(
            session(deviceID).agents.map(\.paneID)
                + session(deviceID).panes.map(\.paneID)
        )).sorted()
    }

    private static let paneTopologyEventKinds: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.moved",
        "pane.agent_detected",
    ]

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            let tabLabel = tabs.first { $0.tabID == agent.tabID }?.customLabel
            NotificationManager.shared.post(
                agent: agent,
                title: agent.title(tabLabel: tabLabel),
                status: agent.status,
                deviceID: device.id,
                deviceName: device.name,
                spaceName: workspaces.first { $0.workspaceID == agent.workspaceID }?.label ?? agent.workspaceID
            )
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and persists it.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(
                target: target,
                credentialID: device.id
            ) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
                self.store.save(self.devices)
            }
        }
    }

    private static func isSSHAuthenticationFailure(_ error: Error) -> Bool {
        guard let herdrError = error as? HerdrError,
              case .tunnelFailed(let reason) = herdrError
        else { return false }
        return [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "no supported authentication methods",
        ].contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// An action fired while the device session is down surfaces the bare
    /// "connection failed: not connected", which points at nothing. The
    /// reconnect loop already knows why the device is unreachable — say that
    /// instead. (#21)
    func actionErrorMessage(_ error: Error, device: Device) -> String {
        guard let herdrError = error as? HerdrError,
              case .connectionFailed(let reason) = herdrError,
              reason == "not connected"
        else { return error.localizedDescription }
        switch session(device.id).connection {
        case .connecting:
            return String(localized: "Still connecting to \(device.name) — try again in a moment.")
        case .failed(let reason):
            return String(localized: "\(device.name) is unreachable: \(reason)")
        case .idle:
            return String(localized: "\(device.name) isn't connected.")
        case .connected:
            return String(localized: "\(device.name) just reconnected — try again.")
        }
    }

    // MARK: - Closing

    func requestCloseSpace(_ entry: SpaceEntry) {
        closeRequest = CloseRequest(
            title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
            message: String(localized: "All terminals and agents in this space will be closed.")
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: entry.device)
                        .closeWorkspace(workspaceID: entry.workspace.workspaceID)
                    if self.selectedSpace == entry.ref { self.selectedSpace = nil }
                    await self.refresh(entry.device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: entry.device)
                }
            }
        }
    }

    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
        closeRequest = CloseRequest(
            title: String(localized: "Close \"\(name)\"?"),
            message: String(localized: "The pane and whatever is running inside it will be terminated.")
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: device).closePane(paneID: ref.paneID)
                    if self.selectedPane == ref { self.selectedPane = nil }
                    await self.refresh(device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: device)
                }
            }
        }
    }

    // MARK: - Actions

    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        Task {
            do {
                try await service(for: entry.device).renameWorkspace(
                    workspaceID: entry.workspace.workspaceID,
                    label: label
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    func renameAgent(_ entry: AgentEntry, name: String) {
        renameTabLabel(device: entry.device, tabID: entry.agent.tabID, current: entry.title, name: name)
    }

    func renameTerminal(_ entry: TerminalEntry, name: String) {
        guard let tabID = entry.tabID else { return }
        renameTabLabel(device: entry.device, tabID: tabID, current: entry.title, name: name)
    }

    private func renameTabLabel(device: Device, tabID: String, current: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return }
        Task {
            do {
                try await service(for: device).renameTab(tabID: tabID, label: name)
                await refresh(device.id)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Reorders a Space by dropping it on another Space of the same device.
    /// Cross-device drops are ignored; herdr remains the source of truth after refresh.
    func moveSpace(_ source: SpaceEntry, onto target: SpaceEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id else { return }
        let orderedIDs = session(source.device.id).workspaces.map(\.workspaceID)
        guard let plan = WorkspaceReorder.plan(
            moving: source.workspace.workspaceID,
            onto: target.workspace.workspaceID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.workspaces {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[source.device.id]?.workspaces = WorkspaceReorder.applying(
                    current,
                    id: \.workspaceID,
                    plan: plan
                )
            }
        }

        Task {
            do {
                try await service(for: source.device).moveWorkspaceBlock(
                    workspaceIDs: plan.workspaceIDs,
                    beforeWorkspaceID: plan.beforeWorkspaceID
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    /// Reorders an agent tab by dropping it on another agent in the same space.
    /// Cross-space and cross-device drops are ignored (`tab.move` is in-workspace).
    func moveAgent(_ source: AgentEntry, onto target: AgentEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.agent.workspaceID == target.agent.workspaceID
        else { return }
        moveTab(
            device: source.device,
            workspaceID: source.agent.workspaceID,
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter
        )
    }

    /// Same `tab.move` path as agents. Cross-space / cross-device drops are ignored.
    func moveTerminal(_ source: TerminalEntry, onto target: TerminalEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.pane.workspaceID == target.pane.workspaceID,
              let moving = source.tabID,
              let onto = target.tabID
        else { return }
        moveTab(
            device: source.device,
            workspaceID: source.pane.workspaceID,
            moving: moving,
            onto: onto,
            placeAfter: placeAfter
        )
    }

    private func moveTab(
        device: Device,
        workspaceID: String,
        moving: String,
        onto: String,
        placeAfter: Bool
    ) {
        let orderedIDs = orderedTabIDs(deviceID: device.id, workspaceID: workspaceID)
        guard let insertIndex = TabReorder.insertIndex(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }
        guard let plan = WorkspaceReorder.plan(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[device.id]?.tabs {
            let scoped = current.filter { $0.workspaceID == workspaceID }
            let reordered = WorkspaceReorder.applying(scoped, id: \.tabID, plan: plan)
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[device.id]?.tabs = Self.replacingTabs(
                    current,
                    workspaceID: workspaceID,
                    with: reordered
                )
            }
        }

        Task {
            do {
                try await service(for: device).moveTab(tabID: moving, insertIndex: insertIndex)
                await refresh(device.id)
            } catch {
                await refresh(device.id)
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    private static func replacingTabs(
        _ tabs: [TabInfo],
        workspaceID: String,
        with reordered: [TabInfo]
    ) -> [TabInfo] {
        var result: [TabInfo] = []
        var inserted = false
        for tab in tabs {
            if tab.workspaceID == workspaceID {
                if !inserted {
                    result.append(contentsOf: reordered)
                    inserted = true
                }
            } else {
                result.append(tab)
            }
        }
        if !inserted { result.append(contentsOf: reordered) }
        return result
    }

    /// Creates a workspace rooted at the given directory ("~" expands to the device's
    /// home, local or remote), then goes straight into the New Agent sheet for it.
    func createNewSpace(device: Device, directory: String, label: String?) {
        Task {
            do {
                let service = service(for: device)
                var path = directory.trimmingCharacters(in: .whitespaces)
                // The browser leaves paths slash-terminated; herdr wants them bare.
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                if path.isEmpty { path = "~" }
                path = try await service.absolutePath(path)
                let trimmedLabel = label?.trimmingCharacters(in: .whitespaces)
                let created = try await service.createWorkspace(
                    label: (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel,
                    cwd: path
                )
                await refresh(device.id)
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: created.workspaceID)
                showNewAgent = true
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Creates a persistent shell tab on the selected Herdr device. Local and
    /// remote terminals use the same server-owned lifecycle and can be detached
    /// and reattached without killing the shell process.
    func startNewTerminal(device: Device, workspaceID: String) {
        Task {
            do {
                let paneID = try await service(for: device).createTab(
                    workspaceID: workspaceID,
                    cwd: nil,
                    label: nil
                )
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
                selectedShellID = nil
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// New Agent: a fresh tab in the space plus agent.start. Agent names are
    /// session-global in herdr, so collisions retry with a unique suffix.
    /// `bypass` appends the kind's skip-permissions flag when one is known.
    func startNewAgent(
        device: Device,
        kind: String,
        workspaceID: String?,
        bypass: Bool
    ) {
        let args = bypass ? (HerdrService.bypassFlags(for: kind) ?? []) : []
        Task {
            let service = service(for: device)
            var createdPane: String?
            do {
                let pane = try await service.createTab(workspaceID: workspaceID, cwd: nil, label: kind)
                createdPane = pane
                do {
                    try await service.startAgent(
                        name: kind,
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await service.startAgent(
                        name: "\(kind)-\(suffix)",
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                }
                await refresh(device.id)
                isFileManagerActive = false
                selectedPane = PaneRef(deviceID: device.id, paneID: pane)
            } catch {
                if let createdPane {
                    try? await service.closePane(paneID: createdPane)
                }
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }
}
