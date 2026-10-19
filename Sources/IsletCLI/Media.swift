// `islet media <op> …`: image and PDF tools for the Preview panel. Runs in this short-lived process so
// big renders never stay in the Islet app's memory. Prints one JSON object; never overwrites originals.
import AppKit
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers

private func reply(_ dict: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    exit(dict["ok"] as? Bool == false ? 1 : 0)
}

private func fail(_ msg: String) -> Never { reply(["ok": false, "error": msg]) }

private func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

/// "photo.png" + "-1080p", "jpg" → photo-1080p.jpg next to the original (or in Downloads if that folder
/// isn't writable), with -2, -3… instead of overwriting anything.
private func outputURL(for src: URL, suffix: String, ext: String, directory: Bool = false) -> URL {
    let fm = FileManager.default
    var dir = src.deletingLastPathComponent()
    if !fm.isWritableFile(atPath: dir.path) { dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    let base = src.deletingPathExtension().lastPathComponent + suffix
    var n = 1
    while true {
        let name = n == 1 ? base : "\(base)-\(n)"
        let url = directory ? dir.appendingPathComponent(name, isDirectory: true) : dir.appendingPathComponent(name).appendingPathExtension(ext)
        if !fm.fileExists(atPath: url.path) { return url }
        n += 1
    }
}

private func readPassword() -> String {
    String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .newlines)
}

// MARK: Images

private func loadImage(_ url: URL) -> (CGImage, [String: Any])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: false] as CFDictionary)
    else { return nil }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
    return (img, props)
}

private func type(for ext: String) -> UTType? {
    switch ext.lowercased() {
    case "jpg", "jpeg": .jpeg
    case "png": .png
    case "heic": .heic
    case "webp": .webP
    case "tiff", "tif": .tiff
    default: nil
    }
}

private func canWrite(_ t: UTType) -> Bool {
    (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(t.identifier)
}

private func encode(_ img: CGImage, as t: UTType, quality: Double? = nil, dpi: Double? = nil) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, t.identifier as CFString, 1, nil) else { return nil }
    var props: [CFString: Any] = [:]
    if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
    if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
}

private func scaled(_ img: CGImage, width: Int, height: Int) -> CGImage? {
    let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}

private func imagePDF(_ urls: [URL]) -> PDFDocument {
    let doc = PDFDocument()
    for url in urls {
        autoreleasepool {
            if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                for i in 0..<pdf.pageCount { if let p = pdf.page(at: i)?.copy() as? PDFPage { doc.insert(p, at: doc.pageCount) } }
            } else if let img = NSImage(contentsOf: url), let page = PDFPage(image: img) {
                doc.insert(page, at: doc.pageCount)
            }
        }
    }
    return doc
}

/// Most common colours (4-bit-per-channel buckets on a 48 px thumbnail), skipping near-duplicates.
private func palette(_ url: URL) -> [String] {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 48] as CFDictionary)
    else { return [] }
    let w = thumb.width, h = thumb.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
    var counts: [Int: Int] = [:]
    for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 128 {
        counts[(Int(px[i]) >> 4) << 8 | (Int(px[i + 1]) >> 4) << 4 | Int(px[i + 2]) >> 4, default: 0] += 1
    }
    var picked: [(Int, Int, Int)] = []
    for (key, _) in counts.sorted(by: { $0.value > $1.value }) {
        let c = ((key >> 8 & 15) * 17, (key >> 4 & 15) * 17, (key & 15) * 17)
        if picked.allSatisfy({ abs($0.0 - c.0) + abs($0.1 - c.1) + abs($0.2 - c.2) > 60 }) { picked.append(c) }
        if picked.count == 6 { break }
    }
    return picked.map { String(format: "#%02X%02X%02X", $0.0, $0.1, $0.2) }
}

// MARK: PDF

/// "2-5, 9" → [1,2,3,4,8] (zero-based), clamped to the page count.
private func pages(_ spec: String, count: Int) -> [Int] {
    var out: [Int] = []
    for part in spec.split(separator: ",") {
        let r = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if r.count == 1, (1...count).contains(r[0]) { out.append(r[0] - 1) }
        if r.count == 2 { for p in min(r[0], r[1])...max(r[0], r[1]) where (1...count).contains(p) { out.append(p - 1) } }
    }
    return out
}

