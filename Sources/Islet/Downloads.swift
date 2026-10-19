import AppKit
import SwiftUI

struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let airDrop: Bool
    var fraction: Double
}

/// Browser downloads and incoming AirDrop, via the system file-progress feed for ~/Downloads
/// (the same one Finder and the Dock use). Event-driven; a 0.5 s tick runs only while something is downloading.
@MainActor @Observable
final class DownloadWatcher {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored var autoShelf = false
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private let tray: TrayStore
    @ObservationIgnored private var tracked: [UUID: (progress: Progress, url: URL?)] = [:]
    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var tick: Timer?

    init(center: ActivityCenter, tray: TrayStore) {
        self.center = center
        self.tray = tray
    }

    func start() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        subscriber = Progress.addSubscriber(forFileURL: dir) { [weak self] progress in
            nonisolated(unsafe) let p = progress
            let id = UUID()
            Task { @MainActor in self?.add(id, p) }
            return { Task { @MainActor in self?.finish(id) } }
        }
    }

    private static func cleanName(_ url: URL?) -> String {
        var name = url?.lastPathComponent ?? "Download"
        for suffix in [".download", ".crdownload", ".part"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        return name
    }

    private func add(_ id: UUID, _ p: Progress) {
        let url = p.fileURL ?? p.userInfo[.fileURLKey] as? URL
        tracked[id] = (p, url)
        let item = DownloadItem(id: id, name: Self.cleanName(url), airDrop: p.fileOperationKind == .receiving,
                                fraction: max(p.fractionCompleted, 0))
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.append(item) }
        center.downloads = items
        if tick == nil {
            tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
        }
    }

    private func update() {
        var changed = false
        for i in items.indices {
            guard let p = tracked[items[i].id]?.progress else { continue }
            let f = min(max(p.fractionCompleted, 0), 1)
            if abs(f - items[i].fraction) >= 0.01 { items[i].fraction = f; changed = true }
        }
        if changed { center.downloads = items }
    }

    private func finish(_ id: UUID) {
        guard let (p, url) = tracked.removeValue(forKey: id), let item = items.first(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        center.downloads = items
        if items.isEmpty { tick?.invalidate(); tick = nil }
        let ok = !p.isCancelled && (p.fractionCompleted >= 0.99 || p.totalUnitCount <= 0)
        center.show(.transferDone(name: item.name, airDrop: item.airDrop, ok: ok), for: 5)
        center.chime(ok ? "Glass" : "Basso")
        if ok, autoShelf, let url {
            let final = url.deletingLastPathComponent().appendingPathComponent(item.name)
            if FileManager.default.fileExists(atPath: final.path) { tray.add([final]) }
        }
    }
}

/// Result of an AirDrop *send* (macOS reports success/failure only, no percentage).
@MainActor
final class AirDropDelegate: NSObject, NSSharingServiceDelegate {
    static let shared = AirDropDelegate()
    var onResult: (_ ok: Bool, _ count: Int) -> Void = { _, _ in }

    /// Without a source window AirDrop falls back to full-screen overlay windows (the "desktop mode"),
    /// and it positions its picker relative to whatever window it gets. So it gets its own invisible,
    /// click-through anchor in the middle of the screen, removed when the share ends.
    private var anchor: NSWindow?

    func prepareAnchor() {
        anchor?.close()
        let screen = NSApp.windows.first { $0 is KeyOnDemandPanel && $0.isVisible }?.screen ?? NSScreen.main
        let f = screen?.visibleFrame ?? .zero
        let w = NSWindow(contentRect: NSRect(x: f.midX - 220, y: f.midY - 170, width: 440, height: 340),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.orderFrontRegardless()
        anchor = w
        // Safety net: never leave it behind if AirDrop reports nothing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak w] in
            if let w, self?.anchor === w { self?.closeAnchor() }
        }
    }

    private func closeAnchor() {
        anchor?.close()
        anchor = nil
    }

    func sharingService(_ sharingService: NSSharingService, sourceFrameOnScreenForShareItem item: Any) -> NSRect {
        anchor?.frame ?? .zero
    }

    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any],
                        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        anchor
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        closeAnchor()
        onResult(true, items.count)
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        closeAnchor()
        if (error as NSError).code != NSUserCancelledError { onResult(false, items.count) }
    }
}
