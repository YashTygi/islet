import AppKit
import SwiftUI

/// File in ~/Library/Application Support/Islet.
func appSupportFile(_ name: String) -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Islet", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

// MARK: Preferences (everything the control panel changes)

enum NotchTab: String, CaseIterable, Identifiable {
    case home, app, work, dev, shelf, camera
    var id: String { rawValue }
    var title: String {
        switch self { case .home: "Home"; case .app: "This App"; case .work: "Agents & Tasks"; case .dev: "Dev"; case .shelf: "File Shelf"; case .camera: "Camera" }
    }
    var symbol: String {
        switch self { case .home: "house.fill"; case .app: "wand.and.stars"; case .work: "sparkles"; case .dev: "chevron.left.forwardslash.chevron.right"; case .shelf: "tray.fill"; case .camera: "camera.fill" }
    }
}

enum HomeCard: String, CaseIterable, Identifiable {
    case media, meeting, usage
    var id: String { rawValue }
    var title: String { switch self { case .media: "Now Playing"; case .meeting: "Next Meeting"; case .usage: "Claude Usage" } }
    var width: CGFloat { self == .media ? 260 : 175 }
}

/// Live activities that can be switched off in the control panel.
enum ActivityKind: String, CaseIterable, Identifiable {
    case agents, privacy, tasks, downloads, timer, media, meetings, battery, bluetooth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: "Agent status & needs-you alerts"
        case .privacy: "Mic & camera in use"
        case .tasks: "Long tasks (islet run)"
        case .downloads: "Downloads & AirDrop progress"
        case .timer: "Timer & focus"
        case .media: "Now playing"
        case .meetings: "Meetings starting soon"
        case .battery: "Charging & low battery"
        case .bluetooth: "Bluetooth connect / disconnect"
        }
    }
}

@MainActor @Observable
final class Prefs {
    @ObservationIgnored private let d = UserDefaults.standard
    /// Called after any change, so services can apply it.
    @ObservationIgnored var onChange: () -> Void = {}

