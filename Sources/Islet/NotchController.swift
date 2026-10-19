import AppKit
import SwiftUI

/// Hardware notch size, or a fake pill on screens without one.
struct NotchGeometry {
    let notch: CGSize

    init(screen: NSScreen) {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width,
                           height: screen.safeAreaInsets.top)
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notch = CGSize(width: 190, height: max(menuBar, 24))
        }
    }
}

/// One borderless, non-activating panel pinned to the top centre of a screen.
/// Collapsed: panel is exactly the notch, so nothing else on the menu bar is blocked.
/// Expanded: panel grows first, then SwiftUI animates the shape inside it.
@MainActor
final class NotchController {
    private let panel: NSPanel
    let model: NotchModel
    let screenFrame: NSRect

    init(screen: NSScreen, media: MediaService, tray: TrayStore, activities: ActivityCenter, services: Services) {
        screenFrame = screen.frame
        model = NotchModel(notchSize: NotchGeometry(screen: screen).notch, media: media, tray: tray, activities: activities, services: services)

        panel = KeyOnDemandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        // Becomes key only when a text field is clicked; the user's app stays active (Spotlight-style).
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // No .fullScreenAuxiliary: hides itself over full-screen apps for free.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = HoverHostingView(rootView: NotchView(model: model))
        panel.contentView = host
        host.onHover = { [weak self] inside in
            self?.setKeyTap(inside)
            self?.model.hover(inside)
        }

        model.resizePanel = { [weak self] size in self?.resize(to: size) }
        model.endEditing = { [weak self] in
            guard let self, self.panel.isKeyWindow else { return }
            self.model.hoverSuppressedUntil = .now + 0.5
            // Ordering out drops key status; keyboard focus returns to the app the user was in.
            self.panel.orderOut(nil)
            self.panel.orderFrontRegardless()
        }
        for (name, editing) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.model.setEditing(editing, pointerInside: self.panel.frame.contains(NSEvent.mouseLocation))
                }
            }
        }

        host.registerForDraggedTypes([.fileURL])
        host.onDrag = { [weak self] x, width in
            guard let self else { return }
            self.model.dragMoved(over: self.zone(x: x, width: width))
        }
        host.onDragEnd = { [weak self] urls, x, width in
            guard let self else { return }
            let target = urls.isEmpty ? nil : self.zone(x: x, width: width)
            switch target {
            case .tray: self.model.tray.add(urls)
            case .airDrop: AirDrop.send(urls)
            case nil: break
            }
            self.model.dragEnded(dropped: target, pointerInside: self.panel.frame.contains(NSEvent.mouseLocation))
        }

        resize(to: model.visibleSize)
        setUpKeyboard()
        panel.orderFrontRegardless()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: false); CFMachPortInvalidate(keyTap) }
        panel.close()
    }

    private var keyMonitor: Any?

    /// Double-Control opens the nook with keyboard focus (Spotlight-style: the panel is key, your app
    /// stays active). Hover never takes focus, so typing elsewhere is never hijacked.
    private func setUpKeyboard() {
        model.onLockChange = { [weak self] locked in
            guard let self else { return }
            if locked {
                self.panel.becomesKeyOnlyIfNeeded = false
                self.panel.makeKey()
            } else {
                self.panel.becomesKeyOnlyIfNeeded = true
                self.model.endEditing()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            nonisolated(unsafe) let event = e
            let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return swallowed ? nil : e
        }
    }

    // MARK: Shortcuts when opened by hover

    private var keyTap: CFMachPort?

    /// Hover-opened nooks don't take keyboard focus (your typing stays in your app), so a key tap catches
    /// just the notch shortcuts while the pointer is over the open nook. It's switched off the moment the
    /// pointer leaves; when off it costs nothing. Needs Accessibility (already granted for the hotkey).
    private func setKeyTap(_ on: Bool) {
        if on && keyTap == nil { createKeyTap() }
        if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: on) }
        debugLog("keytap: \(keyTap == nil ? "unavailable" : (on ? "on" : "off"))")
    }

    private func createKeyTap() {
        let ref = Unmanaged.passUnretained(self).toOpaque()
        keyTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                   eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                   callback: { _, type, event, ref in
            guard let ref else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<NotchController>.fromOpaque(ref).takeUnretainedValue()
            nonisolated(unsafe) let ev = event
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = me.keyTap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard me.model.isExpanded, !me.panel.isKeyWindow, let ns = NSEvent(cgEvent: ev) else { return false }
                return me.handle(ns, fromTap: true)
            }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: ref)
        guard let keyTap else { return }  // not trusted for Accessibility yet: retried on next hover
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, keyTap, 0), .commonModes)
    }

    /// Returns true when the key was a notch shortcut (and is swallowed).
    private func handle(_ e: NSEvent, fromTap: Bool = false) -> Bool {
        guard fromTap || e.window === panel, model.isExpanded else { return false }
        let s = model.services
        let cmd = e.modifierFlags.contains(.command)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)

        if e.keyCode == 53 {  // Esc: close the innermost thing
            if fromTap && !model.timerPanelOpen && !model.showHelp { return false }  // hover mode: Esc stays with your app
            if model.timerPanelOpen { withAnimation(spring) { model.timerPanelOpen = false } }
            else if model.showHelp { withAnimation(spring) { model.showHelp = false } }
            else { model.unlock(pointerInside: false) }
            return true
        }
        if cmd {
            switch (e.keyCode, key) {
            case (123, _): model.media.previous()
            case (124, _): model.media.next()
            case (_, ","): s.openSettings()
            case (_, "t"): withAnimation(spring) { model.timerPanelOpen.toggle() }
            case (_, "/"): withAnimation(spring) { model.showHelp.toggle() }
            case (_, let k) where Int(k).map({ (1...9).contains($0) }) == true: model.selectTab(Int(k)! - 1)
            default: return false
            }
            return true
        }
        if model.timerPanelOpen {
            let presets: [String: Double] = ["1": 1, "2": 3, "3": 5, "4": 10, "5": 25, "6": 45]
            if let m = presets[key] { model.activities.startTimer(minutes: m) }
            else if key == "f" { model.activities.startFocus() }
            else if key == "x" { model.activities.cancelTimer() }
            else { return false }
            withAnimation(spring) { model.timerPanelOpen = false }
            return true
        }
        switch (e.keyCode, key) {
        case (123, _): model.cycleTab(-1)
        case (124, _): model.cycleTab(1)
        case (49, _): model.media.togglePlayPause()
        case (_, "m"): s.privacy.toggleMute()
        case (_, "j"): model.jumpToWaitingAgent()
        case (_, "?"): withAnimation(spring) { model.showHelp.toggle() }
        default: return false
        }
        return true
    }

    func toggleLock() { model.toggleLock(pointerInside: panel.frame.contains(NSEvent.mouseLocation)) }

    /// File drag anywhere on screen (nil = drag finished). Opens the nook while the drag is within
    /// 250 pt below the notch and 300 pt either side of it.
    func fileDrag(at point: NSPoint?) {
        let p = point ?? NSEvent.mouseLocation
        let nearby = point != nil && screenFrame.contains(p)
            && abs(p.x - screenFrame.midX) < 300 && p.y > screenFrame.maxY - 250
        model.fileDrag(nearby: nearby, pointerInside: panel.frame.contains(p))
    }

    /// Right-hand strip of the expanded nook is the AirDrop zone; everything else is the tray.
    private func zone(x: CGFloat, width: CGFloat) -> DropTarget {
        guard model.isExpanded else { return .tray }
        return x > width - NotchModel.contentInset - NotchModel.airDropZoneWidth - 6 ? .airDrop : .tray
    }

    private func resize(to size: CGSize) {
        panel.setFrame(NSRect(x: screenFrame.midX - size.width / 2,
                              y: screenFrame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        // Commit the new layout now, outside any animation, so the shape stays centred
        // under the notch instead of sliding in from the window's new left edge.
        panel.contentView?.layoutSubtreeIfNeeded()
    }
}

/// Borderless panels refuse key status by default; text fields in the nook need it.
final class KeyOnDemandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosting view with an always-active tracking area: works while another app is frontmost.
final class HoverHostingView: NSHostingView<NotchView> {
    var onHover: (Bool) -> Void = { _ in }
    /// x position and view width while a file drag moves over the panel.
    var onDrag: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// Dropped file URLs (empty if the drag just left) with the drop x position and view width.
    var onDragEnd: ([URL], CGFloat, CGFloat) -> Void = { _, _, _ in }

    required init(rootView: NotchView) {
        super.init(rootView: rootView)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Non-activating panel: buttons must work on the first click without focusing the app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        onDrag(convert(sender.draggingLocation, from: nil).x, bounds.width)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDragEnd([], 0, bounds.width) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        onDragEnd(urls, convert(sender.draggingLocation, from: nil).x, bounds.width)
        return !urls.isEmpty
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover(true) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onHover(false) }
}
