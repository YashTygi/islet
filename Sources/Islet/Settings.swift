import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// The control panel window. Built on open and released on close, so it costs nothing while closed.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let services: Services
    private let activities: ActivityCenter

    init(services: Services, activities: ActivityCenter) {
        self.services = services
        self.activities = activities
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Islet"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: SettingsView(services: services, activities: activities))
            w.setContentSize(NSSize(width: 680, height: 480))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

private enum Page: String, CaseIterable, Identifiable {
    case general, notch, actions, agents, about
    var id: String { rawValue }
    var title: String { switch self { case .general: "General"; case .notch: "Notch"; case .actions: "App Actions"; case .agents: "Agents"; case .about: "About" } }
    var symbol: String {
        switch self { case .general: "gearshape"; case .notch: "rectangle.topthird.inset.filled"; case .actions: "wand.and.stars"; case .agents: "sparkles"; case .about: "info.circle" }
    }
}

private struct SettingsView: View {
    let services: Services
    let activities: ActivityCenter
    private let page = State(initialValue: Page.general)  // see Scrubber: no @State without Xcode

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Page.allCases) { p in
                    Button { page.wrappedValue = p } label: {
                        Label(p.title, systemImage: p.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(page.wrappedValue == p ? Color.accentColor.opacity(0.18) : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.top, 40).padding(.horizontal, 10)
            .frame(width: 170)
            .background(.ultraThinMaterial)
            Divider()
            Group {
                switch page.wrappedValue {
                case .general: GeneralPage(prefs: services.prefs)
                case .notch: NotchPage(prefs: services.prefs)
                case .actions: ActionsPage(prefs: services.prefs)
                case .agents: AgentsPage(prefs: services.prefs)
                case .about: AboutPage(openOnboarding: services.openOnboarding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 480)
        .ignoresSafeArea()
    }
}

private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: get, set: set)
}

// MARK: General

private struct GeneralPage: View {
    let prefs: Prefs
    private let tick = State(initialValue: 0)

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: bind({ _ = tick.wrappedValue; return SMAppService.mainApp.status == .enabled }) { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    tick.wrappedValue += 1
                })
                Toggle("Play sounds (agent needs you, task done, timer)", isOn: bind({ prefs.sounds }) { prefs.sounds = $0 })
                Toggle("Haptic tap on open and alerts (Force Touch trackpad)", isOn: bind({ prefs.haptics }) { prefs.haptics = $0 })
                Toggle("Keep the Mac awake while agents or tasks run", isOn: bind({ prefs.keepAwake }) { prefs.keepAwake = $0 })
                Toggle("Put finished downloads on the File Shelf", isOn: bind({ prefs.autoShelf }) { prefs.autoShelf = $0 })
            }
            Section {
                Toggle("Double-tap Control to open and lock the notch", isOn: bind({ prefs.hotkey }) { prefs.hotkey = $0 })
                LabeledContent("Accessibility") {
                    if AXIsProcessTrusted() {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } footer: {
                Text("Needed only for the Control hotkey. Islet reads the Control key state, never what you type.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard (after double-tapping Control)") {
                ForEach(Shortcuts.list, id: \.keys) { s in
                    LabeledContent(s.action) { Text(s.keys).font(.system(.body, design: .rounded).weight(.semibold)) }
                }
            }
            Section("Footprint") {
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    LabeledContent("Memory in use", value: Self.footprint())
                }
            }
        }
        .formStyle(.grouped)
    }

    static func footprint() -> String {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? ByteCountFormatter.string(fromByteCount: Int64(info.ri_phys_footprint), countStyle: .memory) : "—"
    }
}

// MARK: Notch

private struct NotchPage: View {
    let prefs: Prefs

