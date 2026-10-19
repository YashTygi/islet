import AppKit
import SwiftUI

// MARK: Git engine

/// Runs git in `path` off the main thread; returns success and combined output.
func git(_ args: [String], in path: String, timeout: TimeInterval = 20, stdin: String? = nil) async -> (ok: Bool, out: String) {
    await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        guard (try? p.run()) != nil else { return (false, "git not found") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }.value
}

struct GitStatus: Equatable, Sendable {
    var branch = ""
    var ahead = 0
    var behind = 0
    var changed = 0
    /// main/master (origin/… preferred) and how far this branch is behind it.
    var base: String?
    var behindBase = 0
    var stashes = 0
    var lastSHA = ""
    var lastSubject = ""
    var lastPushed = false

    var onBase: Bool { base.map { $0 == branch || $0.hasSuffix("/" + branch) } ?? false }

    static func read(_ path: String) async -> GitStatus? {
        let (ok, out) = await git(["status", "--porcelain=v2", "--branch"], in: path)
        guard ok else { return nil }
        var s = GitStatus()
        for line in out.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { s.branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.ab ") {
                let f = line.split(separator: " ")
                s.ahead = Int(f.dropFirst(2).first?.dropFirst() ?? "") ?? 0
                s.behind = Int(f.dropFirst(3).first?.dropFirst() ?? "") ?? 0
            } else if !line.hasPrefix("#") { s.changed += 1 }
        }
        for ref in ["origin/main", "origin/master", "main", "master"] {
            if await git(["rev-parse", "--verify", "--quiet", ref], in: path).ok { s.base = ref; break }
        }
        if let base = s.base, !s.onBase {
            s.behindBase = Int(await git(["rev-list", "--count", "HEAD..\(base)"], in: path).out) ?? 0
        }
        s.stashes = await git(["stash", "list"], in: path).out.split(separator: "\n").count
        let last = await git(["log", "-1", "--format=%h\t%s"], in: path).out.split(separator: "\t", maxSplits: 1)
        if last.count == 2 { s.lastSHA = String(last[0]); s.lastSubject = String(last[1]) }
        s.lastPushed = !(await git(["branch", "-r", "--contains", "HEAD"], in: path).out.isEmpty)
        return s
    }
}

struct Stash: Identifiable {
    let id: String          // stash@{n}
    let message: String
    let age: String
    var files: [(status: String, path: String)]
}

enum GitOps {
    /// Background fetch at most every 2 min per repo, so "behind main" stays current.
    @MainActor private static var lastFetch: [String: Date] = [:]

    @MainActor static func fetchIfStale(_ path: String) async {
        guard Date.now.timeIntervalSince(lastFetch[path] ?? .distantPast) > 120 else { return }
        lastFetch[path] = .now
        _ = await git(["fetch", "--quiet", "origin"], in: path, timeout: 30)
    }

    static func stashes(_ path: String) async -> [Stash] {
        let list = await git(["stash", "list", "--format=%gd\t%s\t%cr"], in: path).out
        var result: [Stash] = []
        for line in list.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { continue }
            let files = await git(["stash", "show", "--include-untracked", "--name-status", f[0]], in: path).out
                .split(separator: "\n").compactMap { l -> (String, String)? in
                    let p = l.split(separator: "\t", maxSplits: 1).map(String.init)
                    return p.count == 2 ? (p[0], p[1]) : nil
                }
            result.append(Stash(id: f[0], message: f[1], age: f[2], files: files))
        }
        return result
    }

    /// The diff to describe: staged if anything is staged, else everything; new files listed by name.
    static func diffForMessage(_ path: String) async -> String {
        let staged = await git(["diff", "--cached", "--stat"], in: path).out
        let args = staged.isEmpty ? ["diff"] : ["diff", "--cached"]
        let stat = staged.isEmpty ? await git(["diff", "--stat"], in: path).out : staged
        let patch = await git(args + ["--no-color", "-U2"], in: path).out
        let untracked = await git(["ls-files", "--others", "--exclude-standard"], in: path).out
        var text = "Changed files:\n\(stat)\n"
        if !untracked.isEmpty { text += "\nNew files:\n\(untracked)\n" }
        text += "\nDiff:\n\(patch)"
        return String(text.prefix(12_000))  // keep the request tiny
    }

    /// Conventional commit message from Claude Code CLI: cheapest model, lowest effort, no tools,
    /// no hooks (user settings not loaded), no MCP, no saved session, run from an empty temp folder.
    static func generateMessage(diff: String) async -> String? {
        guard let claude = findTool("claude") else { return nil }
        return await Task.detached {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("islet-ai-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.currentDirectoryURL = dir
            p.arguments = ["-p", "--setting-sources", "local", "--strict-mcp-config", "--model", "haiku", "--effort", "low",
                           "--tools", "", "--no-session-persistence",
                           "Write a git commit message for the changes on stdin, in Conventional Commits style: "
                           + "`type(scope): summary` (imperative, max 72 chars), then optionally a blank line and up to 3 short "
                           + "`- ` bullet points for notable details. Output only the message, no quotes or code fences."]
            let input = Pipe(), out = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            input.fileHandleForWriting.write(Data(diff.utf8))
            try? input.fileHandleForWriting.close()
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && !msg.isEmpty ? msg : nil
        }.value
    }
}

