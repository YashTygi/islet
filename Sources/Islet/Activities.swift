import AppKit
import EventKit
import IOKit.pwr_mgt
import IOBluetooth
import IOKit.ps
import SwiftUI

/// What the collapsed pill shows. Highest priority wins:
/// agent needs you > short alerts > running task > timer/focus > agents running > meeting soon > media.
enum LiveActivity: Equatable {
    case media
    case timer(end: Date, kind: TimerKind)
    case event(title: String, start: Date, color: Color)
    case battery(level: Int, charging: Bool, pluggedIn: Bool)
    case bluetooth(name: String, connected: Bool, symbol: String)
    case timerDone(TimerKind)
    case needsYou(name: String, project: String, count: Int)
    case agents(running: Int)
    case task(command: String, start: Date, count: Int)
    case taskDone(command: String, ok: Bool, duration: TimeInterval)
    case agentDone(name: String, project: String, ok: Bool)
    case download(name: String, fraction: Double, airDrop: Bool, count: Int)
    case transferDone(name: String, airDrop: Bool, ok: Bool)
    case privacy(mic: Bool, camera: Bool, muted: Bool)
    case tunnel(url: String)
    case shelved(name: String)
    case working(label: String)
}

/// Trackpad tap (felt only while a finger rests on a Force Touch trackpad).
func haptic() { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }

enum TimerKind: Equatable {
    case plain, focus, rest
    var symbol: String { switch self { case .plain: "timer"; case .focus: "brain.head.profile"; case .rest: "cup.and.saucer.fill" } }
    var color: Color { switch self { case .plain: .orange; case .focus: .purple; case .rest: .mint } }
}

struct UpcomingEvent: Equatable {
    let title: String
    let start: Date
    let end: Date
    let color: Color
    /// Zoom / Meet / Teams / Webex link found in the event, for one-click join.
    let joinURL: URL?
}

/// Picks the current live activity. Event-driven: instead of polling it sleeps until the
/// next moment the choice can change (alert expiry, timer end, an event entering/leaving its window).
@MainActor @Observable
final class ActivityCenter {
    private(set) var current: LiveActivity?
    private(set) var timerEnd: Date?
    private(set) var timerDuration: TimeInterval = 0
    private(set) var timerKind: TimerKind = .plain
    /// Completed focus sessions in the current Pomodoro run (long break after 4).
    private(set) var focusCount = 0

    @ObservationIgnored var onVisibleChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var mediaActive = false { didSet { recompute() } }
    var events: [UpcomingEvent] = [] { didSet { recompute() } }
    /// Inputs from AgentStore / TaskStore.
    @ObservationIgnored var waitingAgents: [Agent] = [] { didSet { recompute() } }
    @ObservationIgnored var runningAgents = 0 { didSet { recompute() } }
    @ObservationIgnored var runningTasks: [RunningTask] = [] { didSet { recompute() } }
    @ObservationIgnored var sounds = true
    /// Keep the display awake (no sleep, no screen saver) while agents or tasks run.
    @ObservationIgnored var keepAwakeEnabled = true { didSet { recompute() } }
    private(set) var keepingAwake = false
    @ObservationIgnored private var awakeAssertion: IOPMAssertionID = 0
    @ObservationIgnored var haptics = true
    @ObservationIgnored var downloads: [DownloadItem] = [] { didSet { recompute() } }
    @ObservationIgnored var mic = false
    @ObservationIgnored var camera = false
    @ObservationIgnored var micMuted = false
    /// Public tunnel URL while a local server is shared (always shown: it's a safety reminder).
    @ObservationIgnored var tunnelURL: String? { didSet { recompute() } }
    /// A Preview/Finder file job is running ("Merging…"): shown until it finishes.
    @ObservationIgnored var working: String? { didSet { recompute() } }
    func privacyChanged(mic: Bool, camera: Bool, muted: Bool) {
        self.mic = mic; self.camera = camera; micMuted = muted
        recompute()
    }
    /// Activity kinds switched off in the control panel.
    @ObservationIgnored var disabled: Set<ActivityKind> = [] { didSet { recompute() } }
    @ObservationIgnored private var alert: (activity: LiveActivity, until: Date)?
    @ObservationIgnored private var wake: Task<Void, Never>?

