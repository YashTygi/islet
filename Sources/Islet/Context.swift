import AppKit
import ApplicationServices
import SwiftUI

/// Which app (and, for browsers, which site) is in front. Driven by app-activation notifications;
/// details (window title, tab URL, git status) are read only while the App tab is on screen.
enum AppContext: Equatable {
    case none
    case code(app: String)          // VS Code / Cursor
    case browser(app: String)       // Chrome / Brave / Safari
    case figma
    case claude(app: String)
    case terminal(app: String)
    case finder
    case other(app: String)

    static let codeIDs = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
    static let browserIDs = ["com.google.Chrome", "com.brave.Browser", "com.apple.Safari"]
    static let terminalIDs = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]

    init(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier else { self = .none; return }
        let name = app.localizedName ?? id
        if Self.codeIDs.contains(id) { self = .code(app: name) }
        else if Self.browserIDs.contains(id) { self = .browser(app: name) }
        else if id == "com.figma.Desktop" { self = .figma }
        else if id == "com.anthropic.claudefordesktop" || id.hasPrefix("com.apple.ScriptEditor.id.Claude") { self = .claude(app: name) }
        else if Self.terminalIDs.contains(id) { self = .terminal(app: name) }
        else if id == "com.apple.finder" { self = .finder }
        else { self = .other(app: name) }
    }

    var hasActions: Bool { if case .other = self { return false }; return self != .none }
}

