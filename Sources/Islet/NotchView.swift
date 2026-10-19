import SwiftUI

@MainActor @Observable
final class NotchModel {
    static let expandedSize = CGSize(width: 680, height: 220)
    static let earRadius: CGFloat = 6
    static let contentInset: CGFloat = 28
    static let airDropZoneWidth: CGFloat = 130

    let notchSize: CGSize
    let media: MediaService
    let tray: TrayStore
    let activities: ActivityCenter
    let services: Services
    /// A text field in the nook has keyboard focus: don't collapse on hover-out.
    private(set) var isEditing = false
    /// Opened with double-Control: ignores hover-out until an outside click or another double-Control.
    private(set) var isLocked = false
    /// Gives keyboard focus back to the app the user was in (Esc in a text field).
    @ObservationIgnored var endEditing: () -> Void = {}
    /// Leave a text field without the out/in blink: drop focus now, hand the keyboard back to your app
    /// when the nook collapses (where the brief hide is invisible behind the notch).
    @ObservationIgnored var dropFocus: () -> Void = {}
    @ObservationIgnored var releaseKeyOnCollapse = false

    func leaveTextField() {
        guard !isLocked else { return }  // locked = you're using the keyboard here on purpose
        dropFocus()
        releaseKeyOnCollapse = true
    }
    private(set) var isExpanded = false
    private(set) var showsActivity: Bool
    var tab: NotchTab = .home
    /// The timer dropdown under the timer chip.
    var timerPanelOpen = false
    /// Keyboard cheat sheet (⌘/).
    var showHelp = false
    /// Lock on/off: the controller takes or releases keyboard focus.
    @ObservationIgnored var onLockChange: (Bool) -> Void = { _ in }
    /// Handing keyboard focus back briefly orders the panel out/in, which looks like the pointer left.
    /// Hover-out is ignored until this time so the nook doesn't blink closed.
    @ObservationIgnored var hoverSuppressedUntil = Date.distantPast
    /// Non-nil while a file drag is over the panel.
    private(set) var dropTarget: DropTarget?
    /// A file drag is close to the notch (not necessarily over it yet).
    private(set) var fileDragNearby = false
    @ObservationIgnored var resizePanel: (CGSize) -> Void = { _ in }
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(notchSize: CGSize, media: MediaService, tray: TrayStore, activities: ActivityCenter, services: Services) {
        self.services = services
        self.notchSize = notchSize
        self.media = media
        self.tray = tray
        self.activities = activities
        showsActivity = activities.current != nil
    }

    /// Width of each side wing of the collapsed live-activity pill.
    var wing: CGFloat { notchSize.height + 10 }

    var visibleSize: CGSize { size(expanded: isExpanded, activity: showsActivity) }

    private func size(expanded: Bool, activity: Bool) -> CGSize {
        if expanded { return Self.expandedSize }
        return CGSize(width: notchSize.width + Self.earRadius * 2 + (activity ? wing * 2 : 0),
                      height: notchSize.height)
    }

