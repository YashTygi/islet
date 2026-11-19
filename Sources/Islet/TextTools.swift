import Foundation

/// Selected-text tools: what a piece of text is, and what you can do with it. Pure functions, offline.
/// ponytail: regex detection, no parser libraries; add a real parser only where a type keeps misfiring.
struct Finding: Identifiable {
    let id = UUID()
    let kind: String
    var items: [Item]
    /// Higher = more specific match, shown first.
    let rank: Int

    enum Item {
        /// A result you can copy; `replace` = makes sense written back over the selection.
        case value(String, String, replace: Bool)
        case action(String, symbol: String, Act)
        case warning(String)
        case image(Data)
        case port(Int)
        case swatch(TextTools.RGB, hex: String)  // colour square + HEX, one row
        case link(String)                       // open, private, AirDrop, QR, public link
        case repo(owner: String, name: String)  // live GitHub status via gh
    }

    enum Act {
        case open(String)                       // URL
        case openFile(path: String, line: Int?, col: Int?)
        case reveal(String)
        case run(String, cwd: String)           // in a visible terminal
    }
}

@MainActor
enum TextTools {
    static func detect(_ raw: String, project: String? = nil, clipboard: String? = nil, now: Date = .now) -> [Finding] {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 100_000 else { return [] }
        let detectors: [() -> Finding?] = [
            { secret(s) }, { jwt(s, now: now) }, { json(s) }, { curl(s) }, { stackTrace(s, project: project) },
            { cron(s, now: now) }, { timestamp(s, now: now) }, { httpStatus(s) }, { color(s) }, { port(s) },
            { git(s, project: project) }, { url(s) }, { filePath(s, project: project) }, { regex(s, clipboard: clipboard) },
            { base64(s) }, { identifier(s) },
        ]
        return detectors.compactMap { $0() }.sorted { $0.rank > $1.rank }
    }

    // MARK: Safety

