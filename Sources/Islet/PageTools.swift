import AppKit
import SwiftUI

/// Page-aware helpers for the browser panel: tickets (GitHub / Linear / Jira), docs pages, PRs.
struct Ticket: Equatable {
    let key: String      // "123", "ABC-123"
    let title: String
    let url: String
    let source: String   // GitHub, Linear, Jira
    var repo: (owner: String, name: String)?

    static func == (a: Ticket, b: Ticket) -> Bool { a.url == b.url && a.title == b.title }

    /// `feat/ABC-123-short-title` (fix/ when the title reads like a bug).
    var branch: String {
        let words = title.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6)
        let kind = title.range(of: #"(?i)\b(fix|bug|crash|error|broken|fails?|regression)\b"#, options: .regularExpression) != nil ? "fix" : "feat"
        let slug = words.joined(separator: "-")
        return "\(kind)/\(key)" + (slug.isEmpty ? "" : "-" + String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")))
    }
}

@MainActor
enum PageTools {
    static func ticket(url: String, pageTitle: String) -> Ticket? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        let p = u.pathComponents.filter { $0 != "/" }
        if host == "github.com", p.count >= 4, p[2] == "issues", Int(p[3]) != nil {
            return Ticket(key: p[3], title: Browser.githubTitle(pageTitle), url: url, source: "GitHub", repo: (p[0], p[1]))
        }
        if host == "linear.app", let i = p.firstIndex(of: "issue"), i + 1 < p.count {
            let key = p[i + 1].uppercased()
            // Slug in the URL is the title; else the tab title "ABC-123 Title".
            let fromSlug = i + 2 < p.count ? p[i + 2].replacingOccurrences(of: "-", with: " ") : ""
            let t = fromSlug.isEmpty ? pageTitle.replacingOccurrences(of: key, with: "").trimmingCharacters(in: .whitespaces) : fromSlug
            return Ticket(key: key, title: t, url: url, source: "Linear")
        }
        if host.hasSuffix("atlassian.net") || host.contains("jira") {
            let key = (p.firstIndex(of: "browse").flatMap { $0 + 1 < p.count ? p[$0 + 1] : nil })
                ?? URLComponents(string: url)?.queryItems?.first { $0.name == "selectedIssue" }?.value
            guard let key, key.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil else { return nil }
            // "[ABC-123] Title - Jira"
            var t = pageTitle.replacingOccurrences(of: "[\(key)]", with: "")
            if let r = t.range(of: " - Jira", options: .backwards) { t = String(t[..<r.lowerBound]) }
            return Ticket(key: key, title: t.trimmingCharacters(in: .whitespaces), url: url, source: "Jira")
        }
        return nil
    }

    static let docsHosts = ["developer.mozilla.org", "developer.apple.com", "react.dev", "nextjs.org", "vuejs.org", "svelte.dev",
                            "nodejs.org", "docs.python.org", "pkg.go.dev", "go.dev", "doc.rust-lang.org", "docs.rs", "kotlinlang.org",
                            "learn.microsoft.com", "tailwindcss.com", "swift.org", "git-scm.com", "docs.github.com", "docs.anthropic.com",
                            "platform.openai.com", "developer.android.com", "angular.dev", "expressjs.com", "postgresql.org", "redis.io"]