    /// Dwell 150 ms before opening, 250 ms grace before closing.
    func hover(_ inside: Bool) {
        if !inside && Date.now < hoverSuppressedUntil { return }
        pending?.cancel()
        guard inside != isExpanded, inside || (!isEditing && !isLocked) else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 250))
            guard !Task.isCancelled, let self else { return }
            self.transition(expanded: inside, activity: self.showsActivity)
        }
    }

    /// File drag over the panel: open immediately (no dwell) and track which zone is targeted.
    func dragMoved(over target: DropTarget) {
        pending?.cancel()
        if dropTarget != target {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dropTarget = target }
        }
        if !isExpanded { transition(expanded: true, activity: showsActivity) }
    }

    /// Drag left or dropped. Stays open while the pointer or a nearby file drag is still around.
    func dragEnded(dropped: DropTarget?, pointerInside: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            dropTarget = nil
            if dropped == .tray { tab = .shelf }
        }
        hover(pointerInside || fileDragNearby)
    }

    /// System-wide file drag approaching (or leaving) the notch: open early, before the
    /// drag can reach the top edge and trigger Mission Control.
    func fileDrag(nearby: Bool, pointerInside: Bool) {
        guard nearby != fileDragNearby else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { fileDragNearby = nearby }
        if nearby {
            pending?.cancel()
            if !isExpanded { transition(expanded: true, activity: showsActivity) }
        } else if dropTarget == nil {
            hover(pointerInside)
        }
    }

    func toggleLock(pointerInside: Bool) {
        if isLocked {
            unlock(pointerInside: pointerInside)
        } else {
            pending?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isLocked = true }
            onLockChange(true)
            if !isExpanded { transition(expanded: true, activity: showsActivity) }
        }
    }

    func unlock(pointerInside: Bool) {
        guard isLocked else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isLocked = false }
        onLockChange(false)
        hover(pointerInside)
    }

    func setEditing(_ editing: Bool, pointerInside: Bool) {
        isEditing = editing
        if !editing { hover(pointerInside) }
    }

    /// Tab actually shown (falls back to Home if the chosen one was switched off).
    var currentTab: NotchTab { tabs.contains(tab) ? tab : .home }

    /// The front app has context actions (built in, or your own buttons).
    var hasAppContext: Bool {
        let ctx = services.context
        return ctx.context.hasActions || services.prefs.customActions.contains { $0.bundleID == ctx.app?.bundleIdentifier }
    }

    /// PDF open in Preview (front app): drops can be merged into it.
    var mergePDF: URL? {
        guard case .preview = services.context.context, let f = services.context.previewFile,
              f.pathExtension.lowercased() == "pdf" else { return nil }
        return f
    }

    /// Tabs shown right now: the App tab only exists while the front app has actions.
    var tabs: [NotchTab] { services.prefs.visibleTabs.filter { $0 != .app || hasAppContext } }

    /// Click on the collapsed pill: an agent needing you → jump straight to its window.
    /// +1 = content slides left (moving right through the tabs), -1 = slides right.
    private(set) var tabDirection = 1
    static let tabSpring = Animation.spring(response: 0.38, dampingFraction: 0.92)

    func select(_ t: NotchTab, direction: Int? = nil) {
        let tabs = self.tabs
        guard t != currentTab, let to = tabs.firstIndex(of: t) else { return }
        let d = direction ?? (to > (tabs.firstIndex(of: currentTab) ?? 0) ? 1 : -1)
        if d == tabDirection {
            withAnimation(Self.tabSpring) { tab = t }
        } else {
            // The outgoing page takes its exit edge from the last frame it was drawn in, so the new
            // direction must land one frame before the switch (16 ms, not noticeable).
            tabDirection = d
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                withAnimation(Self.tabSpring) { self?.tab = t }
            }
        }
    }

    func selectTab(_ index: Int) {
        let tabs = self.tabs
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    func cycleTab(_ step: Int) {
        let tabs = self.tabs
        let i = tabs.firstIndex(of: currentTab) ?? 0
        select(tabs[(i + step + tabs.count) % tabs.count], direction: step)
    }

    /// A file job in progress ("Merging…"): capsule with a moving bar when open, pill when closed.
    private(set) var workLabel: String?

    func beginWork(_ label: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { workLabel = label }
        activities.working = label
    }

    func endWork() {
        withAnimation(.easeOut(duration: 0.2)) { workLabel = nil }
        activities.working = nil
    }

    /// "✓ Added to Shelf" toast inside the open nook (independent of the tab you're on).
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// A Preview/Finder output is ready: put it on the Shelf (with animation + sound), and bring Finder to
    /// the front with the file selected. Lives on the model, so it works even if the panel or nook closed.
    func deliver(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        endWork()
        tray.add(urls)
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        activities.chime("Pop")
        activities.show(.shelved(name: name), for: 4)  // pill when the nook is closed
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { toast = name }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }

    func jumpToWaitingAgent() {
        if let a = services.agents.agents.first(where: { $0.state == .waiting }) { jump(toApp: a.hostApp) }
    }

    func pillTapped() {
        if case .needsYou = activities.current, let a = services.agents.agents.first(where: { $0.state == .waiting }) {
            jump(toApp: a.hostApp)
        } else if case .privacy = activities.current {
            services.privacy.toggleMute()  // All Mute from the collapsed notch
        }
    }

    func setActivity(_ on: Bool) {
        guard on != showsActivity else { return }
        transition(expanded: isExpanded, activity: on)
    }

    /// Growing: resize the panel first (layout committed, no animation), spring on the next turn.
    /// Shrinking: spring first, shrink the panel when it settles.
    private func transition(expanded: Bool, activity: Bool) {
        let old = visibleSize, new = size(expanded: expanded, activity: activity)
        generation += 1
        let gen = generation
        let spring: Animation = expanded && !isExpanded
            ? .spring(response: 0.42, dampingFraction: 0.78)
            : .spring(response: 0.32, dampingFraction: 0.9)
        if new.width > old.width || new.height > old.height {
            resizePanel(CGSize(width: max(old.width, new.width), height: max(old.height, new.height)))
            Task { [weak self] in self?.animate(expanded: expanded, activity: activity, spring: spring, gen: gen) }
        } else {
            animate(expanded: expanded, activity: activity, spring: spring, gen: gen)
        }
    }

    private func animate(expanded: Bool, activity: Bool, spring: Animation, gen: Int) {
        guard gen == generation else { return }
        if expanded && !isExpanded && services.prefs.haptics { haptic() }
        if expanded && !isExpanded { services.context.refresh() }
        if expanded && !isExpanded && dropTarget == nil && !fileDragNearby, services.prefs.openToAppTab {
            // Apps with context actions (built in, or your own buttons) open on the App tab;
            // everything else (Music, Mail, …) opens on Home instead of a leftover App tab.
            if hasAppContext { tab = .app } else if tab == .app { tab = .home }
        }
        withAnimation(spring) {
            isExpanded = expanded
            showsActivity = activity
            if !expanded { timerPanelOpen = false; showHelp = false }
        } completion: { [weak self] in
            guard let self, self.generation == gen else { return }
            self.resizePanel(self.visibleSize)
            if !expanded {
                // Hand freed view/render memory back to macOS as soon as the nook closes.
                malloc_zone_pressure_relief(nil, 0)
            }
            if !expanded && self.releaseKeyOnCollapse {
                self.releaseKeyOnCollapse = false
                self.endEditing()
            }
        }
    }
}

