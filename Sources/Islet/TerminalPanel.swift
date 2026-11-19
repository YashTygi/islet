import AppKit
import SwiftUI

/// Recent shell commands from zsh/bash history: last 15 distinct, newest first. Read only while the
/// Terminal panel is visible (tail of the file); lines that look like secrets are never shown.
enum ShellHistory {
    private static let secret = try! NSRegularExpression(
        pattern: #"(?i)(password|passwd|secret|token|api[_-]?key|bearer|authorization|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_\-]{20,}|xox[abprs]-)"#)

    @MainActor private static var cache: (stamp: Date, size: Int, lines: [String])?

    /// Re-reads only when the history file changed (size or modification date).
    @MainActor static func recent(_ limit: Int = 15) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = [".zsh_history", ".bash_history"].map { home.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file else { return [] }
        let v = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = v?.contentModificationDate ?? .distantPast, fsize = v?.fileSize ?? 0
        if let c = cache, c.stamp == stamp, c.size == fsize { return c.lines }
        let lines = read(file, limit: limit)
        cache = (stamp, fsize, lines)
        return lines
    }

    private static func read(_ file: URL, limit: Int) -> [String] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65_536 ? size - 65_536 : 0)  // the tail is plenty
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var seen = Set<String>(), out: [String] = []
        for raw in text.split(separator: "\n").reversed() {
            // zsh extended history: ": 1712345678:0;command"
            var line = String(raw)
            if line.hasPrefix(": "), let semi = line.firstIndex(of: ";") { line = String(line[line.index(after: semi)...]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.count < 300, !line.hasSuffix("\\"), !seen.contains(line),
                  secret.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil else { continue }
            seen.insert(line)
            out.append(line)
            if out.count == limit { break }
        }
        return out
    }
}

/// Commands logged by the shell hook (`islet shell-init zsh`): text, folder, exit code, duration, terminal app.
/// One JSON object per line in Application Support/Islet/commands.jsonl, written by the `islet cmd` helper.
struct LoggedCommand: Hashable {
    let time: Date, command: String, cwd: String, code: Int, duration: Double, app: String
}

enum CommandLog {
    static var file: URL { appSupportFile("commands.jsonl") }
    static let keep = 5000

    /// Newest first, `limit` distinct commands. Reads the last 256 KB only.
    static func recent(_ limit: Int = 15, distinct: Bool = true) -> [LoggedCommand] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        return parse(String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self), limit: limit, distinct: distinct)
    }

    static func parse(_ text: String, limit: Int, distinct: Bool) -> [LoggedCommand] {
        let all = text.split(separator: "\n").compactMap { line -> LoggedCommand? in
            guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let cmd = j["cmd"] as? String, let t = (j["t"] as? NSNumber)?.doubleValue else { return nil }
            return LoggedCommand(time: Date(timeIntervalSince1970: t), command: cmd, cwd: j["cwd"] as? String ?? "",
                                 code: (j["code"] as? NSNumber)?.intValue ?? 0, duration: (j["dur"] as? NSNumber)?.doubleValue ?? 0,
                                 app: j["app"] as? String ?? "")
        }.sorted { $0.time > $1.time }  // background writes can land slightly out of order
        var seen = Set<String>(), out: [LoggedCommand] = []
        for c in all where !distinct || seen.insert(c.command).inserted {
            out.append(c)
            if out.count == limit { break }
        }
        return out
    }

    /// Keeps the newest `keep` lines (run at launch, off the main thread).
    static func trim() {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > keep + 500 else { return }
        try? (lines.suffix(keep).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    static func selfTest() {
        let text = #"{"t":2,"cmd":"b","cwd":"/x","code":1,"dur":0.5,"app":"Terminal"}"# + "\n"
            + #"{"t":1,"cmd":"a","cwd":"/y","code":0,"dur":0,"app":"iTerm"}"# + "\nnot json\n"
            + #"{"t":3,"cmd":"b","cwd":"/x","code":0,"dur":0,"app":"Terminal"}"#
        let r = parse(text, limit: 10, distinct: true)
        precondition(r.map(\.command) == ["b", "a"] && r[0].code == 0 && r[1].cwd == "/y")
        precondition(parse(text, limit: 10, distinct: false).count == 3)
        print("CommandLog self-test passed")
    }
}

/// A command still running after the terminal that started it closed (orphaned to launchd).
struct StrayProcess: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32, command: String, start: Date
}