    static func isDocs(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host else { return false }
        if docsHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return true }
        if host.hasPrefix("docs.") || host.hasSuffix(".readthedocs.io") || host.hasPrefix("developer.") { return true }
        let path = u.path.lowercased()
        return ["/docs", "/documentation", "/reference", "/api/", "/guide", "/manual"].contains { path.hasPrefix($0) || path.contains($0 + "/") }
    }

    /// A local clone of owner/repo in the usual project folders (reads `.git/config`, two levels deep).
    static func localClone(owner: String, name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let needle = "\(owner)/\(name)".lowercased()
        for base in ["Developer", "Projects", "Code", "code", "src", "dev", "Documents/GitHub", "GitHub"].map({ "\(home)/\($0)" }) {
            guard let level1 = try? fm.contentsOfDirectory(atPath: base) else { continue }
            var dirs = level1.map { "\(base)/\($0)" }
            for d in level1 where !d.hasPrefix(".") { dirs += ((try? fm.contentsOfDirectory(atPath: "\(base)/\(d)")) ?? []).map { "\(base)/\(d)/\($0)" } }
            for d in dirs {
                guard let config = try? String(contentsOfFile: d + "/.git/config", encoding: .utf8).lowercased() else { continue }
                if config.contains("github.com/\(needle)") || config.contains("github.com:\(needle)") { return d }
            }
        }
        return nil
    }

    /// The front tab's readable text (article/main first), capped. Needs "Allow JavaScript from Apple Events".
    static func pageText(browser: String) async -> String? {
        let js = "(()=>{const e=document.querySelector('article, main, [role=main]')||document.body;return (e.innerText||'').slice(0,40000);})()"
        return await ChatExporter.runJS(browser, js).flatMap { $0.isEmpty || $0 == "missing value" ? nil : $0 }
    }

    static func saveTemp(_ text: String, name: String) -> String? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("islet-\(UUID().uuidString.prefix(6))-\(name)")
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url.path : nil
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Interactive Claude Code in a visible terminal in `cwd` (it reports to the Agents tab through its hooks).
    static func startAgent(_ prompt: String, cwd: String, project: String, tasks: TaskStore) {
        shell("claude " + shq(prompt), cwd: cwd, project: project, tasks: tasks)
    }

    static func selfTest() {
        let g = ticket(url: "https://github.com/acme/api/issues/42", pageTitle: "Login fails on Safari · Issue #42 · acme/api")
        precondition(g?.key == "42" && g?.branch == "fix/42-login-fails-on-safari" && g?.repo?.owner == "acme")
        let l = ticket(url: "https://linear.app/acme/issue/ENG-123/add-dark-mode-toggle", pageTitle: "ENG-123 Add dark mode toggle")
        precondition(l?.key == "ENG-123" && l?.branch == "feat/ENG-123-add-dark-mode-toggle")
        let j = ticket(url: "https://acme.atlassian.net/browse/PAY-7", pageTitle: "[PAY-7] Refund webhook times out - Jira")
        precondition(j?.title == "Refund webhook times out" && j?.branch == "feat/PAY-7-refund-webhook-times-out")
        precondition(ticket(url: "https://github.com/acme/api/pull/3", pageTitle: "") == nil)
        precondition(isDocs("https://developer.mozilla.org/en-US/docs/Web/API/fetch") && isDocs("https://docs.stripe.com/payments")
                     && isDocs("https://example.com/docs/intro") && !isDocs("https://news.ycombinator.com/"))
        print("PageTools self-test passed")
    }
}

// MARK: PR status

struct PRStatus {
    struct Check { let name, state, url: String }
    var title = "", state = "", draft = false, review = "", mergeable = "", head = "", base = "", author = ""
    var additions = 0, deletions = 0, files = 0
    var checks: [Check] = []

    enum Load { case loading, noGH, noAccess, ok(PRStatus) }

