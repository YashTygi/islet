import AppKit
import SwiftUI

/// Live status of one GitHub repo, read with your `gh` sign-in: CI runs, recent branches, PRs, release.
struct RepoStatus {
    struct Run { let name, branch, state: String, updated: Date?, url: String }
    struct Branch { let name: String, updated: Date? }
    struct PR { let number: Int, title, url: String }
    var isPrivate = false, stars = 0, description = ""
    var defaultBranch = "", headline = "", headDate: Date?, headCI: String?
    var branches: [Branch] = [], runs: [Run] = [], prs: [PR] = [], openPRs = 0, openIssues = 0
    var release: (tag: String, date: Date?)?

    enum Load { case loading, noGH, noAccess, ok(RepoStatus) }

    private static func date(_ s: Any?) -> Date? { (s as? String).flatMap { ISO8601DateFormatter().date(from: $0) } }

    static func load(owner: String, name: String) async -> Load {
        guard let gh = GitHub.path, case .ready = await GitHub.status() else { return .noGH }
        let query = """
        query($o: String!, $r: String!) { repository(owner: $o, name: $r) {
          isPrivate stargazerCount description
          defaultBranchRef { name target { ... on Commit { messageHeadline committedDate statusCheckRollup { state } } } }
          refs(refPrefix: "refs/heads/", first: 4, orderBy: {field: TAG_COMMIT_DATE, direction: DESC}) {
            nodes { name target { ... on Commit { committedDate } } } }
          pullRequests(states: OPEN, first: 3, orderBy: {field: UPDATED_AT, direction: DESC}) { totalCount nodes { number title url } }
          issues(states: OPEN) { totalCount }
          latestRelease { tagName publishedAt } } }
        """
        async let gql = runTool(gh, ["api", "graphql", "-f", "query=\(query)", "-f", "o=\(owner)", "-f", "r=\(name)"], timeout: 10)
        async let rest = runTool(gh, ["api", "repos/\(owner)/\(name)/actions/runs?per_page=4"], timeout: 10)
        guard let out = await gql, let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let r = (j["data"] as? [String: Any])?["repository"] as? [String: Any] else { return .noAccess }
        var s = RepoStatus()
        s.isPrivate = r["isPrivate"] as? Bool ?? false
        s.stars = r["stargazerCount"] as? Int ?? 0
        s.description = r["description"] as? String ?? ""
        if let d = r["defaultBranchRef"] as? [String: Any] {
            s.defaultBranch = d["name"] as? String ?? ""
            let t = d["target"] as? [String: Any]
            s.headline = t?["messageHeadline"] as? String ?? ""
            s.headDate = date(t?["committedDate"])
            s.headCI = (t?["statusCheckRollup"] as? [String: Any])?["state"] as? String
        }
        s.branches = ((r["refs"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).map {
            Branch(name: $0["name"] as? String ?? "", updated: date(($0["target"] as? [String: Any])?["committedDate"]))
        }
        let prs = r["pullRequests"] as? [String: Any]
        s.openPRs = prs?["totalCount"] as? Int ?? 0
        s.prs = (prs?["nodes"] as? [[String: Any]] ?? []).map { PR(number: $0["number"] as? Int ?? 0, title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "") }
        s.openIssues = (r["issues"] as? [String: Any])?["totalCount"] as? Int ?? 0
        if let rel = r["latestRelease"] as? [String: Any], let tag = rel["tagName"] as? String { s.release = (tag, date(rel["publishedAt"])) }
        if let out = await rest, let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] {
            s.runs = (j["workflow_runs"] as? [[String: Any]] ?? []).map {
                let conclusion = $0["conclusion"] as? String
                return Run(name: $0["name"] as? String ?? "", branch: $0["head_branch"] as? String ?? "",
                           state: conclusion ?? ($0["status"] as? String ?? ""), updated: date($0["updated_at"]), url: $0["html_url"] as? String ?? "")
            }
        }
        return .ok(s)
    }
}

/// Repo card used by selected text (owner/repo, GitHub links) and the browser panel on GitHub pages.
struct GitHubRepoCard: View {
    let owner: String
    let name: String
    private let status = State<RepoStatus.Load>(initialValue: .loading)  // see Scrubber: no @State without Xcode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch status.wrappedValue {
            case .loading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); hint("Reading \(owner)/\(name) from GitHub…") }
            case .noGH:
                hint("Set up GitHub in the Dev tab to see CI runs, branches and PRs here.")
            case .noAccess:
                hint("Can't read \(owner)/\(name) with your GitHub account (private, renamed, or no access).")
            case .ok(let s):
                content(s)
            }
        }
        .padding(7).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        .task(id: "\(owner)/\(name)") { status.wrappedValue = await RepoStatus.load(owner: owner, name: name) }
    }

    @ViewBuilder private func content(_ s: RepoStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: s.isPrivate ? "lock.fill" : "globe").font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
            Text("\(owner)/\(name)").font(.system(size: 11, weight: .semibold))
            Text("★ \(s.stars)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            link("\(s.openPRs) PRs", "https://github.com/\(owner)/\(name)/pulls")
            link("\(s.openIssues) issues", "https://github.com/\(owner)/\(name)/issues")
            if let rel = s.release { link(rel.tag, "https://github.com/\(owner)/\(name)/releases/latest") }
        }
        if !s.defaultBranch.isEmpty {
            line(symbol: DevView.checkSymbol(s.headCI), color: DevView.checkColor(s.headCI),
                 text: "\(s.defaultBranch): \(s.headline)", date: s.headDate, url: "https://github.com/\(owner)/\(name)/commits/\(s.defaultBranch)")
        }
        if !s.runs.isEmpty {
            label("Latest runs")
            ForEach(Array(s.runs.enumerated()), id: \.offset) { _, r in
                line(symbol: Self.runSymbol(r.state), color: Self.runColor(r.state), text: "\(r.name) · \(r.branch)", date: r.updated, url: r.url)
            }
        }
        if !s.branches.isEmpty {
            label("Recent branches")
            ForEach(Array(s.branches.enumerated()), id: \.offset) { _, b in
                line(symbol: "arrow.triangle.branch", color: .white.opacity(0.5), text: b.name, date: b.updated,
                     url: "https://github.com/\(owner)/\(name)/tree/\(b.name)")
            }
        }
        if !s.prs.isEmpty {
            label("Open pull requests")
            ForEach(s.prs, id: \.number) { p in line(symbol: "arrow.triangle.pull", color: .green, text: "#\(p.number) \(p.title)", date: nil, url: p.url) }
        }
    }

    static func runSymbol(_ s: String) -> String {
        switch s { case "success": "checkmark.circle.fill"; case "failure", "timed_out", "startup_failure": "xmark.circle.fill"
        case "cancelled", "skipped": "minus.circle.fill"; default: "clock.fill" }
    }
    static func runColor(_ s: String) -> Color {
        switch s { case "success": .green; case "failure", "timed_out", "startup_failure": .red; case "cancelled", "skipped": .gray; default: .yellow }
    }

    private func line(symbol: String, color: Color, text: String, date: Date?, url: String) -> some View {
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 12)
                Text(text).font(.system(size: 10.5)).lineLimit(1)
                Spacer(minLength: 4)
                if let date { Text(date, style: .relative).font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.4)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func link(_ title: String, _ url: String) -> some View {
        Button(title) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
    }

    private func hint(_ t: String) -> some View { Text(t).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)) }
}