enum StrayProcesses {
    /// Your processes whose parent is launchd and whose environment came from a shell (SHLVL set):
    /// launchd agents, apps and helpers never have SHLVL, so only shell-started leftovers match.
    static func scan() async -> [StrayProcess] {
        guard let out = await runTool("/bin/ps", ["-Eww", "-xo", "pid=,ppid=,etime=,args="]) else { return [] }
        return parse(out, now: .now).filter { !isAppOrShell($0.pid) }
    }

    static func parse(_ text: String, now: Date) -> [StrayProcess] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, f[1] == "1", let pid = Int32(f[0]), let age = seconds(String(f[2])),
                  f[3].contains(" SHLVL=") else { return nil }
            // ps -E appends the environment after the arguments; cut at the first NAME= after a space.
            // ponytail: an argument shaped like FOO=bar also cuts here; fine for display.
            let args = String(f[3])
            let cut = args.range(of: #" [A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression)?.lowerBound ?? args.endIndex
            return StrayProcess(pid: pid, command: String(args[..<cut]), start: now - age)
        }.sorted { $0.start > $1.start }
    }

    /// ps etime: [[dd-]hh:]mm:ss
    static func seconds(_ etime: String) -> TimeInterval? {
        let dayParts = etime.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) : 0
        let hms = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        guard let days, (2...3).contains(hms.count) else { return nil }
        return days * 86400 + hms.reduce(0) { $0 * 60 + $1 }
    }

    private static func isAppOrShell(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return true }
        let path = String(cString: buf)
        let name = (path as NSString).lastPathComponent
        return path.contains(".app/") || ["zsh", "bash", "sh", "fish", "login", "tmux"].contains(name)
    }

    static func selfTest() {
        precondition(seconds("01:07") == 67 && seconds("03:28:19") == 12499 && seconds("01-00:00:01") == 86401)
        let ps = "90819     1    02:00 .venv/bin/python pipeline.py ui SHELL=/bin/zsh SHLVL=2 PWD=/x\n"
            + "  821     1 01-22:19:41 /opt/homebrew/bin/redis-server 127.0.0.1:6379 HOME=/Users/a\n"
            + "  500   400    00:10 node server.js SHLVL=1\n"
        let r = parse(ps, now: Date(timeIntervalSince1970: 1000))
        precondition(r.count == 1 && r[0].pid == 90819 && r[0].command == ".venv/bin/python pipeline.py ui" && r[0].start.timeIntervalSince1970 == 880)
        print("StrayProcesses self-test passed")
    }
}

/// Terminal context: live `islet run` tasks (Stop), commands left running after their terminal closed (Stop), recent `islet run` results (copy / re-run), and your
/// recent shell commands (click to copy).
struct TerminalPanel: View {
    let model: NotchModel
    private let history = State<[String]>(initialValue: [])
    private let logged = State<[LoggedCommand]>(initialValue: [])
    private let copied = State<String?>(initialValue: nil)  // see Scrubber: no @State without Xcode
    private let strays = State<[StrayProcess]>(initialValue: [])
    private let confirmKill = State<Int32?>(initialValue: nil)