    /// Calendar events show from 10 min before start until 5 min after.
    private static let eventLead: TimeInterval = 10 * 60
    private static let eventTail: TimeInterval = 5 * 60
    static let focusMinutes = 25.0, restMinutes = 5.0, longRestMinutes = 15.0

    var nextMeeting: UpcomingEvent? { events.first { $0.end > .now } }

    func show(_ activity: LiveActivity, for seconds: TimeInterval = 4) {
        let kind: ActivityKind? = switch activity {
        case .battery: .battery
        case .bluetooth: .bluetooth
        case .timerDone: .timer
        case .taskDone: .tasks
        case .agentDone: .agents
        case .transferDone: .downloads
        default: nil
        }
        if let kind, disabled.contains(kind) { return }
        if haptics { haptic() }
        alert = (activity, .now + seconds)
        recompute()
    }

    func chime(_ name: String) {
        if sounds { NSSound(named: name)?.play() }
        if haptics { haptic() }
    }

    func startTimer(minutes: Double, kind: TimerKind = .plain) {
        if kind == .plain { focusCount = 0 }
        timerKind = kind
        timerDuration = minutes * 60
        timerEnd = .now + timerDuration
        recompute()
    }

    func startFocus() {
        focusCount = 0
        startTimer(minutes: Self.focusMinutes, kind: .focus)
    }

    func cancelTimer() {
        timerEnd = nil
        focusCount = 0
        timerKind = .plain
        recompute()
    }

    private func recompute() {
        let now = Date.now
        if let a = alert, a.until <= now { alert = nil }
        if let end = timerEnd, end <= now { timerFinished(now: now) }
        let soon = events.first { $0.start - Self.eventLead <= now && now < min($0.end, $0.start + Self.eventTail) }

        let waiting: LiveActivity? = waitingAgents.first.map {
            .needsYou(name: $0.name, project: $0.project, count: waitingAgents.count)
        }
        let task: LiveActivity? = runningTasks.first.map {
            .task(command: $0.command, start: $0.start, count: runningTasks.count)
        }
        // Candidates in priority order; the first allowed, present one wins.
        var candidates: [(ActivityKind?, LiveActivity?)] = []
        candidates.append((.agents, waiting))
        candidates.append((.privacy, mic || camera ? LiveActivity.privacy(mic: mic, camera: camera, muted: micMuted) : nil))
        candidates.append((nil, tunnelURL.map { LiveActivity.tunnel(url: $0) }))
        candidates.append((nil, alert?.activity))
        candidates.append((nil, working.map { LiveActivity.working(label: $0) }))
        candidates.append((.tasks, task))
        candidates.append((.downloads, downloads.first.map {
            LiveActivity.download(name: $0.name, fraction: $0.fraction, airDrop: $0.airDrop, count: downloads.count)
        }))
        candidates.append((.timer, timerEnd.map { LiveActivity.timer(end: $0, kind: timerKind) }))
        candidates.append((.agents, runningAgents > 0 ? LiveActivity.agents(running: runningAgents) : nil))
        candidates.append((.meetings, soon.map { LiveActivity.event(title: $0.title, start: $0.start, color: $0.color) }))
        candidates.append((.media, mediaActive ? LiveActivity.media : nil))
        let next = candidates.first { kind, activity in
            activity != nil && (kind.map { !disabled.contains($0) } ?? true)
        }?.1 ?? nil

        if next != current {
            debugLog("activity: \(next.map { "\($0)" } ?? "none")")
            let wasVisible = current != nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { current = next }
            if wasVisible != (next != nil) { onVisibleChange(next != nil) }
        }
        updateKeepAwake()
        scheduleWake(now: now)
    }

    /// A power assertion held by macOS (like `caffeinate -d`): no timers or fake input, so it costs nothing.
    /// Released the moment no agent is running/waiting and no task is running (and on quit, automatically).
    private func updateKeepAwake() {
        let busy = keepAwakeEnabled && (runningAgents > 0 || !waitingAgents.isEmpty || !runningTasks.isEmpty)
        guard busy != keepingAwake else { return }
        if busy {
            let ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Islet: agents or tasks are running" as CFString, &awakeAssertion)
            keepingAwake = ok == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(awakeAssertion)
            awakeAssertion = 0
            keepingAwake = false
        }
        debugLog("keep awake: \(keepingAwake)")
    }