    static let secrets: [(name: String, pattern: String, rotate: String)] = [
        ("AWS access key", #"\bAKIA[0-9A-Z]{16}\b"#, "https://console.aws.amazon.com/iam/home#/security_credentials"),
        ("GitHub token", #"\b(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,})\b"#, "https://github.com/settings/tokens"),
        ("Stripe live key", #"\b(sk|rk)_live_[0-9a-zA-Z]{20,}"#, "https://dashboard.stripe.com/apikeys"),
        ("Anthropic API key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#, "https://console.anthropic.com/settings/keys"),
        ("OpenAI API key", #"\bsk-(proj-)?(?!ant-)[A-Za-z0-9_-]{32,}"#, "https://platform.openai.com/api-keys"),
        ("Private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, ""),
    ]

    static func secret(_ s: String) -> Finding? {
        guard let hit = secrets.first(where: { s.range(of: $0.pattern, options: .regularExpression) != nil }) else { return nil }
        var items: [Finding.Item] = [.warning("This looks like a \(hit.name). Don't paste it into chats, issues or commits. If it was shared, rotate it.")]
        if !hit.rotate.isEmpty { items.append(.action("Rotate \(hit.name)", symbol: "arrow.triangle.2.circlepath", .open(hit.rotate))) }
        return Finding(kind: "Secret", items: items, rank: 100)
    }

    // MARK: Data

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    static func jwt(_ s: String, now: Date) -> Finding? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, s.hasPrefix("eyJ"),
              let h = base64URLDecode(String(parts[0])), let p = base64URLDecode(String(parts[1])),
              let header = pretty(h), let payload = pretty(p) else { return nil }
        var items: [Finding.Item] = [.value("Header", header, replace: false), .value("Payload", payload, replace: false)]
        let claims = (try? JSONSerialization.jsonObject(with: p)) as? [String: Any] ?? [:]
        for (key, label) in [("exp", "Expires"), ("iat", "Issued"), ("nbf", "Not before")] {
            if let t = (claims[key] as? NSNumber)?.doubleValue {
                let d = Date(timeIntervalSince1970: t)
                items.append(.value(label, "\(local(d)) (\(relative(d, now: now)))", replace: false))
            }
        }
        return Finding(kind: "JWT", items: items, rank: 90)
    }

    static func pretty(_ data: Data, sorted: Bool = false) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let out = try? JSONSerialization.data(withJSONObject: o, options: sorted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.prettyPrinted, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    static func json(_ s: String) -> Finding? {
        guard let first = s.first, first == "{" || first == "[" else { return nil }
        let data = Data(s.utf8)
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data) } catch {
            let why = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
            guard let fixed = healJSON(s), let p = pretty(Data(fixed.utf8)) else {
                guard s.last == "}" || s.last == "]" else { return nil }  // only call it broken JSON if it ends like JSON
                return Finding(kind: "JSON (invalid)", items: [.warning(why)], rank: 70)
            }
            return Finding(kind: "JSON (fixed)", items: [.value("Fixed", p, replace: true), .value("Fixed, minified", fixed, replace: true),
                                                         .warning("Was invalid: \(why)")], rank: 70)
        }
        let minified = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        var items: [Finding.Item] = []
        if let p = pretty(data) { items.append(.value("Pretty", p, replace: true)) }
        if let m = minified { items.append(.value("Minified", m, replace: true)) }
        if let p = pretty(data, sorted: true) { items.append(.value("Sorted keys", p, replace: true)) }
        items.append(.value("Swift Codable", swiftType(obj), replace: false))
        items.append(.value("TypeScript", tsType(obj), replace: false))
        return Finding(kind: "JSON", items: items, rank: 80)
    }


    /// Repairs common broken JSON: comments, trailing or missing commas, missing colons, single quotes,
    /// unquoted keys, Python/JS literals (True, None, undefined, NaN), unclosed brackets.
    /// Tokenizes, then re-emits through a small state machine. nil if the result still doesn't parse.
    static func healJSON(_ src: String) -> String? {
        enum Tok { case punct(Character), str(String), scalar(String) }
        var toks: [Tok] = []
        let c = Array(src)
        var i = 0
        func esc(_ s: String) -> String {
            String(decoding: try! JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed), as: UTF8.self)  // swiftlint:disable:this force_try
        }
        while i < c.count {
            let ch = c[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" { while i < c.count, c[i] != "\n" { i += 1 }; continue }
            if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2; continue
            }
            if "{}[]:,".contains(ch) { toks.append(.punct(ch)); i += 1; continue }
            if ch == "\"" || ch == "'" || ch == "`" {
                var out = "", j = i + 1
                while j < c.count, c[j] != ch {
                    if c[j] == "\\", j + 1 < c.count {
                        let n = c[j + 1]
                        out.append(n == "n" ? "\n" : n == "t" ? "\t" : n == "r" ? "\r" : n)
                        j += 2; continue
                    }
                    out.append(c[j]); j += 1
                }
                toks.append(.str(out)); i = j + 1; continue
            }
            var word = "", j = i
            while j < c.count, !c[j].isWhitespace, !"{}[]:,\"'".contains(c[j]) { word.append(c[j]); j += 1 }
            i = j
            switch word {
            case "true", "True": toks.append(.scalar("true"))
            case "false", "False": toks.append(.scalar("false"))
            case "null", "None", "undefined", "NaN", "Infinity", "-Infinity", "nil": toks.append(.scalar("null"))
            default:
                var n = word.hasPrefix("+") ? String(word.dropFirst()) : word
                if n.hasPrefix(".") { n = "0" + n } else if n.hasPrefix("-.") { n = "-0" + n.dropFirst() }
                if n.hasSuffix(".") { n += "0" }
                toks.append(n.range(of: #"^-?\d+(\.\d+)?([eE][+-]?\d+)?$"#, options: .regularExpression) != nil ? .scalar(n) : .str(word))
            }
        }
        enum State { case key, colon, value, next }
        var out = "", stack: [(obj: Bool, state: State)] = [], topDone = false
        func valueDone() { if stack.isEmpty { topDone = true } else { stack[stack.count - 1].state = .next } }
        func close() {
            let top = stack.removeLast()
            if top.obj, top.state == .colon || top.state == .value { out += (top.state == .colon ? ":" : "") + "null" }
            out += top.obj ? "}" : "]"
            valueDone()
        }
        var k = 0
        while k < toks.count, !topDone {
            let t = toks[k]
            guard let top = stack.last else {
                switch t {
                case .punct("{"): out += "{"; stack.append((true, .key))
                case .punct("["): out += "["; stack.append((false, .value))
                case .str(let s): out += esc(s); topDone = true
                case .scalar(let s): out += s; topDone = true
                default: break
                }
                k += 1; continue
            }
            var again = false
            switch (top.obj, top.state, t) {
            case (true, .key, .str(let s)), (true, .key, .scalar(let s)): out += esc(s); stack[stack.count - 1].state = .colon
            case (true, .colon, .punct(":")): out += ":"; stack[stack.count - 1].state = .value
            case (true, .colon, _): out += ":"; stack[stack.count - 1].state = .value; again = true        // missing colon
            case (_, .next, .punct(",")): stack[stack.count - 1].state = top.obj ? .key : .value; out += ","
            case (_, _, .punct("}")) where top.obj, (_, _, .punct("]")) where !top.obj:
                if out.hasSuffix(",") { out.removeLast() }                                                 // trailing comma
                close()
            case (_, _, .punct("}")), (_, _, .punct("]")): close(); again = true                           // wrong closer: close inner
            case (_, .next, _): out += ","; stack[stack.count - 1].state = top.obj ? .key : .value; again = true  // missing comma
            case (_, _, .punct(",")): break                                                                 // stray comma
            case (_, _, .punct(":")): break
            case (true, .key, _): break                                                                     // value without key
            case (_, _, .punct("{")): out += "{"; stack.append((true, .key))
            case (_, _, .punct("[")): out += "["; stack.append((false, .value))
            case (_, _, .str(let s)): out += esc(s); valueDone()
            case (_, _, .scalar(let s)): out += s; valueDone()
            default: break
            }
            if !again { k += 1 }
        }
        while !stack.isEmpty {
            if out.hasSuffix(",") { out.removeLast() }
            close()
        }
        guard (try? JSONSerialization.jsonObject(with: Data(out.utf8), options: .fragmentsAllowed)) != nil else { return nil }
        return out
    }

    private static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    private static func typeName(_ key: String) -> String {
        let words = key.split { !$0.isLetter && !$0.isNumber }
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        let singular = name.hasSuffix("ies") ? String(name.dropLast(3)) + "y" : name.hasSuffix("s") && name.count > 3 ? String(name.dropLast()) : name
        return singular.isEmpty || singular.first!.isNumber ? "Item" : singular
    }

    private static func swiftName(_ key: String) -> String {
        let words = key.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard let first = words.first else { return "value" }
        let name = first.prefix(1).lowercased() + first.dropFirst() + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return name.first!.isNumber ? "_" + name : name
    }

    /// Swift `Codable` structs for a JSON value (types from the first array element).
    static func swiftType(_ root: Any) -> String {
        var out: [String] = []
        func type(of v: Any, key: String) -> String {
            if isBool(v) { return "Bool" }
            if let n = v as? NSNumber { return n.doubleValue == n.doubleValue.rounded() && !"\(n)".contains(".") ? "Int" : "Double" }
            if v is String { return "String" }
            if let a = v as? [Any] { return "[\(a.first.map { type(of: $0, key: key) } ?? "String")]" }
            if let d = v as? [String: Any] { let n = typeName(key); emit(d, name: n); return n }
            return "String?"  // null: type unknown
        }
        func emit(_ d: [String: Any], name: String) {
            var props: [String] = [], keys: [String] = []
            for k in d.keys.sorted() {
                let p = swiftName(k)
                props.append("    let \(p): \(type(of: d[k]!, key: k))")
                keys.append(p == k ? "        case \(p)" : "        case \(p) = \"\(k)\"")
            }
            let needsKeys = zip(d.keys.sorted(), keys).contains { $1.contains("=") }
            out.append("struct \(name): Codable {\n" + props.joined(separator: "\n")
                       + (needsKeys ? "\n\n    enum CodingKeys: String, CodingKey {\n" + keys.joined(separator: "\n") + "\n    }" : "") + "\n}")
        }
        let top = type(of: root, key: "Root")
        if out.isEmpty { return "typealias Root = \(top)" }
        if root is [Any] { out.append("typealias Root = \(top)") }
        return out.joined(separator: "\n\n")
    }

    static func tsType(_ root: Any) -> String {
        var out: [String] = []
        func type(of v: Any, key: String) -> String {
            if isBool(v) { return "boolean" }
            if v is NSNumber { return "number" }
            if v is String { return "string" }
            if let a = v as? [Any] { return "\(a.first.map { type(of: $0, key: key) } ?? "unknown")[]" }
            if let d = v as? [String: Any] {
                let n = typeName(key)
                let fields = d.keys.sorted().map { k -> String in
                    let safe = k.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil ? k : "\"\(k)\""
                    return "  \(safe): \(type(of: d[k]!, key: k));"
                }
                out.append("interface \(n) {\n" + fields.joined(separator: "\n") + "\n}")
                return n
            }
            return "null"
        }
        let top = type(of: root, key: "Root")
        if root is [Any] || out.isEmpty { out.append("type Root = \(top);") }
        return out.joined(separator: "\n\n")
    }

    static func base64(_ s: String) -> Finding? {
        guard s.count >= 12, !s.contains(" "), s.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil,
              s.range(of: #"[0-9+/=_-]|[a-z].*[A-Z]|[A-Z].*[a-z]"#, options: .regularExpression) != nil,
              s.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) == nil,  // hex: hashes / SHAs
              let data = base64URLDecode(s), !data.isEmpty else { return nil }
        for sig: [UInt8] in [[0x89, 0x50, 0x4E, 0x47], [0xFF, 0xD8, 0xFF], [0x47, 0x49, 0x46], [0x52, 0x49, 0x46, 0x46]] where data.starts(with: sig) {
            return Finding(kind: "Base64 image", items: [.image(data), .value("Size", "\(data.count) bytes", replace: false)], rank: 60)
        }
        guard let text = String(data: data, encoding: .utf8),
              Double(text.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }.count) / Double(max(text.unicodeScalars.count, 1)) > 0.95
        else { return nil }
        return Finding(kind: "Base64", items: [.value("Decoded", text, replace: true)], rank: 40)
    }

    // MARK: Time

    static func local(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .standard) }
    static func relative(_ d: Date, now: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: now)
    }

    static func timestamp(_ s: String, now: Date) -> Finding? {
        guard s.range(of: #"^\d{10}(\.\d+)?$|^\d{13}$|^\d{16}$"#, options: .regularExpression) != nil, let n = Double(s) else { return nil }
        let (secs, unit) = s.count == 13 ? (n / 1000, "milliseconds") : s.count == 16 ? (n / 1_000_000, "microseconds") : (n, "seconds")
        guard (946_684_800...4_102_444_800).contains(secs) else { return nil }  // 2000…2100
        let d = Date(timeIntervalSince1970: secs)
        let iso = ISO8601DateFormatter()
        return Finding(kind: "Unix time (\(unit))", items: [
            .value("Local", local(d), replace: true), .value("UTC", iso.string(from: d), replace: true),
            .value("Relative", relative(d, now: now), replace: false),
        ], rank: 75)
    }

    /// Standard 5-field cron (numbers, `*`, lists, ranges, steps). ponytail: no names (MON, JAN), no @daily.
    static func cronField(_ f: Substring, _ range: ClosedRange<Int>) -> Set<Int>? {
        var out = Set<Int>()
        for part in f.split(separator: ",") {
            let ps = part.split(separator: "/", omittingEmptySubsequences: false)
            guard ps.count <= 2, let step = ps.count == 2 ? Int(ps[1]) : 1, step > 0 else { return nil }
            var lo = range.lowerBound, hi = range.upperBound
            if ps[0] != "*" {
                let r = ps[0].split(separator: "-", omittingEmptySubsequences: false)
                guard r.count <= 2, let a = Int(r[0]), let b = r.count == 2 ? Int(r[1]) : (ps.count == 2 ? range.upperBound : a),
                      range.contains(a), range.contains(b), a <= b else { return nil }
                lo = a; hi = b
            }
            out.formUnion(stride(from: lo, through: hi, by: step))
        }
        return out.isEmpty ? nil : out
    }

    static func cron(_ s: String, now: Date) -> Finding? {
        let f = s.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count == 5, s.range(of: #"^[\d*,/\- ]+$"#, options: .regularExpression) != nil, s.contains("*") || s.contains("/"),
              let min = cronField(f[0], 0...59), let hour = cronField(f[1], 0...23), let dom = cronField(f[2], 1...31),
              let mon = cronField(f[3], 1...12), var dow = cronField(f[4], 0...7) else { return nil }
        if dow.contains(7) { dow.insert(0); dow.remove(7) }
        var cal = Calendar.current
        cal.timeZone = .current
        var t = cal.date(bySetting: .second, value: 0, of: now.addingTimeInterval(60)) ?? now
        if t <= now { t = t.addingTimeInterval(60) }
        var runs: [Date] = []
        let domStar = f[2] == "*", dowStar = f[4] == "*"
        for _ in 0..<(366 * 24 * 60) where runs.count < 5 {
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            let dayOK = domStar || dowStar ? dom.contains(c.day!) && dow.contains(c.weekday! - 1)
                                           : dom.contains(c.day!) || dow.contains(c.weekday! - 1)  // cron: either matches
            if min.contains(c.minute!), hour.contains(c.hour!), mon.contains(c.month!), dayOK { runs.append(t) }
            t = t.addingTimeInterval(60)
        }
        return Finding(kind: "Cron", items: [
            .value("Meaning", cronEnglish(f), replace: false),
            .value("Next runs", runs.map(local).joined(separator: "\n"), replace: false),
        ], rank: 85)
    }

    static func cronEnglish(_ f: [Substring]) -> String {
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        func every(_ x: Substring, _ unit: String) -> String? {
            x == "*" ? "every \(unit)" : x.hasPrefix("*/") ? "every \(x.dropFirst(2)) \(unit)s" : nil
        }
        var time: String
        if let m = Int(f[0]), let h = Int(f[1]) { time = String(format: "At %02d:%02d", h, m) }
        else if let m = every(f[0], "minute") { time = m.prefix(1).uppercased() + m.dropFirst() + (f[1] == "*" ? "" : ", hour \(f[1])") }
        else if let h = every(f[1], "hour") { time = "At minute \(f[0]), \(h)" }
        else { time = "At minute \(f[0]), hour \(f[1])" }
        if f[2] != "*" { time += ", on day \(f[2]) of the month" }
        if f[3] != "*" { time += ", in month \(f[3])" }
        if f[4] != "*" {
            let d = f[4] == "1-5" ? "Monday to Friday" : f[4].split(separator: ",").map { p -> String in
                let r = p.split(separator: "-").compactMap { Int($0) }.map { days[min($0, 7)] }
                return r.count == 2 ? "\(r[0]) to \(r[1])" : r.first ?? String(p)
            }.joined(separator: ", ")
            time += ", \(d)"
        }
        return time
    }

    // MARK: Numbers

    static let statuses: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        206: "Partial Content", 301: "Moved Permanently: use the new URL from now on", 302: "Found: temporary redirect",
        303: "See Other", 304: "Not Modified: use your cached copy", 307: "Temporary Redirect (keeps the method)",
        308: "Permanent Redirect (keeps the method)", 400: "Bad Request: the request is malformed",
        401: "Unauthorized: missing or invalid credentials", 403: "Forbidden: authenticated but not allowed",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout",
        409: "Conflict: clashes with the current state", 410: "Gone: removed for good", 411: "Length Required",
        412: "Precondition Failed", 413: "Payload Too Large", 414: "URI Too Long", 415: "Unsupported Media Type",
        418: "I'm a teapot", 422: "Unprocessable Content: valid syntax, failed validation", 425: "Too Early",
        426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests: rate limited",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error: the server crashed or threw", 501: "Not Implemented",
        502: "Bad Gateway: the upstream server sent a bad response", 503: "Service Unavailable: overloaded or down",
        504: "Gateway Timeout: the upstream server didn't answer in time", 505: "HTTP Version Not Supported",
    ]

    static func httpStatus(_ s: String) -> Finding? {
        guard s.count == 3, let n = Int(s), let text = statuses[n] else { return nil }
        let cls = ["", "Informational", "Success", "Redirect", "Client error", "Server error"][n / 100]
        return Finding(kind: "HTTP \(n)", items: [.value(cls, text, replace: false),
                                                  .action("MDN docs", symbol: "book", .open("https://developer.mozilla.org/docs/Web/HTTP/Status/\(n)"))], rank: 65)
    }

    // MARK: Code and text

    static func words(_ s: String) -> [String] {
        let spaced = s.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2", options: .regularExpression)
        return spaced.split { $0 == "_" || $0 == "-" || $0 == " " || $0 == "." }.map { $0.lowercased() }
    }

    static func identifier(_ s: String) -> Finding? {
        guard (2...80).contains(s.count), s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$-]*[A-Za-z0-9]$"#, options: .regularExpression) != nil,
              s.contains("_") || s.contains("-") || s.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil else { return nil }
        let w = words(s)
        guard w.count > 1 else { return nil }
        let cap = w.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let forms = [("camelCase", w[0] + cap.dropFirst().joined()), ("snake_case", w.joined(separator: "_")),
                     ("kebab-case", w.joined(separator: "-")), ("PascalCase", cap.joined()),
                     ("CONSTANT_CASE", w.joined(separator: "_").uppercased())]
        return Finding(kind: "Identifier", items: forms.filter { $0.1 != s }.map { .value($0.0, $0.1, replace: true) }, rank: 20)
    }

    /// Splits a shell command line into words (quotes, backslash escapes, line continuations).
    static func shellWords(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character? = nil, escape = false, any = false
        for ch in s {
            if escape { if ch != "\n" { cur.append(ch) }; escape = false; continue }
            if ch == "\\" && quote != "'" { escape = true; any = true; continue }
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) }; continue }
            if ch == "'" || ch == "\"" { quote = ch; any = true; continue }
            if ch.isWhitespace { if any || !cur.isEmpty { out.append(cur) }; cur = ""; any = false; continue }
            cur.append(ch)
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }

