// `islet usage --json`: Claude Code usage for the current 5-hour window.
// Runs in this short-lived process so the scan's memory is returned to macOS the moment it exits;
// the Islet app only ever receives the few bytes of JSON.
import Foundation

struct UsageWindow: Codable {
    let start: Date
    let end: Date
    let tokens: Int        // input + output + cache read + cache write
    let output: Int
    let messages: Int
    let lastActivity: Date
}

/// Off-main, incremental: remembers each file's read offset and only parses assistant lines
/// that contain usage. Keeps the last 10 h of entries (enough to find the current window).
final class UsageParser {
    /// ISLET_CLAUDE_DIR overrides the log folder (load testing only).
    static let root = ProcessInfo.processInfo.environment["ISLET_CLAUDE_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private static let window: TimeInterval = 5 * 3600
    private static let keep: TimeInterval = 10 * 3600
    private static let maxLine = 2 << 20

    private struct Entry { let time: Date; let tokens: Int; let output: Int }
    private var offsets: [String: UInt64] = [:]
    private var entries: [String: Entry] = [:]  // message id + request id → usage (dedup)
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let usageMarker = Data("\"usage\"".utf8)

    func scan() -> UsageWindow? {
        let cutoff = Date.now - Self.keep
        let fm = FileManager.default
        if let files = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let url as URL in files where url.pathExtension == "jsonl" {
                let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let mod = v?.contentModificationDate, mod > cutoff else { continue }
                read(url, size: UInt64(v?.fileSize ?? 0), cutoff: cutoff)
            }
        }
        entries = entries.filter { $0.value.time > cutoff }
        malloc_zone_pressure_relief(nil, 0)  // give freed read buffers back to macOS right away
        return currentWindow()
    }

    private func read(_ url: URL, size: UInt64, cutoff: Date) {
        var offset = offsets[url.path] ?? 0
        if size < offset { offset = 0 }  // rewritten / truncated
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        var pending = Data()
        var skipping = false  // inside a giant line (tool output): drop bytes until its newline
        // One autorelease pool per 1 MB chunk: the scan is a single job, so without this every
        // read buffer of the file would stay alive until the end (60 MB file ≈ 60 MB peak).
        while true {
            let more: Bool = autoreleasepool {
                guard let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                if skipping {
                    guard let nl = chunk.firstIndex(of: 0x0A) else { offset += UInt64(chunk.count); return true }
                    offset += UInt64(nl - chunk.startIndex + 1)
                    skipping = false
                    pending = Data(chunk[(nl + 1)...])
                } else {
                    pending.append(chunk)
                }
                var start = pending.startIndex
                while let nl = pending[start...].firstIndex(of: 0x0A) {
                    let line = pending[start..<nl]
                    offset += UInt64(line.count + 1)
                    if line.range(of: usageMarker) != nil { parse(line, cutoff: cutoff) }
                    start = pending.index(after: nl)
                }
                pending = Data(pending[start...])  // keep only the unfinished line
                // Usage lines are a few KB; anything this big is tool output. Never buffer it.
                if pending.count > Self.maxLine {
                    offset += UInt64(pending.count)
                    pending = Data()
                    skipping = true
                }
                return true
            }
            if !more { break }
        }
        offsets[url.path] = offset  // a trailing partial line is re-read next time
    }

    /// Lines carry whole responses and tool output (often megabytes), so they are never fully decoded:
    /// four fields are found by byte search and only the small `usage` object is JSON-parsed.
    /// (Structural keys appear unescaped; the same text inside message content is escaped as \"…\".)
    private func parse(_ line: Data, cutoff: Date) {
        autoreleasepool {
            guard line.range(of: Self.assistantKey) != nil,
                  let ts = string(after: Self.timestampKey, in: line).flatMap(iso.date(from:)), ts > cutoff,
                  let usage = usageObject(in: line),
                  let u = try? JSONSerialization.jsonObject(with: usage) as? [String: Any] else { return }
            let n = { (k: String) in u[k] as? Int ?? 0 }
            let output = n("output_tokens")
            let total = n("input_tokens") + output + n("cache_read_input_tokens") + n("cache_creation_input_tokens")
            let key = "\(string(after: Self.messageIdKey, in: line) ?? UUID().uuidString)|\(string(after: Self.requestIdKey, in: line) ?? "")"
            entries[key] = Entry(time: ts, tokens: total, output: output)
        }
    }

    private static let assistantKey = Data(#""type":"assistant""#.utf8)
    private static let timestampKey = Data(#""timestamp":""#.utf8)
    private static let messageIdKey = Data(#""id":"msg_"#.utf8)
    private static let requestIdKey = Data(#""requestId":""#.utf8)
    private static let usageKey = Data(#""usage":{"#.utf8)

    /// Text from right after `key` up to the next quote (message ids keep their "msg_" prefix off; fine for dedup).
    private func string(after key: Data, in line: Data) -> String? {
        guard let r = line.range(of: key), let end = line[r.upperBound...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: line[r.upperBound..<end], as: UTF8.self)
    }

    /// The `{…}` of the first structural "usage" key (it holds no strings with braces).
    private func usageObject(in line: Data) -> Data? {
        guard let r = line.range(of: Self.usageKey) else { return nil }
        var depth = 0
        var i = r.upperBound - 1  // the "{"
        while i < line.endIndex {
            switch line[i] {
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 { return line[(r.upperBound - 1)...i] }
            default: break
            }
            i += 1
        }
        return nil
    }

    private func currentWindow() -> UsageWindow? {
        let sorted = entries.values.sorted { $0.time < $1.time }
        var start: Date?, last: Date?
        var block: [Entry] = []
        for e in sorted {
            if let s = start, let l = last, e.time < s + Self.window, e.time.timeIntervalSince(l) < Self.window {
                block.append(e)
            } else {
                start = Calendar.current.dateInterval(of: .hour, for: e.time)?.start ?? e.time
                block = [e]
            }
            last = e.time
        }
        guard let s = start, let l = last, Date.now < s + Self.window else { return nil }
        return UsageWindow(start: s, end: s + Self.window,
                           tokens: block.reduce(0) { $0 + $1.tokens },
                           output: block.reduce(0) { $0 + $1.output },
                           messages: block.count, lastActivity: l)
    }
}