    /// Plain timer: chime and done. Focus/rest: chime and roll into the next phase (Pomodoro).
    private func timerFinished(now: Date) {
        let kind = timerKind
        timerEnd = nil
        chime(kind == .focus ? "Hero" : "Glass")
        alert = (.timerDone(kind), now + 5)
        switch kind {
        case .plain:
            break
        case .focus:
            focusCount += 1
            timerKind = .rest
            timerDuration = (focusCount % 4 == 0 ? Self.longRestMinutes : Self.restMinutes) * 60
            timerEnd = now + timerDuration
        case .rest:
            timerKind = .focus
            timerDuration = Self.focusMinutes * 60
            timerEnd = now + timerDuration
        }
    }

    private func scheduleWake(now: Date) {
        var dates = [alert?.until, timerEnd].compactMap { $0 }
        for e in events {
            dates.append(e.start - Self.eventLead)
            dates.append(min(e.end, e.start + Self.eventTail))
        }
        wake?.cancel()
        guard let next = dates.filter({ $0 > now }).min() else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.05))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }
}

// MARK: Battery (IOKit power-source notifications, no polling)

@MainActor
final class PowerService {
    private let center: ActivityCenter
    private var source: CFRunLoopSource?
    private var lastPluggedIn: Bool?
    private var warnedLow = false

    init(center: ActivityCenter) { self.center = center }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.read() }
        }, ctx)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        read()
    }

    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let battery = list.first,
              let d = IOPSGetPowerSourceDescription(info, battery)?.takeUnretainedValue() as? [String: Any]
        else { return }
        let level = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let pluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        debugLog("power: \(level)% charging=\(charging) pluggedIn=\(pluggedIn)")

        defer { lastPluggedIn = pluggedIn }
        if let last = lastPluggedIn, last != pluggedIn {
            center.show(.battery(level: level, charging: charging, pluggedIn: pluggedIn))
        }
        if pluggedIn || level > 20 {
            warnedLow = false
        } else if !warnedLow, lastPluggedIn != nil {
            warnedLow = true
            center.show(.battery(level: level, charging: false, pluggedIn: false), for: 6)
        }
    }
}

// MARK: Bluetooth (IOBluetooth connect/disconnect notifications)

@MainActor
final class BluetoothService: NSObject {
    private let center: ActivityCenter
    private var connectNote: IOBluetoothUserNotification?
    /// Registration replays already-connected devices; those aren't news.
    private var quietUntil = Date.distantFuture

    init(center: ActivityCenter) { self.center = center }

    func start() {
        quietUntil = .now + 3
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(connected(_:device:)))
    }

    // IOBluetooth posts these from a CoreBluetooth background queue; only Strings cross to main,
    // where the window resize happens (AppKit throws if setFrame runs off the main thread).
    @objc nonisolated private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:)))
        let name = device.name ?? "Device", symbol = Self.symbol(device)
        DispatchQueue.main.async { MainActor.assumeIsolated {
            debugLog("bluetooth: connected \(name) (replay=\(Date.now <= self.quietUntil))")
            guard Date.now > self.quietUntil else { return }
            self.center.show(.bluetooth(name: name, connected: true, symbol: symbol))
        } }
    }

    @objc nonisolated private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        let name = device.name ?? "Device", symbol = Self.symbol(device)
        DispatchQueue.main.async { MainActor.assumeIsolated {
            self.center.show(.bluetooth(name: name, connected: false, symbol: symbol))
        } }
    }

    nonisolated private static func symbol(_ d: IOBluetoothDevice) -> String {
        let name = (d.name ?? "").lowercased()
        if name.contains("airpods max") { return "airpodsmax" }
        if name.contains("airpods pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("mouse") { return "computermouse" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if name.contains("keyboard") { return "keyboard" }
        if d.deviceClassMajor == kBluetoothDeviceClassMajorAudio { return "headphones" }
        return "dot.radiowaves.left.and.right"
    }
}

// MARK: Calendar (EventKit; refetch on store change and every 30 min)

@MainActor
final class CalendarService {
    private let center: ActivityCenter
    private let store = EKEventStore()
    private var refreshTimer: Timer?

    init(center: ActivityCenter) { self.center = center }

