import AppKit
import ApplicationServices
import SwiftUI

/// Detects a quick double tap of Control on its own: down/up, down/up, each press held
/// ≤ 0.3 s, second release ≤ 0.4 s after the first. Any other key or modifier in between
/// (e.g. Ctrl+C) cancels it.
struct DoubleTapDetector {
    var maxHold: TimeInterval = 0.3
    var maxGap: TimeInterval = 0.4
    private var downAt: TimeInterval?
    private var lastTapAt: TimeInterval?

    /// Control went down or up. `alone` = no other modifier held. Returns true on a completed double tap.
    mutating func control(down: Bool, alone: Bool, at t: TimeInterval) -> Bool {
        if down {
            downAt = alone ? t : nil
            if !alone { lastTapAt = nil }
            return false
        }
        guard let d = downAt, t - d <= maxHold else { reset(); return false }
        downAt = nil
        if let last = lastTapAt, t - last <= maxGap {
            lastTapAt = nil
            return true
        }
        lastTapAt = t
        return false
    }

    mutating func reset() {
        downAt = nil
        lastTapAt = nil
    }

    /// Run with MYNOTCH_SELFTEST=1.
    static func selfTest() {
        var d = DoubleTapDetector()
        // Clean double tap.
        precondition(!d.control(down: true, alone: true, at: 0.00))
        precondition(!d.control(down: false, alone: true, at: 0.08))
        precondition(!d.control(down: true, alone: true, at: 0.20))
        precondition(d.control(down: false, alone: true, at: 0.28))
        // Too slow between taps.
        d.reset()
        _ = d.control(down: true, alone: true, at: 0); _ = d.control(down: false, alone: true, at: 0.1)
        _ = d.control(down: true, alone: true, at: 0.6)
        precondition(!d.control(down: false, alone: true, at: 0.7))
        // Held too long (Control used as a modifier for a click etc.).
        d.reset()
        _ = d.control(down: true, alone: true, at: 0); _ = d.control(down: false, alone: true, at: 0.5)
        _ = d.control(down: true, alone: true, at: 0.6)
        precondition(!d.control(down: false, alone: true, at: 0.65))
        // Ctrl+C in between cancels.
        d.reset()
        _ = d.control(down: true, alone: true, at: 0); _ = d.control(down: false, alone: true, at: 0.1)
        d.reset()  // keyDown
        _ = d.control(down: true, alone: true, at: 0.2)
        precondition(!d.control(down: false, alone: true, at: 0.25))
        // Shift held with Control doesn't count.
        d.reset()
        _ = d.control(down: true, alone: false, at: 0); _ = d.control(down: false, alone: true, at: 0.1)
        _ = d.control(down: true, alone: true, at: 0.2)
        precondition(!d.control(down: false, alone: true, at: 0.3))
        print("DoubleTapDetector self-test passed")
    }
}

/// Shortcuts inside the nook (active when it was opened with double-Control).
enum Shortcuts {
    static let list: [(keys: String, action: String)] = [
        ("⌃ ⌃", "Open / close the notch (locked)"),
        ("⌘1 … ⌘4", "Switch tab, in order"),
        ("← →", "Previous / next tab"),
        ("⌘,", "Control panel"),
        ("⌘T", "Timer  ·  then 1–6 presets, F focus, X cancel"),
        ("Space", "Play / pause"),
        ("⌘← ⌘→", "Previous / next track"),
        ("M", "Mute / unmute microphone (all apps)"),
        ("J", "Jump to the agent that needs you"),
        ("⌘/  or  ?", "Show these shortcuts"),
        ("Esc", "Close"),
    ]
}

struct ShortcutsHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Keyboard").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Shortcuts.list, id: \.keys) { s in
                    GridRow {
                        Text(s.keys).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text(s.action).font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
    }
}

/// Global double-Control hotkey. Needs Accessibility permission: macOS only delivers other
/// apps' keyboard events to trusted apps. Only the event type and Control flag are read;
/// no key contents are looked at or stored.
@MainActor
final class HotkeyMonitor {
    var onDoubleControl: () -> Void = {}
    private var detector = DoubleTapDetector()
    private var monitors: [Any] = []
    private static let controlKeyCodes: Set<UInt16> = [59, 62]  // left, right Control

    private var trustPoll: Timer?

    func start() {
        debugLog("hotkey: accessibility trusted=\(AXIsProcessTrusted()) path=\(Bundle.main.bundlePath)")
        guard !AXIsProcessTrusted() else { install(); return }
        // Shows the system prompt pointing at Privacy & Security → Accessibility, then waits for the
        // grant so no relaunch is needed. Checks every 2 s only until trusted.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted() else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
                self.install()
            }
        }
    }

    private func install() {
        debugLog("hotkey: listening for double Control")
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e
        }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        guard e.type == .flagsChanged else { detector.reset(); return }
        guard Self.controlKeyCodes.contains(e.keyCode) else { detector.reset(); return }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let down = flags.contains(.control)
        if detector.control(down: down, alone: !down || flags == [.control], at: e.timestamp) {
            onDoubleControl()
        }
    }
}
