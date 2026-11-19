import AppKit
import ApplicationServices
import SwiftUI

// Hold Control + Shift and talk: words go into the text box you're focused on (as you speak where the app
// allows it, else pasted when you let go). Nothing focused: after you let go, a bubble drops from the notch
// with the text and Copy, then shrinks back after 5 s. Nothing extra is drawn on screen while you talk.

/// The text field that has keyboard focus right now, if any. Never guesses: no focused editable field, no target.
@MainActor
struct TextTarget {
    let app: NSRunningApplication
    let element: AXUIElement?   // nil: a web field found via the page (paste only)

    static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func focused() async -> TextTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              AXIsProcessTrusted() else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps (VS Code, Slack, Claude…) hide their UI from Accessibility until asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var f: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success,
           let f, CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement  // swiftlint:disable:this force_cast
            var role: CFTypeRef?, editable: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(el, "AXEditableAncestor" as CFString, &editable)
            if editableRoles.contains(role as? String ?? "") || editable != nil { return TextTarget(app: app, element: el) }
        }
        // Chrome / Brave without their full accessibility tree: ask the page what's focused.
        if let name = ChatWatcher.browsers.first(where: { $0.id == app.bundleIdentifier })?.name {
            let js = "(()=>{const a=document.activeElement;return !!a&&(a.isContentEditable||(/^(INPUT|TEXTAREA)$/.test(a.tagName)&&!a.readOnly&&!a.disabled))})()"
            if await ChatExporter.runJS(name, js, timeout: 2) == "true" { return TextTarget(app: app, element: nil) }
        }
        return nil
    }
}

/// Puts dictated text into a TextTarget. Finished phrases go in live through Accessibility (no keystrokes, so
/// the held Control + Shift can't turn them into shortcuts). Apps that ignore that get one paste on release.
@MainActor
final class TextInserter {
    let target: TextTarget
    private(set) var inserted = ""
    private var live: Bool?   // nil = not tried yet

    init(_ target: TextTarget) { self.target = target }

    private func length(_ el: AXUIElement) -> Int? {
        var n: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXNumberOfCharactersAttribute as CFString, &n) == .success else {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success ? (v as? String)?.count : nil
        }
        return (n as? Int)
    }

    /// A finished phrase while you're still talking.
    func add(_ phrase: String) {
        guard live != false, let el = target.element else { return }
        let piece = Self.join(inserted, phrase)
        let before = length(el)
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, piece as CFString) == .success,
              before == nil || length(el) != before else {
            live = false  // claims success but nothing changed (common in web views): paste at the end instead
            return
        }
        live = true
        inserted += piece
    }

    /// You let go: whatever didn't go in live is pasted now (clipboard put back afterwards).
    func finish(_ full: String) {
        let rest = inserted.isEmpty ? full : full.hasPrefix(inserted) ? String(full.dropFirst(inserted.count)) : ""
        let text = inserted.isEmpty ? rest : Self.join(inserted, rest.trimmingCharacters(in: .whitespaces))
        guard !rest.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if live == true, let el = target.element,
           AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return }
        Self.paste(text, into: target.app)
    }

    static func join(_ before: String, _ next: String) -> String {
        guard let last = before.last, !last.isWhitespace, let first = next.first, !first.isWhitespace, !",.!?;:".contains(first) else { return next }
        return " " + next
    }

    static func paste(_ text: String, into app: NSRunningApplication) {
        let pb = NSPasteboard.general
        let saved = (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
        pb.clearContents()
        pb.setString(text, forType: .string)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)  // ⌘V
            e?.flags = .maskCommand
            e?.postToPid(app.processIdentifier)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            pb.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (t, d) in types { item.setData(d, forType: t) }
                return item
            })
        }
    }

    static func selfTest() {
        precondition(join("", "Hello") == "Hello" && join("Hello", "world") == " world")
        precondition(join("Hello", ", world") == ", world" && join("Hello ", "world") == "world")
        print("TextInserter self-test passed")
    }
}

// MARK: Learning from your fixes

/// After dictated text lands in a field, re-reads that field every 2 s for 20 s. A dictated word you change into a
/// similar-looking word ("dusting" → "testing") is remembered as a pair with a count. The pair isn't a rule: it
/// only lets "testing" win when the recognizer is unsure and offers "testing" itself (VoiceGuess). Only word
/// pairs are kept, never the text. Stops early when you start the next dictation.
@MainActor
final class CorrectionLearner {
    let prefs: Prefs
    private var timer: Timer?
    private var found: [(String, String)] = []
    private var element: AXUIElement?
    private var dictated = ""
    private var said: [String] = []
    private var start: Int?   // where the dictated text sits in the field, found on a later read (pastes land late)
    private var ticks = 0

    init(prefs: Prefs) { self.prefs = prefs }