    func start() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) == true
            debugLog("calendar: access \(granted ? "granted" : "denied")")
            guard granted else { return }
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            refresh()
        }
    }

    private static let meetingPattern = try! NSRegularExpression(
        pattern: #"https://[\w.-]*(zoom\.us/(j|my)/|meet\.google\.com/|teams\.microsoft\.com/l/meetup-join/|teams\.live\.com/meet/|[\w-]+\.webex\.com/)[^\s<>"']+"#)

    /// First video-call link in the event's URL, location or notes.
    private static func joinURL(_ e: EKEvent) -> URL? {
        let text = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let range = NSRange(text.startIndex..., in: text)
        guard let m = meetingPattern.firstMatch(in: text, range: range), let r = Range(m.range, in: text) else { return nil }
        return URL(string: String(text[r]))
    }

    private func refresh() {
        let now = Date.now
        let predicate = store.predicateForEvents(withStart: now - 3600, end: now + 24 * 3600, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(20)
            .map { UpcomingEvent(title: $0.title ?? "Event", start: $0.startDate, end: $0.endDate,
                                 color: Color(cgColor: $0.calendar.cgColor), joinURL: Self.joinURL($0)) }
        debugLog("calendar: \(events.count) upcoming, next: \(events.first.map { "\($0.title) at \($0.start)" } ?? "none")")
        center.events = Array(events)
    }
}

// MARK: Pill content

/// Left and right wing content of the collapsed pill for the current activity.
struct ActivityWings: View {
    let activity: LiveActivity
    let media: NowPlaying
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: height - 12, height: height - 12)
            Spacer(minLength: 0)
            right.frame(minWidth: 22, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
        .id(kind)  // crossfade when the activity type changes
    }

    private var kind: String {
        switch activity {
        case .media: "media"
        case .timer: "timer"
        case .event: "event"
        case .battery: "battery"
        case .bluetooth: "bluetooth"
        case .timerDone: "done"
        case .needsYou: "needs"
        case .agents: "agents"
        case .task: "task"
        case .taskDone: "taskDone"
        case .agentDone: "agentDone"
        case .download: "download"
        case .transferDone: "transferDone"
        case .privacy: "privacy"
        case .tunnel: "tunnel"
        case .shelved: "shelved"
        case .working: "working"
        }
    }

    @ViewBuilder private var left: some View {
        switch activity {
        case .media:
            Artwork(image: media.artwork, corner: 6)
        case .timer(_, let k):
            symbol(k.symbol, k.color)
        case .event(_, _, let color):
            symbol("calendar", color)
        case .battery(let level, let charging, let pluggedIn):
            symbol(pluggedIn ? "bolt.fill" : Self.batterySymbol(level),
                   pluggedIn || charging ? .green : (level <= 20 ? .red : .white))
        case .bluetooth(_, let connected, let s):
            symbol(s, connected ? .blue : .white.opacity(0.6))
        case .timerDone(let k):
            symbol(k == .plain ? "bell.fill" : k.symbol, k.color).symbolEffect(.bounce, value: k == .plain)
        case .needsYou(_, _, let count):
            // One bounce per new request, then static: a waiting agent can sit for hours, and a
            // looping pulse would redraw every frame the whole time.
            symbol("hand.raised.fill", .orange).symbolEffect(.bounce, value: count)
        case .agents:
            symbol("sparkles", .purple)
        case .task:
            symbol("terminal.fill", .green)
        case .taskDone(_, let ok, _):
            symbol(ok ? "checkmark.circle.fill" : "xmark.octagon.fill", ok ? .green : .red)
        case .agentDone(_, _, let ok):
            symbol("sparkles", ok ? .green : .red)
        case .download(_, _, let airDrop, _):
            symbol(airDrop ? "dot.radiowaves.left.and.right" : "arrow.down.circle.fill", .blue)
        case .transferDone(_, let airDrop, let ok):
            symbol(ok ? (airDrop ? "dot.radiowaves.left.and.right" : "arrow.down.circle.fill") : "exclamationmark.triangle.fill", ok ? .green : .red)
        case .privacy(_, let camera, let muted):
            symbol(camera ? "video.fill" : (muted ? "mic.slash.fill" : "mic.fill"), camera ? .green : (muted ? .red : .orange))
        case .tunnel:
            symbol("globe", .green)
        case .shelved:
            symbol("tray.and.arrow.down.fill", .green).symbolEffect(.bounce, value: activity)
        case .working:
            symbol("doc.badge.gearshape", .blue).symbolEffect(.pulse)  // only for the seconds a job runs
        }
    }

    @ViewBuilder private var right: some View {
        switch activity {
        case .media:
            Bars(playing: media.isPlaying, color: media.accent)
        case .timer(let end, let k):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clock(max(end.timeIntervalSince(ctx.date), 0))).foregroundStyle(k.color)
            }
        case .event(_, let start, let color):
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let mins = Int((start.timeIntervalSince(ctx.date) / 60).rounded(.up))
                Text(mins > 0 ? "\(mins)m" : "now").foregroundStyle(color)
            }
        case .battery(let level, _, _):
            Text("\(level)%")
        case .bluetooth(_, let connected, _):
            Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(connected ? .blue : .white.opacity(0.6))
        case .timerDone(let k):
            Text(k == .focus ? "Break" : k == .rest ? "Focus" : "Done").foregroundStyle(k.color)
        case .needsYou(_, _, let count):
            Text(count > 1 ? "\(count)" : "!").foregroundStyle(.orange)
        case .agents(let n):
            Text("\(n)").foregroundStyle(.purple)  // static: no spinner redrawing for the length of a run
        case .task(_, let start, _):
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clock(ctx.date.timeIntervalSince(start))).foregroundStyle(.green)
            }
        case .taskDone(_, let ok, let d):
            Text(Self.clock(d)).foregroundStyle(ok ? .green : .red)
        case .agentDone(_, _, let ok):
            Image(systemName: ok ? "checkmark" : "xmark").foregroundStyle(ok ? .green : .red)
        case .download(_, let f, _, let count):
            Text(count > 1 ? "\(count)×" : "\(Int(f * 100))%").foregroundStyle(.blue)
        case .transferDone(_, _, let ok):
            Image(systemName: ok ? "checkmark" : "xmark").foregroundStyle(ok ? .green : .red)
        case .privacy(let mic, let camera, let muted):
            HStack(spacing: 3) {  // iPhone-style dots: green = camera, orange = mic
                if camera { Circle().fill(.green).frame(width: 6, height: 6) }
                if mic { Circle().fill(muted ? .red : .orange).frame(width: 6, height: 6) }
            }
        case .tunnel:
            Text("LIVE").font(.system(size: 10, weight: .heavy)).foregroundStyle(.red)
        case .shelved:
            Image(systemName: "checkmark").foregroundStyle(.green)
        case .working:
            ProgressView().controlSize(.mini).tint(.blue)
        }
    }

    private func symbol(_ name: String, _ color: Color) -> some View {
        Image(systemName: name).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
    }

    private static func batterySymbol(_ level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Timer chip in the strip right of the notch. Opens TimerPanel (custom dropdown, not an NSMenu).
struct TimerButton: View {
    let center: ActivityCenter
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: center.timerEnd == nil ? "timer" : center.timerKind.symbol)
                if let end = center.timerEnd {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(ActivityWings.clock(max(end.timeIntervalSince(ctx.date), 0)))
                    }
                }
            }
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(center.timerEnd == nil && !isOpen ? .white.opacity(0.55) : center.timerKind.color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(center.timerEnd != nil || isOpen ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// The dropdown: presets + focus when idle, progress ring + cancel when running.
struct TimerPanel: View {
    let center: ActivityCenter
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let end = center.timerEnd {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(end.timeIntervalSince(ctx.date), 0)
                    let progress = center.timerDuration > 0 ? left / center.timerDuration : 0
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 5)
                        Circle().trim(from: 0, to: progress)
                            .stroke(center.timerKind.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 1), value: progress)
                        VStack(spacing: 1) {
                            Text(ActivityWings.clock(left)).font(.system(size: 17, weight: .semibold).monospacedDigit())
                            if center.timerKind != .plain {
                                Text(center.timerKind == .focus ? "Focus \(center.focusCount + 1)" : "Break")
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .frame(width: 84, height: 84)
                }
                Button("Cancel") { center.cancelTimer(); close() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(center.timerKind.color)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach([1.0, 3, 5, 10, 25, 45], id: \.self) { m in
                        chip("\(Int(m))m", .orange) { center.startTimer(minutes: m); close() }
                    }
                }
                chip("Focus  25 / 5", .purple, symbol: "brain.head.profile") { center.startFocus(); close() }
            }
        }
        .padding(12)
        .frame(width: 200)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.1)))
        .foregroundStyle(.white)
    }

    private func chip(_ title: String, _ color: Color, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { if let symbol { Image(systemName: symbol) } }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Capsule().fill(color.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).foregroundStyle(color)
    }
}
