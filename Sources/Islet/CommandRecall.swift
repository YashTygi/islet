import AppKit
import ApplicationServices
import Foundation

/// "The command I ran for X": hold Control + Shift in a terminal and describe it. Islet searches what you've
/// run (shell hook log, zsh history, Claude Code's Bash calls, project scripts), reads what's on the terminal
/// screen for context, and asks Claude for the best 3, or a suggestion when nothing in history fits.
struct RecallCandidate: Hashable {
    let command: String
    let source: String   // "you", "history", "Claude Code", "script"
    let cwd: String
    let time: Date?
    let failed: Bool
}

struct RecallMatch: Hashable {
    let command: String
    let why: String
    let source: String   // where it came from, or "suggested"
}

@MainActor
enum CommandRecall {
    static let secret = try! NSRegularExpression(  // swiftlint:disable:this force_try
        pattern: #"(?i)(password|passwd|secret|token|api[_-]?key|bearer|authorization|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_\-]{20,}|xox[abprs]-|-----BEGIN)"#)

    static func isSecret(_ s: String) -> Bool { secret.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    // MARK: Terminal focus

    /// A terminal app in front, or VS Code / Cursor with its terminal focused (not the editor).
    static func terminalFocused() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
        if AppContext.terminalIDs.contains(id) { return app }
        guard AppContext.codeIDs.contains(id), AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let f, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        // xterm.js: the focused input is labelled "Terminal 1, zsh…" (on it or a parent).
        var el = f as! AXUIElement  // swiftlint:disable:this force_cast
        for _ in 0..<4 {
            for attr in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute] {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, (v as? String)?.lowercased().contains("terminal") == true { return app }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parent) == .success, let p = parent,
                  CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            el = p as! AXUIElement  // swiftlint:disable:this force_cast
        }
        return nil
    }