    func watch(_ target: TextTarget, dictated: String) {
        stop()
        guard let el = target.element else { return }   // web fields found via the page: can't be read back
        said = VoiceGuess.words(dictated)
        guard said.count >= 3 else { return }
        element = el
        self.dictated = dictated
        start = nil
        ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        ticks += 1
        if let el = element, let v = Self.value(el), v.count < 200_000 {
            if start == nil, let r = v.range(of: dictated, options: .backwards) { start = v.distance(from: v.startIndex, to: r.lowerBound) }
            if let s = start {
                // ponytail: fixed window around where it was; typing a lot above it shifts it out of view.
                let lo = v.index(v.startIndex, offsetBy: max(0, min(s - 300, v.count)))
                let hi = v.index(lo, offsetBy: min(v.distance(from: lo, to: v.endIndex), dictated.count + 600))
                found = Self.fixes(said, VoiceGuess.words(String(v[lo..<hi])))
            }
        }
        if ticks >= 10 || (start == nil && ticks >= 2) { stop() }
    }

    /// Ends watching and records what was found.
    func stop() {
        timer?.invalidate()
        timer = nil
        element = nil
        guard !found.isEmpty else { return }
        var l = prefs.voiceLearned
        for (h, m) in found { l["\(h)>\(m)", default: 0] += 1 }
        if l.count > 300 { for k in l.sorted(by: { $0.value < $1.value }).prefix(l.count - 300).map(\.key) { l[k] = nil } }
        prefs.voiceLearned = l
        found = []
    }

    private static func value(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success ? v as? String : nil
    }

    /// One-word swaps between what you said and what the field holds now: a single changed word with matching
    /// words on both sides, changed into a similar word (at most 60% of its letters differ). Lowercased.
    static func fixes(_ said: [String], _ now: [String]) -> [(String, String)] {
        let n = said.count, m = now.count
        guard n > 0, m > 0, n * m <= 400_000 else { return [] }
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = said[i] == now[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if said[i] == now[j] { pairs.append((i, j)); i += 1; j += 1 } else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 }
        }
        var out: [(String, String)] = []
        for (a, b) in zip(pairs, pairs.dropFirst()) where b.0 - a.0 == 2 && b.1 - a.1 == 2 {
            let h = said[a.0 + 1], w = now[a.1 + 1]
            if similar(h, w) { out.append((h, w)) }
        }
        return out
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let word = { (w: String) in w.count > 1 && w.allSatisfy { $0.isLetter || $0 == "'" } }
        guard a != b, word(a), word(b) else { return false }
        let x = Array(a), y = Array(b)
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]; row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return row[y.count] * 5 <= max(x.count, y.count) * 3   // at most 60% of letters differ ("happen" → "haven't")
    }

    static func selfTest() {
        let w = VoiceGuess.words
        func f(_ a: String, _ b: String) -> [String] { fixes(w(a), w(b)).map { "\($0.0)>\($0.1)" } }
        precondition(f("Oh, dusting it out again.", "Hi there. Oh, testing it out again. More text") == ["dusting>testing"])
        precondition(f("I happen done it yet", "I haven't done it yet") == ["happen>haven't"])
        precondition(f("we should cash the results", "we should store the results") == [])      // a different word, not a fix
        precondition(f("open the chart window", "open the chart window now") == [])            // nothing changed
        precondition(f("dusting it out", "testing it out") == [])                              // first word: no match before it
        print("CorrectionLearner self-test passed")
    }
}

// MARK: Bubble

/// Only when nothing was focused: after you speak, a circle drops from the notch and opens into a small card
/// with the text and Copy for 5 s, then shrinks back into the notch. (With a field focused, text goes there.)
@MainActor @Observable
final class VoiceBubble {
    enum Mode: Equatable {
        case result, failed(String)
        /// Command recall in a terminal: what you asked, then the matches (nil while searching).
        case recall(query: String, matches: [RecallMatch]?, error: String?)
    }
    private(set) var mode: Mode = .result
    private(set) var dropped = false
    private(set) var open = false
    /// 1 → 0 over the time the card stays: drawn as a line around Copy that runs out.
    private(set) var remaining: Double = 1
    static let lifetime: TimeInterval = 5
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var closeWork: DispatchWorkItem?
    @ObservationIgnored let voice: VoiceInput
    /// The terminal that Insert pastes into.
    @ObservationIgnored var recallApp: NSRunningApplication?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var clickMonitor: Any?

    static let size = CGSize(width: 480, height: 260)

    init(voice: VoiceInput) { self.voice = voice }