// MARK: Git guide

/// Common situations → the exact command for this repo (current branch, main, last commit filled in).
struct GitRecipe: Identifiable, Sendable {
    let id: String
    let group: String
    let command: @Sendable (_ s: GitStatus) -> String
    var danger = false
}

enum GitGuide {
    static let recipes: [GitRecipe] = [
        GitRecipe(id: "Undo last commit, keep changes", group: "Undo") { _ in "git reset --soft HEAD~1" },
        GitRecipe(id: "Revert a pushed commit", group: "Undo") { s in "git revert \(s.lastSHA.isEmpty ? "<sha>" : s.lastSHA)" },
        GitRecipe(id: "Unstage a file", group: "Undo") { _ in "git restore --staged <file>" },
        GitRecipe(id: "Discard changes in a file", group: "Undo", command: { _ in "git restore <file>" }, danger: true),
        GitRecipe(id: "Discard ALL local changes", group: "Undo", command: { _ in "git restore . && git clean -fd" }, danger: true),
        GitRecipe(id: "Fix last commit message", group: "Undo") { _ in "git commit --amend -m \"<new message>\"" },
        GitRecipe(id: "Stash everything (incl. new files)", group: "Stash") { _ in "git stash push -u -m \"<what this is>\"" },
        GitRecipe(id: "List stashes", group: "Stash") { _ in "git stash list" },
        GitRecipe(id: "Apply a stash (keep it)", group: "Stash") { _ in "git stash apply stash@{0}" },
        GitRecipe(id: "Apply and drop a stash", group: "Stash") { _ in "git stash pop stash@{0}" },
        GitRecipe(id: "See a stash's files", group: "Stash") { _ in "git stash show --include-untracked --name-status stash@{0}" },
        GitRecipe(id: "Update branch from main (rebase)", group: "Sync") { s in "git fetch origin && git rebase --autostash \(s.base ?? "origin/main")" },
        GitRecipe(id: "Update branch from main (merge)", group: "Sync") { s in "git fetch origin && git merge \(s.base ?? "origin/main")" },
        GitRecipe(id: "Abort a rebase / merge", group: "Sync") { _ in "git rebase --abort   # or: git merge --abort" },
        GitRecipe(id: "Merge this branch into main", group: "Merge") { s in
            let main = (s.base ?? "main").replacingOccurrences(of: "origin/", with: "")
            return "git switch \(main) && git pull && git merge --no-ff \(s.branch) && git push"
        },
        GitRecipe(id: "Delete branch after merge", group: "Merge") { s in "git branch -d \(s.branch) && git push origin --delete \(s.branch)" },
        GitRecipe(id: "Rename this branch", group: "Branch") { s in "git branch -m \(s.branch) <new-name>" },
        GitRecipe(id: "Push a new branch", group: "Branch") { s in "git push -u origin \(s.branch)" },
        GitRecipe(id: "Copy one commit here", group: "Branch") { _ in "git cherry-pick <sha>" },
        GitRecipe(id: "What changed (summary)", group: "Look") { _ in "git diff --stat" },
        GitRecipe(id: "Last 10 commits", group: "Look") { _ in "git log --oneline -10" },
    ]
}

// MARK: VS Code panel

/// Compact git panel for the App tab: one status line, one row of actions; Commit, Stash and the
/// Git guide open in place (with a back button) so the main view never gets crowded.
struct CodePanel: View {
    let model: NotchModel
    let project: (name: String, path: String?)?
    let status: GitStatus?
    let ports: [ListeningPort]
    let refresh: () -> Void
    let done: (String) -> Void