    var body: some View {
        let tasks = model.services.tasks
        HStack(alignment: .top, spacing: 14) {
            column("islet run", symbol: "terminal", trailing: tasks.finished.isEmpty ? nil : ("Clear", { tasks.clearFinished() })) {
                if tasks.running.isEmpty && tasks.finished.isEmpty && strays.wrappedValue.isEmpty {
                    hint("Start a command with `islet run …` to watch it here")
                }
                ForEach(tasks.running) { t in
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini).frame(width: 14)
                        Text(t.command).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(ActivityWings.clock(ctx.date.timeIntervalSince(t.start)))
                                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.green)
                        }
                        Button { tasks.stop(t) } label: {
                            Label("Stop", systemImage: "stop.fill").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(.red.opacity(0.25)))
                        }
                        .buttonStyle(.plain).foregroundStyle(.red).disabled(t.pid == 0)
                    }
                    .frame(height: 24)
                }
                ForEach(strays.wrappedValue) { p in
                    HStack(spacing: 7) {
                        Image(systemName: "moon.zzz.fill").font(.system(size: 10)).foregroundStyle(.orange).frame(width: 14)
                            .help("Still running after its terminal closed (pid \(p.pid))")
                        Text(p.command).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(ActivityWings.clock(ctx.date.timeIntervalSince(p.start)))
                                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.orange)
                        }
                        if confirmKill.wrappedValue == p.pid {
                            Button("Kill") {
                                Ports.kill(p.pid)
                                confirmKill.wrappedValue = nil
                                strays.wrappedValue.removeAll { $0.pid == p.pid }
                            }
                            .buttonStyle(.plain).font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                        } else {
                            IconButton(symbol: "xmark.circle", help: "Stop \(p.command) (pid \(p.pid))") { confirmKill.wrappedValue = p.pid }
                        }
                    }
                    .frame(height: 24)
                }
                ForEach(tasks.finished) { t in
                    HStack(spacing: 7) {
                        Image(systemName: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(t.ok ? .green : .red).frame(width: 14)
                        commandText(t.command)
                        Spacer(minLength: 4)
                        Text(ActivityWings.clock(t.duration)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        IconButton(symbol: "arrow.clockwise", help: "Run again in \(t.cwd.isEmpty ? "home" : shortPath(t.cwd))") { tasks.rerun(t) }
                    }
                    .frame(height: 22)
                }
            }
            column("Recent commands", symbol: "clock.arrow.circlepath", trailing: nil) {
                if !logged.wrappedValue.isEmpty {
                    // From the shell hook: exit code and folder too.
                    ForEach(logged.wrappedValue, id: \.self) { c in
                        HStack(spacing: 6) {
                            Image(systemName: c.code == 0 ? "checkmark" : "xmark").font(.system(size: 9, weight: .bold))
                                .foregroundStyle(c.code == 0 ? .green : .red).frame(width: 12)
                                .help(c.code == 0 ? "Succeeded" : "Exit code \(c.code)")
                            commandText(c.command)
                            Spacer(minLength: 4)
                            Text(shortPath(c.cwd)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                        }
                        .frame(height: 20)
                    }
                } else {
                    if history.wrappedValue.isEmpty { hint("No shell history found") }
                    ForEach(history.wrappedValue, id: \.self) { cmd in
                        HStack(spacing: 6) { commandText(cmd); Spacer(minLength: 0) }.frame(height: 20)
                    }
                }
            }
        }
        .task {
            // Refresh while visible (cheap: reads the last 64 KB of the history file).
            while !Task.isCancelled {
                logged.wrappedValue = CommandLog.recent()
                if logged.wrappedValue.isEmpty { history.wrappedValue = ShellHistory.recent() }
                strays.wrappedValue = await StrayProcesses.scan()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// Click to copy; shows "Copied" briefly.
    private func commandText(_ cmd: String) -> some View {
        Button {
            copyToClipboard(cmd)
            withAnimation { copied.wrappedValue = cmd }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { if copied.wrappedValue == cmd { copied.wrappedValue = nil } } }
        } label: {
            Text(copied.wrappedValue == cmd ? "Copied" : cmd)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(copied.wrappedValue == cmd ? .green : .white.opacity(0.85))
                .lineLimit(1).truncationMode(.tail)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func column<C: View>(_ title: String, symbol: String, trailing: (String, () -> Void)?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let (label, action) = trailing {
                    Button(label, action: action).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            // Lazy: only the ~6 rows on screen are built (each row costs SwiftUI bookkeeping memory).
            ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading, spacing: 1) { content() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
    }
}