    /// The last ~3,000 characters on the terminal screen (Terminal and iTerm via AppleScript; others via
    /// Accessibility where they expose it). Secret-looking lines are dropped.
    static func screen(_ app: NSRunningApplication) async -> String? {
        var text: String?
        switch app.bundleIdentifier {
        case "com.apple.Terminal": text = await appleScript("tell application \"Terminal\" to get contents of selected tab of front window")
        case "com.googlecode.iterm2": text = await appleScript("tell application \"iTerm2\" to tell current session of current window to get contents")
        default:
            var f: CFTypeRef?, v: CFTypeRef?
            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success, let f,
               CFGetTypeID(f) == AXUIElementGetTypeID(),
               AXUIElementCopyAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, &v) == .success {  // swiftlint:disable:this force_cast
                text = v as? String
            }
        }
        guard let text, !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !isSecret($0) }
        return String(lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).suffix(3000))
    }

    // MARK: Candidates

    static func candidates(cwd: String?) async -> [RecallCandidate] {
        await Task.detached(priority: .userInitiated) { () -> [RecallCandidate] in
            var out: [RecallCandidate] = []
            // 1. Shell hook log: folder + exit code.
            if let text = try? String(contentsOf: appSupportFile("commands.jsonl"), encoding: .utf8) {
                for line in text.split(separator: "\n").suffix(5000) {
                    guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let c = j["cmd"] as? String else { continue }
                    out.append(RecallCandidate(command: c, source: "you", cwd: j["cwd"] as? String ?? "",
                                               time: (j["t"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                                               failed: ((j["code"] as? NSNumber)?.intValue ?? 0) != 0))
                }
            }
            // 2. zsh / bash history (extended format has a timestamp).
            let home = FileManager.default.homeDirectoryForCurrentUser
            for f in [".zsh_history", ".bash_history"] {
                guard let data = try? Data(contentsOf: home.appendingPathComponent(f)) else { continue }
                for raw in String(decoding: data, as: UTF8.self).split(separator: "\n").suffix(10_000) {
                    var line = String(raw), time: Date?
                    if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") {
                        time = Double(line.dropFirst(2).prefix { $0.isNumber }).map(Date.init(timeIntervalSince1970:))
                        line = String(line[line.index(after: semi)...])
                    }
                    out.append(RecallCandidate(command: line, source: "history", cwd: "", time: time, failed: false))
                }
            }
            // 3. Commands Claude Code ran for you (newest 60 sessions).
            out += claudeCommands(limitFiles: 60)
            // 4. This project's scripts.
            if let cwd { out += scripts(in: cwd) }
            // Clean: no secrets, no junk, newest copy of each command.
            var seen = Set<String>()
            return out.filter { !$0.command.isEmpty && $0.command.count < 400 && !$0.command.hasSuffix("\\") }
                .sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
                .filter { c in
                    let t = c.command.trimmingCharacters(in: .whitespaces)
                    return !t.isEmpty && seen.insert(t).inserted
                }
                .filter { !CommandRecall.isSecretNonisolated($0.command) }
        }.value
    }

    nonisolated static func isSecretNonisolated(_ s: String) -> Bool {
        s.range(of: #"(?i)(password|passwd|secret|token|api[_-]?key|bearer|authorization|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_\-]{20,}|xox[abprs]-|-----BEGIN)"#,
                options: .regularExpression) != nil
    }

    /// Bash tool calls from Claude Code session logs (~/.claude/projects/*/*.jsonl).
    nonisolated static func claudeCommands(limitFiles: Int) -> [RecallCandidate] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let dirs: [URL] = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var all: [URL] = []
        for d in dirs { all += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" } }
        let dated: [(URL, Date)] = all.map { ($0, modified($0)) }
        let files: [URL] = dated.sorted { $0.1 > $1.1 }.prefix(limitFiles).map(\.0)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [RecallCandidate] = []
        for f in files {
            guard let data = try? Data(contentsOf: f) else { continue }
            for line in data.split(separator: 0x0A) where line.count < 200_000 {
                guard line.firstRange(of: Data(#""name":"Bash""#.utf8)) != nil,
                      let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let content = (j["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
                for c in content where c["type"] as? String == "tool_use" && c["name"] as? String == "Bash" {
                    guard let cmd = (c["input"] as? [String: Any])?["command"] as? String else { continue }
                    out.append(RecallCandidate(command: cmd.trimmingCharacters(in: .whitespacesAndNewlines), source: "Claude Code",
                                               cwd: j["cwd"] as? String ?? "", time: (j["timestamp"] as? String).flatMap { iso.date(from: $0) }, failed: false))
                }
            }
        }
        return out
    }

    /// `npm run x`, `make x` for the project the terminal is in.
    nonisolated static func scripts(in cwd: String) -> [RecallCandidate] {
        var out: [RecallCandidate] = []
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<4 {  // walk up to the project root
            let pkg = dir.appendingPathComponent("package.json")
            if let d = try? Data(contentsOf: pkg), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let s = j["scripts"] as? [String: Any] {
                let pm = FileManager.default.fileExists(atPath: dir.path + "/pnpm-lock.yaml") ? "pnpm" : FileManager.default.fileExists(atPath: dir.path + "/bun.lockb") ? "bun run" : "npm run"
                out += s.keys.sorted().map { RecallCandidate(command: "\(pm) \($0)", source: "script", cwd: dir.path, time: nil, failed: false) }
            }
            if let mk = try? String(contentsOf: dir.appendingPathComponent("Makefile"), encoding: .utf8) {
                for m in mk.matches(of: /(?m)^([A-Za-z0-9][\w.-]*):(?!=)/) {
                    out.append(RecallCandidate(command: "make \(m.1)", source: "script", cwd: dir.path, time: nil, failed: false))
                }
            }
            if !out.isEmpty || FileManager.default.fileExists(atPath: dir.path + "/.git") { break }
            dir.deleteLastPathComponent()
        }
        return out
    }

    // MARK: Ranking

    static let stop: Set<String> = ["the", "a", "an", "i", "to", "for", "of", "and", "that", "this", "it", "in", "on", "my", "me", "used",
                                    "use", "ran", "run", "command", "earlier", "which", "what", "with", "was", "is", "did", "do", "like", "some", "something"]

    /// Cheap local pass: the 150 best keyword matches plus the 30 most recent, for Claude to judge.
    static func prefilter(_ query: String, _ cands: [RecallCandidate], cwd: String?) -> [RecallCandidate] {
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "_" }
            .map(String.init).filter { $0.count > 1 && !stop.contains($0) }
        func score(_ c: RecallCandidate) -> Double {
            let cmd = c.command.lowercased()
            var s = 0.0
            for w in words {
                if cmd.contains(w) { s += 2 }
                else if w.count > 4, cmd.contains(String(w.prefix(4))) { s += 0.8 }  // "services" ~ "service"
            }
            if let cwd, !c.cwd.isEmpty, c.cwd == cwd { s += 0.5 }
            if c.failed { s -= 0.5 }
            return s
        }
        let ranked = cands.map { ($0, score($0)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(150).map(\.0)
        var seen = Set(ranked)
        return ranked + cands.prefix(30).filter { seen.insert($0).inserted }
    }

    // MARK: Claude

    static func ask(query: String, screen: String?, cwd: String?, candidates: [RecallCandidate]) async -> [RecallMatch]? {
        let rel = RelativeDateTimeFormatter()
        let list = candidates.enumerated().map { i, c in
            var meta = [c.source]
            if !c.cwd.isEmpty { meta.append("in " + shortPath(c.cwd)) }
            if let t = c.time { meta.append(rel.localizedString(for: t, relativeTo: .now)) }
            if c.failed { meta.append("failed") }
            return "\(i + 1). \(c.command)    [\(meta.joined(separator: ", "))]"
        }.joined(separator: "\n")
        let input = """
        What the user asked for (spoken, may have transcription errors): \(query)
        Terminal folder: \(cwd.map(shortPath) ?? "unknown")

        Terminal screen (most recent at the bottom):
        \(screen ?? "(not available)")

        Commands they have run before (newest first):
        \(list.isEmpty ? "(none)" : list)
        """
        let prompt = """
        You help a developer find a shell command. Pick up to 3 commands from their history that best match what \
        they asked for, best first, using the terminal screen as context (errors shown, folder, tools in use). \
        Prefer commands that succeeded. If nothing in the history fits, suggest the right command instead and \
        mark it suggested; never invent history. Reply with JSON only, no code fences: \
        {"matches":[{"command":"...","why":"one short line","source":"history|suggested"}]}
        """
        guard let out = await ChatExporter.claude(prompt, input: input, model: "haiku") else { return nil }
        let json = out.firstRange(of: "{").map { String(out[$0.lowerBound...]) } ?? out
        guard let j = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let ms = j["matches"] as? [[String: Any]] else { return nil }
        return ms.prefix(3).compactMap { m in
            guard let c = m["command"] as? String, !c.isEmpty, !isSecret(c) else { return nil }
            return RecallMatch(command: c, why: m["why"] as? String ?? "", source: m["source"] as? String ?? "history")
        }
    }

    static func selfTest() {
        let now = Date()
        let cands = [
            RecallCandidate(command: "git log --oneline -- services/auth", source: "you", cwd: "/p", time: now, failed: false),
            RecallCandidate(command: "npm test", source: "you", cwd: "/p", time: now, failed: false),
            RecallCandidate(command: "docker compose logs -f api", source: "history", cwd: "", time: nil, failed: false),
        ]
        let r = prefilter("the git log command for services", cands, cwd: "/p")
        precondition(r.first?.command == "git log --oneline -- services/auth" && r.count == 3)
        precondition(isSecret("export API_KEY=abc") && !isSecret("git status"))
        print("CommandRecall self-test passed")
    }
}
