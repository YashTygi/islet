import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchController] = []
    private let media = MediaService()
    private let tray = TrayStore()
    private let activities = ActivityCenter()
    private lazy var services = Services(activities: activities, tray: tray)
    private lazy var settings = SettingsWindow(services: services, activities: activities)
    private let events = EventBus()
    private lazy var power = PowerService(center: activities)
    private lazy var bluetooth = BluetoothService(center: activities)
    private lazy var calendar = CalendarService(center: activities)
    private let hotkey = HotkeyMonitor()
    private let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    private var dragMonitors: [Any] = []
    private var dragCountAtMouseDown = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A tunnel left by a killed/crashed run (matched by our own known_hosts path, never your ssh sessions).
        let stale = Process()
        stale.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        stale.arguments = ["-f", "UserKnownHostsFile=\(appSupportFile("known_hosts").path)"]
        try? stale.run()
        stale.waitUntilExit()
        // `kill`/`pkill` (SIGTERM) → normal quit, so applicationWillTerminate stops the tunnel and helpers.
        signal(SIGTERM, SIG_IGN)
        termSource.setEventHandler { NSApp.terminate(nil) }
        termSource.resume()
        if ProcessInfo.processInfo.environment["MYNOTCH_SELFTEST"] != nil {
            DoubleTapDetector.selfTest()
            exit(0)
        }
        media.state.onActiveChange = { [weak self] on in self?.activities.mediaActive = on }
        activities.onVisibleChange = { [weak self] on in
            self?.controllers.forEach { $0.model.setActivity(on) }
        }
        services.openSettings = { [weak self] in self?.settings.show() }
        services.prefs.onChange = { [weak self] in self?.applyPrefs() }
        applyPrefs()
        events.onAgent = { [weak self] in self?.services.agents.apply($0) }
        events.onTask = { [weak self] in self?.services.tasks.apply($0) }
        events.onSettings = { [weak self] in self?.settings.show() }
        events.start()
        services.downloads.start()
        services.context.start()
        services.tunnel.onChange = { [weak self] s in
            if case .live(_, let url) = s { self?.activities.tunnelURL = url } else { self?.activities.tunnelURL = nil }
        }
        services.privacy.onChange = { [weak self] in
            guard let self else { return }
            let p = self.services.privacy
            self.activities.privacyChanged(mic: p.micInUse, camera: p.cameraInUse, muted: p.micMuted)
        }
        services.privacy.start()
        AirDropDelegate.shared.onResult = { [weak self] ok, count in
            self?.activities.show(.transferDone(name: "\(count) item\(count == 1 ? "" : "s")", airDrop: true, ok: ok), for: 5)
        }
        media.start()
        power.start()
        bluetooth.start()
        calendar.start()
        if let port = ProcessInfo.processInfo.environment["MYNOTCH_TEST_TUNNEL"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.services.tunnel.start(port: port) }  // dev hook
        }
        if let f = ProcessInfo.processInfo.environment["MYNOTCH_TEST_AIRDROP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AirDrop.send([URL(fileURLWithPath: f)]) }  // dev hook
        }
        if let m = ProcessInfo.processInfo.environment["MYNOTCH_TEST_TIMER"].flatMap(Double.init) {
            activities.startTimer(minutes: m)  // dev hook: exercise the timer pill without clicking
        }
        rebuild()
        watchFileDrags()
        hotkey.onDoubleControl = { [weak self] in
            guard let self, self.services.prefs.hotkey else { return }
            let mouse = NSEvent.mouseLocation
            // Open on the screen the pointer is on; make sure no other screen stays locked.
            let target = self.controllers.first { $0.screenFrame.contains(mouse) } ?? self.controllers.first
            for c in self.controllers where c !== target { c.model.unlock(pointerInside: false) }
            target?.toggleLock()
        }
        hotkey.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    /// macOS opens Mission Control when a drag hits the top screen edge, which is where the notch is.
    /// So the nook opens early, as soon as a *file* drag gets near it, and the drop happens well below the edge.
    /// Global mouse monitors need no permission; they only fire while the button is down.
    private func watchFileDrags() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
                // Global monitors only see clicks going to other apps, i.e. outside the nook.
                self.controllers.forEach { $0.model.unlock(pointerInside: false) }
            }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pb = NSPasteboard(name: .drag)
                // A new drag session since mouse-down, carrying files (not a window move or text selection).
                guard pb.changeCount != self.dragCountAtMouseDown,
                      pb.types?.contains(.fileURL) == true else { return }
                let p = NSEvent.mouseLocation
                self.controllers.forEach { $0.fileDrag(at: p) }
            }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.controllers.forEach { $0.fileDrag(at: nil) } }
        }
        dragMonitors = [down, dragged, up].compactMap { $0 }
    }

    private func applyPrefs() {
        let p = services.prefs
        activities.disabled = p.disabledActivities
        activities.sounds = p.sounds
        activities.haptics = p.haptics
        services.downloads.autoShelf = p.autoShelf
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows the control panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        media.stop()
        services.tunnel.stop()  // never leave a local server public after quitting
    }

    // ponytail: rebuild every panel on any display change; diff per screen if this ever flickers
    private func rebuild() {
        controllers.forEach { $0.close() }
        controllers = NSScreen.screens.map { NotchController(screen: $0, media: media, tray: tray, activities: activities, services: services) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
