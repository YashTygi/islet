import AppKit
import SwiftUI
import ImageIO

/// What is playing right now. Views read this; only MediaService writes it.
@MainActor @Observable
final class NowPlaying {
    var title: String?
    var artist: String?
    var bundleID: String?
    var appIcon: NSImage?
    var isPlaying = false
    var duration: Double = 0
    var rate: Double = 1
    var artwork: NSImage?
    var accent: Color = .white
    /// Elapsed seconds at `anchor`. Position is derived, never ticked.
    var elapsed: Double = 0
    var anchor = Date()
    /// Playing now, or stopped less than 2 s ago (avoids pill flicker between tracks).
    private(set) var isActive = false

    @ObservationIgnored var onActiveChange: (Bool) -> Void = { _ in }
    @ObservationIgnored private var deactivate: Task<Void, Never>?

    func position(at date: Date) -> Double {
        let p = elapsed + (isPlaying ? rate * date.timeIntervalSince(anchor) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }

    fileprivate func updateActivity() {
        deactivate?.cancel()
        if isPlaying {
            setActive(true)
        } else if isActive {
            deactivate = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.setActive(false)
            }
        }
    }

    private func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        onActiveChange(on)
    }
}

/// Owns exactly one `perl mediaremote-adapter.pl … stream` helper.
/// Restarts it with backoff if it dies, and kills it if its footprint passes 50 MB
/// (NotchNook's copy of this helper reached 2.35 GB).
@MainActor
final class MediaService {
    let state = NowPlaying()

    private static let footprintLimit: UInt64 = 50 << 20
    private let script: String
    private let framework: String
    private var process: Process?
    private var startedAt = Date()
    private var backoff: Double = 1
    private var stopping = false
    private var watchdog: Timer?
    private var raw: [String: Any] = [:]

    init() {
        let res = Bundle.main.resourcePath ?? ""
        script = res + "/mediaremote-adapter.pl"
        framework = res + "/MediaRemoteAdapter.framework"
    }

    func start() {
        guard FileManager.default.fileExists(atPath: script) else { return }
        // A previous run killed with SIGTERM can leave an orphaned helper behind.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", script]
        try? pkill.run()
        pkill.waitUntilExit()

        launch()
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFootprint() }
        }
    }

    func stop() {
        stopping = true
        watchdog?.invalidate()
        process?.terminate()
    }

    // MARK: Commands (short-lived helper per command)

    func togglePlayPause() {
        state.elapsed = state.position(at: .now)
        state.anchor = .now
        state.isPlaying.toggle()
        run(["send", "2"])
    }

    func next() { run(["send", "4"]) }
    func previous() { run(["send", "5"]) }

    func seek(to seconds: Double) {
        state.elapsed = seconds
        state.anchor = .now
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    private func run(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Stream helper lifecycle

    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script, framework, "stream", "--micros", "--debounce=50"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        let reader = LineReader { [weak self] update in
            Task { @MainActor in self?.apply(update) }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.feed(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        do {
            try p.run()
            process = p
            startedAt = .now
        } catch {
            terminated()
        }
    }

    private func terminated() {
        process = nil
        guard !stopping else { return }
        if Date.now.timeIntervalSince(startedAt) > 60 { backoff = 1 }
        let delay = backoff
        backoff = min(backoff * 2, 60)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopping, self.process == nil else { return }
            self.launch()
        }
    }

    private func checkFootprint() {
        guard let p = process, p.isRunning else { return }
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(p.processIdentifier, RUSAGE_INFO_V2, $0)
            }
        }
        if ok == 0, info.ri_phys_footprint > Self.footprintLimit {
            p.terminate()  // terminationHandler restarts it
        }
    }

    // MARK: Applying stream updates

    private func apply(_ u: LineReader.Update) {
        if u.diff {
            for (k, v) in u.payload {
                if v is NSNull { raw.removeValue(forKey: k) } else { raw[k] = v }
            }
        } else {
            raw = u.payload
        }
        if let art = u.artwork {
            state.artwork = NSImage(cgImage: art.image, size: .zero)
            state.accent = art.accent
        } else if u.artworkCleared {
            state.artwork = nil
            state.accent = .white
        }

        let s = state
        s.title = raw["title"] as? String
        s.artist = raw["artist"] as? String
        let bundle = raw["bundleIdentifier"] as? String
        if bundle != s.bundleID {
            s.bundleID = bundle
            s.appIcon = bundle.flatMap(Self.icon(for:))
        }
        s.isPlaying = raw["playing"] as? Bool ?? false
        s.duration = (raw["durationMicros"] as? Double ?? 0) / 1_000_000
        s.rate = raw["playbackRate"] as? Double ?? 1
        if let e = raw["elapsedTimeMicros"] as? Double, let t = raw["timestampEpochMicros"] as? Double {
            s.elapsed = e / 1_000_000
            s.anchor = Date(timeIntervalSince1970: t / 1_000_000)
        }
        if s.rate == 0 { s.rate = 1 }
        s.updateActivity()
        debugLog("media: \(s.title ?? "-") playing=\(s.isPlaying) pos=\(Int(s.position(at: .now)))/\(Int(s.duration)) art=\(s.artwork.map { "\(Int($0.size.width))" } ?? "none")")
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}

/// Splits helper stdout into JSON lines and decodes artwork on the reader thread,
/// so the main thread never sees base64 or full-size images.
private final class LineReader: @unchecked Sendable {
    struct Artwork { let image: CGImage; let accent: Color }
    struct Update: @unchecked Sendable {
        let diff: Bool
        let payload: [String: Any]
        let artwork: Artwork?
        let artworkCleared: Bool
    }

    private var buffer = Data()
    private let emit: @Sendable (Update) -> Void

    init(emit: @escaping @Sendable (Update) -> Void) { self.emit = emit }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let u = Self.parse(line) { emit(u) }
        }
    }

    private static func parse(_ line: Data) -> Update? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              var payload = obj["payload"] as? [String: Any] else { return nil }
        let diff = obj["diff"] as? Bool ?? false
        let artValue = payload.removeValue(forKey: "artworkData")
        payload.removeValue(forKey: "artworkMimeType")
        let artwork = (artValue as? String).flatMap(decodeArtwork)
        let cleared = artValue is NSNull || (!diff && artValue == nil)
        return Update(diff: diff, payload: payload, artwork: artwork, artworkCleared: cleared)
    }

    /// 192 px thumbnail (enough for 76 pt @2x) + accent colour from a 1×1 redraw.
    private static func decodeArtwork(_ base64: String) -> Artwork? {
        guard let data = Data(base64Encoded: base64),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 192,
              ] as CFDictionary) else { return nil }

        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.interpolationQuality = .medium
        ctx?.draw(thumb, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // Keep the hue, but make it bright enough to read on black.
        let avg = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                          blue: CGFloat(px[2]) / 255, alpha: 1)
        let accent = NSColor(hue: avg.hueComponent, saturation: min(avg.saturationComponent * 1.2, 0.9),
                             brightness: max(avg.brightnessComponent, 0.75), alpha: 1)
        return Artwork(image: thumb, accent: Color(nsColor: accent))
    }
}

private let debugEnabled = ProcessInfo.processInfo.environment["ISLET_DEBUG"] != nil

/// Opt-in diagnostics: run the binary with ISLET_DEBUG=1 to log to stderr.
func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data((message() + "\n").utf8))
}