@MainActor @Observable
final class ContextService {
    private(set) var context: AppContext = .none
    private(set) var app: NSRunningApplication?
    private(set) var icon: NSImage?
    /// Figma eyedropper history (hex), newest first.
    private(set) var colors: [String] = UserDefaults.standard.stringArray(forKey: "pickedColors") ?? []

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            nonisolated(unsafe) let a = app
            MainActor.assumeIsolated { self?.set(a) }
        }
        set(NSWorkspace.shared.frontmostApplication)
    }

    private func set(_ a: NSRunningApplication?) {
        guard a?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }  // our own settings window
        app = a
        context = AppContext(a)
        // Finder is "in front" whenever you're on the desktop; it only counts with a real window open.
        if context == .finder && !Self.finderHasWindow(a) { context = .other(app: "Finder") }
        icon = a?.icon
        icon?.size = NSSize(width: 32, height: 32)
        debugLog("context: \(context)")
    }

    /// Re-check when the notch opens (Finder windows can close without an app switch).
    func refresh() {
        guard let a = app, a.bundleIdentifier == "com.apple.finder" else { return }
        let ctx: AppContext = Self.finderHasWindow(a) ? .finder : .other(app: "Finder")
        if ctx != context { context = ctx }
    }

    /// A real, visible Finder window (layer 0) as opposed to just the desktop. Stage Manager's side-strip
    /// thumbnails are reported as tiny (~140 pt) Finder windows; Finder windows can't be that small, so
    /// anything under 250×150 pt doesn't count.
    private static func finderHasWindow(_ a: NSRunningApplication?) -> Bool {
        guard let pid = a?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        return list.contains {
            guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
                  let b = $0[kCGWindowBounds as String] as? [String: Any] else { return false }
            return (b["Width"] as? Double ?? 0) >= 250 && (b["Height"] as? Double ?? 0) >= 150
        }
    }

    // MARK: Reading details (only called from the visible App tab)

    /// Focused window via Accessibility (Islet already has it for the hotkey).
    private func focusedWindow() -> AXUIElement? {
        guard let pid = app?.processIdentifier else { return nil }
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return nil }
        return (win as! AXUIElement)  // swiftlint:disable:this force_cast
    }

    private func attribute(_ name: String) -> String? {
        guard let w = focusedWindow() else { return nil }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(w, name as CFString, &v)
        return v as? String
    }

    func windowTitle() -> String? { attribute(kAXTitleAttribute) }

    @ObservationIgnored private var spotlightCache: [String: String] = [:]

    /// The project open in VS Code / Cursor, wherever it lives (external drives included):
    /// 1. the window's document (file of the active editor) → walk up to the git root;
    /// 2. else the folder name from the title ("file — folder", "folder", with or without "— Visual Studio Code"),
    ///    found in the usual dev folders or via Spotlight.
    func codeProject() -> (name: String, path: String?)? {
        if let doc = attribute(kAXDocumentAttribute), let file = URL(string: doc), file.isFileURL,
           let root = Self.projectRoot(containing: file.path) {
            return (URL(fileURLWithPath: root).lastPathComponent, root)
        }
        guard let title = windowTitle() else { return nil }
        var parts = title.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = parts.last, ["Visual Studio Code", "Cursor", "Code - Insiders"].contains(last) { parts.removeLast() }
        guard var name = parts.last, !name.isEmpty else { return nil }
        name = name.replacingOccurrences(of: " [Workspace]", with: "").replacingOccurrences(of: "● ", with: "")
        return (name, findFolder(named: name))
    }

    /// Nearest ancestor with .git (else package.json / Package.swift / Cargo.toml / go.mod / pyproject.toml).
    static func projectRoot(containing path: String) -> String? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        var marker: String?
        while dir.path != "/" && dir.path != "/Volumes" {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            if marker == nil, ["package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml"]
                .contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) { marker = dir.path }
            dir.deleteLastPathComponent()
        }
        return marker
    }

    private func findFolder(named name: String) -> String? {
        if let hit = spotlightCache[name] { return hit }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let isProject = { (p: String) in fm.fileExists(atPath: p + "/.git") || fm.fileExists(atPath: p + "/package.json") }
        var found = ["Developer", "Projects", "Code", "dev", "src", "Documents/GitHub", ""]
            .map { "\(home)/\($0)/\(name)".replacingOccurrences(of: "//", with: "/") }
            .first(where: isProject)
        if found == nil {  // Spotlight, any volume; cached per name
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["kMDItemFSName == '\(name.replacingOccurrences(of: "'", with: ""))' && kMDItemContentType == 'public.folder'"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init).first(where: isProject)
        }
        if let found { spotlightCache[name] = found }
        return found
    }

    /// Active tab of Chrome / Brave / Safari via AppleScript (asks for Automation permission once).
    func browserTab() async -> (title: String, url: String)? {
        guard let id = app?.bundleIdentifier, let name = app?.localizedName else { return nil }
        let src = id == "com.apple.Safari"
            ? "tell application \"Safari\" to return (name of current tab of front window) & linefeed & (URL of current tab of front window)"
            : "tell application \"\(name)\" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"
        guard let out = await appleScript(src) else { return nil }
        let lines = out.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        return (lines.dropLast().joined(separator: "\n"), lines.last ?? "")
    }

    /// Finder's current folder (front window, else Desktop) and selected items, as POSIX paths.
    func finderInfo() async -> (folder: String?, selection: [String]) {
        let src = """
        tell application "Finder"
          set out to ""
          repeat with s in (selection as alias list)
            set out to out & POSIX path of s & linefeed
          end repeat
          try
            set f to POSIX path of (target of front Finder window as alias)
          on error
            set f to POSIX path of (desktop as alias)
          end try
          return f & "||" & out
        end tell
        """
        guard let out = await appleScript(src) else { return (nil, []) }
        let parts = out.components(separatedBy: "||")
        let folder = parts.first.flatMap { $0.isEmpty ? nil : $0 }
        let sel = parts.count > 1 ? parts[1].split(separator: "\n").map(String.init) : []
        return (folder, sel)
    }

    /// Path relative to the enclosing git project root, else to the home folder (~/…).
    static func relativePath(_ path: String) -> String {
        let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        var dir = URL(fileURLWithPath: clean)
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let rel = String(clean.dropFirst(dir.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return rel.isEmpty ? "." : rel
            }
            dir.deleteLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return clean.hasPrefix(home) ? "~" + clean.dropFirst(home.count) : clean
    }

    /// Sends a keyboard shortcut to the frontmost app (e.g. ⌘D mute in Google Meet). Needs Accessibility.
    func sendShortcut(_ keyCode: CGKeyCode, flags: CGEventFlags = .maskCommand) {
        guard let pid = app?.processIdentifier else { return }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)
            e?.flags = flags
            e?.postToPid(pid)
        }
    }

    func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            MainActor.assumeIsolated {
                guard let self else { return }
                copyToClipboard(hex)
                self.colors.removeAll { $0 == hex }
                self.colors.insert(hex, at: 0)
                if self.colors.count > 12 { self.colors.removeLast() }
                UserDefaults.standard.set(self.colors, forKey: "pickedColors")
            }
        }
    }
}

