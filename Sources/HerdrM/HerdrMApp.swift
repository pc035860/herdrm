import AppKit
import Darwin
import HerdrKit
import Sparkle
import SwiftUI
import UserNotifications

/// Holds app termination open long enough to tear the SSH tunnels down: without
/// `.terminateLater` the process dies before the teardown task gets to run, and the
/// `ssh` children survive with PPID 1 along with their sockets.
///
/// The delegate owns the model rather than borrowing it from the window: closing the
/// last window (⌘W) would otherwise drop the only strong reference, and the quit that
/// follows would find nothing left to tear down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdownAllSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct AppModelFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel
}

/// The split tree travels as its own focused value, not read off the model.
/// `Commands` gets the AppModel by reference and never subscribes to its
/// objectWillChange, so reading tree state off `focusedModel` evaluates once
/// and sticks: menu items stay disabled with a split open, and a disabled
/// NSMenuItem does not fire its key equivalent. A value type changes identity,
/// which does invalidate the commands body — measured on the old axis key,
/// same mechanism here.
private struct SplitTreeFocusedValueKey: FocusedValueKey {
    typealias Value = AppModel.SplitNode
}
extension FocusedValues {
    var appModel: AppModel? {
        get { self[AppModelFocusedValueKey.self] }
        set { self[AppModelFocusedValueKey.self] = newValue }
    }

    var splitTree: AppModel.SplitNode? {
        get { self[SplitTreeFocusedValueKey.self] }
        set { self[SplitTreeFocusedValueKey.self] = newValue }
    }
}