private func openPDF(_ url: URL) -> PDFDocument {
    guard let doc = PDFDocument(url: url) else { fail("Couldn't open the PDF") }
    if doc.isLocked { fail("This PDF is password-protected. Remove the password first.") }
    return doc
}

private func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) -> Never {
    guard doc.write(to: url, withOptions: options) else { fail("Couldn't save the PDF") }
    reply(["ok": true, "out": url.path, "bytes": fileSize(url)])
}

// MARK: Entry

func media(_ args: [String]) -> Never {
    guard let op = args.first else { fail("missing operation") }
    let rest = Array(args.dropFirst())
    let src = rest.first.map { URL(fileURLWithPath: $0) }

    switch op {
    case "qr":  // qr TEXT → base64 PNG (software render: no GPU context)
        guard rest.count >= 1 else { fail("missing text") }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(rest[0].utf8)
        f.correctionLevel = "M"
        guard let ci = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(ci, from: ci.extent),
              let png = encode(cg, as: .png) else { fail("Couldn't make the QR code") }
        reply(["ok": true, "png": png.base64EncodedString()])

    case "info":
        guard let src else { fail("missing file") }
        if src.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: src) else { fail("Couldn't open the PDF") }
            let box = doc.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
            reply(["ok": true, "kind": "pdf", "pages": doc.pageCount, "bytes": fileSize(src), "locked": doc.isLocked,
                   "width": Int(box.width), "height": Int(box.height),
                   "hasText": !doc.isLocked && !(doc.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty])
        }
        guard let isrc = CGImageSourceCreateWithURL(src as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(isrc, 0, nil) as? [String: Any] else { fail("Couldn't read the image") }
        reply(["ok": true, "kind": "image", "bytes": fileSize(src),
               "width": p[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
               "height": p[kCGImagePropertyPixelHeight as String] as? Int ?? 0,
               "dpi": p[kCGImagePropertyDPIWidth as String] as? Double ?? 72,
               "profile": p[kCGImagePropertyProfileName as String] as? String ?? (p[kCGImagePropertyColorModel as String] as? String ?? ""),
               "palette": palette(src),
               "writable": ["jpg", "png", "heic", "webp", "tiff"].filter { type(for: $0).map(canWrite) ?? false }])

    case "convert":  // convert FILE FORMAT
        guard let src, rest.count >= 2 else { fail("usage: convert FILE FORMAT") }
        let fmt = rest[1].lowercased()
        if fmt == "pdf" {
            write(imagePDF([src]), to: outputURL(for: src, suffix: "", ext: "pdf"))
        }
        guard let t = type(for: fmt), canWrite(t) else { fail("\(fmt.uppercased()) isn't supported for writing on this Mac") }
        guard let (img, props) = loadImage(src),
              let data = encode(img, as: t, quality: t == .png || t == .tiff ? nil : 0.9, dpi: props[kCGImagePropertyDPIWidth as String] as? Double)
        else { fail("Couldn't convert") }
        let out = outputURL(for: src, suffix: "", ext: fmt == "jpeg" ? "jpg" : fmt)
        do { try data.write(to: out) } catch { fail(error.localizedDescription) }
        reply(["ok": true, "out": out.path, "bytes": data.count])

    case "resize":  // resize FILE WIDTH HEIGHT(0 = keep ratio) | resize FILE icons | resize FILE scale 0.5
        guard let src, rest.count >= 2, let (img, _) = loadImage(src) else { fail("Couldn't read the image") }
        let t = type(for: src.pathExtension).flatMap { canWrite($0) ? $0 : nil } ?? .png
        let ext = src.pathExtension.isEmpty ? "png" : src.pathExtension.lowercased()
        if rest[1] == "icons" {
            let dir = outputURL(for: src, suffix: "-icons", ext: "", directory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for s in [1024, 512, 256, 128, 64, 32, 16] {
                autoreleasepool {
                    if let small = scaled(img, width: s, height: s), let d = encode(small, as: .png) {
                        try? d.write(to: dir.appendingPathComponent("icon-\(s).png"))
                    }
                }
            }
            reply(["ok": true, "out": dir.path])
        }
        var w: Int, h: Int
        var suffix: String
        if rest[1] == "scale", rest.count >= 3, let f = Double(rest[2]) {
            w = Int(Double(img.width) * f); h = Int(Double(img.height) * f); suffix = "-\(Int(f * 100))pct"
        } else {
            w = Int(rest[1]) ?? 0; h = rest.count >= 3 ? Int(rest[2]) ?? 0 : 0
            if w > 0 && h == 0 { h = Int(Double(img.height) * Double(w) / Double(img.width)) }
            if h > 0 && w == 0 { w = Int(Double(img.width) * Double(h) / Double(img.height)) }
            suffix = "-\(w)x\(h)"
        }
        guard w > 0, h > 0, w <= 20_000, h <= 20_000, let out = scaled(img, width: w, height: h),
              let data = encode(out, as: t, quality: t == .png ? nil : 0.9) else { fail("Invalid size") }
        let url = outputURL(for: src, suffix: suffix, ext: ext)
        do { try data.write(to: url) } catch { fail(error.localizedDescription) }
        reply(["ok": true, "out": url.path, "bytes": data.count, "width": w, "height": h])

    case "compress":  // compress FILE QUALITY [--dry]   (lossy: keeps JPG/HEIC/WebP, PNG → JPG)
        guard let src, rest.count >= 2, let q = Double(rest[1]), let (img, props) = loadImage(src) else { fail("Couldn't read the image") }
        let own = type(for: src.pathExtension)
        let t: UTType = own == .heic || own == .webP ? own! : .jpeg
        guard let data = encode(img, as: t, quality: max(0.05, min(q, 1)), dpi: props[kCGImagePropertyDPIWidth as String] as? Double)
        else { fail("Couldn't compress") }
        if rest.contains("--dry") { reply(["ok": true, "bytes": data.count, "original": fileSize(src)]) }
        let url = outputURL(for: src, suffix: "-small", ext: t == .jpeg ? "jpg" : t == .heic ? "heic" : "webp")
        do { try data.write(to: url) } catch { fail(error.localizedDescription) }
        reply(["ok": true, "out": url.path, "bytes": data.count, "original": fileSize(src)])

    case "target":  // target FILE MAXBYTES  → best quality under the limit, scaling down only if needed
        guard let src, rest.count >= 2, let limit = Int(rest[1]), var (img, _) = loadImage(src) else { fail("Couldn't read the image") }
        let own = type(for: src.pathExtension)
        let t: UTType = own == .heic ? .heic : .jpeg
        var best: Data?
        for _ in 0..<6 {
            var lo = 0.05, hi = 0.95
            for _ in 0..<7 {
                let mid = (lo + hi) / 2
                if let d = encode(img, as: t, quality: mid), d.count <= limit { best = d; lo = mid } else { hi = mid }
            }
            if best != nil { break }
            guard let smaller = scaled(img, width: Int(Double(img.width) * 0.75), height: Int(Double(img.height) * 0.75)) else { break }
            img = smaller
        }
        guard let best else { fail("Couldn't get under the limit") }
        let label = limit >= 1_000_000 ? "\(limit / 1_000_000)MB" : "\(limit / 1000)KB"
        let url = outputURL(for: src, suffix: "-under\(label)", ext: t == .heic ? "heic" : "jpg")
        do { try best.write(to: url) } catch { fail(error.localizedDescription) }
        reply(["ok": true, "out": url.path, "bytes": best.count, "width": img.width, "height": img.height])

    case "images-pdf":  // images-pdf FILE… → one PDF (images and PDFs, in order)
        let urls = rest.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { fail("no files") }
        let doc = imagePDF(urls)
        guard doc.pageCount > 0 else { fail("No images or PDFs to combine") }
        write(doc, to: outputURL(for: first, suffix: urls.count > 1 ? "-combined" : "", ext: "pdf"))

    case "pdf-images":  // pdf-images FILE png|jpg DPI
        guard let src, rest.count >= 3, let dpi = Double(rest[2]), let t = type(for: rest[1]) else { fail("usage: pdf-images FILE png|jpg DPI") }
        let doc = openPDF(src)
        let dir = outputURL(for: src, suffix: "-pages", ext: "", directory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            autoreleasepool {
                guard let page = doc.page(at: i) else { return }
                let box = page.bounds(for: .mediaBox)
                let w = Int(box.width * dpi / 72), h = Int(box.height * dpi / 72)
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: dpi / 72, y: dpi / 72)
                page.draw(with: .mediaBox, to: ctx)
                if let img = ctx.makeImage(), let d = encode(img, as: t, quality: t == .jpeg ? 0.9 : nil, dpi: dpi) {
                    try? d.write(to: dir.appendingPathComponent(String(format: "page-%03d.\(rest[1] == "jpg" ? "jpg" : "png")", i + 1)))
                }
            }
        }
        reply(["ok": true, "out": dir.path, "pages": doc.pageCount])

    case "pdf-text":  // pdf-text FILE copy|txt|md   (copy → text on stdout)
        guard let src, rest.count >= 2 else { fail("usage: pdf-text FILE copy|txt|md") }
        let doc = openPDF(src)
        if rest[1] == "copy" { reply(["ok": true, "text": doc.string ?? "", "pages": doc.pageCount]) }
        let text: String
        if rest[1] == "md" {
            text = "# \(src.deletingPathExtension().lastPathComponent)\n\n" + (0..<doc.pageCount).map {
                "## Page \($0 + 1)\n\n\(doc.page(at: $0)?.string ?? "")"
            }.joined(separator: "\n\n")
        } else {
            text = doc.string ?? ""
        }
        let url = outputURL(for: src, suffix: "", ext: rest[1] == "md" ? "md" : "txt")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { fail(error.localizedDescription) }
        reply(["ok": true, "out": url.path, "bytes": fileSize(url)])

    case "pdf-extract":  // pdf-extract FILE "2-5, 9"
        guard let src, rest.count >= 2 else { fail("usage: pdf-extract FILE PAGES") }
        let doc = openPDF(src)
        let picks = pages(rest[1], count: doc.pageCount)
        guard !picks.isEmpty else { fail("No valid pages (this PDF has \(doc.pageCount))") }
        let out = PDFDocument()
        for i in picks { if let p = doc.page(at: i)?.copy() as? PDFPage { out.insert(p, at: out.pageCount) } }
        write(out, to: outputURL(for: src, suffix: "-pages-" + rest[1].replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: "_"), ext: "pdf"))

    case "pdf-split":  // pdf-split FILE → folder with one PDF per page
        guard let src else { fail("missing file") }
        let doc = openPDF(src)
        let dir = outputURL(for: src, suffix: "-split", ext: "", directory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            autoreleasepool {
                let one = PDFDocument()
                if let p = doc.page(at: i)?.copy() as? PDFPage { one.insert(p, at: 0) }
                one.write(to: dir.appendingPathComponent(String(format: "page-%03d.pdf", i + 1)))
            }
        }
        reply(["ok": true, "out": dir.path, "pages": doc.pageCount])

    case "pdf-merge":  // pdf-merge FILE… (first file names the result)
        let urls = rest.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first, urls.count >= 2 else { fail("Need at least two files") }
        write(imagePDF(urls), to: outputURL(for: first, suffix: "-merged", ext: "pdf"))

    case "pdf-encrypt":  // pdf-encrypt FILE   (password on stdin, never on the command line)
        guard let src else { fail("missing file") }
        let pw = readPassword()
        guard !pw.isEmpty else { fail("Empty password") }
        let doc = openPDF(src)
        write(doc, to: outputURL(for: src, suffix: "-protected", ext: "pdf"),
              options: [.userPasswordOption: pw, .ownerPasswordOption: pw])

    case "pdf-decrypt":  // pdf-decrypt FILE   (password on stdin)
        guard let src, let doc = PDFDocument(url: src) else { fail("Couldn't open the PDF") }
        guard doc.isEncrypted || doc.isLocked else { fail("This PDF has no password") }
        guard doc.unlock(withPassword: readPassword()) else { fail("Wrong password") }
        // Copying the pages into a fresh document drops the encryption.
        let open = PDFDocument()
        for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { open.insert(p, at: open.pageCount) } }
        write(open, to: outputURL(for: src, suffix: "-unlocked", ext: "pdf"))

    default:
        fail("unknown media operation: \(op)")
    }
}