    static func load(owner: String, name: String, number: Int) async -> Load {
        guard let gh = GitHub.path, case .ready = await GitHub.status() else { return .noGH }
        guard let out = await runTool(gh, ["pr", "view", "\(number)", "-R", "\(owner)/\(name)", "--json",
                                           "title,state,isDraft,reviewDecision,mergeable,headRefName,baseRefName,additions,deletions,changedFiles,statusCheckRollup,author"], timeout: 10),
              let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return .noAccess }
        var s = PRStatus()
        s.title = j["title"] as? String ?? ""
        s.state = j["state"] as? String ?? ""
        s.draft = j["isDraft"] as? Bool ?? false
        s.review = j["reviewDecision"] as? String ?? ""
        s.mergeable = j["mergeable"] as? String ?? ""
        s.head = j["headRefName"] as? String ?? ""
        s.base = j["baseRefName"] as? String ?? ""
        s.author = (j["author"] as? [String: Any])?["login"] as? String ?? ""
        s.additions = j["additions"] as? Int ?? 0
        s.deletions = j["deletions"] as? Int ?? 0
        s.files = j["changedFiles"] as? Int ?? 0
        s.checks = (j["statusCheckRollup"] as? [[String: Any]] ?? []).map { c in
            // CheckRun: name/conclusion/status/detailsUrl; StatusContext: context/state/targetUrl.
            let state = (c["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? c["state"] as? String ?? c["status"] as? String ?? ""
            return Check(name: c["name"] as? String ?? c["context"] as? String ?? "check", state: state.uppercased(),
                         url: c["detailsUrl"] as? String ?? c["targetUrl"] as? String ?? "")
        }
        // Failing first, then running, then passed.
        let order = ["FAILURE": 0, "ERROR": 0, "TIMED_OUT": 0, "CANCELLED": 1, "ACTION_REQUIRED": 1, "IN_PROGRESS": 2, "QUEUED": 2, "PENDING": 2, "EXPECTED": 2]
        s.checks.sort { (order[$0.state] ?? 3) < (order[$1.state] ?? 3) }
        return .ok(s)
    }
}

struct PRCard: View {
    let owner: String, name: String, number: Int
    let model: NotchModel
    let done: (String) -> Void
    private let status = State<PRStatus.Load>(initialValue: .loading)  // see Scrubber: no @State without Xcode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch status.wrappedValue {
            case .loading: HStack(spacing: 6) { ProgressView().controlSize(.small); hint("Reading #\(number)…") }
            case .noGH: hint("Set up GitHub in the Dev tab to see checks and reviews here.")
            case .noAccess: hint("Can't read \(owner)/\(name)#\(number) with your GitHub account.")
            case .ok(let s): content(s)
            }
        }
        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        .task(id: number) { status.wrappedValue = await PRStatus.load(owner: owner, name: name, number: number) }
    }

    @ViewBuilder private func content(_ s: PRStatus) -> some View {
        let clone = PageTools.localClone(owner: owner, name: name)
        HStack(spacing: 6) {
            Text(s.draft ? "Draft" : s.state.capitalized).font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 6).frame(height: 16)
                .background(Capsule().fill((s.state == "MERGED" ? Color.purple : s.state == "CLOSED" ? .red : s.draft ? .gray : .green).opacity(0.35)))
            Text(review(s.review)).font(.system(size: 10, weight: .medium)).foregroundStyle(s.review == "CHANGES_REQUESTED" ? .orange : .white.opacity(0.75))
            if s.mergeable == "CONFLICTING" { Text("Conflicts").font(.system(size: 10, weight: .medium)).foregroundStyle(.red) }
            Spacer(minLength: 4)
            Text(verbatim: "+\(s.additions) −\(s.deletions) · \(s.files) files").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
        }
        Text(verbatim: "\(s.head) → \(s.base) · \(s.author)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        HStack(spacing: 5) {
            small("Checkout + test", "play.fill") {
                let test = clone.flatMap { TestRunner.command(in: $0)?.command }
                let cmd = "gh pr checkout \(number)" + (test.map { " && \($0)" } ?? "")
                if let clone { shell(cmd, cwd: clone, project: name, tasks: model.services.tasks) }
                else {
                    let dest = FileManager.default.homeDirectoryForCurrentUser.path + "/Developer"
                    shell("gh repo clone \(owner)/\(name) && cd \(PageTools.shq(name)) && \(cmd)", cwd: dest, project: name, tasks: model.services.tasks)
                }
                done(clone == nil ? "Cloning into ~/Developer" : "Running in a terminal")
            }
            small("Ask about this diff", "sparkles") {
                let prompt = "Review GitHub PR \(owner)/\(name)#\(number) (\"\(s.title)\"). Read it with `gh pr view \(number) -R \(owner)/\(name)` "
                    + "and `gh pr diff \(number) -R \(owner)/\(name)`. Summarize what it changes, then list risks and anything that looks wrong, "
                    + "with file:line. Don't change any files."
                PageTools.startAgent(prompt, cwd: clone ?? FileManager.default.homeDirectoryForCurrentUser.path, project: name, tasks: model.services.tasks)
                done("Claude Code opened")
            }
        }
        if !s.checks.isEmpty {
            let failed = s.checks.filter { ["FAILURE", "ERROR", "TIMED_OUT"].contains($0.state) }.count
            Text(verbatim: failed > 0 ? "Checks · \(failed) failing" : "Checks").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(failed > 0 ? .red : .white.opacity(0.45)).padding(.top, 2)
            ForEach(Array(s.checks.prefix(5).enumerated()), id: \.offset) { _, c in
                Button { if let u = URL(string: c.url) { NSWorkspace.shared.open(u) } } label: {
                    HStack(spacing: 6) {
                        let kind: String? = c.state == "SUCCESS" ? "SUCCESS" : ["FAILURE", "ERROR", "TIMED_OUT"].contains(c.state) ? "FAILURE"
                            : ["SKIPPED", "NEUTRAL", "CANCELLED"].contains(c.state) ? nil : "PENDING"
                        Image(systemName: DevView.checkSymbol(kind)).font(.system(size: 10)).foregroundStyle(DevView.checkColor(kind))
                        Text(c.name).font(.system(size: 10.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func review(_ r: String) -> String {
        switch r { case "APPROVED": "Approved"; case "CHANGES_REQUESTED": "Changes requested"; case "REVIEW_REQUIRED": "Review required"; default: "No review yet" }
    }

    private func small(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.1))).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func hint(_ t: String) -> some View { Text(t).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)) }
}
