import AppKit
import SwiftUI

/// Runs `islet media …` (the bundled CLI) so image/PDF work never loads into Islet's memory.
func mediaTool(_ args: [String], stdin: String? = nil) async -> [String: Any] {
    let cli = Bundle.main.bundlePath + "/Contents/Helpers/islet"
    let data: Data? = await Task.detached {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["media"] + args
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = inPipe
        guard (try? p.run()) != nil else { return nil }
        if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? inPipe.fileHandleForWriting.close()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return data
    }.value
    guard let data else { return ["ok": false, "error": "Islet helper missing"] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? ["ok": false, "error": "No result"]
}

func byteString(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

/// "/Users/me/Downloads" → "~/Downloads".
func shortPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

/// Preview context: actions for the open image or PDF. Every action writes a new file next to the original.
struct PreviewPanel: View {
    let model: NotchModel
    let file: URL

    private enum Mode { case main, resize, compress, pages, password }
    private let mode = State(initialValue: Mode.main)
    private let direction = State(initialValue: 1)
    private let info = State<[String: Any]>(initialValue: [:])
    private let busy = State<String?>(initialValue: nil)
    private let result = State<(text: String, out: String?, ok: Bool)?>(initialValue: nil)
    private let width = State(initialValue: "")
    private let height = State(initialValue: "")
    private let quality = State(initialValue: 0.7)
    private let estimate = State<Int?>(initialValue: nil)
    private let pageSpec = State(initialValue: "")
    private let password = State(initialValue: "")
    private let dpi = State(initialValue: 150)
    private let format = State(initialValue: "png")  // see Scrubber: no @State without Xcode

    private var isPDF: Bool { file.pathExtension.lowercased() == "pdf" }

    var body: some View {
        let d = direction.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                Group {
                    switch mode.wrappedValue {
                    case .main: isPDF ? AnyView(pdfMain) : AnyView(imageMain)
                    case .resize: AnyView(resizeView)
                    case .compress: AnyView(compressView)
                    case .pages: AnyView(pagesView)
                    case .password: AnyView(passwordView)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(mode.wrappedValue)
                .transition(.asymmetric(insertion: .move(edge: d > 0 ? .trailing : .leading).combined(with: .opacity),
                                        removal: .move(edge: d > 0 ? .leading : .trailing).combined(with: .opacity)))
            }
            .clipped()
            statusLine
        }
        .task(id: file) { await loadInfo() }
    }

    // MARK: Images

    private var imageMain: some View {
        let i = info.wrappedValue
        let writable = i["writable"] as? [String] ?? ["jpg", "png", "heic"]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(imageInfoLine(i)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 4)
                ForEach(i["palette"] as? [String] ?? [], id: \.self) { hex in
                    Button { copyToClipboard(hex); flash("\(hex) copied") } label: {
                        RoundedRectangle(cornerRadius: 4).fill(Color(hex: hex)).frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain).help("\(hex) · click to copy")
                }
            }
            row("Convert") {
                ForEach(["jpg", "png", "heic", "webp", "tiff"].filter { writable.contains($0) && $0 != file.pathExtension.lowercased() }, id: \.self) { f in
                    chip(f.uppercased(), nil) { run(["convert", file.path, f], label: "Converting…") }
                }
                chip("PDF", nil) { run(["convert", file.path, "pdf"], label: "Making PDF…") }
            }
            row("Resize") {
                chip("50%", nil) { run(["resize", file.path, "scale", "0.5"], label: "Resizing…") }
                chip("1080p", nil) { run(["resize", file.path, "0", "1080"], label: "Resizing…") }
                chip("720p", nil) { run(["resize", file.path, "0", "720"], label: "Resizing…") }
                chip("Icon set", "app.dashed") { run(["resize", file.path, "icons"], label: "Making icons…") }
                chip("Custom…", "arrow.up.left.and.arrow.down.right") {
                    width.wrappedValue = "\(i["width"] as? Int ?? 0)"; height.wrappedValue = ""; go(.resize)
                }
            }
            row("Shrink") {
                chip("Compress…", "slider.horizontal.3") { go(.compress); Task { await updateEstimate() } }
                chip("Under 1 MB", nil) { run(["target", file.path, "1000000"], label: "Shrinking…") }
                chip("Under 500 KB", nil) { run(["target", file.path, "500000"], label: "Shrinking…") }
            }
        }
    }

    private var resizeView: some View {
        VStack(alignment: .leading, spacing: 8) {
            header("Resize", detail: "\(info.wrappedValue["width"] as? Int ?? 0)×\(info.wrappedValue["height"] as? Int ?? 0) now")
            HStack(spacing: 8) {
                field("Width", width)
                Text("×").foregroundStyle(.white.opacity(0.5))
                field("Height (auto)", height)
                Text("px").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                chip("Resize", "checkmark", tint: .green) {
                    run(["resize", file.path, width.wrappedValue.isEmpty ? "0" : width.wrappedValue,
                         height.wrappedValue.isEmpty ? "0" : height.wrappedValue], label: "Resizing…") { back() }
                }
            }
            Text("Leave one side empty to keep proportions.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var compressView: some View {
        let original = info.wrappedValue["bytes"] as? Int ?? 0
        let label = quality.wrappedValue > 0.75 ? "High" : quality.wrappedValue > 0.45 ? "Medium" : "Small"
        return VStack(alignment: .leading, spacing: 8) {
            header("Compress", detail: "now \(byteString(original))")
            HStack(spacing: 10) {
                Text(label).font(.system(size: 11, weight: .semibold)).frame(width: 52, alignment: .leading)
                Slider(value: Binding(get: { quality.wrappedValue }, set: { quality.wrappedValue = $0 }), in: 0.1...0.95,
                       onEditingChanged: { editing in if !editing { Task { await updateEstimate() } } })
                    .controlSize(.small)
                Text(estimate.wrappedValue.map { "≈ \(byteString($0))" } ?? "…").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 80, alignment: .trailing)
                    .foregroundStyle((estimate.wrappedValue ?? 0) < original ? .green : .orange)
                chip("Save", "checkmark", tint: .green) {
                    run(["compress", file.path, String(quality.wrappedValue)], label: "Compressing…") { back() }
                }
            }
            HStack(spacing: 6) {
                chip("Under 1 MB", nil) { run(["target", file.path, "1000000"], label: "Shrinking…") { back() } }
                chip("Under 500 KB", nil) { run(["target", file.path, "500000"], label: "Shrinking…") { back() } }
                Text("PNG saves as JPG; HEIC stays HEIC.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: PDF

    private var pdfMain: some View {
        let i = info.wrappedValue
        let locked = i["locked"] as? Bool ?? false
        return VStack(alignment: .leading, spacing: 6) {
            Text(pdfInfoLine(i)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            if locked {
                row("Locked") { chip("Remove password…", "lock.open") { password.wrappedValue = ""; go(.password) } }
            } else {
                row("Images") {
                    Picker("", selection: Binding(get: { format.wrappedValue }, set: { format.wrappedValue = $0 })) {
                        Text("PNG").tag("png"); Text("JPG").tag("jpg")
                    }.pickerStyle(.segmented).frame(width: 96).labelsHidden()
                    Picker("", selection: Binding(get: { dpi.wrappedValue }, set: { dpi.wrappedValue = $0 })) {
                        Text("72").tag(72); Text("150").tag(150); Text("300").tag(300)
                    }.pickerStyle(.segmented).frame(width: 120).labelsHidden()
                    Text("dpi").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    chip("Export pages", "photo.on.rectangle") {
                        run(["pdf-images", file.path, format.wrappedValue, "\(dpi.wrappedValue)"], label: "Rendering pages…")
                    }
                }
                row("Text") {
                    chip("Copy all text", "doc.on.doc") {
                        Task {
                            busy.wrappedValue = "Reading text…"
                            model.beginWork("Reading text…")
                            let r = await mediaTool(["pdf-text", file.path, "copy"])
                            model.endWork()
                            busy.wrappedValue = nil
                            if let t = r["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                copyToClipboard(t); flash("Copied \(t.count) characters")
                            } else { flash(r["error"] as? String ?? "No text in this PDF (scanned?)", ok: false) }
                        }
                    }
                    chip(".txt", nil) { run(["pdf-text", file.path, "txt"], label: "Saving text…") }
                    chip("Markdown", nil) { run(["pdf-text", file.path, "md"], label: "Saving Markdown…") }
                }
                row("Pages") {
                    chip("Extract / split…", "doc.on.doc.fill") { pageSpec.wrappedValue = ""; go(.pages) }
                    chip("Merge…", "plus.rectangle.on.rectangle") { mergeWithPicker() }
                    chip("Password…", "lock") { password.wrappedValue = ""; go(.password) }
                }
                Text("Tip: drag PDFs or images onto the notch to merge them into this PDF.")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var pagesView: some View {
        let count = info.wrappedValue["pages"] as? Int ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            header("Pages", detail: "\(count) page\(count == 1 ? "" : "s")")
            HStack(spacing: 8) {
                field("e.g. 2-5, 9", pageSpec, width: 140)
                chip("Extract", "doc.badge.plus", tint: .green) {
                    guard !pageSpec.wrappedValue.isEmpty else { return }
                    run(["pdf-extract", file.path, pageSpec.wrappedValue], label: "Extracting…") { back() }
                }
                chip("Split every page", "square.split.2x1") { run(["pdf-split", file.path], label: "Splitting…") { back() } }
            }
            Text("Extract makes one new PDF from those pages. Split makes one PDF per page in a folder.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
    }

    private var passwordView: some View {
        let locked = (info.wrappedValue["locked"] as? Bool ?? false)
        return VStack(alignment: .leading, spacing: 8) {
            header(locked ? "Remove password" : "Password", detail: locked ? "enter the current password" : "")
            HStack(spacing: 8) {
                SecureField("Password", text: Binding(get: { password.wrappedValue }, set: { password.wrappedValue = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).frame(width: 180, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
                    .onExitCommand(perform: model.endEditing)
                if !locked {
                    chip("Add password", "lock.fill", tint: .green) {
                        guard !password.wrappedValue.isEmpty else { return }
                        run(["pdf-encrypt", file.path], stdin: password.wrappedValue, label: "Encrypting…") { password.wrappedValue = ""; back() }
                    }
                }
                chip("Remove password", "lock.open") {
                    guard !password.wrappedValue.isEmpty else { return }
                    run(["pdf-decrypt", file.path], stdin: password.wrappedValue, label: "Unlocking…") { password.wrappedValue = ""; back() }
                }
            }
            Text("Saves a new copy. The password is passed privately (never on the command line) and isn't stored.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: Status

    @ViewBuilder private var statusLine: some View {
        if let b = busy.wrappedValue {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(b).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)) }
        } else if let r = result.wrappedValue {
            HStack(spacing: 8) {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(r.ok ? .green : .orange)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.text).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    if let out = r.out {
                        Text("in \(shortPath(URL(fileURLWithPath: out).deletingLastPathComponent().path)) · added to the Shelf")
                            .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if let out = r.out {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: out)]) }
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: out)) }
                }
            }
            .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .transition(.opacity)
        }
    }

    // MARK: Actions

    private func loadInfo() async {
        info.wrappedValue = await mediaTool(["info", file.path])
        estimate.wrappedValue = nil
    }

    private func updateEstimate() async {
        estimate.wrappedValue = nil
        let r = await mediaTool(["compress", file.path, String(quality.wrappedValue), "--dry"])
        estimate.wrappedValue = r["bytes"] as? Int
    }

    private func run(_ args: [String], stdin: String? = nil, label: String, then: @escaping @MainActor () -> Void = {}) {
        guard busy.wrappedValue == nil else { return }
        withAnimation { busy.wrappedValue = label; result.wrappedValue = nil }
        model.beginWork(label)
        let model = self.model
        Task {
            let r = await mediaTool(args, stdin: stdin)
            busy.wrappedValue = nil
            if r["ok"] as? Bool == true, let out = r["out"] as? String {
                let name = URL(fileURLWithPath: out).lastPathComponent
                let size = (r["bytes"] as? Int).map { " · \(byteString($0))" } ?? ""
                withAnimation { result.wrappedValue = ("Saved \(name)\(size)", out, true) }
                model.deliver([URL(fileURLWithPath: out)])
                then()
            } else {
                model.endWork()
                withAnimation { result.wrappedValue = (r["error"] as? String ?? "Failed", nil, false) }
            }
        }
    }

    private func mergeWithPicker() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose PDFs or images to add after \(file.lastPathComponent)"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        run(["pdf-merge", file.path] + panel.urls.map(\.path), label: "Merging…")
    }

    private func flash(_ text: String, ok: Bool = true) {
        withAnimation { result.wrappedValue = (text, nil, ok) }
    }

    private func go(_ m: Mode) {
        let d = m == .main ? -1 : 1
        result.wrappedValue = nil
        if d == direction.wrappedValue {
            withAnimation(NotchModel.tabSpring) { mode.wrappedValue = m }
        } else {
            direction.wrappedValue = d
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { withAnimation(NotchModel.tabSpring) { mode.wrappedValue = m } }
        }
    }

    private func back() {
        let hadField = mode.wrappedValue != .compress
        go(.main)
        if hadField { model.leaveTextField() }
        Task { await loadInfo() }
    }

    // MARK: Pieces

    private func imageInfoLine(_ i: [String: Any]) -> String {
        guard let w = i["width"] as? Int else { return "Reading…" }
        let dpi = (i["dpi"] as? Double).map { "\(Int($0)) dpi" } ?? ""
        return "\(w)×\(i["height"] as? Int ?? 0) · \(byteString(i["bytes"] as? Int ?? 0)) · \(dpi) · \(i["profile"] as? String ?? "")"
    }

    private func pdfInfoLine(_ i: [String: Any]) -> String {
        guard let p = i["pages"] as? Int else { return "Reading…" }
        let w = Double(i["width"] as? Int ?? 0), h = Double(i["height"] as? Int ?? 0)
        let size = abs(w - 595) < 4 && abs(h - 842) < 4 ? "A4" : abs(w - 612) < 4 && abs(h - 792) < 4 ? "Letter" : "\(Int(w))×\(Int(h)) pt"
        let text = (i["locked"] as? Bool ?? false) ? "password-protected" : (i["hasText"] as? Bool ?? false) ? "has text" : "scanned / no text"
        return "\(p) page\(p == 1 ? "" : "s") · \(byteString(i["bytes"] as? Int ?? 0)) · \(size) · \(text)"
    }

    private func header(_ title: String, detail: String) -> some View {
        HStack(spacing: 8) {
            Button { back() } label: {
                Label("Back", systemImage: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(.white.opacity(0.12))).contentShape(Capsule())
            }
            .buttonStyle(.plain)
            Text("Preview ›").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            Spacer()
        }
    }

    private func field(_ placeholder: String, _ s: State<String>, width w: CGFloat = 90) -> some View {
        TextField(placeholder, text: Binding(get: { s.wrappedValue }, set: { s.wrappedValue = $0 }))
            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 8).frame(width: w, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            .onExitCommand(perform: model.endEditing)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(width: 44, alignment: .leading)
            content()
        }
    }

    private func chip(_ title: String, _ symbol: String?, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(tint == .white ? .white.opacity(0.1) : tint.opacity(0.22)))
            .foregroundStyle(tint == .white ? .white : tint)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy.wrappedValue != nil)
    }
}