    struct Request { var method = "GET", url = "", headers: [(String, String)] = [], body: String? }

    static func parseCurl(_ s: String) -> Request? {
        let w = shellWords(s)
        guard w.first == "curl" else { return nil }
        var r = Request(), i = 1, explicitMethod = false
        while i < w.count {
            let a = w[i]
            func next() -> String? { i += 1; return i < w.count ? w[i] : nil }
            switch a {
            case "-X", "--request": r.method = next() ?? r.method; explicitMethod = true
            case "-H", "--header":
                if let h = next(), let c = h.firstIndex(of: ":") {
                    r.headers.append((String(h[..<c]), h[h.index(after: c)...].trimmingCharacters(in: .whitespaces)))
                }
            case "-d", "--data", "--data-raw", "--data-binary", "--data-ascii": r.body = next()
            case "--json":
                r.body = next()
                r.headers.append(("Content-Type", "application/json")); r.headers.append(("Accept", "application/json"))
            case "-u", "--user":
                if let u = next() { r.headers.append(("Authorization", "Basic " + Data(u.utf8).base64EncodedString())) }
            case "-I", "--head": r.method = "HEAD"; explicitMethod = true
            case "--url": r.url = next() ?? ""
            case "-o", "--output", "-A", "--user-agent", "-e", "--referer", "-b", "--cookie", "-m", "--max-time", "--connect-timeout", "-w", "--write-out":
                let v = next()
                if a == "-A" || a == "--user-agent", let v { r.headers.append(("User-Agent", v)) }
                if a == "-b" || a == "--cookie", let v { r.headers.append(("Cookie", v)) }
            default: if !a.hasPrefix("-"), r.url.isEmpty { r.url = a }
            }
            i += 1
        }
        if r.body != nil && !explicitMethod { r.method = "POST" }
        return r.url.isEmpty ? nil : r
    }