struct NotchView: View {
    let model: NotchModel

    var body: some View {
        let size = model.visibleSize
        ZStack(alignment: .top) {
            NotchShape(earRadius: NotchModel.earRadius, bottomRadius: model.isExpanded ? 32 : 10)
                .fill(.black)  // stays seamless with the hardware notch; "needs you" is the ✋ + bounce + sound
            if model.isExpanded {
                ExpandedContent(model: model)
                    .padding(.top, model.notchSize.height)
                    .overlay(alignment: .topLeading) { TopTabs(model: model) }
                    .overlay(alignment: .topTrailing) { TopRight(model: model) }
                    .overlay(alignment: .topTrailing) {
                        if model.timerPanelOpen {
                            TimerPanel(center: model.activities) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.timerPanelOpen = false }
                            }
                            .padding(.top, model.notchSize.height + 2)
                            .padding(.trailing, NotchModel.contentInset - 10)
                            .transition(.scale(scale: 0.9, anchor: .topTrailing).combined(with: .opacity))
                        }
                    }
                    // No blur: it forces offscreen rendering every frame of the spring.
                    .overlay(alignment: .bottom) {
                        if let label = model.workLabel, model.toast == nil {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.gearshape").foregroundStyle(.blue).symbolEffect(.pulse)
                                Text(label).font(.system(size: 11, weight: .semibold))
                                ProgressView().progressViewStyle(.linear).tint(.blue).frame(width: 70)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Color(white: 0.14)))
                            .overlay(Capsule().strokeBorder(.blue.opacity(0.35)))
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let name = model.toast {
                            HStack(spacing: 7) {
                                Image(systemName: "tray.and.arrow.down.fill").foregroundStyle(.green)
                                    .symbolEffect(.bounce, value: name)
                                Text("Added to Shelf").font(.system(size: 11, weight: .semibold))
                                Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(Color(white: 0.14)))
                            .overlay(Capsule().strokeBorder(.green.opacity(0.35)))
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .overlay {
                        if model.showHelp {
                            ShortcutsHelp().transition(.scale(scale: 0.95).combined(with: .opacity))
                        }
                    }
                    // Opening unchanged. Closing: content fades out in 0.12 s, well inside the notch's own
                    // spring, so nothing is left showing after the black shape has closed.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: .top).combined(with: .opacity),
                        removal: .scale(scale: 0.95, anchor: .top).combined(with: .opacity)
                            .animation(.easeOut(duration: 0.08))))
            } else if model.showsActivity, let activity = model.activities.current {
                ActivityWings(activity: activity, media: model.media.state, height: model.notchSize.height)
                    .padding(.horizontal, NotchModel.earRadius + 8)
                    .frame(height: model.notchSize.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.pillTapped() }
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        // Content can never draw outside the black notch, at any point of the spring.
        .clipShape(NotchShape(earRadius: NotchModel.earRadius, bottomRadius: model.isExpanded ? 32 : 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct ExpandedContent: View {
    let model: NotchModel

    var body: some View {
        let s = model.services
        Group {
            if model.dropTarget != nil || model.fileDragNearby {
                DropZones(target: model.dropTarget, trayCount: model.tray.items.count,
                          mergeInto: model.mergePDF?.lastPathComponent)
            } else {
                // Every page fills the same frame and slides in from the side you're moving toward.
                let d = model.tabDirection
                ZStack {
                    Group {
                        switch model.currentTab {
                        case .home: HomeView(model: model)
                        case .app: AppTabView(model: model)
                        case .work: WorkView(agents: s.agents, tasks: s.tasks, downloads: s.downloads, openSettings: s.openSettings)
                        case .dev: DevView()
                        case .shelf: TrayView(tray: model.tray)
                        case .camera: CameraTabView(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .id(model.currentTab)
                    .transition(.asymmetric(
                        insertion: .move(edge: d > 0 ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: d > 0 ? .leading : .trailing).combined(with: .opacity)))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, NotchModel.contentInset)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

/// Tab switcher in the strip left of the hardware notch.
private struct TopTabs: View {
    let model: NotchModel

    var body: some View {
        let waiting = model.services.agents.agents.filter { $0.state == .waiting }.count
        let tabs = model.tabs
        let index = CGFloat(tabs.firstIndex(of: model.currentTab) ?? 0)
        // The bar itself never changes; one highlight capsule slides to the selected tab.
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.16))
                .frame(width: 28, height: 22)
                .offset(x: index * 30)
            HStack(spacing: 2) {
                ForEach(tabs) { t in
                    tab(t, badge: t == .work ? waiting : t == .shelf ? model.tray.items.count : 0,
                        badgeColor: t == .work ? .orange : .blue)
                }
            }
        }
        .frame(height: model.notchSize.height)
        .padding(.leading, NotchModel.contentInset - 8)
    }

    private func tab(_ t: NotchTab, badge: Int, badgeColor: Color) -> some View {
        let selected = model.currentTab == t
        return Button {
            model.select(t)
        } label: {
            Image(systemName: t.symbol)
                .font(.system(size: 11, weight: .medium))
                .symbolEffect(.bounce, value: t == .shelf ? badge : 0)  // Shelf icon hops when something lands
                .frame(width: 28, height: 22)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 3).background(Capsule().fill(badgeColor)).offset(x: 3, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(selected ? 1 : 0.5))
        .help(t.title)
    }
}

/// Lock indicator, timer chip and control-panel button, right of the hardware notch.
private struct TopRight: View {
    let model: NotchModel

    var body: some View {
        HStack(spacing: 6) {
            PrivacyButtons(privacy: model.services.privacy)
            if model.activities.keepingAwake {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Keeping your Mac awake while agents or tasks run")
                    .transition(.scale.combined(with: .opacity))
            }
            if model.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .transition(.scale.combined(with: .opacity))
                    .help("Locked open — click outside or double-tap Control to close")
            }
            TimerButton(center: model.activities, isOpen: model.timerPanelOpen) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { model.timerPanelOpen.toggle() }
            }
            IconButton(symbol: "gearshape.fill", help: "Control panel", action: model.services.openSettings)
        }
        .frame(height: model.notchSize.height)
        .padding(.trailing, NotchModel.contentInset - 10)
    }
}

struct Player: View {
    let media: MediaService
    var artSize: CGFloat = 76

    var body: some View {
        let s = media.state
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Artwork(image: s.artwork, corner: 12)
                    .frame(width: artSize, height: artSize)
                    .overlay(alignment: .bottomTrailing) {
                        if let icon = s.appIcon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22).offset(x: 6, y: 6)
                        }
                    }
                    .onTapGesture { openSourceApp(s.bundleID) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title ?? "").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(s.artist ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Bars(playing: s.isPlaying, color: s.accent)
            }
            Scrubber(media: media)
            HStack(spacing: 34) {
                ControlButton(symbol: "backward.fill", size: 18) { media.previous() }
                ControlButton(symbol: s.isPlaying ? "pause.fill" : "play.fill", size: 26) { media.togglePlayPause() }
                ControlButton(symbol: "forward.fill", size: 18) { media.next() }
            }
        }
    }

    private func openSourceApp(_ bundleID: String?) {
        guard let id = bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

/// Only this view re-renders while playing, and only twice a second, only while expanded.
private struct Scrubber: View {
    let media: MediaService
    // ponytail: plain State values, not @State: Command Line Tools lack the SwiftUIMacros plugin.
    // Switch back to @State once building with Xcode.
    private let drag = State<Double?>(initialValue: nil)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let s = media.state
            let pos = s.position(at: ctx.date)
            let dragFraction = drag.wrappedValue
            let fraction = dragFraction ?? (s.duration > 0 ? pos / s.duration : 0)
            HStack(spacing: 10) {
                Text(Self.format(dragFraction.map { $0 * s.duration } ?? pos))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(s.accent).frame(width: g.size.width * fraction)
                    }
                    .frame(height: dragFraction == nil ? 5 : 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag.wrappedValue = min(max($0.location.x / g.size.width, 0), 1) }
                        .onEnded { _ in
                            if let f = dragFraction, s.duration > 0 { media.seek(to: f * s.duration) }
                            drag.wrappedValue = nil
                        })
                }
                .frame(height: 14)
                Text("-" + Self.format(max(s.duration - pos, 0)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
    }

    private static func format(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 34)
                .background(Circle().fill(.white.opacity(hover.wrappedValue ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .animation(.easeOut(duration: 0.15), value: hover.wrappedValue)
    }
}

// MARK: Shared pieces

struct Artwork: View {
    let image: NSImage?
    let corner: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(.white.opacity(0.12))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note").foregroundStyle(.white.opacity(0.5))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

/// Four bars bouncing via Core Animation layers: the render server runs the loop,
/// so the app does no per-frame work (SwiftUI repeatForever cost ~4.5 % CPU).
struct Bars: NSViewRepresentable {
    let playing: Bool
    let color: Color

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.update(playing: playing, color: NSColor(color).cgColor)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsView, context: Context) -> CGSize? {
        CGSize(width: 22, height: 16)
    }
}

final class BarsView: NSView {
    private static let durations: [CFTimeInterval] = [0.42, 0.58, 0.36, 0.5]
    private var bars: [CALayer] = []
    private var playing: Bool?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 16))
        wantsLayer = true
        for i in 0..<4 {
            let bar = CALayer()
            bar.frame = CGRect(x: CGFloat(i) * 5.5, y: 0, width: 3, height: 16)
            bar.cornerRadius = 1.5
            bar.transform = CATransform3DMakeScale(1, 0.3, 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(playing: Bool, color: CGColor) {
        bars.forEach { $0.backgroundColor = color }
        guard playing != self.playing else { return }
        self.playing = playing
        for (bar, d) in zip(bars, Self.durations) {
            bar.removeAnimation(forKey: "bounce")
            guard playing else { continue }
            let a = CABasicAnimation(keyPath: "transform.scale.y")
            a.fromValue = 0.3
            a.toValue = 1
            a.duration = d
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.add(a, forKey: "bounce")
        }
    }
}

private struct Blur: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

/// Notch outline: concave "ears" at the top edge flowing into rounded bottom corners.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set { earRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let e = earRadius
        let b = min(bottomRadius, (rect.width - 2 * e) / 2, rect.height - e)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e),
                       control: CGPoint(x: rect.minX + e, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + e + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - e, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