    private enum Mode { case main, commit, stash, guide }
    private let mode = State(initialValue: Mode.main)
    /// +1 = going into a sub-view (slides in from the right), -1 = back to the main view.
    private let direction = State(initialValue: 1)
    private let message = State(initialValue: "")
    private let generating = State(initialValue: false)
    private let stageAll = State(initialValue: true)
    private let busy = State(initialValue: false)
    private let confirmUndo = State(initialValue: false)
    private let stashList = State<[Stash]>(initialValue: [])
    private let openStash = State<String?>(initialValue: nil)
    private let recipe = State<String?>(initialValue: GitGuide.recipes.first?.id)  // see Scrubber: no @State without Xcode

    var body: some View {
        Group {
            if let path = project?.path, let s = status {
                let d = direction.wrappedValue
                ZStack(alignment: .topLeading) {
                    Group {
                        switch mode.wrappedValue {
                        case .main: main(s, path: path)
                        case .commit: commitView(s, path: path)
                        case .stash: stashView(path: path)
                        case .guide: guideView(s)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(mode.wrappedValue)
                    .transition(.asymmetric(
                        insertion: .move(edge: d > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: d > 0 ? .leading : .trailing).combined(with: .opacity)))
                }
                .clipped()
            } else {
                Text(project?.path == nil ? "Open a folder in VS Code to see its git status" : "Not a git repository")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Main

    private func main(_ s: GitStatus, path: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.purple)
                Text(s.branch).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1)
                if s.ahead > 0 { Text(verbatim: "↑\(s.ahead)").foregroundStyle(.green) }
                if s.behind > 0 { Text(verbatim: "↓\(s.behind)").foregroundStyle(.orange) }
                Text(s.changed == 0 ? "clean" : "\(s.changed) changed").font(.system(size: 11))
                    .foregroundStyle(s.changed == 0 ? .green : .orange)
                if s.behindBase > 0, let base = s.base { behindMenu(s, base: base, path: path) }
                Spacer(minLength: 4)
                projectBadge
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            HStack(spacing: 6) {
                chip("Commit", "sparkles") { go(.commit); generate(path) }
                chip(s.stashes > 0 ? "Stash · \(s.stashes)" : "Stash", "tray.and.arrow.down") {
                    go(.stash)
                    Task { stashList.wrappedValue = await GitOps.stashes(path) }
                }
                if !s.lastSHA.isEmpty { undoChip(s, path: path) }
                chip("Guide", "book") { go(.guide) }
                chip("Terminal", "terminal") {
                    NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
                if let t = TestRunner.command(in: path) {
                    chip("Test", "play.fill") { TestRunner.run(t.command, in: path, project: project?.name ?? "", tasks: model.services.tasks) }
                }
            }
            if !s.lastSubject.isEmpty {
                Text(verbatim: "last: \(s.lastSHA) \(s.lastSubject)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35)).lineLimit(1)
            }
            ForEach(ports) { p in
                HStack(spacing: 6) {
                    Image(systemName: "network").foregroundStyle(.cyan)
                    Text(verbatim: ":\(p.port) \(p.command)").font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    IconButton(symbol: "safari", help: "Open") { if let u = URL(string: "http://localhost:\(p.port)") { NSWorkspace.shared.open(u) } }
                    IconButton(symbol: "xmark.circle", help: "Stop") { Ports.kill(p.pid) }
                }
            }
        }
        .task(id: path) { await GitOps.fetchIfStale(path) }
        // Preloaded so the stash view never pops in after the slide.
        .task(id: s.stashes) { stashList.wrappedValue = await GitOps.stashes(path) }
    }

    /// "main moved ↓N": update this branch by rebase or merge.
    private func behindMenu(_ s: GitStatus, base: String, path: String) -> some View {
        Menu {
            Button("Rebase onto \(base)") { run(["rebase", "--autostash", base], path: path, ok: "Rebased onto \(base)") }
            Button("Merge \(base) in") { run(["merge", "--no-edit", base], path: path, ok: "Merged \(base)") }
        } label: {
            Text(verbatim: "\(base.replacingOccurrences(of: "origin/", with: "")) ↓\(s.behindBase) · update")
                .font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).frame(height: 18)
                .background(Capsule().fill(.orange.opacity(0.22))).foregroundStyle(.orange)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("\(base) has \(s.behindBase) commit(s) this branch doesn't")
    }

    private func undoChip(_ s: GitStatus, path: String) -> some View {
        Group {
            if confirmUndo.wrappedValue {
                chip(s.lastPushed ? "Pushed! Undo anyway?" : "Undo \(s.lastSHA)?", "exclamationmark.triangle.fill", tint: .red) {
                    confirmUndo.wrappedValue = false
                    run(["reset", "--soft", "HEAD~1"], path: path, ok: "Commit undone, changes kept")
                }
            } else {
                chip("Undo commit", "arrow.uturn.backward") {
                    confirmUndo.wrappedValue = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmUndo.wrappedValue = false }
                }
            }
        }
    }

    /// Small "✦ 1 · ▶ 2" badge: this project's agents and tasks; click → Agents & Tasks tab.
    @ViewBuilder private var projectBadge: some View {
        let name = project?.name
        let agents = model.services.agents.agents.filter { $0.project == name }
        let running = model.services.tasks.running.filter { $0.project == name }.count
        if !agents.isEmpty || running > 0 {
            Button { model.select(.work) } label: {
                HStack(spacing: 6) {
                    if !agents.isEmpty {
                        Label("\(agents.count)", systemImage: agents.contains { $0.state == .waiting } ? "hand.raised.fill" : "sparkles")
                            .foregroundStyle(agents.contains { $0.state == .waiting } ? .orange : .purple)
                    }
                    if running > 0 { Label("\(running)", systemImage: "terminal").foregroundStyle(.green) }
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Agents & tasks in this project")
        }
    }

    // MARK: Commit

    private func commitView(_ s: GitStatus, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Commit to \(s.branch)", detail: "\(s.changed) changed") {
                IconButton(symbol: "doc.on.doc", help: "Copy message") {
                    guard !message.wrappedValue.isEmpty else { return }
                    copyToClipboard(message.wrappedValue); done("Copied")
                }
                .disabled(message.wrappedValue.isEmpty)
            }
            TextField(generating.wrappedValue ? "Writing a commit message…" : "Commit message", text: bind(message), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .lineLimit(3...4)
                .padding(7).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                .onExitCommand(perform: model.endEditing)
            HStack(spacing: 6) {
                Toggle("Stage all", isOn: bind(stageAll)).toggleStyle(.checkbox).font(.system(size: 11))
                Spacer()
                chip(busy.wrappedValue ? "Committing…" : "Commit", "checkmark", tint: .green) {
                    let msg = message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !msg.isEmpty, !busy.wrappedValue else { return }
                    busy.wrappedValue = true
                    Task {
                        if stageAll.wrappedValue { _ = await git(["add", "-A"], in: path) }
                        let r = await git(["commit", "-F", "-"], in: path, stdin: msg)
                        busy.wrappedValue = false
                        done(r.ok ? "Committed" : String(r.out.split(separator: "\n").last ?? "Commit failed"))
                        if r.ok { back(); refresh() }
                    }
                }
                .disabled(message.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Stash dashboard

    private func stashView(path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header("Stashes", detail: "\(stashList.wrappedValue.count)") {
                chip("Stash changes", "tray.and.arrow.down.fill") {
                    let name = "notch \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    runThen(["stash", "push", "-u", "-m", name], path: path, ok: "Stashed") {
                        stashList.wrappedValue = await GitOps.stashes(path)
                    }
                }
            }
            if stashList.wrappedValue.isEmpty {
                Text("No stashes").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(stashList.wrappedValue) { st in stashRow(st, path: path) }
                }
            }
        }
    }

    private func stashRow(_ st: Stash, path: String) -> some View {
        let open = openStash.wrappedValue == st.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                Text(verbatim: st.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                Text(st.message.replacingOccurrences(of: "On \(status?.branch ?? ""): ", with: "")).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text("· \(st.files.count) file\(st.files.count == 1 ? "" : "s") · \(st.age)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.down.doc", help: "Apply (keep stash)") {
                    run(["stash", "apply", st.id], path: path, ok: "Applied \(st.id)")
                }
                IconButton(symbol: "tray.and.arrow.up", help: "Pop (apply and remove)") {
                    runThen(["stash", "pop", st.id], path: path, ok: "Popped \(st.id)") { stashList.wrappedValue = await GitOps.stashes(path) }
                }
                IconButton(symbol: "trash", help: "Drop (delete this stash)") {
                    runThen(["stash", "drop", st.id], path: path, ok: "Dropped \(st.id)") { stashList.wrappedValue = await GitOps.stashes(path) }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { openStash.wrappedValue = open ? nil : st.id } }
            if open {
                ForEach(Array(st.files.enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 6) {
                        Text(f.status).font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(f.status.hasPrefix("A") ? .green : f.status.hasPrefix("D") ? .red : .orange).frame(width: 14)
                        Text(f.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(open ? 0.07 : 0.03)))
    }

    // MARK: Git guide

    private func guideView(_ s: GitStatus) -> some View {
        let selected = GitGuide.recipes.first { $0.id == recipe.wrappedValue } ?? GitGuide.recipes[0]
        let cmd = selected.command(s)
        return VStack(alignment: .leading, spacing: 6) {
            header("Git guide", detail: "commands for this repo")
            HStack(alignment: .top, spacing: 10) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(GitGuide.recipes) { r in
                            Button { recipe.wrappedValue = r.id } label: {
                                HStack(spacing: 5) {
                                    Text(r.group).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.35)).frame(width: 34, alignment: .leading)
                                    Text(r.id).font(.system(size: 11)).foregroundStyle(r.danger ? .red.opacity(0.9) : .white.opacity(r.id == selected.id ? 1 : 0.7))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 6).frame(height: 20).frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(r.id == selected.id ? 0.12 : 0)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 6) {
                    Text(cmd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
                    HStack(spacing: 6) {
                        chip("Copy", "doc.on.doc") { copyToClipboard(cmd); done("Copied") }
                        if selected.danger { Text("Destructive: can't be undone").font(.system(size: 10)).foregroundStyle(.red) }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func header<T: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> T = { EmptyView() }) -> some View {
        HStack(spacing: 8) {
            Button { back() } label: {
                Label("Back", systemImage: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(.white.opacity(0.12))).contentShape(Capsule())
            }
            .buttonStyle(.plain).help("Back to git overview")
            Text("Git ›").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            Spacer()
            trailing()
        }
    }

    /// Back to the overview. Keyboard focus is only handed back when leaving the commit text box and the
    /// nook isn't locked open (locked = you opened it with the keyboard and want to keep using it).
    private func back() {
        let leavingTextBox = mode.wrappedValue == .commit
        go(.main)
        if leavingTextBox && !model.isLocked { model.endEditing() }
    }

    /// Slide to a view. The outgoing page reads its exit edge from its last drawn frame, so a flipped
    /// direction is committed one frame (16 ms) before the switch.
    private func go(_ m: Mode) {
        let d = m == .main ? -1 : 1
        if d == direction.wrappedValue {
            withAnimation(NotchModel.tabSpring) { mode.wrappedValue = m }
        } else {
            direction.wrappedValue = d
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) {
                withAnimation(NotchModel.tabSpring) { mode.wrappedValue = m }
            }
        }
    }

    /// Writes the message as soon as the Commit view opens (no button to press).
    private func generate(_ path: String) {
        message.wrappedValue = ""
        guard !generating.wrappedValue else { return }
        generating.wrappedValue = true
        Task {
            let diff = await GitOps.diffForMessage(path)
            let msg = await GitOps.generateMessage(diff: diff)
            generating.wrappedValue = false
            if let msg, message.wrappedValue.isEmpty { message.wrappedValue = msg }  // never overwrite what you typed
            else if msg == nil { done(findTool("claude") == nil ? "Claude Code not found" : "Couldn't generate a message") }
        }
    }

    private func run(_ args: [String], path: String, ok: String) { runThen(args, path: path, ok: ok) {} }

    private func runThen(_ args: [String], path: String, ok: String, then: @escaping @MainActor () async -> Void) {
        Task {
            let r = await git(args, in: path, timeout: 60)
            done(r.ok ? ok : String(r.out.split(separator: "\n").last ?? "Failed"))
            await then()
            refresh()
        }
    }

    private func bind<T>(_ s: State<T>) -> Binding<T> { Binding(get: { s.wrappedValue }, set: { s.wrappedValue = $0 }) }

    private func chip(_ title: String, _ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(tint == .white ? .white.opacity(0.1) : tint.opacity(0.22)))
                .foregroundStyle(tint == .white ? .white : tint)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
