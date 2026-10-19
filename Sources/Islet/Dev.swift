import AppKit
import SwiftUI

/// Runs a tool off the main thread with a timeout; nil if it's missing, fails or hangs.
func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 5) async -> String? {
    await Task.detached {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }.value
}

/// First existing copy of a CLI in the usual install locations (GUI apps don't get your shell PATH).
func findTool(_ name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.docker/bin", "\(home)/.local/bin", "/usr/bin"]
        .map { "\($0)/\(name)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) }
}

// MARK: Ports

struct ListeningPort: Identifiable, Hashable {
    var id: String { "\(pid):\(port)" }
    let pid: Int32
    let port: Int
    let command: String
}

enum Ports {
    /// User processes listening on TCP. System daemons (AirPlay receiver on 5000/7000, etc.) are hidden.
    static func scan() async -> [ListeningPort] {
        guard let out = await runTool("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return [] }
        var result = Set<ListeningPort>()
        var pid: Int32 = 0
        var command = ""
        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "n":
                guard let port = value.split(separator: ":").last.flatMap({ Int($0) }), !isSystem(pid) else { continue }
                result.insert(ListeningPort(pid: pid, port: port, command: command))
            default: break
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    private static func isSystem(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return true }
        let path = String(cString: buf)
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }

    /// SIGTERM, then SIGKILL if it's still there after 2 s.
    static func kill(_ pid: Int32) {
        Darwin.kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) }
        }
    }
}

// MARK: Containers / GitHub

struct Container: Identifiable { let id: String; let name: String; let image: String; let status: String }

struct PullRequest: Identifiable {
    let id: String
    let title: String
    let repo: String
    let number: Int
    let url: URL?
    /// SUCCESS / FAILURE / PENDING / ERROR / EXPECTED, or nil when there are no checks.
    let checks: String?
    let review: String?
}

enum Docker {
    static let path = findTool("docker")

    static func containers() async -> [Container]? {
        guard let path, let out = await runTool(path, ["ps", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"]) else { return nil }
        return out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return f.count >= 4 ? Container(id: f[0], name: f[1], image: f[2], status: f[3]) : nil
        }
    }
}

enum GitHub {
    static let demo = [
        PullRequest(id: "1", title: "feat(api): stream agent events over SSE", repo: "acme/api-server", number: 142, url: nil, checks: "SUCCESS", review: "APPROVED"),
        PullRequest(id: "2", title: "fix(web): hydrate dashboard without layout shift", repo: "acme/web", number: 88, url: nil, checks: "PENDING", review: nil),
        PullRequest(id: "3", title: "chore: bump Swift toolchain to 6.2", repo: "acme/ios", number: 31, url: nil, checks: "FAILURE", review: "CHANGES_REQUESTED"),
    ]

    /// Re-checked each time so a fresh install is picked up without relaunching.
    static var path: String? { findTool("gh") }

    enum Status: Equatable { case missing, signedOut, ready(String) }

