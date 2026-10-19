import AppKit
import ApplicationServices
import EventKit
import ServiceManagement
import SwiftUI

/// First-run setup. Shown once (or from Control panel → About). Built on open, released on close.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() })
            w.setContentSize(NSSize(width: 560, height: 470))
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        Self.done = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}

enum Installer {
    static var inApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Copies this app to /Applications (an older copy goes to the Trash), then relaunches from there.
    static func moveToApplications() throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/Islet.app")
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: dest)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(dest.path)\""]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}

private enum Step: Int, CaseIterable { case welcome, install, permissions, claude, finish }

private struct OnboardingView: View {
    let onDone: () -> Void
    private let step = State(initialValue: Step.welcome)
    private let tick = State(initialValue: 0)          // re-reads permission/install state
    private let error = State<String?>(initialValue: nil)
    private let calendarGranted = State(initialValue: EKEventStore.authorizationStatus(for: .event) == .fullAccess)

    var body: some View {
        let _ = tick.wrappedValue
        VStack(spacing: 0) {
            Group {
                switch step.wrappedValue {
                case .welcome: welcome
                case .install: install
                case .permissions: permissions
                case .claude: claude
                case .finish: finish
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40).padding(.top, 36)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step.wrappedValue)

            if let e = error.wrappedValue { Text(e).font(.caption).foregroundStyle(.red).padding(.bottom, 6) }
            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.rawValue) { s in
                        Circle().fill(s == step.wrappedValue ? Color.accentColor : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step.wrappedValue != .welcome {
                    Button("Back") { go(-1) }.keyboardShortcut(.cancelAction)
                }
                Button(step.wrappedValue == .finish ? "Start using Islet" : "Continue") {
                    step.wrappedValue == .finish ? onDone() : go(1)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(step.wrappedValue == .install && !Installer.inApplications)
            }
            .padding(20)
        }
        .frame(width: 560, height: 470)
        // Permission changes happen in System Settings: re-check whenever we come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in tick.wrappedValue += 1 }
    }

    private func go(_ d: Int) {
        error.wrappedValue = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            step.wrappedValue = Step(rawValue: step.wrappedValue.rawValue + d) ?? step.wrappedValue
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Welcome to Islet").font(.largeTitle.weight(.semibold))
            Text("Mission control for background work").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                tip("cursorarrow.motionlines", "Move the pointer to the notch to open it.")
                tip("control", "Double-tap Control to open it locked, then ⌘1–⌘6 to switch tabs.")
                tip("sparkles", "See your Claude Code agents: running, waiting for you, done.")
                tip("tray.and.arrow.down", "Drop files on the notch to park them or AirDrop them.")
            }
            .padding(.top, 8)
        }
    }

    private var install: some View {
        VStack(spacing: 14) {
            header("folder.badge.plus", "Install in Applications")
            if Installer.inApplications {
                Label("Islet is in Applications", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
                Text("All set. Continue to permissions.").foregroundStyle(.secondary)
            } else {
                Text("Islet is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path). Move it to Applications so it keeps working after you eject the disk image, and so Claude Code can find it.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Move to Applications and Relaunch") {
                    do { try Installer.moveToApplications() } catch { self.error.wrappedValue = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("lock.shield", "Permissions").frame(maxWidth: .infinity)
            permissionRow("Accessibility", "Double-tap Control and keyboard shortcuts. Islet reads only the Control key state, never what you type.",
                          granted: AXIsProcessTrusted()) {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            permissionRow("Calendar (optional)", "Shows your next meeting with a one-click Join.", granted: calendarGranted.wrappedValue) {
                Task {
                    calendarGranted.wrappedValue = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
                }
            }
            Text("Camera, browser and Finder access are asked only when you first use those features.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var claude: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("sparkles", "Connect Claude Code").frame(maxWidth: .infinity)
            if !ClaudeHooks.claudePresent {
                Text("Claude Code isn't installed on this Mac. You can connect it later from Control panel → Agents.")
                    .foregroundStyle(.secondary)
            } else {
                permissionRow("Agent status hooks", "Islet shows each Claude session as running, needs you, done or error. Adds hooks to ~/.claude/settings.json (your settings are kept and backed up).",
                              granted: ClaudeHooks.isInstalled, action: "Connect") {
                    do { try ClaudeHooks.install() } catch { self.error.wrappedValue = error.localizedDescription }
                    tick.wrappedValue += 1
                }
            }
            permissionRow("`islet` command", "Run `islet run npm test` in any terminal to watch long tasks in the notch.",
                          granted: CLIInstaller.isInstalled, action: "Install") {
                do { try CLIInstaller.install() } catch { self.error.wrappedValue = error.localizedDescription }
                tick.wrappedValue += 1
            }
            Text("Usage meter: reads Claude Code's local logs. Nothing leaves your Mac.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var finish: some View {
        VStack(spacing: 14) {
            header("checkmark.seal.fill", "You're set")
            Toggle("Open Islet at login", isOn: Binding(
                get: { _ = tick.wrappedValue; return SMAppService.mainApp.status == .enabled },
                set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister(); tick.wrappedValue += 1 }))
            .toggleStyle(.switch)
            Text("Everything can be changed later in the control panel: click the gear in the notch, or press ⌘, while it's open.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func header(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(Color.accentColor)
            Text(title).font(.title.weight(.semibold))
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 22) }
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, action: String = "Allow",
                               perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