/// Runs AppleScript in a separate `osascript` process: keeps macOS's AppleScript engine (~12 MB) out of
/// Islet's memory. Automation permission stays attributed to Islet (the responsible app).
func appleScript(_ src: String) async -> String? {
    guard let out = await runTool("/usr/bin/osascript", ["-e", src], timeout: 5) else { return nil }
    return out.hasSuffix("\n") ? String(out.dropLast()) : out
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Drops tracking parameters (utm_*, fbclid, gclid, …) from a URL.
func cleanURL(_ s: String) -> String {
    guard var c = URLComponents(string: s) else { return s }
    let junk = ["fbclid", "gclid", "dclid", "mc_cid", "mc_eid", "igshid", "ref_src", "si", "spm"]
    c.queryItems = c.queryItems?.filter { q in !q.name.hasPrefix("utm_") && !junk.contains(q.name) }
    if c.queryItems?.isEmpty == true { c.queryItems = nil }
    return c.string ?? s
}

/// Ports whose process runs inside `path` (dev servers of this project).
func projectPorts(_ path: String) async -> [ListeningPort] {
    var result: [ListeningPort] = []
    for p in await Ports.scan() {
        guard let out = await runTool("/usr/sbin/lsof", ["-a", "-p", "\(p.pid)", "-d", "cwd", "-Fn"], timeout: 2),
              let cwd = out.split(separator: "\n").first(where: { $0.hasPrefix("n") })?.dropFirst() else { continue }
        if String(cwd).hasPrefix(path) { result.append(p) }
    }
    return result
}

// MARK: App tab

struct AppTabView: View {
    let model: NotchModel
    private let title = State<String?>(initialValue: nil)
    private let url = State<String?>(initialValue: nil)
    private let project = State<(name: String, path: String?)?>(initialValue: nil)
    private let git = State<GitStatus?>(initialValue: nil)
    private let ports = State<[ListeningPort]>(initialValue: [])
    private let flash = State<String?>(initialValue: nil)  // see Scrubber: no @State without Xcode
    private let showQR = State(initialValue: false)
    private let finder = State<(folder: String?, selection: [String])>(initialValue: (nil, []))

    var body: some View {
        let ctx = model.services.context
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon = ctx.icon { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                Text(header(ctx.context)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let f = flash.wrappedValue {
                    Text(f).font(.system(size: 10, weight: .medium)).foregroundStyle(.green).transition(.opacity)
                }
                Spacer()
            }
            Group {
                switch ctx.context {
                case .code: codePanel
                case .browser: browserPanel
                case .figma: figmaPanel
                case .claude: claudePanel
                case .terminal: workPanel(filter: nil)
                case .finder: finderPanel
                case .other, .none: customPanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: ctx.app?.processIdentifier) {
            // Refresh while this tab is visible; cancelled when it isn't.
            while !Task.isCancelled {
                await refresh(ctx)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func header(_ c: AppContext) -> String {
        switch c {
        case .code: project.wrappedValue.map { "\($0.name)" } ?? "VS Code"
        case .browser(let app): title.wrappedValue ?? app
        case .figma: "Figma"
        case .claude(let app): app
        case .terminal(let app): app
        case .finder: finder.wrappedValue.folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Finder"
        case .other(let app): app
        case .none: "No app in front"
        }
    }

    private func refresh(_ ctx: ContextService) async {
        switch ctx.context {
        case .code:
            project.wrappedValue = ctx.codeProject()
            if let path = project.wrappedValue?.path {
                git.wrappedValue = await GitStatus.read(path)
                ports.wrappedValue = await projectPorts(path)
            } else {
                git.wrappedValue = nil; ports.wrappedValue = []
            }
        case .finder:
            finder.wrappedValue = await ctx.finderInfo()
        case .browser:
            let t = await ctx.browserTab()
            title.wrappedValue = t?.title
            url.wrappedValue = t?.url
        default: break
        }
    }

    private func done(_ text: String) {
        withAnimation { flash.wrappedValue = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { flash.wrappedValue = nil } }
    }

    // MARK: VS Code / Cursor

    private var codePanel: some View {
        CodePanel(model: model, project: project.wrappedValue, status: git.wrappedValue, ports: ports.wrappedValue,
                  refresh: { Task { await refresh(model.services.context) } }, done: done)
    }

    // MARK: Browser

    @ViewBuilder private var browserPanel: some View {
        let ctx = model.services.context
        let u = url.wrappedValue ?? ""
        let pageTitle = title.wrappedValue ?? ""
        let host = URL(string: u)?.host ?? ""
        let lan = Browser.networkURL(u)
        let others = Browser.all.filter { $0.id != ctx.app?.bundleIdentifier }
        HStack(alignment: .top, spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(u).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    if url.wrappedValue == nil {
                        Text("Allow Islet to control \(ctx.app?.localizedName ?? "the browser") when macOS asks, to see the current tab.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    if let lan {
                        // Same dev server, reachable from your phone on the same Wi-Fi.
                        HStack(spacing: 6) {
                            Image(systemName: "iphone").foregroundStyle(.green)
                            Text(lan).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                            IconButton(symbol: "doc.on.doc", help: "Copy network URL") { copyToClipboard(lan); done("Copied") }
                        }
                        Text("Phone can't connect? Start the server on 0.0.0.0 (e.g. --host).")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
                        publicRow(port: URLComponents(string: u)?.port ?? 80)
                    }
                    // Window sizes for responsive checks: on every page, not just localhost.
                    row("Size") {
                        ForEach(Browser.sizes, id: \.name) { s in
                            chip(s.name, s.symbol) { Task { await Browser.resize(ctx.app, width: s.w, height: s.h) } }
                        }
                    }
                    row("Link") {
                        chip("Clean link", "link") { copyToClipboard(cleanURL(u)); done("Copied") }
                        chip("Markdown", "text.badge.plus") { copyToClipboard("[\(pageTitle.isEmpty ? host : pageTitle)](\(cleanURL(u)))"); done("Copied") }
                        chip(showQR.wrappedValue ? "Hide QR" : "To phone (QR)", "qrcode") { withAnimation { showQR.wrappedValue.toggle() } }
                    }
                    if Browser.shelfActions {
                        row("Shelf") {
                            chip("Screenshot", "camera.viewfinder") {
                                Task {
                                    if let f = await Browser.screenshot(ctx.app, title: pageTitle.isEmpty ? host : pageTitle) {
                                        model.tray.add([f]); done("On the shelf")
                                    } else { done("Allow Screen Recording for Islet") }
                                }
                            }
                            chip("Link file", "doc.badge.plus") {
                                if let f = Browser.linkFile(title: pageTitle, url: cleanURL(u)) { model.tray.add([f]); done("On the shelf") }
                            }
                        }
                    }
                    if Browser.tabActions {
                        row("Tabs") {
                            chip("All tabs → Markdown", "list.bullet.rectangle") {
                                Task { if let r = await Browser.allTabsMarkdown(ctx.app) { copyToClipboard(r.text); done("\(r.count) tabs copied") } }
                            }
                            chip("Close duplicates", "square.on.square.dashed") {
                                Task { let n = await Browser.closeDuplicates(ctx.app); done(n == 0 ? "No duplicates" : "Closed \(n)") }
                            }
                        }
                    }
                    row("Open in") {
                        ForEach(others, id: \.id) { b in chip(b.name, "arrow.up.forward.app") { Browser.open(u, inBrowserAt: b.path) } }
                        if !Browser.isSafari(ctx.app) { chip("Private", "eye.slash") { Task { await Browser.openPrivate(u, in: ctx.app) } } }
                    }
                    if let gh = Browser.github(u) { githubRow(gh, pageTitle: pageTitle) }
                    if host == "meet.google.com" {
                        row("Meet") {
                            chip("Mute / unmute", "mic.slash.fill") { ctx.sendShortcut(2) }       // ⌘D
                            chip("Camera on / off", "video.slash.fill") { ctx.sendShortcut(14) }  // ⌘E
                        }
                    }
                    if host.hasSuffix("notion.so") || host.hasSuffix("notion.site") {
                        row("Notion") {
                            chip("Copy page link", "link") { ctx.sendShortcut(37); done("Copied") }  // ⌘L
                            chip("New page", "plus") { ctx.sendShortcut(45) }                      // ⌘N
                            chip("Search", "magnifyingglass") { ctx.sendShortcut(35) }             // ⌘P
                        }
                    }
                    ForEach(model.services.downloads.items) { d in
                        HStack { Text(d.name).font(.system(size: 11)).lineLimit(1); ProgressView(value: d.fraction).tint(.blue) }
                    }
                }
            }
            if showQR.wrappedValue || lan != nil, let img = Browser.qr(publicURL(for: u) ?? lan ?? u) {
                VStack(spacing: 4) {
                    Image(nsImage: img).interpolation(.none).resizable()
                        .frame(width: 104, height: 104)
                        .padding(6).background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    Text(publicURL(for: u) != nil ? "Scan · public link" : lan != nil ? "Scan · same Wi-Fi" : "Scan to open on phone")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                }
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private func githubRow(_ page: Browser.GitHubPage, pageTitle: String) -> some View {
        row("GitHub") {
            switch page {
            case .repo(let owner, let repo):
                chip("Copy clone", "terminal") { copyToClipboard("git clone https://github.com/\(owner)/\(repo).git"); done("Copied") }
                chip("Clone in VS Code", "chevron.left.forwardslash.chevron.right") {
                    if let v = URL(string: "vscode://vscode.git/clone?url=https%3A%2F%2Fgithub.com%2F\(owner)%2F\(repo).git") { NSWorkspace.shared.open(v) }
                }
            case .pull(let owner, let repo, let n):
                chip("Copy checkout", "arrow.triangle.branch") { copyToClipboard("gh pr checkout \(n) -R \(owner)/\(repo)"); done("Copied") }
                chip("Copy #\(n) title", "number") { copyToClipboard("#\(n) \(Browser.githubTitle(pageTitle))"); done("Copied") }
            case .issue(let owner, let repo, let n):
                chip("Copy as task", "checklist") {
                    copyToClipboard("- [ ] \(owner)/\(repo)#\(n) \(Browser.githubTitle(pageTitle))"); done("Copied")
                }
                chip("Copy #\(n) title", "number") { copyToClipboard("#\(n) \(Browser.githubTitle(pageTitle))"); done("Copied") }
            }
        }
    }

    /// Live public URL if the tunnel is sharing this page's port.
    private func publicURL(for pageURL: String) -> String? {
        guard case .live(let p, let url) = model.services.tunnel.state,
              p == (URLComponents(string: pageURL)?.port ?? 80) else { return nil }
        return url
    }

    /// Share publicly: start/stop a tunnel for this port, show the link.
    @ViewBuilder private func publicRow(port: Int) -> some View {
        let tunnel = model.services.tunnel
        row("Public") {
            switch tunnel.state {
            case .live(let p, let url) where p == port:
                Image(systemName: "globe").foregroundStyle(.green)
                Text(url).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                IconButton(symbol: "doc.on.doc", help: "Copy public link") { copyToClipboard(url); done("Copied") }
                chip("Stop", "stop.fill") { tunnel.stop() }
            case .starting(let p) where p == port:
                ProgressView().controlSize(.small)
                Text("Opening a tunnel via \(TunnelService.provider)…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            default:
                chip("Share publicly", "globe") { tunnel.start(port: port) }
                if case .failed(let why) = tunnel.state {
                    Text(why).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                } else if let other = tunnel.livePort {
                    Text("Sharing :\(other); this stops it").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        Text("Anyone with the public link can open this server until you press Stop (or quit Islet). Some dev servers need the tunnel host allowed (e.g. Vite allowedHosts).")
            .font(.system(size: 9)).foregroundStyle(.orange.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
    }

    /// A labelled row of chips.
    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(width: 40, alignment: .leading)
            content()
        }
    }

    // MARK: Finder

    @ViewBuilder private var finderPanel: some View {
        let f = finder.wrappedValue
        // Selection if there is one, otherwise the current folder.
        let targets = f.selection.isEmpty ? (f.folder.map { [$0] } ?? []) : f.selection
        let terminalDir: String? = targets.first.map { p in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            return isDir.boolValue ? p : URL(fileURLWithPath: p).deletingLastPathComponent().path
        }
        VStack(alignment: .leading, spacing: 8) {
            if targets.isEmpty {
                Text("Allow Islet to control Finder when macOS asks, to act on the current folder.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text(f.selection.isEmpty ? (f.folder ?? "") : f.selection.count == 1 ? f.selection[0] : "\(f.selection.count) items selected")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                HStack(spacing: 6) {
                    if let dir = terminalDir {
                        chip("Open Terminal here", "terminal") {
                            NSWorkspace.shared.open([URL(fileURLWithPath: dir)],
                                                    withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                                    configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    chip("Copy path", "doc.on.doc") {
                        copyToClipboard(targets.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }.joined(separator: "\n"))
                        done("Copied")
                    }
                    chip("Copy relative path", "arrow.turn.down.right") {
                        copyToClipboard(targets.map(ContextService.relativePath).joined(separator: "\n"))
                        done("Copied")
                    }
                }
                if let rel = targets.first.map(ContextService.relativePath) {
                    Text("relative: \(rel)\(targets.count > 1 ? " …" : "")")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                }
            }
        }
    }

    // MARK: Figma

    @ViewBuilder private var figmaPanel: some View {
        let ctx = model.services.context
        VStack(alignment: .leading, spacing: 8) {
            chip("Pick a colour from the screen", "eyedropper") { ctx.pickColor() }
            if !ctx.colors.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                    ForEach(ctx.colors, id: \.self) { hex in
                        Button { copyToClipboard(hex); done("\(hex) copied") } label: {
                            VStack(spacing: 2) {
                                RoundedRectangle(cornerRadius: 6).fill(Color(hex: hex)).frame(height: 24)
                                Text(hex).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                Text("Picked colours appear here; click one to copy its hex.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    // MARK: Claude

    @ViewBuilder private var claudePanel: some View {
        HStack(alignment: .top, spacing: 12) {
            UsageCard(usage: model.services.usage, tokenLimit: model.services.prefs.claudeTokenLimit)
                .frame(width: 200).background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
            workPanel(filter: nil)
        }
    }

    // MARK: Shared

    private func workPanel(filter project: String?) -> some View {
        let agents = model.services.agents.agents.filter { project == nil || $0.project == project }
        let tasks = model.services.tasks.finished.filter { project == nil || $0.project == project }.prefix(3)
        return VStack(alignment: .leading, spacing: 4) {
            Label(project == nil ? "Agents & tasks" : "In this project", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            if agents.isEmpty && tasks.isEmpty {
                Text("Nothing running").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            ForEach(agents) { a in
                Button { jump(toApp: a.hostApp) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: a.state.symbol).foregroundStyle(a.state.color)
                        Text("\(a.name) · \(a.state.label)").font(.system(size: 11)).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(tasks)) { t in
                HStack(spacing: 6) {
                    Image(systemName: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(t.ok ? .green : .red)
                    Text(t.command).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var customPanel: some View {
        let actions = model.services.prefs.customActions.filter { $0.bundleID == model.services.context.app?.bundleIdentifier }
        if actions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No actions for this app yet.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Button("Add your own in the control panel…", action: model.services.openSettings)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.purple)
            }
        } else {
            FlowChips(actions: actions, tasks: model.services.tasks)
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(.white.opacity(0.1))).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct FlowChips: View {
    let actions: [CustomAction]
    let tasks: TaskStore

    var body: some View {
        HStack(spacing: 6) {
            ForEach(actions) { a in
                Button { CustomAction.run(a, tasks: tasks) } label: {
                    Label(a.title, systemImage: "bolt.fill").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(.purple.opacity(0.25))).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension Color {
    init(hex: String) {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

// MARK: Running things in the background (shown as tasks)

enum TestRunner {
    /// The project's test command, from what's in the folder.
    static func command(in path: String) -> (label: String, command: String)? {
        let fm = FileManager.default
        if let data = fm.contents(atPath: path + "/package.json"),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (j["scripts"] as? [String: Any])?["test"] != nil {
            return ("tests", fm.fileExists(atPath: path + "/pnpm-lock.yaml") ? "pnpm test" : fm.fileExists(atPath: path + "/bun.lockb") ? "bun test" : "npm test")
        }
        if fm.fileExists(atPath: path + "/Package.swift") { return ("tests", "swift test") }
        if fm.fileExists(atPath: path + "/Cargo.toml") { return ("tests", "cargo test") }
        if fm.fileExists(atPath: path + "/pyproject.toml") || fm.fileExists(atPath: path + "/pytest.ini") { return ("tests", "pytest") }
        if fm.fileExists(atPath: path + "/go.mod") { return ("tests", "go test ./...") }
        return nil
    }

    @MainActor
    static func run(_ command: String, in path: String, project: String, tasks: TaskStore) {
        shell(command, cwd: path, project: project, tasks: tasks)
    }
}

/// Runs a command in a login shell (your PATH, nvm etc.), reported as a task with a done/failed chime.
/// Output goes to a log file you can open from the result.
@MainActor
func shell(_ command: String, cwd: String, project: String, tasks: TaskStore) {
    let id = UUID().uuidString
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("islet-\(id.prefix(8)).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    tasks.apply(["id": id, "state": "start", "command": command, "project": project])
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
    p.terminationHandler = { proc in
        let code = proc.terminationStatus
        Task { @MainActor in tasks.apply(["id": id, "state": "finish", "code": "\(code)", "command": command]) }
    }
    do { try p.run() } catch { tasks.apply(["id": id, "state": "finish", "code": "127", "command": command]) }
}

/// A user-defined button for one app, set up in the control panel.
struct CustomAction: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var title: String
    var command: String

    @MainActor
    static func run(_ a: CustomAction, tasks: TaskStore) {
        shell(a.command, cwd: FileManager.default.homeDirectoryForCurrentUser.path, project: a.appName, tasks: tasks)
    }
}
