import Foundation
import SwiftUI

/// Claude Code usage in the current 5-hour window, read from ~/.claude/projects/**/*.jsonl.
/// Same blocking rule as ccusage: a window starts at the hour of its first message and lasts 5 h;
/// a new one starts after that or after a 5 h gap. Cost isn't logged locally, so only tokens are shown.
struct UsageWindow: Sendable, Equatable, Codable {
    let start: Date
    let end: Date
    let tokens: Int        // input + output + cache read + cache write
    let output: Int
    let messages: Int
    let lastActivity: Date
}

@MainActor @Observable
final class UsageService {
    private(set) var claude: UsageWindow?
    private(set) var available = FileManager.default.fileExists(atPath: UsageService.root.path)
    @ObservationIgnored private var lastRefresh = Date.distantPast
    /// ISLET_CLAUDE_DIR overrides the log folder (load testing only; inherited by the CLI).
    static let root = ProcessInfo.processInfo.environment["ISLET_CLAUDE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")

    /// Called by visible views; at most once per 30 s.
    func refresh() async {
        guard available, Date.now.timeIntervalSince(lastRefresh) > 30 else { return }
        lastRefresh = .now
        let started = Date.now
        // Scanned by the bundled `islet` CLI in its own process, so none of the log reading stays in our memory.
        let cli = Bundle.main.bundlePath + "/Contents/Helpers/islet"
        if let out = await runTool(cli, ["usage", "--json"], timeout: 30), let data = out.data(using: .utf8) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            claude = try? dec.decode(UsageWindow?.self, from: data)
        }
        debugLog("usage: scanned in \(Int(Date.now.timeIntervalSince(started) * 1000)) ms → \(claude.map { "\($0.tokens) tokens, \($0.messages) msgs, resets \($0.end)" } ?? "no active window")")
    }
}

/// Home card: tokens in the current Claude window and time until it resets.
struct UsageCard: View {
    let usage: UsageService
    let tokenLimit: Int  // 0 = unknown: show elapsed window instead of quota

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude · 5h window", systemImage: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange.opacity(0.9))
            if let w = usage.claude {
                Text(Self.compact(w.tokens)).font(.system(size: 26, weight: .semibold).monospacedDigit())
                    + Text(" tokens").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    let fraction = tokenLimit > 0 ? Double(w.tokens) / Double(tokenLimit)
                                                  : ctx.date.timeIntervalSince(w.start) / w.end.timeIntervalSince(w.start)
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .tint(fraction > 0.85 && tokenLimit > 0 ? .red : .orange)
                        HStack {
                            Text("\(Self.compact(w.output)) out · \(w.messages) msgs")
                            Spacer()
                            Text("resets in \(Self.duration(w.end.timeIntervalSince(ctx.date)))")
                        }
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else {
                Text(usage.available ? "No Claude activity in the last 5 h" : "Claude Code not found")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .task {
            // Refresh while visible only; cancelled automatically when the card goes away.
            while !Task.isCancelled {
                await usage.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.0fK", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let m = max(Int(t / 60), 0)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}
