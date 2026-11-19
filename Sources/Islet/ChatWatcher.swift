import AppKit
import ApplicationServices

/// Watches AI chats that have no hooks (Claude / ChatGPT / Gemini in Chrome or Brave, Claude desktop's chat)
/// and feeds their state into the Agents list: generating, needs you, done, error.
/// Reads only button labels and the chat title, never message text.
@MainActor @Observable
final class ChatWatcher {
    /// A browser that has chat tabs but "Allow JavaScript from Apple Events" turned off.
    private(set) var blockedBrowser: String?

    @ObservationIgnored private let agents: AgentStore
    @ObservationIgnored private var last: [String: String] = [:]   // id → running / waiting / idle / error
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var ticks = 0

    static let browsers: [(id: String, name: String)] = [("com.google.Chrome", "Google Chrome"), ("com.brave.Browser", "Brave Browser")]
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let idPrefix = "chat|"

    init(agents: AgentStore) { self.agents = agents }

    func start() {
        // ponytail: 3 s poll (one osascript per running browser), push via a browser extension is the upgrade path.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard !busy else { return }
        busy = true
        ticks += 1
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let scanDesktop = ticks % 2 == 0 && running.contains(Self.claudeDesktop)
        let claudeHookWaiting = agents.agents.contains { $0.state == .waiting && $0.hostApp.contains("Claude.app") && !$0.id.hasPrefix(Self.idPrefix) }
        Task {
            var seen: [String: (state: String, name: String, title: String, host: String)] = [:]
            var blocked: String?
            for b in Self.browsers where running.contains(b.id) {  // never launch a browser by asking it
                guard let out = await appleScript(Self.tabsScript(b.name)) else { continue }
                for line in out.split(separator: "\n") {
                    let f = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                    guard f.count == 5 else { continue }
                    if f[2] == "blocked" { blocked = b.name; continue }
                    let (name, title) = Self.site(host: f[3], title: f[4])
                    seen["\(Self.idPrefix)\(b.id)|\(f[0])|\(f[1])"] = (f[2], name, title, b.name)
                }
            }
            if scanDesktop, let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.claudeDesktop).first {
                var state = await Task.detached { Self.desktopState(pid: app.processIdentifier) }.value
                if state.hasPrefix("waiting"), claudeHookWaiting { state = "idle" }  // Code tab prompt: hooks already show it
                seen["\(Self.idPrefix)\(Self.claudeDesktop)"] = (state, "Claude", "Desktop chat", "Claude")
            }
            debugLog("chats: \(seen.map { "\($0.key)=\($0.value.state)" }) blocked=\(blocked ?? "-")")
            self.apply(seen, keepDesktop: !scanDesktop && running.contains(Self.claudeDesktop))
            self.blockedBrowser = blocked
            self.busy = false
        }
    }

    private func apply(_ seen: [String: (state: String, name: String, title: String, host: String)], keepDesktop: Bool) {
        for (id, c) in seen {
            let old = last[id] ?? "idle"
            let kind = String(c.state.prefix { $0 != ":" })
            last[id] = kind
            let post: String? = switch (old, kind) {
            case (_, "waiting") where old != "waiting": "waiting"
            case (_, "running") where old != "running": "running"
            case ("running", "idle"), ("waiting", "idle"): "done"
            case ("running", "error"): "error"  // alerts only count right after generating
            default: nil
            }
            guard let post else { continue }
            debugLog("chat post \(id) \(post) name=\(c.name) title=\(c.title)")
            let label = c.state.hasPrefix("waiting:") ? "Waiting for: " + c.state.dropFirst(8) : ""
            agents.apply(["id": id, "state": post, "name": c.name, "project": c.title, "message": label,
                          "hostApp": NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundle(of: id))?.path ?? ""])
        }
        for id in last.keys where seen[id] == nil && !(keepDesktop && id.hasSuffix(Self.claudeDesktop)) {  // tab closed
            last[id] = nil
            remove(id)
        }
    }

    private func remove(_ id: String) {
        if agents.agents.contains(where: { $0.id == id }) { agents.apply(["id": id, "state": "ended"]) }
    }

    // MARK: Browsers

    /// Button labels per site. Matched by accessible name / visible text, not CSS classes (those change every deploy).
    /// A site redesign means editing these lists.
    private static let siteJS = """
    (function(){var S={'claude.ai':{r:['Stop response'],w:['Allow once','Always allow','Allow always']},\
    'chatgpt.com':{r:['Stop streaming','Stop generating'],w:['Approve','Confirm']},\
    'gemini.google.com':{r:['Stop response','Stop generating'],w:['Start research']}};\
    var s=S[location.host];if(!s)return 'idle||';var st='idle';\
    var bs=document.querySelectorAll('button,[role=button]');\
    for(var i=0;i<bs.length;i++){var b=bs[i];if(!b.getClientRects().length)continue;\
    var l=(b.getAttribute('aria-label')||'').trim(),t=(b.innerText||'').trim();\
    if(s.w.indexOf(l)>=0||s.w.indexOf(t)>=0){st='waiting:'+(t||l);break;}\
    if(s.r.indexOf(l)>=0||b.getAttribute('data-testid')=='stop-button')st='running';}\
    if(st=='idle'){var a=document.querySelectorAll('[role=alert]');for(var j=0;j<a.length;j++){if((a[j].innerText||'').trim()){st='error';break;}}}\
    return st+'|'+location.host+'|'+document.title.split('|').join(' ').split(String.fromCharCode(10)).join(' ').slice(0,80);})()
    """

    /// One line per chat tab: windowID|tabID|state|host|title.
    static func tabsScript(_ app: String) -> String {
        """
        tell application "\(app)"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              set u to URL of t
              if u starts with "https://claude.ai/" or u starts with "https://chatgpt.com/" or u starts with "https://gemini.google.com/" then
                try
                  set s to execute t javascript "\(siteJS)"
                on error
                  set s to "blocked||"
                end try
                set out to out & (id of w) & "|" & (id of t) & "|" & s & linefeed
              end if
            end repeat
          end repeat
          return out
        end tell
        """
    }

    /// Site name from the host; chat title from the page title minus the site's suffix.
    static func site(host: String, title: String) -> (String, String) {
        let name = ["claude.ai": "Claude", "chatgpt.com": "ChatGPT", "gemini.google.com": "Gemini"][host] ?? "Chat"
        var t = title
        for suffix in [" - Claude", " | ChatGPT", " - ChatGPT", " - Gemini", " | Gemini"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return (name, t.isEmpty || t == name || t.contains("Gemini") ? "New chat" : t)
    }

    static func bundle(of id: String) -> String { id.split(separator: "|").dropFirst().first.map(String.init) ?? "" }

    /// Brings a chat back: the browser window + tab, or Claude desktop.
    static func focus(_ id: String) {
        let f = id.split(separator: "|").map(String.init)  // chat | bundle | window | tab
        guard f.count == 4, let name = browsers.first(where: { $0.id == f[1] })?.name else {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle(of: id)).first?.activate()
            return
        }
        Task {
            await appleScript("""
            tell application "\(name)"
              repeat with w in windows
                if (id of w as text) = "\(f[2])" then
                  set i to 0
                  repeat with t in tabs of w
                    set i to i + 1
                    if (id of t as text) = "\(f[3])" then set active tab index of w to i
                  end repeat
                  set index of w to 1
                end if
              end repeat
              activate
            end tell
            """)
        }
    }

    // MARK: Claude desktop (Electron, read via Accessibility)

    /// "Stop response" is the chat composer's button; the Code tab says "Stop" and reports through hooks instead.
    nonisolated static func desktopState(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)  // Electron: expose web content
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        var state = "idle", visited = 0
        // ponytail: full tree walk (~2–3k nodes, ~0.3 s, off the main thread, every 6 s); cache the composer subtree if it shows up in profiles.
        func walk(_ e: AXUIElement, _ depth: Int) {
            visited += 1
            guard visited < 8000, depth < 60, !state.hasPrefix("waiting") else { return }
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role)
            if role as? String == "AXButton" {
                var t: CFTypeRef?, d: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXTitleAttribute as CFString, &t)
                AXUIElementCopyAttributeValue(e, kAXDescriptionAttribute as CFString, &d)
                let label = (d as? String).flatMap { $0.isEmpty ? nil : $0 } ?? t as? String ?? ""
                if ["Allow once", "Always allow", "Allow always"].contains(label) { state = "waiting:" + label; return }
                if label == "Stop response" { state = "running" }
            }
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids)
            for k in kids as? [AXUIElement] ?? [] { walk(k, depth + 1) }
        }
        for w in windows as? [AXUIElement] ?? [] { walk(w, 0) }
        return state + "|"
    }

    static func selfTest() {
        precondition(site(host: "claude.ai", title: "Fix the bug - Claude") == ("Claude", "Fix the bug"))
        precondition(site(host: "chatgpt.com", title: "Trip ideas") == ("ChatGPT", "Trip ideas"))
        precondition(site(host: "chatgpt.com", title: "ChatGPT") == ("ChatGPT", "New chat"))
        precondition(site(host: "gemini.google.com", title: "Google Gemini") == ("Gemini", "New chat"))
        precondition(AIChatSite.match("https://claude.ai/chat/abc")?.name == "Claude")
        precondition(AIChatSite.match("https://gemini.google.com/app/1")?.name == "Gemini")
        precondition(AIChatSite.match("https://example.com/claude.ai") == nil)
        precondition(bundle(of: "chat|com.google.Chrome|1|2") == "com.google.Chrome")
        precondition(bundle(of: "chat|com.anthropic.claudefordesktop") == "com.anthropic.claudefordesktop")
        precondition(!siteJS.contains("\""), "JS goes inside an AppleScript string: no double quotes")
    }
}