    /// After you let go with nothing focused: a circle drops from the notch (the one the pointer is under),
    /// opens into a card with the text and Copy, and shrinks back after 5 s.
    func present(_ mode: Mode, on screen: NSRect, notchHeight: CGFloat) {
        closeWork?.cancel()
        self.mode = mode
        open = false
        let p = panel ?? makePanel()
        p.setFrame(NSRect(x: screen.midX - Self.size.width / 2, y: screen.maxY - notchHeight - Self.size.height,
                          width: Self.size.width, height: Self.size.height), display: false)
        p.ignoresMouseEvents = false
        p.orderFrontRegardless()
        // A click anywhere else (other apps; clicks on the card itself are ours) closes it.
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        remaining = 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dropped = true }
        let isRecall = if case .recall = mode { true } else { false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { self?.open = true }
            if !isRecall { withAnimation(.linear(duration: Self.lifetime - 0.15)) { self?.remaining = 0 } }
        }
        // Recall waits for the answer, then stays 20 s (longer while the pointer is on it).
        if !isRecall { scheduleClose(after: Self.lifetime) }
    }

    /// Recall answer arrived.
    func showRecall(query: String, matches: [RecallMatch]?, error: String?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { mode = .recall(query: query, matches: matches, error: error) }
        scheduleClose(after: 20)
    }

    func setHover(_ on: Bool) {
        hovering = on
        if !on, case .recall(_, let m, let e) = mode, m != nil || e != nil { scheduleClose(after: 6) }
    }

    /// Paste the command at the terminal prompt (not run: you press Return).
    func insert(_ command: String) {
        if let app = recallApp { TextInserter.paste(command, into: app) }
        close()
    }

    func copy(_ command: String) {
        copyToClipboard(command)
        close()
    }

    func copyAndClose() {
        copyToClipboard(voice.text)
        close()
    }

    private func scheduleClose(after s: TimeInterval) {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hovering { self.scheduleClose(after: 2) } else { self.close() }
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    /// Card folds back to a circle, the circle rises into the notch.
    func close() {
        closeWork?.cancel()
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { self?.dropped = false }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, !self.dropped else { return }
            self.panel?.orderOut(nil)
            if !self.voice.active { self.voice.clear() }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)  // just under the notch panel
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: VoiceBubbleView(bubble: self))
        panel = p
        return p
    }
}

private struct VoiceBubbleView: View {
    let bubble: VoiceBubble

    var body: some View {
        let v = bubble.voice
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: bubble.open ? 18 : 16, style: .continuous).fill(.black)
                    .overlay(RoundedRectangle(cornerRadius: bubble.open ? 18 : 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
                if bubble.open {
                    content(v).padding(.horizontal, 14).padding(.vertical, 10)
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.1)), removal: .identity))
                }
            }
            .frame(width: bubble.open ? 460 : 32, height: bubble.open ? nil : 32)
            .clipped()
            .onHover { bubble.setHover($0) }
            .frame(minHeight: 32)
            .fixedSize(horizontal: false, vertical: true)
            .scaleEffect(bubble.dropped ? 1 : 0.2, anchor: .top)
            .offset(y: bubble.dropped ? 6 : -30)
            .opacity(bubble.dropped ? 1 : 0)
            Spacer(minLength: 0)
        }
        .frame(width: VoiceBubble.size.width, height: VoiceBubble.size.height)
    }

    @ViewBuilder private func content(_ v: VoiceInput) -> some View {
        if case .recall(let query, let matches, let error) = bubble.mode {
            recall(query, matches, error)
        } else {
            dictation(v)
        }
    }

    @ViewBuilder private func recall(_ query: String, _ matches: [RecallMatch]?, _ error: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                Text(query).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if matches == nil && error == nil { ProgressView().controlSize(.mini) }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
            } else if let matches {
                if matches.isEmpty { Text("Nothing close in your history.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)) }
                ForEach(matches, id: \.self) { m in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.command).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                                .lineLimit(2).textSelection(.enabled)
                            HStack(spacing: 5) {
                                if m.source == "suggested" {
                                    Text("SUGGESTED").font(.system(size: 8, weight: .heavy)).foregroundStyle(.orange)
                                }
                                Text(m.why).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        small("Insert", "text.insert") { bubble.insert(m.command) }
                            .help("Puts it at the prompt without running it")
                        small("Copy", "doc.on.doc") { bubble.copy(m.command) }
                    }
                    .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
                }
            } else {
                Text("Looking through your commands…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private func small(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(.white.opacity(0.14)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func dictation(_ v: VoiceInput) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                switch bubble.mode {
                case .failed(let why): Text(why).foregroundStyle(.orange)
                case .result, .recall: Text(v.text).foregroundStyle(.white)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .lineLimit(5).truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            if bubble.mode == .result, !v.text.isEmpty {
                Button { bubble.copyAndClose() } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).frame(height: 24).background(Capsule().fill(.white.opacity(0.14)))
                        .foregroundStyle(.white)
                        // Time left before the card closes: the line shrinks away, gone when it closes.
                        .overlay(Capsule().trim(from: 0, to: bubble.remaining)
                            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .padding(-2.5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
