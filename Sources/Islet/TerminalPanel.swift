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

/// Terminal context: live `islet run` tasks (Stop), recent `islet run` results (copy / re-run), and your
/// recent shell commands (click to copy).
struct TerminalPanel: View {
    let model: NotchModel
    private let history = State<[String]>(initialValue: [])
    private let copied = State<String?>(initialValue: nil)  // see Scrubber: no @State without Xcode

    var body: some View {
        let tasks = model.services.tasks
        HStack(alignment: .top, spacing: 14) {
            column("islet run", symbol: "terminal", trailing: tasks.finished.isEmpty ? nil : ("Clear", { tasks.clearFinished() })) {
                if tasks.running.isEmpty && tasks.finished.isEmpty {
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
                if history.wrappedValue.isEmpty { hint("No shell history found") }
                ForEach(history.wrappedValue, id: \.self) { cmd in
                    HStack(spacing: 6) { commandText(cmd); Spacer(minLength: 0) }.frame(height: 20)
                }
            }
        }
        .task {
            // Refresh while visible (cheap: reads the last 64 KB of the history file).
            while !Task.isCancelled {
                history.wrappedValue = ShellHistory.recent()
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
