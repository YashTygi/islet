import AppKit
import SwiftUI

/// Browser actions for the App tab. Tabs are read and changed via AppleScript (one Automation
/// prompt per browser); the window screenshot uses `screencapture` (Screen Recording prompt once).
@MainActor
enum Browser {
    static let all: [(id: String, name: String, path: String)] = [
        ("com.google.Chrome", "Chrome", "/Applications/Google Chrome.app"),
        ("com.brave.Browser", "Brave", "/Applications/Brave Browser.app"),
        ("com.apple.Safari", "Safari", "/Applications/Safari.app"),
    ].filter { FileManager.default.fileExists(atPath: $0.2) }

    /// Feature switches: built and working, turned off for now. Flip to true to bring a row back.
    static let shelfActions = false   // Screenshot → shelf, Link file → shelf
    static let tabActions = false     // All tabs → Markdown, Close duplicates

    static func isSafari(_ app: NSRunningApplication?) -> Bool { app?.bundleIdentifier == "com.apple.Safari" }

    @discardableResult
    static func script(_ src: String) async -> String? { await appleScript(src) }

    // MARK: Tabs

    /// Every tab of every window as a Markdown list.
    static func allTabsMarkdown(_ app: NSRunningApplication?) async -> (text: String, count: Int)? {
        guard let name = app?.localizedName else { return nil }
        let (tabsOf, title) = isSafari(app) ? ("tabs", "name") : ("tabs", "title")
        let src = """
        set out to ""
        tell application "\(name)"
          repeat with w in windows
            repeat with t in \(tabsOf) of w
              set out to out & "- [" & (\(title) of t) & "](" & (URL of t) & ")" & linefeed
            end repeat
          end repeat
        end tell
        return out
        """
        guard let text = await script(src), !text.isEmpty else { return nil }
        return (text, text.split(separator: "\n").count)
    }

    /// Closes tabs whose URL is already open earlier in the same window. Returns how many closed.
    static func closeDuplicates(_ app: NSRunningApplication?) async -> Int {
        guard let name = app?.localizedName else { return 0 }
        let src = """
        set closed to 0
        tell application "\(name)"
          repeat with w in windows
            set seen to {}
            set n to count of tabs of w
            set i to 1
            repeat while i ≤ n
              set u to URL of tab i of w
              if seen contains u then
                close tab i of w
                set closed to closed + 1
                set n to n - 1
              else
                set end of seen to u
                set i to i + 1
              end if
            end repeat
          end repeat
        end tell
        return closed
        """
        return Int(await script(src) ?? "") ?? 0
    }

    static func openPrivate(_ url: String, in app: NSRunningApplication?) async {
        guard let name = app?.localizedName, !isSafari(app) else { return }
        await script("""
        tell application "\(name)"
          set w to make new window with properties {mode:"incognito"}
          set URL of active tab of w to "\(url.replacingOccurrences(of: "\"", with: "%22"))"
          activate
        end tell
        """)
    }

    static func open(_ url: String, inBrowserAt path: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open([u], withApplicationAt: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Device sizes

    static let sizes: [(name: String, symbol: String, w: Int, h: Int)] = [
        ("iPhone", "iphone", 393, 852), ("iPad", "ipad", 820, 1180),
        ("Laptop", "laptopcomputer", 1280, 800), ("Desktop", "display", 1440, 900),
    ]

    /// Resizes the front browser window (keeps its top-left; height capped to the screen).
    static func resize(_ app: NSRunningApplication?, width: Int, height: Int) async {
        guard let name = app?.localizedName else { return }
        let maxH = Int(NSScreen.main?.visibleFrame.height ?? 900)
        await script("""
        tell application "\(name)"
          set b to bounds of front window
          set x to item 1 of b
          set y to item 2 of b
          set bounds of front window to {x, y, x + \(width), y + \(min(height, maxH))}
        end tell
        """)
    }

    // MARK: Shelf

    private static func folder(_ name: String) -> URL {
        let dir = appSupportFile(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func safe(_ s: String) -> String {
        String(s.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// A .webloc you can drag into any app or prompt.
    static func linkFile(title: String, url: String) -> URL? {
        let file = folder("Links").appendingPathComponent("\(safe(title.isEmpty ? url : title)).webloc")
        let plist = try? PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0)
        return (try? plist?.write(to: file)) != nil ? file : nil
    }

    /// PNG of the front browser window only (no other windows, no shadow).
    static func screenshot(_ app: NSRunningApplication?, title: String) async -> URL? {
        guard let pid = app?.processIdentifier else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let id = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        })?[kCGWindowNumber as String] as? Int else { return nil }
        let dir = folder("Captures")
        prune(dir, keep: 30)
        let file = dir.appendingPathComponent("\(safe(title)) \(Date.now.formatted(.dateTime.hour().minute().second())).png")
        _ = await runTool("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(id)", file.path], timeout: 10)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// Keeps the newest `keep` files so captures never pile up on disk.
    private static func prune(_ dir: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let old = files.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.dropFirst(keep)
        old.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    // MARK: Phone / network

    /// The Mac's Wi-Fi / Ethernet IPv4 address (what your phone can reach).
    static func lanIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var best: String?
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            best = best ?? ip
        }
        return best
    }

    /// localhost / 127.0.0.1 / 0.0.0.0 URL rewritten to the LAN address.
    static func networkURL(_ url: String) -> String? {
        guard var c = URLComponents(string: url), let host = c.host,
              ["localhost", "127.0.0.1", "0.0.0.0"].contains(host), let ip = lanIP() else { return nil }
        c.host = ip
        return c.string
    }


    // MARK: GitHub

    enum GitHubPage { case repo(owner: String, repo: String), pull(owner: String, repo: String, number: Int), issue(owner: String, repo: String, number: Int) }

    static func github(_ url: String) -> GitHubPage? {
        guard let u = URL(string: url), u.host == "github.com" else { return nil }
        let p = u.pathComponents.filter { $0 != "/" }
        guard p.count >= 2 else { return nil }
        if p.count >= 4, let n = Int(p[3]) {
            if p[2] == "pull" { return .pull(owner: p[0], repo: p[1], number: n) }
            if p[2] == "issues" { return .issue(owner: p[0], repo: p[1], number: n) }
        }
        return .repo(owner: p[0], repo: p[1])
    }

    /// "Fix login bug by octocat · Pull Request #12 · owner/repo" → "Fix login bug".
    static func githubTitle(_ tabTitle: String) -> String {
        var t = tabTitle.components(separatedBy: " · ").first ?? tabTitle
        if let r = t.range(of: " by ", options: .backwards) { t = String(t[..<r.lowerBound]) }
        return t
    }
}
