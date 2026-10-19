import AppKit
import SwiftUI

/// Files parked on the notch. Stores bookmarks (references), not copies: the tray costs no disk
/// space and items follow renames/moves. Items whose file is gone are dropped on load.
/// ponytail: references only; add a "copy into tray" option if users want items to survive deletion.
@MainActor @Observable
final class TrayStore {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let icon: NSImage
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Islet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("tray.json")
        load()
    }

    func add(_ urls: [URL]) {
        let new = urls.filter { u in !items.contains { $0.url == u } }
        guard !new.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            items.append(contentsOf: new.map(Self.item))
        }
        save()
    }

    func remove(_ id: Item.ID) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll { $0.id == id } }
        save()
    }

    func clear() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { items.removeAll() }
        save()
    }

    private static func item(_ url: URL) -> Item {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return Item(url: url, icon: icon)
    }

    private func save() {
        let bookmarks = items.compactMap { try? $0.url.bookmarkData() }
        if let data = try? JSONEncoder().encode(bookmarks) { try? data.write(to: file, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let bookmarks = try? JSONDecoder().decode([Data].self, from: data) else { return }
        items = bookmarks.compactMap { b in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: b, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Self.item(url)
        }
        save()  // rewrites stale bookmarks, drops missing files
    }
}

@MainActor
enum AirDrop {
    static func send(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate()  // accessory app: the AirDrop picker needs us frontmost
        AirDropDelegate.shared.prepareAnchor()
        service.delegate = AirDropDelegate.shared
        service.perform(withItems: urls)
    }
}

// MARK: Views

enum DropTarget { case tray, airDrop }

/// Shown while a file drag is over the nook.
struct DropZones: View {
    /// Zone under the pointer, or nil while the drag is only approaching.
    let target: DropTarget?
    let trayCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Zone(symbol: "tray.and.arrow.down.fill",
                 title: trayCount > 0 ? "Add to Tray (\(trayCount))" : "Add to Tray",
                 active: target == .tray)
            Zone(symbol: "dot.radiowaves.left.and.right", title: "AirDrop", active: target == .airDrop)
                .frame(width: NotchModel.airDropZoneWidth)
        }
    }

    private struct Zone: View {
        let symbol: String
        let title: String
        let active: Bool

        var body: some View {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(active ? 1 : 0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(active ? 0.14 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(active ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .scaleEffect(active ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
        }
    }
}

struct TrayView: View {
    let tray: TrayStore

    var body: some View {
        if tray.items.isEmpty {
            Label("Drag files onto the notch to park them here", systemImage: "tray.and.arrow.down")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text("\(tray.items.count) item\(tray.items.count == 1 ? "" : "s")")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    IconButton(symbol: "dot.radiowaves.left.and.right", help: "AirDrop all") {
                        AirDrop.send(tray.items.map(\.url))
                    }
                    IconButton(symbol: "trash", help: "Clear tray") { tray.clear() }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 10) {
                        ForEach(tray.items) { item in
                            TrayTile(item: item) { tray.remove(item.id) }
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
            }
        }
    }
}

private struct TrayTile: View {
    let item: TrayStore.Item
    let onRemove: () -> Void
    private let hover = State(initialValue: false)  // see Scrubber: no @State without Xcode

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: item.icon).resizable().frame(width: 48, height: 48)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(width: 76, height: 84)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(hover.wrappedValue ? 0.1 : 0)))
        .overlay(alignment: .topTrailing) {
            if hover.wrappedValue {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag {
            debugLog("tray: drag out \(item.url.lastPathComponent)")
            // File URL (not file contents) so Finder and other apps treat it like a real file drag.
            return NSItemProvider(object: item.url as NSURL)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("AirDrop") { AirDrop.send([item.url]) }
            Divider()
            Button("Remove from Tray", action: onRemove)
        }
        .help(item.url.path)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.75))
        .help(help)
    }
}