    static func q(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    static func curl(_ s: String) -> Finding? {
        guard s.hasPrefix("curl "), let r = parseCurl(s) else { return nil }
        let hdrJS = r.headers.map { "    \(q($0.0)): \(q($0.1))," }.joined(separator: "\n")
        var fetch = "await fetch(\(q(r.url)), {\n  method: \(q(r.method)),"
        if !r.headers.isEmpty { fetch += "\n  headers: {\n\(hdrJS.replacingOccurrences(of: "    ", with: "    "))\n  }," }
        if let b = r.body { fetch += "\n  body: \(q(b))," }
        fetch += "\n});"
        var swift = "var request = URLRequest(url: URL(string: \(q(r.url)))!)\nrequest.httpMethod = \(q(r.method))"
        for h in r.headers { swift += "\nrequest.setValue(\(q(h.1)), forHTTPHeaderField: \(q(h.0)))" }
        if let b = r.body { swift += "\nrequest.httpBody = Data(\(q(b)).utf8)" }
        swift += "\nlet (data, response) = try await URLSession.shared.data(for: request)"
        var axios = "await axios({\n  method: \(q(r.method.lowercased())),\n  url: \(q(r.url)),"
        if !r.headers.isEmpty { axios += "\n  headers: {\n\(hdrJS)\n  }," }
        if let b = r.body { axios += "\n  data: \(q(b))," }
        axios += "\n});"
        func sq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var httpie = "http \(r.method) \(sq(r.url))"
        for h in r.headers { httpie += " \(sq("\(h.0):\(h.1)"))" }
        if let b = r.body { httpie = "echo \(sq(b)) | " + httpie }
        return Finding(kind: "curl", items: [.value("fetch", fetch, replace: true), .value("URLSession", swift, replace: true),
                                             .value("axios", axios, replace: true), .value("HTTPie", httpie, replace: true)], rank: 88)
    }

    static func regex(_ s: String, clipboard: String?) -> Finding? {
        var pattern = s, options: NSRegularExpression.Options = []
        if s.count > 2, s.hasPrefix("/"), let end = s.lastIndex(of: "/"), end != s.startIndex,
           s[s.index(after: end)...].allSatisfy({ "gimsuy".contains($0) }) {
            pattern = String(s[s.index(after: s.startIndex)..<end])
            if s[end...].contains("i") { options.insert(.caseInsensitive) }
            if s[end...].contains("m") { options.insert(.anchorsMatchLines) }
            if s[end...].contains("s") { options.insert(.dotMatchesLineSeparators) }
        } else {
            let tokens = [#"\d"#, #"\w"#, #"\s"#, #"\b"#, "[^", "(?:", "(?<", ".*", ".+", "+?", "*?", "{1,", "[a-z", "[A-Z", "[0-9"]
            let hits = tokens.filter { s.contains($0) }.count + (s.hasPrefix("^") ? 1 : 0) + (s.hasSuffix("$") ? 1 : 0)
            guard hits >= 2, !s.contains("\n") else { return nil }
        }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        guard let text = clipboard, !text.isEmpty, text != s else {
            return Finding(kind: "Regex", items: [.value("Pattern", pattern, replace: false),
                                                  .warning("Copy some sample text first, then select the regex again to test it.")], rank: 50)
        }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let shown = matches.prefix(10).map { m -> String in
            let groups = (1..<max(m.numberOfRanges, 1)).compactMap { g -> String? in
                m.range(at: g).location == NSNotFound ? nil : "$\(g)=" + ns.substring(with: m.range(at: g))
            }
            return "• " + ns.substring(with: m.range) + (groups.isEmpty ? "" : "   " + groups.joined(separator: " "))
        }
        return Finding(kind: "Regex", items: [
            .value("\(matches.count) match\(matches.count == 1 ? "" : "es") in clipboard text", shown.isEmpty ? "No matches" : shown.joined(separator: "\n"), replace: false),
        ], rank: 50)
    }

    // MARK: Developer references

    static func resolve(_ p: String, project: String?) -> String? {
        let fm = FileManager.default
        var path = (p as NSString).expandingTildeInPath
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? path }
        if !path.hasPrefix("/") {
            guard let project else { return nil }
            path = (project as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        return fm.fileExists(atPath: path) ? path : nil
    }

    /// `path`, `path:12`, `path:12:5`.
    static func splitLocation(_ s: String) -> (path: String, line: Int?, col: Int?) {
        let m = s.firstMatch(of: /^(.+?)(?::(\d+))?(?::(\d+))?$/)
        return (String(m?.1 ?? Substring(s)), m?.2.flatMap { Int($0) }, m?.3.flatMap { Int($0) })
    }

    static func fileActions(_ path: String, line: Int?, col: Int?, project: String?) -> [Finding.Item] {
        var items: [Finding.Item] = [.action(line.map { "Open at line \($0)" } ?? "Open in VS Code", symbol: "chevron.left.forwardslash.chevron.right",
                                             .openFile(path: path, line: line, col: col)),
                                     .action("Reveal in Finder", symbol: "folder", .reveal(path))]
        items.append(.value("Relative path", ContextService.relativePath(path), replace: true))
        items.append(.value("Full path", path, replace: true))
        return items
    }

    static func filePath(_ s: String, project: String?) -> Finding? {
        guard !s.contains("\n"), s.count < 500, s.range(of: #"^(file://|~|/|\.{1,2}/)|^[\w@.+-]+/[\w@.+/-]*\.\w+(:\d+){0,2}$|^[\w@+-]+\.\w{1,6}(:\d+){1,2}$"#, options: .regularExpression) != nil
        else { return nil }
        let loc = splitLocation(s)
        guard let path = resolve(loc.path, project: project) else { return nil }
        return Finding(kind: loc.line == nil ? "File path" : "File location", items: fileActions(path, line: loc.line, col: loc.col, project: project), rank: 72)
    }

    static func stackTrace(_ s: String, project: String?) -> Finding? {
        // Whole text, not per line: rendered chat/markdown often joins a trace into one line.
        var found: [(at: String.Index, path: String, line: Int, col: Int?)] = []
        let patterns = [
            #/File "(?<p>[^"]+)", line (?<l>\d+)(?:, column (?<c>\d+))?/#,           // Python (same captures as below)
            #/(?<p>(?:/|~/|\./|[A-Za-z]:\\)[^\s:()'"]+\.\w+):(?<l>\d+)(?::(?<c>\d+))?/#, // Swift, Node, Go, Rust (absolute)
            #/\(?(?<p>[\w@./-]+\.(?:js|jsx|ts|tsx|mjs|cjs|swift|py|go|rs|rb|java|kt|m|c|cc|cpp|h|vue|svelte)):(?<l>\d+)(?::(?<c>\d+))?/#,
        ]
        for re in patterns {
            for m in s.matches(of: re) {
                guard let n = Int(m.l), let path = resolve(String(m.p), project: project),
                      !found.contains(where: { $0.at <= m.range.upperBound && m.range.lowerBound <= $0.at }) else { continue }
                found.append((m.range.lowerBound, path, n, m.c.flatMap { Int($0) }))
            }
        }
        let frames = found.sorted { $0.at < $1.at }.map { (path: $0.path, line: $0.line, col: $0.col) }
        let looksLikeTrace = s.range(of: #"Error|Exception|Traceback|panic|\bat |fatal"#, options: .regularExpression) != nil
        guard frames.count >= 2 || (frames.count == 1 && looksLikeTrace && s.count > frames[0].path.count + 20) else { return nil }
        // Project frames first, dependencies last.
        let ordered = frames.enumerated().sorted { a, b in
            func score(_ p: String) -> Int { p.contains("/node_modules/") || p.contains("/.build/") || p.contains("site-packages") ? 1 : 0 }
            return (score(a.element.path), a.offset) < (score(b.element.path), b.offset)
        }.map(\.element)
        var seen = Set<String>()
        let items: [Finding.Item] = ordered.filter { seen.insert("\($0.path):\($0.line)").inserted }.prefix(8).map {
            .action("\(ContextService.relativePath($0.path)):\($0.line)", symbol: "arrow.right.circle", .openFile(path: $0.path, line: $0.line, col: $0.col))
        }
        return Finding(kind: "Stack trace (\(frames.count) frames)", items: items, rank: 87)
    }

    /// `owner/repo` of the project's GitHub remote.
    static func githubRepo(_ project: String?) -> String? {
        guard let project, let config = try? String(contentsOfFile: project + "/.git/config", encoding: .utf8),
              let m = config.firstMatch(of: /github\.com[:\/]([\w.-]+)\/([\w.-]+?)(?:\.git)?\s/) else { return nil }
        return "\(m.1)/\(m.2)"
    }

    static func git(_ s: String, project: String?) -> Finding? {
        let repo = githubRepo(project)
        if s.range(of: #"^[0-9a-f]{7,40}$"#, options: .regularExpression) != nil, s.range(of: #"[a-f]"#, options: .regularExpression) != nil,
           s.range(of: #"[0-9]"#, options: .regularExpression) != nil, let project {
            var items: [Finding.Item] = [.action("git show", symbol: "terminal", .run("git show --stat \(s)", cwd: project))]
            if let repo { items.insert(.action("Open commit on GitHub", symbol: "arrow.up.right.square", .open("https://github.com/\(repo)/commit/\(s)")), at: 0) }
            return Finding(kind: "Git commit", items: items, rank: 55)
        }
        if let m = s.firstMatch(of: /^#(\d+)$/), let repo {
            return Finding(kind: "Issue / PR #\(m.1)", items: [.action("Open on GitHub", symbol: "arrow.up.right.square", .open("https://github.com/\(repo)/issues/\(m.1)"))], rank: 55)
        }
        if let m = s.firstMatch(of: /^(?:https?:\/\/github\.com\/)?([A-Za-z0-9][\w.-]*)\/([\w.-]+?)(?:\.git)?\/?$/), !s.contains("."), s.count < 100 || s.hasPrefix("http") {
            return Finding(kind: "GitHub repo", items: [
                .repo(owner: String(m.1), name: String(m.2)),
                .action("Open \(m.1)/\(m.2)", symbol: "arrow.up.right.square", .open("https://github.com/\(m.1)/\(m.2)")),
                .value("Clone", "git clone https://github.com/\(m.1)/\(m.2).git", replace: false),
            ], rank: 15)
        }
        return nil
    }

    static func url(_ s: String) -> Finding? {
        guard !s.contains(" "), !s.contains("\n"),
              s.range(of: #"^(https?://[^\s]+|(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(/\S*)?)$"#, options: .regularExpression) != nil
        else { return nil }
        let full = s.hasPrefix("http") ? s : "http://" + s
        guard let u = URL(string: full), let host = u.host else { return nil }
        var items: [Finding.Item] = [.link(full)]
        if ["localhost", "127.0.0.1", "0.0.0.0"].contains(host) { items.append(.port(u.port ?? 80)) }  // what's serving it, Stop
        if host == "github.com" {
            let p = u.pathComponents.filter { $0 != "/" }
            if p.count >= 2 { items.append(.repo(owner: p[0], name: p[1].replacingOccurrences(of: ".git", with: ""))) }
        }
        return Finding(kind: host == "github.com" ? "GitHub link" : "Link", items: items, rank: 74)
    }

    static func port(_ s: String) -> Finding? {
        guard let m = s.firstMatch(of: /^(?:https?:\/\/)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0)?:(\d{2,5})\/?$|^(?:localhost|127\.0\.0\.1):(\d{2,5})/),
              let n = Int(m.1 ?? m.2 ?? ""), (1...65535).contains(n) else { return nil }
        return Finding(kind: "Port \(n)", items: [.port(n), .action("Open localhost:\(n)", symbol: "safari", .open("http://localhost:\(n)"))], rank: 68)
    }

    // MARK: Colour

    struct RGB { var r, g, b, a: Double }

    static func parseColor(_ s: String) -> RGB? {
        let t = s.lowercased().replacingOccurrences(of: " ", with: "")
        if let m = t.firstMatch(of: /^#?([0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/), t.hasPrefix("#") || m.1.count == 6 {
            var h = String(m.1)
            if h.count <= 4 { h = h.map { "\($0)\($0)" }.joined() }
            let v = UInt64(h, radix: 16)!
            return h.count == 8 ? RGB(r: Double(v >> 24 & 255) / 255, g: Double(v >> 16 & 255) / 255, b: Double(v >> 8 & 255) / 255, a: Double(v & 255) / 255)
                                : RGB(r: Double(v >> 16 & 255) / 255, g: Double(v >> 8 & 255) / 255, b: Double(v & 255) / 255, a: 1)
        }
        let nums = s.lowercased().split { !"0123456789.%".contains($0) }.map(String.init).filter { !$0.isEmpty }
        func num(_ i: Int, scale: Double) -> Double? {
            guard i < nums.count else { return nil }
            let x = nums[i]
            return x.hasSuffix("%") ? Double(x.dropLast()).map { $0 / 100 } : Double(x).map { $0 / scale }
        }
        let alpha = nums.count >= 4 ? num(3, scale: 1) ?? 1 : 1
        if t.hasPrefix("rgb"), let r = num(0, scale: 255), let g = num(1, scale: 255), let b = num(2, scale: 255) { return RGB(r: r, g: g, b: b, a: alpha) }
        if t.hasPrefix("hsl"), nums.count >= 3, let h = Double(nums[0]), let sat = num(1, scale: 100), let l = num(2, scale: 100) {
            let c = (1 - abs(2 * l - 1)) * sat, hp = h.truncatingRemainder(dividingBy: 360) / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            let (r, g, b): (Double, Double, Double) = hp < 1 ? (c, x, 0) : hp < 2 ? (x, c, 0) : hp < 3 ? (0, c, x) : hp < 4 ? (0, x, c) : hp < 5 ? (x, 0, c) : (c, 0, x)
            let m = l - c / 2
            return RGB(r: r + m, g: g + m, b: b + m, a: alpha)
        }
        if t.hasPrefix("oklch"), nums.count >= 3, let l = num(0, scale: 1), let c = Double(nums[1]), let h = Double(nums[2]) {
            let a = c * cos(h * .pi / 180), b = c * sin(h * .pi / 180)
            let l_ = l + 0.3963377774 * a + 0.2158037573 * b, m_ = l - 0.1055613458 * a - 0.0638541728 * b, s_ = l - 0.0894841775 * a - 1.2914855480 * b
            let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
            func enc(_ x: Double) -> Double { let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055; return min(max(v, 0), 1) }
            return RGB(r: enc(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                       g: enc(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                       b: enc(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S), a: alpha)
        }
        return nil
    }

    static func color(_ s: String) -> Finding? {
        guard s.count < 60, let c = parseColor(s) else { return nil }
        let r = Int((c.r * 255).rounded()), g = Int((c.g * 255).rounded()), b = Int((c.b * 255).rounded())
        var hex = String(format: "#%02x%02x%02x", r, g, b)
        if c.a < 1 { hex += String(format: "%02x", Int((c.a * 255).rounded())) }
        // HSL
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), l = (mx + mn) / 2, d = mx - mn
        let sat = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var h = d == 0 ? 0 : mx == c.r ? ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6) : mx == c.g ? (c.b - c.r) / d + 2 : (c.r - c.g) / d + 4
        h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        // OKLCH
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (lin(c.r), lin(c.g), lin(c.b))
        let L = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let M = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let S = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        let ol = 0.2104542553 * L + 0.7936177850 * M - 0.0040720468 * S
        let oa = 1.9779984951 * L - 2.4285922050 * M + 0.4505937099 * S
        let ob = 0.0259040371 * L + 0.7827717662 * M - 0.8086757660 * S
        let oc = sqrt(oa * oa + ob * ob), oh = (atan2(ob, oa) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let alpha = c.a < 1 ? String(format: " / %.2f", c.a) : ""
        let items: [Finding.Item] = [
            .swatch(c, hex: hex),
            .value("RGB", c.a < 1 ? String(format: "rgba(%d, %d, %d, %.2f)", r, g, b, c.a) : "rgb(\(r), \(g), \(b))", replace: true),
            .value("HSL", String(format: "hsl(%.0f %.0f%% %.0f%%%@)", h, sat * 100, l * 100, alpha), replace: true),
            .value("OKLCH", String(format: "oklch(%.3f %.3f %.1f%@)", ol, oc, oh, alpha), replace: true),
            .value("SwiftUI", String(format: "Color(red: %.3f, green: %.3f, blue: %.3f%@)", c.r, c.g, c.b, c.a < 1 ? String(format: ", opacity: %.2f", c.a) : ""), replace: true),
            .value("Tailwind", "bg-[\(hex)] text-[\(hex)]", replace: false),
        ]
        return Finding(kind: "Colour", items: items, rank: 78)
    }

    // MARK: Self-test

    static func selfTest() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func top(_ s: String, project: String? = nil, clipboard: String? = nil) -> String { detect(s, project: project, clipboard: clipboard, now: now).first?.kind ?? "-" }
        func value(_ s: String, _ label: String) -> String? {
            for f in detect(s, now: now) {
                for item in f.items {
                    if case .value(let l, let v, _) = item, l == label { return v }
                    if case .swatch(_, let hex) = item, label == "HEX" { return hex }
                }
            }
            return nil
        }
        precondition(top("AKIAIOSFODNN7EXAMPLE") == "Secret")
        precondition(top("sk-ant-api03-abcdefghijklmnopqrstuvwxyz") == "Secret")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIiwiZXhwIjoxNzAwMDAzNjAwfQ.sig"
        precondition(top(jwt) == "JWT" && value(jwt, "Expires")?.contains("in 1 hour") == true)
        precondition(top(#"{"user_name":"a","age":3,"ok":true,"tags":["x"]}"#) == "JSON")
        precondition(value(#"{"b":1,"a":2}"#, "Minified")?.count == 13)
        precondition(value(#"{"user_name":"a"}"#, "Swift Codable")?.contains("case userName = \"user_name\"") == true)
        precondition(top(#"{"a": 1 "b": 2}"#) == "JSON (fixed)")
        for (broken, fixed) in [(#"{"a": 1 "b": 2}"#, #"{"a":1,"b":2}"#), (#"{'a': 'x', b: True, c: None,}"#, #"{"a":"x","b":true,"c":null}"#),
                                (#"[1, 2,, 3,]"#, "[1,2,3]"), (#"{"a": [1, 2"#, #"{"a":[1,2]}"#), ("{\"a\": 1, // note\n \"b\" 2}", #"{"a":1,"b":2}"#),
                                (#"{"a": {"b": 1}"#, #"{"a":{"b":1}}"#), ("{'n': 'y', t: ['a',], ok: True, // c", #"{"n":"y","t":["a"],"ok":true}"#), (#"{"x": .5, "y": +3}"#, #"{"x":0.5,"y":3}"#)] {
            precondition(healJSON(broken) == fixed, "heal \(broken) → \(healJSON(broken) ?? "nil")")
        }
        precondition(top("1700000000") == "Unix time (seconds)" && top("1700000000000") == "Unix time (milliseconds)")
        precondition(top("*/15 9-17 * * 1-5") == "Cron")
        precondition(value("30 2 * * *", "Meaning") == "At 02:30")
        precondition(value("0 9 * * 1-5", "Next runs")?.split(separator: "\n").count == 5)
        precondition(top("404") == "HTTP 404")
        precondition(value("userName", "snake_case") == "user_name" && value("HTTPServerError", "kebab-case") == "http-server-error")
        precondition(value("max_retry_count", "camelCase") == "maxRetryCount")
        let curl = #"curl -X POST https://api.x.com/v1 -H 'Content-Type: application/json' -d '{"a":1}'"#
        precondition(top(curl) == "curl" && value(curl, "fetch")?.contains("method: \"POST\"") == true)
        precondition(value("curl -u me:pw https://x.com", "URLSession")?.contains("Basic bWU6cHc=") == true)
        precondition(shellWords(#"a "b c" 'd\e' f\ g"#) == ["a", "b c", #"d\e"#, "f g"])
        precondition(top(#"^\d{3}-\w+$"#, clipboard: "123-abc\n456-de") == "Regex")
        precondition(detect(#"/(\d+)px/g"#, clipboard: "10px 20px", now: now).contains { f in
            f.items.contains { if case .value(let l, _, _) = $0 { return l.hasPrefix("2 matches") }; return false }
        })
        precondition(top("#ff8800") == "Colour" && value("rgb(255, 136, 0)", "HEX") == "#ff8800")
        precondition(value("#ff0000", "OKLCH") == "oklch(0.628 0.258 29.2)")
        precondition(value("oklch(0.628 0.258 29.2)", "HEX") == "#ff0000")
        precondition(value("hsl(120, 100%, 50%)", "HEX") == "#00ff00")
        precondition(value("rgb(255 136 0 / 50%)", "HEX") == "#ff880080")
        precondition(top(":3000") == "Port 3000" && top("localhost:5173") == "Link")
        precondition(top("anthropics/claude-code") == "GitHub repo")
        precondition(top("/etc/hosts") == "File path" && top("/etc/hosts:3") == "File location")
        let plist = "/System/Library/CoreServices/SystemVersion.plist"
        let trace = "Error: boom\n    at run (\(plist):10:5)\n    at main (\(plist):20:1)"
        precondition(top(trace) == "Stack trace (2 frames)")
        precondition(top(trace.replacingOccurrences(of: "\n    ", with: " ")) == "Stack trace (2 frames)")  // joined into one line
        precondition(top("https://example.com/a?b=1") == "Link" && top("localhost:3000/app") == "Link")
        precondition(detect("https://github.com/anthropics/claude-code", now: now).first?.kind == "GitHub link")
        precondition(top("hello") == "-" && top("hello world") == "-" && top("deadbeefcafe") != "Base64")
        precondition(top("SGVsbG8sIHdvcmxkIQ==") == "Base64" && value("SGVsbG8sIHdvcmxkIQ==", "Decoded") == "Hello, world!")
        print("TextTools self-test passed")
    }
}
