import AppKit
import AVFoundation
import SwiftUI

/// Camera for the Camera tab. Runs only while the tab is on screen; stops on tab switch or collapse.
@MainActor @Observable
final class CameraController {
    private(set) var running = false
    private(set) var denied = false
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private var configured = false
    private static let queue = DispatchQueue(label: "camera.session")

    func start() {
        guard !running else { return }
        running = true
        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else { denied = true; running = false; return }
            guard running else { return }  // tab left while the prompt was up
            if !configured {
                configured = true
                session.sessionPreset = .high
                if let cam = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: cam),
                   session.canAddInput(input) { session.addInput(input) }
            }
            nonisolated(unsafe) let s = session
            Self.queue.async { s.startRunning() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        nonisolated(unsafe) let s = session
        Self.queue.async { s.stopRunning() }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        // Mirror like a real mirror (your right on the right). Flipping the layer always works; the
        // connection's isVideoMirrored doesn't exist yet when the view is made, so it was silently skipped.
        layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A soft white (or warm) glow around the screen edges that lights your face, like a ring light.
/// Click-through, below the notch, drawn once (static: no per-frame cost).
@MainActor
final class RingLight {
    private var window: NSWindow?

    func show(on screen: NSScreen?, intensity: Double, warmth: Double) {
        guard let screen = screen ?? NSScreen.main else { return }
        if window == nil {
            let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.level = .statusBar  // above apps, below the notch panel
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.setFrame(screen.frame, display: false)
        window?.contentView = NSHostingView(rootView: RingGlow(intensity: intensity, warmth: warmth))
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
        window?.contentView = nil
    }
}

private struct RingGlow: View {
    let intensity: Double
    let warmth: Double

    var body: some View {
        // Neutral white → warm (about 3200 K) as warmth goes 0 → 1.
        let color = Color(red: 1, green: 1 - 0.12 * warmth, blue: 1 - 0.38 * warmth)
        ZStack {
            RoundedRectangle(cornerRadius: 28).strokeBorder(color.opacity(intensity), lineWidth: 70).blur(radius: 26)
            RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(intensity), lineWidth: 26)
        }
        .ignoresSafeArea()
    }
}

/// Camera tab: the nook is the camera; ring light controls along the bottom.
struct CameraTabView: View {
    let model: NotchModel

    var body: some View {
        let cam = model.services.camera
        let prefs = model.services.prefs
        ZStack(alignment: .bottom) {
            Group {
                if cam.denied {
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash").font(.system(size: 24))
                        Text("Camera access is off. Allow it in System Settings → Privacy & Security → Camera.")
                            .font(.system(size: 11)).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.55))
                } else {
                    CameraPreview(session: cam.session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Toggle(isOn: Binding(get: { prefs.ringLight }, set: { prefs.ringLight = $0; syncRing() })) {
                    Label("Ring light", systemImage: "light.max").font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.switch).controlSize(.mini)
                if prefs.ringLight {
                    Image(systemName: "sun.min").font(.system(size: 10))
                    Slider(value: Binding(get: { prefs.ringIntensity }, set: { prefs.ringIntensity = $0; syncRing() }), in: 0.25...1)
                        .frame(width: 110).controlSize(.mini)
                    Image(systemName: "thermometer.sun").font(.system(size: 10))
                    Slider(value: Binding(get: { prefs.ringWarmth }, set: { prefs.ringWarmth = $0; syncRing() }), in: 0...1)
                        .frame(width: 90).controlSize(.mini)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(.black.opacity(0.55)))
            .padding(.bottom, 8)
        }
        .foregroundStyle(.white)
        .onAppear { cam.start(); syncRing() }
        .onDisappear { cam.stop(); model.services.ringLight.hide() }
    }

    private func syncRing() {
        let p = model.services.prefs
        if p.ringLight && model.services.camera.running {
            model.services.ringLight.show(on: NSScreen.main, intensity: p.ringIntensity, warmth: p.ringWarmth)
        } else {
            model.services.ringLight.hide()
        }
    }
}