    var hiddenTabs: Set<NotchTab> { didSet { save("hiddenTabs", hiddenTabs.map(\.rawValue)); onChange() } }
    var homeCards: [HomeCard] { didSet { save("homeCards", homeCards.map(\.rawValue)); onChange() } }
    var disabledActivities: Set<ActivityKind> { didSet { save("disabledActivities", disabledActivities.map(\.rawValue)); onChange() } }
    var sounds: Bool { didSet { d.set(sounds, forKey: "sounds"); onChange() } }
    var hotkey: Bool { didSet { d.set(hotkey, forKey: "hotkey"); onChange() } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics"); onChange() } }
    var keepAwake: Bool { didSet { d.set(keepAwake, forKey: "keepAwake"); onChange() } }
    /// Finished downloads land on the File Shelf automatically.
    var autoShelf: Bool { didSet { d.set(autoShelf, forKey: "autoShelf"); onChange() } }
    /// Open straight to the App tab when the front app has context actions.
    var openToAppTab: Bool { didSet { d.set(openToAppTab, forKey: "openToAppTab"); onChange() } }
    var ringLight: Bool { didSet { d.set(ringLight, forKey: "ringLight"); onChange() } }
    var ringIntensity: Double { didSet { d.set(ringIntensity, forKey: "ringIntensity"); onChange() } }
    var ringWarmth: Double { didSet { d.set(ringWarmth, forKey: "ringWarmth"); onChange() } }
    var customActions: [CustomAction] {
        didSet { d.set(try? JSONEncoder().encode(customActions), forKey: "customActions"); onChange() }
    }
    /// Optional per-window token budget for the usage bar (0 = show time elapsed instead).
    var claudeTokenLimit: Int { didSet { d.set(claudeTokenLimit, forKey: "claudeTokenLimit"); onChange() } }

    init() {
        let d = UserDefaults.standard
        hiddenTabs = Set((d.stringArray(forKey: "hiddenTabs") ?? [NotchTab.camera.rawValue]).compactMap(NotchTab.init))  // Camera is opt-in (Control panel → Notch)
        homeCards = d.stringArray(forKey: "homeCards")?.compactMap(HomeCard.init) ?? HomeCard.allCases
        disabledActivities = Set((d.stringArray(forKey: "disabledActivities") ?? []).compactMap(ActivityKind.init))
        sounds = d.object(forKey: "sounds") as? Bool ?? true
        hotkey = d.object(forKey: "hotkey") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
        autoShelf = d.bool(forKey: "autoShelf")
        openToAppTab = d.object(forKey: "openToAppTab") as? Bool ?? true
        ringLight = d.object(forKey: "ringLight") as? Bool ?? true
        ringIntensity = d.object(forKey: "ringIntensity") as? Double ?? 0.8
        ringWarmth = d.object(forKey: "ringWarmth") as? Double ?? 0.3
        customActions = (d.data(forKey: "customActions")).flatMap { try? JSONDecoder().decode([CustomAction].self, from: $0) } ?? []
        claudeTokenLimit = d.integer(forKey: "claudeTokenLimit")
    }

    var visibleTabs: [NotchTab] { NotchTab.allCases.filter { $0 == .home || !hiddenTabs.contains($0) } }

    private func save(_ key: String, _ value: [String]) { d.set(value, forKey: key) }
}

/// Shared stores, one instance for all screens.
@MainActor
final class Services {
    let prefs = Prefs()
    let agents: AgentStore
    let tasks: TaskStore
    let usage = UsageService()
    let downloads: DownloadWatcher
    let privacy = PrivacyMonitor()
    let context = ContextService()
    let tunnel = TunnelService()
    let camera = CameraController()
    let ringLight = RingLight()
    var openSettings: () -> Void = {}
    var openOnboarding: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    init(activities: ActivityCenter, tray: TrayStore) {
        agents = AgentStore(center: activities)
        tasks = TaskStore(center: activities)
        downloads = DownloadWatcher(center: activities, tray: tray)
    }
}

// MARK: Home row

struct HomeView: View {
    let model: NotchModel

    var body: some View {
        let s = model.services
        HStack(spacing: 10) {
            ForEach(s.prefs.homeCards) { card in
                Group {
                    switch card {
                    case .media: MediaCard(media: model.media)
                    case .meeting: MeetingCard(center: model.activities)
                    case .usage: UsageCard(usage: s.usage, tokenLimit: s.prefs.claudeTokenLimit)
                    }
                }
                .frame(width: card.width)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            if s.prefs.homeCards.isEmpty {
                Button("Choose what to show…", action: s.openSettings)
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MediaCard: View {
    let media: MediaService

    var body: some View {
        Group {
            if media.state.title != nil {
                Player(media: media, artSize: 56)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.system(size: 22))
                    Text("Nothing playing").font(.system(size: 12))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
    }
}

/// Next meeting with a one-click Join (Zoom, Meet, Teams, Webex), so you know when to wrap up.
private struct MeetingCard: View {
    let center: ActivityCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next meeting", systemImage: "video.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue.opacity(0.9))
            if let m = center.nextMeeting {
                HStack(spacing: 6) {
                    Capsule().fill(m.color).frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(m.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    let mins = Int((m.start.timeIntervalSince(ctx.date) / 60).rounded(.up))
                    Text(mins > 0 ? (mins >= 60 ? "in \(mins / 60)h \(mins % 60)m" : "in \(mins) min") : "now")
                        .font(.system(size: 18, weight: .semibold).monospacedDigit())
                        .foregroundStyle(mins <= 5 ? .orange : .white)
                }
                Spacer(minLength: 0)
                if let url = m.joinURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Label("Join", systemImage: "video.fill").font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 26)
                            .background(Capsule().fill(.blue)).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("No more meetings today")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }
}