    /// Local check (reads gh's config, no network), so being offline never looks like "signed out".
    static func status() async -> Status {
        guard let path else { return .missing }
        let user = await runTool(path, ["config", "get", "-h", "github.com", "user"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return user.isEmpty ? .signedOut : .ready(user)
    }

    static var hasHomebrew: Bool { findTool("brew") != nil }

    /// Homebrew if present, otherwise GitHub's own installer page (its .pkg puts gh in /usr/local/bin).
    @MainActor static func install() {
        if let brew = findTool("brew") {
            runInTerminal("'\(brew)' install gh")
        } else if let u = URL(string: "https://cli.github.com") {
            NSWorkspace.shared.open(u)
        }
    }

    /// Browser sign-in (device code). gh stores the token in the Keychain; Islet never sees it.
    @MainActor static func signIn() {
        guard let path else { return }
        runInTerminal("'\(path)' auth login --hostname github.com --git-protocol https --web")
    }

    /// Opening a .command file runs it in Terminal without needing Automation permission.
    @MainActor private static func runInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("islet-github.command")
        let script = "#!/bin/zsh\nclear\n\(command) && echo '\\n✓ Done. You can close this window and go back to Islet.'\n"
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    /// Your open PRs with the latest commit's CI rollup and review decision (one GraphQL call).
    static func myPullRequests() async -> [PullRequest]? {
        let query = """
        query { viewer { pullRequests(states: OPEN, first: 8, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes {
          id title number url reviewDecision repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }
        """
        guard let path, let out = await runTool(path, ["api", "graphql", "-f", "query=\(query)"], timeout: 10),
              let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let nodes = ((((j["data"] as? [String: Any])?["viewer"] as? [String: Any])?["pullRequests"] as? [String: Any])?["nodes"]) as? [[String: Any]]
        else { return nil }
        return nodes.map { n in
            let commit = (((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"]) as? [String: Any]
            return PullRequest(id: n["id"] as? String ?? UUID().uuidString, title: n["title"] as? String ?? "",
                               repo: (n["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
                               number: n["number"] as? Int ?? 0, url: (n["url"] as? String).flatMap(URL.init(string:)),
                               checks: (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String,
                               review: n["reviewDecision"] as? String)
        }
    }
}

// MARK: Dev tab

/// Only exists while the Dev tab is open, so nothing here runs in the background.
struct DevView: View {
    private let ports = State<[ListeningPort]>(initialValue: [])
    private let containers = State<[Container]?>(initialValue: nil)
    private let prs = State<[PullRequest]?>(initialValue: nil)
    private let gh = State<GitHub.Status?>(initialValue: nil)
    private let confirmKill = State<String?>(initialValue: nil)  // see Scrubber: no @State without Xcode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            section("Ports", symbol: "network") {
                if ports.wrappedValue.isEmpty {
                    hint("No local servers listening")
                } else {
                    ForEach(ports.wrappedValue) { p in portRow(p) }
                }
            }
            section("PRs & CI", symbol: "arrow.triangle.pull") {
                prRows
                dockerRows  // ponytail: unadvertised; rows appear only when containers are running
            }
        }
        .task { await loop(every: 3) { ports.wrappedValue = await Ports.scan() } }
        .task { await loop(every: 5) { containers.wrappedValue = await Docker.containers() } }
        .task {
            // Poll quickly while setting up so the list appears as soon as sign-in finishes.
            while !Task.isCancelled {
                let s = await GitHub.status()
                gh.wrappedValue = s
                if case .ready = s { prs.wrappedValue = await GitHub.myPullRequests() }
                if ProcessInfo.processInfo.environment["ISLET_DEMO"] != nil { gh.wrappedValue = .ready("demo"); prs.wrappedValue = GitHub.demo }  // dev: screenshots
                try? await Task.sleep(for: .seconds(gh.wrappedValue == .missing || gh.wrappedValue == .signedOut ? 3 : 60))
            }
        }
    }

    private func loop(every seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        while !Task.isCancelled {
            await work()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    private func portRow(_ p: ListeningPort) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: ":\(p.port)").font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(width: 52, alignment: .leading)
            Text(p.command).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            Spacer(minLength: 4)
            IconButton(symbol: "safari", help: "Open http://localhost:\(p.port)") {
                if let u = URL(string: "http://localhost:\(p.port)") { NSWorkspace.shared.open(u) }
            }
            if confirmKill.wrappedValue == p.id {
                Button("Kill") { Ports.kill(p.pid); confirmKill.wrappedValue = nil }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
            } else {
                IconButton(symbol: "xmark.circle", help: "Stop \(p.command) (pid \(p.pid))") { confirmKill.wrappedValue = p.id }
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder private var prRows: some View {
        switch gh.wrappedValue {
        case nil: EmptyView()
        case .missing: setup("See your pull requests and CI status here.", button: "Set up GitHub") { GitHub.install() }
        case .signedOut: setup("One step left: sign in to GitHub in your browser.", button: "Sign in to GitHub") { GitHub.signIn() }
        case .ready: prList
        }
    }

    private func setup(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            hint(text)
            Button(button, action: action)
                .buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.15)))
        }
    }

    @ViewBuilder private var prList: some View {
        if let prs = prs.wrappedValue {
            if prs.isEmpty { hint("No open pull requests") }
            ForEach(prs) { pr in
                Button { if let u = pr.url { NSWorkspace.shared.open(u) } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Self.checkSymbol(pr.checks)).foregroundStyle(Self.checkColor(pr.checks))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(pr.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text("\(pr.repo) #\(pr.number)\(pr.review == "CHANGES_REQUESTED" ? " · changes requested" : pr.review == "APPROVED" ? " · approved" : "")")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            hint("Couldn't load pull requests")
        }
    }

    @ViewBuilder private var dockerRows: some View {
        if let cs = containers.wrappedValue {
            ForEach(cs) { c in
                HStack(spacing: 6) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.cyan)
                    Text(c.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(c.status).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                .frame(height: 20)
            }
        }
    }

    private func section<C: View>(_ title: String, symbol: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading, spacing: 2) { content() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
    }

    static func checkSymbol(_ s: String?) -> String {
        switch s { case "SUCCESS": "checkmark.circle.fill"; case "FAILURE", "ERROR": "xmark.circle.fill"; case "PENDING", "EXPECTED": "clock.fill"; default: "circle" }
    }

    static func checkColor(_ s: String?) -> Color {
        switch s { case "SUCCESS": .green; case "FAILURE", "ERROR": .red; case "PENDING", "EXPECTED": .yellow; default: .white.opacity(0.4) }
    }
}
