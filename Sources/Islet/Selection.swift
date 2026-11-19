import AppKit
import ApplicationServices
import SwiftUI

/// Text selected in the front app when the hotkey was pressed, and what TextTools found in it.
struct SelectedText {
    let text: String
    let element: AXUIElement?   // set when read through Accessibility: replace writes back the same way
    let app: NSRunningApplication
    let project: String?
    let findings: [Finding]
}

@MainActor
enum Selection {
    /// Selected text via Accessibility; apps that don't expose it (Chrome, VS Code, Electron) get a ⌘C that
    /// puts your clipboard back afterwards. nil when nothing is selected or nothing useful was found.
    static func read(project: String?) async -> SelectedText? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              AXIsProcessTrusted() else { return nil }
        let clipboard = NSPasteboard.general.string(forType: .string)
        var text: String?, element: AXUIElement?
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
            let e = f as! AXUIElement  // swiftlint:disable:this force_cast
            var sel: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXSelectedTextAttribute as CFString, &sel) == .success, let s = sel as? String, !s.isEmpty {
                text = s; element = e
            }
        }
        if text == nil { text = await copyWithKeystroke(app) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let findings = TextTools.detect(text, project: project, clipboard: clipboard)
        debugLog("selection: \(app.bundleIdentifier ?? "?") via \(element == nil ? "⌘C" : "AX") \(text.count) chars → \(findings.map(\.kind))")
        guard !findings.isEmpty else { return nil }
        return SelectedText(text: text, element: element, app: app, project: project, findings: findings)
    }

    private static func key(_ code: CGKeyCode, to app: NSRunningApplication) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = .maskCommand
            e?.postToPid(app.processIdentifier)
        }
    }

    /// Every item and type on the clipboard, to put back after we borrow it.
    private static func snapshot() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    private static func restore(_ snap: [[(NSPasteboard.PasteboardType, Data)]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(snap.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }

    private static func copyWithKeystroke(_ app: NSRunningApplication) async -> String? {
        let pb = NSPasteboard.general
        let snap = snapshot(), before = pb.changeCount
        key(8, to: app)  // ⌘C
        for _ in 0..<15 {  // up to 300 ms for the app to copy
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before { break }
        }
        guard pb.changeCount != before else { return nil }  // nothing selected
        let text = pb.string(forType: .string)
        restore(snap)
        return text
    }

    /// Writes `text` over the selection: Accessibility where the selection came from there, else a paste
    /// (clipboard restored after).
    static func replace(_ sel: SelectedText, with text: String) {
        if let e = sel.element, AXUIElementSetAttributeValue(e, kAXSelectedTextAttribute as CFString, text as CFString) == .success { return }
        let snap = snapshot()
        sel.app.activate()
        copyToClipboard(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            key(9, to: sel.app)  // ⌘V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { restore(snap) }
        }
    }

    static func run(_ act: Finding.Act, tasks: TaskStore) {
        switch act {
        case .open(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .reveal(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        case .run(let cmd, let cwd): shell(cmd, cwd: cwd, project: URL(fileURLWithPath: cwd).lastPathComponent, tasks: tasks)
        case .openFile(let path, let line, let col):
            // VS Code (or Cursor) opens at the line through its URL scheme; otherwise the default app.
            let scheme = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil ? "vscode"
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92") != nil ? "cursor" : nil
            let loc = line.map { ":\($0)" + (col.map { ":\($0)" } ?? "") } ?? ""
            if let scheme, let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let url = URL(string: "\(scheme)://file\(enc)\(loc)") {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
        }
    }
}

// MARK: Panel

struct SelectionPanel: View {
    let model: NotchModel
    let sel: SelectedText
    let done: (String) -> Void
    private let picked = State(initialValue: 0)  // see Scrubber: no @State without Xcode

    var body: some View {
        let f = sel.findings[min(picked.wrappedValue, sel.findings.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            if sel.findings.count > 1 {
                HStack(spacing: 5) {
                    ForEach(Array(sel.findings.enumerated()), id: \.element.id) { i, x in
                        Button { picked.wrappedValue = i } label: {
                            Text(x.kind).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).frame(height: 20)
                                .background(Capsule().fill(.white.opacity(x.id == f.id ? 0.22 : 0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            let link = f.items.first { if case .link = $0 { true } else { false } }
            let rest = f.items.filter { if case .link = $0 { false } else { true } }
            HStack(alignment: .top, spacing: 10) {
                if let link { row(link).frame(width: 350) }  // sharing left, everything else (GitHub, port) right
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(rest.enumerated()), id: \.offset) { _, item in row(item) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(sel.text)
    }

    @ViewBuilder private func row(_ item: Finding.Item) -> some View {
        switch item {
        case .value(let label, let value, let replace):
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(value).font(.system(size: 10.5, design: .monospaced)).lineLimit(5).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                small("Copy", "doc.on.doc") { copyToClipboard(value); done("Copied") }
                if replace && value != sel.text {
                    small("Replace", "arrow.uturn.left") {
                        model.unlock(pointerInside: false)
                        Selection.replace(sel, with: value)
                    }
                }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        case .action(let title, let symbol, let act):
            small(title, symbol) { Selection.run(act, tasks: model.services.tasks); done("Done") }
        case .warning(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
        case .image(let data):
            if let img = NSImage(data: data) { Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 70) }
        case .port(let n):
            PortRow(port: n, done: done)
        case .swatch(let c, let hex):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.25)))
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("HEX").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                    Text(hex).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                }
                Spacer(minLength: 4)
                small("Copy", "doc.on.doc") { copyToClipboard(hex); done("Copied") }
                if hex != sel.text { small("Replace", "arrow.uturn.left") { model.unlock(pointerInside: false); Selection.replace(sel, with: hex) } }
            }
            .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        case .link(let u):
            LinkRow(url: u, tunnel: model.services.tunnel, done: done)
        case .repo(let owner, let name):
            GitHubRepoCard(owner: owner, name: name)
        }
    }

    private func small(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Capsule().fill(.white.opacity(0.1))).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// What's listening on a port, with Stop.
private struct PortRow: View {
    let port: Int
    let done: (String) -> Void
    private let owners = State<[ListeningPort]?>(initialValue: nil)

    var body: some View {
        HStack(spacing: 8) {
            if let list = owners.wrappedValue {
                if list.isEmpty {
                    Text(verbatim: "Nothing is listening on \(port)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(list) { p in
                    Text(verbatim: "\(p.command) (pid \(p.pid))").font(.system(size: 11, design: .monospaced))
                    Button("Stop") { Ports.kill(p.pid); owners.wrappedValue = list.filter { $0 != p }; done("Stopped") }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.red)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task { owners.wrappedValue = await Ports.scan().filter { $0.port == port } }
    }
}

/// A link: open, open private, send to iPhone (AirDrop), copy, QR; for localhost also the same-Wi-Fi address and a
/// public tunnel link. Phones get the public link, else the Wi-Fi one. Compact: QR sits on the right.
struct LinkRow: View {
    let url: String
    let tunnel: TunnelService
    let done: (String) -> Void
    private let qr = State<NSImage?>(initialValue: nil)
    private let qrFor = State(initialValue: "")

    var body: some View {
        let local = URL(string: url).flatMap(\.host).map { ["localhost", "127.0.0.1", "0.0.0.0"].contains($0) } ?? false
        let port = URLComponents(string: url)?.port ?? 80
        let lan = Browser.networkURL(url)
        let live: String? = if case .live(let p, let u) = tunnel.state, p == port, local {
            u + (URLComponents(string: url).map { $0.percentEncodedPath + ($0.percentEncodedQuery.map { "?" + $0 } ?? "") } ?? "")
        } else { nil }
        let phone = live ?? lan ?? url
        let privateBrowser = Browser.all.first { $0.id != "com.apple.Safari" }
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(url).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.7)).textSelection(.enabled)
                HStack(spacing: 4) {
                    chip("Open", "safari") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
                    if let b = privateBrowser {
                        chip("Private", "eye.slash") { Task { await Browser.openPrivate(url, appName: b.name == "Chrome" ? "Google Chrome" : "Brave Browser") } }
                    }
                }
                HStack(spacing: 4) {
                    chip("Send to iPhone", "iphone") { if let u = URL(string: phone) { AirDrop.send([u]) } }
                    chip("Copy", "doc.on.doc") { copyToClipboard(cleanURL(url)); done("Copied") }
                }
                if local {
                    if let lan { line("Wi-Fi", lan) }
                    switch tunnel.state {
                    case .live(let p, _) where p == port:
                        HStack(spacing: 4) {
                            line("Public", live ?? "")
                            icon("stop.fill") { tunnel.stop() }
                        }
                    case .starting(let p) where p == port:
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Opening tunnel…").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.6))
                        }
                    default:
                        HStack(spacing: 5) {
                            chip("Share publicly", "globe") { tunnel.start(port: port) }
                            if case .failed(let why) = tunnel.state { Text(why).font(.system(size: 9.5)).foregroundStyle(.red).lineLimit(1) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                if let img = qr.wrappedValue { Image(nsImage: img).interpolation(.none).resizable().frame(width: 62, height: 62) }
                Text(live != nil ? "public" : lan != nil ? "same Wi-Fi" : "scan").font(.system(size: 8)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        .task(id: phone) {
            guard phone != qrFor.wrappedValue else { return }
            let r = await mediaTool(["qr", phone])
            if let b64 = r["png"] as? String, let data = Data(base64Encoded: b64) { qr.wrappedValue = NSImage(data: data); qrFor.wrappedValue = phone }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).frame(width: 34, alignment: .leading)
            Text(value).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            icon("doc.on.doc") { copyToClipboard(value); done("Copied") }
        }
    }

    private func chip(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 10, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 7).frame(height: 20)
                .background(Capsule().fill(.white.opacity(0.1))).contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func icon(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 9)).frame(width: 18, height: 18).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
    }
}