@main
struct HerdrMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("app.theme") private var themePreference = "system"
    @FocusedValue(\.appModel) private var focusedModel
    @FocusedValue(\.splitTree) private var focusedSplitTree

    private let updaterController: SPUStandardUpdaterController

    init() {
        if ProcessInfo.processInfo.environment[SSHCredentialStore.askPassModeEnvironmentKey] == "1" {
            Self.runSSHAskPass()
        }
        AppLanguage.synchronize()
        SSHCredentialStore.purgeAuthorizations()
        TerminalDefaults.registerBundledFonts()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: appDelegate.model)
                .onAppear { Self.applyTheme(themePreference) }
                .onChange(of: themePreference) { _, newValue in
                    Self.applyTheme(newValue)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // herdrm is a single-window console: a second window would duplicate the
            // whole device tree, so New Window gives up ⌘N to the action that matters.
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { focusedModel?.showNewAgent = true }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Terminal") { focusedModel?.showNewTerminal = true }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(focusedModel == nil)
                Button("New Space") { focusedModel?.showNewSpace = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(focusedModel == nil)
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updaterController.checkForUpdates(nil)
                }
            }

            CommandMenu("Terminal") {
                // Enabled whenever a tree or a selected entry exists: with the
                // placeholder on screen and no tree, a split would be invisible
                // yet arm state the next ⌘W would "close" instead of the window.
                Button("Split Vertically") { focusedModel?.openSplit(axis: .vertical) }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(focusedSplitTree == nil && focusedModel?.selectedAttachedEntry == nil)
                Button("Split Horizontally") { focusedModel?.openSplit(axis: .horizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(focusedSplitTree == nil && focusedModel?.selectedAttachedEntry == nil)

                Divider()

                // Four directional items with FIXED shortcuts, enabled while any
                // tree exists — deliberately not axis-gated. The old eight-item
                // workaround existed because shortcuts froze on the axis current
                // at launch; items no longer encode the axis, so that staleness
                // class can't recur. The neighbor comes from tree structure, and
                // a missing neighbor (layout edge) is a safe no-op — never gate
                // correctness on `.disabled()` revalidation (the ⌘D lesson).
                Button("Focus Left Pane") {
                    focusedModel?.focusNeighbor(.left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(focusedSplitTree == nil)
                Button("Focus Right Pane") {
                    focusedModel?.focusNeighbor(.right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(focusedSplitTree == nil)
                Button("Focus Top Pane") {
                    focusedModel?.focusNeighbor(.up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(focusedSplitTree == nil)
                Button("Focus Bottom Pane") {
                    focusedModel?.focusNeighbor(.down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(focusedSplitTree == nil)

                Divider()

                // Resize nudges the focused leaf's nearest same-direction divider
                // by 5% toward the pressed arrow; a leaf facing the other axis
                // no-ops (same ⌘D-lesson rule as focus above).
                Button("Widen Active Pane") {
                    focusedModel?.nudgeFocusedLeaf(arrow: .right)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(focusedSplitTree == nil)
                Button("Narrow Active Pane") {
                    focusedModel?.nudgeFocusedLeaf(arrow: .left)
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(focusedSplitTree == nil)
                Button("Grow Active Pane") {
                    focusedModel?.nudgeFocusedLeaf(arrow: .down)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
                .disabled(focusedSplitTree == nil)
                Button("Shrink Active Pane") {
                    focusedModel?.nudgeFocusedLeaf(arrow: .up)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
                .disabled(focusedSplitTree == nil)

                Divider()

                // No shortcut on purpose: the ⌘⌥/⌘⌃ arrow rows are full, and
                // anything else risks a Ghostty keybind collision.
                Button("Balance Split Panes") {
                    focusedModel?.rebalanceSplits()
                }
                .disabled(focusedSplitTree == nil)
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘W closes the most local thing first: the focused split pane,
                // then the selected standalone terminal, then the window.
                // Server-owned panes close from their confirmed sidebar action
                // instead. Closing the agent leaf collapses the whole tree.
                Button(closeButtonTitle) {
                    if let model = focusedModel, model.splitTree != nil {
                        switch model.focusedSplitLeaf {
                        case .pane(let deviceID, let paneID):
                            model.closeSplitLeaf(.pane(deviceID: deviceID, paneID: paneID))
                            model.focusSplitLeaf(model.focusedSplitLeaf)
                        case .agent:
                            model.collapseSplitTree()
                        }
                    } else if let model = focusedModel, let shell = model.selectedShell {
                        model.closeShellSession(shell.id)
                    } else {
                        NSApp.keyWindow?.performClose(nil)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }
        }

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    private var closeButtonTitle: String {
        if focusedSplitTree != nil { return String(localized: "Close Split Pane") }
        // Reads through the reference (stale until a focus event) — acceptable
        // here because selection changes coincide with scene-focus events, unlike
        // split-tree mutations which fire with focus steady. Don't copy this for
        // split state; that's what the focused value above is for.
        if focusedModel?.selectedShell != nil { return String(localized: "Close Terminal") }
        return String(localized: "Close")
    }

    static func applyTheme(_ preference: String) {
        switch preference {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: - Split commands

    private static func runSSHAskPass() -> Never {
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment[SSHCredentialStore.authorizationIDEnvironmentKey],
              let authorizationID = UUID(uuidString: rawID),
              let password = try? SSHCredentialStore.consumePassword(authorizationID: authorizationID)
        else {
            Darwin.exit(EXIT_FAILURE)
        }
        FileHandle.standardOutput.write(Data("\(password)\n".utf8))
        Darwin.exit(EXIT_SUCCESS)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            AgentsSettingsView(model: model)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            NotificationSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 420)
    }
}

struct AgentsSettingsView: View {
    var model: AppModel
    @State private var drafts: [String: String] = AgentBinaryOverrides.load()

    /// Kinds the picker knows how to start. The lookup command is `kind`,
    /// except Cursor which installs as `cursor-agent`.
    private static let kinds: [(kind: String, label: String, hint: String)] = [
        ("claude", "Claude", "claude"),
        ("codex", "Codex", "codex"),
        ("cursor", "Cursor", "cursor-agent"),
        ("gemini", "Gemini", "gemini"),
        ("grok", "Grok", "grok"),
        ("kimi", "Kimi", "kimi"),
        ("opencode", "OpenCode", "opencode"),
        ("pi", "Pi", "pi"),
        ("omp", "Oh My Pi", "omp"),
        ("copilot", "Copilot", "copilot"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Self.kinds, id: \.kind) { row in
                    TextField(row.label, text: binding(row.kind), prompt: Text("Automatic"))
                        .font(.system(size: 12).monospaced())
                        .help(String(localized: "Command or path for \(row.hint). Leave empty to detect."))
                }
            } footer: {
                Text("Finder-launched apps don’t inherit your terminal PATH. herdrm captures it once from a login + interactive shell, then looks up these names. A path here is an escape hatch when detection picks the wrong binary.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { drafts = AgentBinaryOverrides.load() }
        .onChange(of: drafts) { _, _ in commit() }
        .onDisappear(perform: commit)
        .onSubmit(commit)
    }

    private func commit() {
        AgentBinaryOverrides.save(drafts)
        model.reloadAgentCatalog(deviceID: Device.local.id)
    }

    private func binding(_ kind: String) -> Binding<String> {
        Binding(
            get: { drafts[kind] ?? "" },
            set: { drafts[kind] = $0 }
        )
    }
}

struct TerminalSettingsView: View {
    @AppStorage(TerminalDefaults.fontNameKey) private var fontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var fontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var thinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var fontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var lineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage("terminal.mouseReporting") private var mouseReporting = true

    private let families = TerminalDefaults.monospacedFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                Picker("Font", selection: $fontName) {
                    Text("System Mono (SF Mono)").tag("")
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Slider(value: $fontSize, in: 9...22, step: 0.5) {
                        Text("Size")
                    }
                    Text(String(format: "%.1f pt", fontSize))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                    Stepper("", value: $fontSize, in: 9...22, step: 0.5)
                        .labelsHidden()
                }

                Picker("Weight", selection: $fontWeight) {
                    Text(String(localized: "font.weight.light", defaultValue: "Light"))
                        .tag(Double(NSFont.Weight.light.rawValue))
                    Text(String(localized: "font.weight.regular", defaultValue: "Regular"))
                        .tag(TerminalDefaults.defaultFontWeight)
                    Text(String(localized: "font.weight.medium", defaultValue: "Medium"))
                        .tag(Double(NSFont.Weight.medium.rawValue))
                }
                .pickerStyle(.segmented)
                .disabled(!fontName.isEmpty)
                .help("Only the system monospaced font has selectable weights.")

                HStack {
                    Slider(value: $lineSpacing, in: 1.0...1.4, step: 0.05) {
                        Text("Line spacing")
                    }
                    Text(String(format: "%.0f%%", lineSpacing * 100))
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }

                Toggle(isOn: $thinStrokes) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Thin strokes")
                        Text("Turns off macOS font smoothing, which thickens glyph stems and makes agent output — Claude Code's bold text especially — look heavy and smudged.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Toggle(isOn: $mouseReporting) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mouse reporting")
                        Text("Forwards clicks and drags to TUI apps that ask for them. Turn off to always select text with the mouse — Shift-drag selects either way.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button("Reset to Defaults") {
                    fontName = ""
                    fontSize = TerminalDefaults.defaultFontSize
                    fontWeight = TerminalDefaults.defaultFontWeight
                    lineSpacing = TerminalDefaults.defaultLineSpacing
                    thinStrokes = true
                    mouseReporting = true
                }
            }

            // Outside the Form: its two-column layout has no label for these
            // rows and would indent them by the whole label column.
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("❯ herdr agent attach w1:p1 — 中文 ABC 0123")
                    .font(Font(TerminalDefaults.font(name: fontName, size: fontSize, weight: fontWeight)))
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.terminalBackground, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(20)
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("app.theme") private var themePreference = "system"
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Picker("Theme", selection: $themePreference) {
                Text(String(localized: "theme.system", defaultValue: "System")).tag("system")
                Text(String(localized: "theme.light", defaultValue: "Light")).tag("light")
                Text(String(localized: "theme.dark", defaultValue: "Dark")).tag("dark")
            }
            .pickerStyle(.segmented)
            Text("The terminal follows the app theme.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Picker("Language", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(verbatim: option.displayName).tag(option.rawValue)
                }
            }
            .onChange(of: language) { _, newValue in
                AppLanguage.apply(AppLanguage(rawValue: newValue) ?? .system)
            }
            // Changing AppleLanguages only takes effect on the next process start.
            Text("Changing language takes effect after you quit and reopen herdrm.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct NotificationSettingsView: View {
    @AppStorage("notifications.enabled") private var enabled = true
    @AppStorage("notifications.sound") private var sound = true
    @State private var authorization: UNAuthorizationStatus?

    var body: some View {
        Form {
            Toggle("Notify when an agent finishes or needs input", isOn: $enabled)
            Toggle("Play a sound", isOn: $sound)
            Text("Finished agents only notify while you're not watching them — herdr reports panes you have open as idle, not done.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Divider()

            switch authorization {
            case .denied:
                HStack(spacing: 8) {
                    Text("Notifications are disabled in System Settings.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Open System Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            case .notDetermined:
                HStack(spacing: 8) {
                    Text("Notification permission hasn't been granted yet.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Button("Request Permission") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
                            refreshAuthorization()
                        }
                    }
                    .controlSize(.small)
                }
            case .authorized, .provisional:
                Text("Notification permission granted.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .padding(20)
        .onAppear { refreshAuthorization() }
    }

    private func refreshAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { authorization = settings.authorizationStatus }
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Text("herdrm — a native macOS console for herdr.")
                .font(.system(size: 12.5))
            Text("Devices are managed from the switcher in the sidebar footer.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}