    var body: some View {
        Form {
            Section("Tabs") {
                ForEach(NotchTab.allCases.filter { $0 != .home }) { t in
                    Toggle(isOn: bind({ !prefs.hiddenTabs.contains(t) }) { on in
                        if on { prefs.hiddenTabs.remove(t) } else { prefs.hiddenTabs.insert(t) }
                    }) { Label(t.title, systemImage: t.symbol) }
                }
            }
            Section {
                Toggle("Open to the App tab when the front app has actions", isOn: bind({ prefs.openToAppTab }) { prefs.openToAppTab = $0 })
            }
            Section("Home cards") {
                ForEach(HomeCard.allCases) { c in
                    HStack {
                        Toggle(c.title, isOn: bind({ prefs.homeCards.contains(c) }) { on in
                            if on { prefs.homeCards.append(c) } else { prefs.homeCards.removeAll { $0 == c } }
                        })
                        Spacer()
                        if let i = prefs.homeCards.firstIndex(of: c) {
                            Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(i == prefs.homeCards.count - 1)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Section("Live activities in the collapsed notch") {
                ForEach(ActivityKind.allCases) { k in
                    Toggle(k.title, isOn: bind({ !prefs.disabledActivities.contains(k) }) { on in
                        if on { prefs.disabledActivities.remove(k) } else { prefs.disabledActivities.insert(k) }
                    })
                }
            }
        }
        .formStyle(.grouped)
    }

    private func move(_ i: Int, by d: Int) {
        var cards = prefs.homeCards
        cards.swapAt(i, i + d)
        withAnimation { prefs.homeCards = cards }
    }
}

// MARK: App actions

/// Your own buttons per app: a title and a shell command (runs in a login shell, shown as a task).
private struct ActionsPage: View {
    let prefs: Prefs
    private let appID = State(initialValue: "")
    private let name = State(initialValue: "")
    private let command = State(initialValue: "")

    var body: some View {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { a in a.bundleIdentifier.map { ($0, a.localizedName ?? $0) } }
            .sorted { $0.1 < $1.1 }
        Form {
            Section {
                Text("Built in: VS Code/Cursor (git, project servers, run tests, terminal), Chrome/Brave/Safari (clean & Markdown links, localhost, Google Meet mute/camera, Notion shortcuts), Figma (eyedropper + colour history), Claude (usage + agents). Add your own buttons for any app below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Your actions") {
                if prefs.customActions.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(prefs.customActions) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(a.appName) · \(a.title)")
                            Text(a.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button(role: .destructive) { prefs.customActions.removeAll { $0.id == a.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Add an action") {
                Picker("App", selection: bind({ appID.wrappedValue }) { appID.wrappedValue = $0 }) {
                    Text("Choose…").tag("")
                    ForEach(apps, id: \.0) { Text($0.1).tag($0.0) }
                }
                TextField("Button title", text: bind({ name.wrappedValue }) { name.wrappedValue = $0 })
                TextField("Shell command (e.g. open -a Terminal ~/Developer)", text: bind({ command.wrappedValue }) { command.wrappedValue = $0 })
                    .font(.system(.body, design: .monospaced))
                Button("Add") {
                    let appName = apps.first { $0.0 == appID.wrappedValue }?.1 ?? appID.wrappedValue
                    prefs.customActions.append(CustomAction(bundleID: appID.wrappedValue, appName: appName,
                                                            title: name.wrappedValue, command: command.wrappedValue))
                    name.wrappedValue = ""; command.wrappedValue = ""
                }
                .disabled(appID.wrappedValue.isEmpty || name.wrappedValue.isEmpty || command.wrappedValue.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Agents

private struct AgentsPage: View {
    let prefs: Prefs
    private let tick = State(initialValue: 0)
    private let error = State<String?>(initialValue: nil)

    var body: some View {
        let _ = tick.wrappedValue
        Form {
            Section {
                LabeledContent("Claude Code") {
                    if !ClaudeHooks.claudePresent {
                        Text("Not found").foregroundStyle(.secondary)
                    } else if ClaudeHooks.isInstalled {
                        HStack {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove") { run(ClaudeHooks.uninstall) }
                        }
                    } else {
                        Button("Install hooks") { run(ClaudeHooks.install) }.buttonStyle(.borderedProminent)
                    }
                }
                if let e = error.wrappedValue { Text(e).foregroundStyle(.red).font(.caption) }
            } header: {
                Text("Agent status")
            } footer: {
                Text("Adds Islet hooks for SessionStart, UserPromptSubmit, Pre/PostToolUse, Notification, Stop and SessionEnd to ~/.claude/settings.json. Your other settings are kept, and the original is backed up to settings.json.mynotch-backup. New Claude sessions pick it up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("`islet` command") {
                    if CLIInstaller.isInstalled {
                        Label("~/.local/bin/islet", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install") { run(CLIInstaller.install) }
                    }
                }
                Text("islet run npm test        # watch any long task\nislet agent waiting --name Cursor   # report from any tool")
                    .font(.system(size: 11, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
            } header: {
                Text("Long tasks & other agents")
            } footer: {
                Text("Codex: add  notify = [\"\(ClaudeHooks.cliPath)\", \"hook\", \"codex\"]  to ~/.codex/config.toml.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section {
                TextField("Tokens per 5-hour window (optional)", value: bind({ prefs.claudeTokenLimit }) { prefs.claudeTokenLimit = max($0, 0) },
                          format: .number)
            } header: {
                Text("Usage meter")
            } footer: {
                Text("Leave at 0 to show how far into the 5-hour window you are. Set your plan's budget to see a quota bar instead. Token counts come from Claude Code's local session logs; nothing leaves your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error.wrappedValue = nil } catch { self.error.wrappedValue = error.localizedDescription }
        tick.wrappedValue += 1
    }
}

/// Installs/removes Islet hooks in ~/.claude/settings.json without touching anything else.
enum ClaudeHooks {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    static let file = dir.appendingPathComponent("settings.json")
    static var cliPath: String { Bundle.main.bundlePath + "/Contents/Helpers/islet" }
    static var command: String { "'\(cliPath)' hook claude" }
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionEnd"]

    static var claudePresent: Bool { FileManager.default.fileExists(atPath: dir.path) }

    static var isInstalled: Bool {
        let hooks = (load()["hooks"] as? [String: Any]) ?? [:]
        return events.allSatisfy { ((hooks[$0] as? [[String: Any]]) ?? []).contains(where: isOurs) }
    }

    static func install() throws {
        var settings = load()
        let backup = dir.appendingPathComponent("settings.json.mynotch-backup")
        if FileManager.default.fileExists(atPath: file.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: file, to: backup)
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for e in events {
            var list = (hooks[e] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
            if e == "PreToolUse" || e == "PostToolUse" { entry["matcher"] = "*" }
            list.append(entry)
            hooks[e] = list
        }
        settings["hooks"] = hooks
        try save(settings)
    }

    static func uninstall() throws {
        var settings = load()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for e in events {
            let list = (hooks[e] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            if list.isEmpty { hooks.removeValue(forKey: e) } else { hooks[e] = list }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        try save(settings)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        ((entry["hooks"] as? [[String: Any]]) ?? []).contains {
            let c = ($0["command"] as? String) ?? ""
            return c.contains("hook claude") && (c.contains("/Helpers/islet") || c.contains("/MacOS/notch"))
        }
    }

    private static func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func save(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: file, options: .atomic)
    }
}

/// `islet` on your PATH via a symlink in ~/.local/bin (where Claude Code installs itself too).
enum CLIInstaller {
    static let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/islet")

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == ClaudeHooks.cliPath
    }

    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try fm.removeItem(at: link)  // our old link (e.g. app moved)
        } else if fm.fileExists(atPath: link.path) {
            throw NSError(domain: "Islet", code: 1, userInfo: [NSLocalizedDescriptionKey: "~/.local/bin/islet already exists and isn't a Islet link; left it alone."])
        }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: ClaudeHooks.cliPath)
        // Old name: remove ~/.local/bin/notch if it's our link from before the rename.
        let old = link.deletingLastPathComponent().appendingPathComponent("notch")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: old.path), dest.hasSuffix("/Contents/MacOS/notch") {
            try? fm.removeItem(at: old)
        }
    }
}

// MARK: About

private struct AboutPage: View {
    let openOnboarding: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Islet").font(.title2.weight(.semibold))
            Text("Mission control for background work").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .font(.caption).foregroundStyle(.secondary)
            Text("Everything stays on this Mac. No accounts, no analytics.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Show setup again", action: openOnboarding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
