import Foundation
import SwiftUI

/// "Share publicly": a temporary internet URL for a localhost port.
/// Uses Cloudflare quick tunnels if `cloudflared` is installed, otherwise localhost.run over the
/// system `ssh` (nothing to install). One tunnel at a time; stops on Stop, on quit, or if it drops.
@MainActor @Observable
final class TunnelService {
    enum State: Equatable {
        case idle
        case starting(port: Int)
        case live(port: Int, url: String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private static let urlPattern = try! NSRegularExpression(pattern: #"https://[a-zA-Z0-9.-]+\.(trycloudflare\.com|lhr\.life|localhost\.run)"#)
    @ObservationIgnored var onChange: (State) -> Void = { _ in }
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = ""

    static var provider: String { findTool("cloudflared") != nil ? "Cloudflare" : "localhost.run" }

    var livePort: Int? {
        switch state { case .live(let p, _), .starting(let p): p; default: nil }
    }

    func start(port: Int) {
        stop()
        let p = Process()
        if let cf = findTool("cloudflared") {
            p.executableURL = URL(fileURLWithPath: cf)
            p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://localhost:\(port)"]
        } else {
            // Anonymous localhost.run tunnel. Own known_hosts file: ~/.ssh is never touched.
            // BatchMode: never prompts for a password.
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes",
                           "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=\(appSupportFile("known_hosts").path)",
                           "-R", "80:localhost:\(port)", "nokey@localhost.run"]
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = Pipe()  // keep ssh's stdin open but empty
        buffer = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consume(text, port: port) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.ended() }
        }
        do {
            try p.run()
            process = p
            set(.starting(port: port))
            // Give up if no URL arrives (network down, provider blocked).
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, case .starting = self.state else { return }
                self.stop()
                self.set(.failed("No tunnel URL after 20 s. Check your connection."))
            }
        } catch {
            set(.failed(error.localizedDescription))
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        p.terminate()
        set(.idle)
    }

    private func consume(_ text: String, port: Int) {
        debugLog("tunnel out: \(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
        buffer += text
        if buffer.count > 20_000 { buffer = String(buffer.suffix(4_000)) }
        guard case .starting = state else { return }
        // The banner has other links (admin page, docs) before the tunnel URL: check every match and
        // take the first actual tunnel host.
        let range = NSRange(buffer.startIndex..., in: buffer)
        for m in Self.urlPattern.matches(in: buffer, range: range) {
            guard let r = Range(m.range, in: buffer) else { continue }
            let url = String(buffer[r])
            if let host = URL(string: url)?.host, !["admin.localhost.run", "localhost.run", "www.localhost.run"].contains(host) {
                set(.live(port: port, url: url))
                return
            }
        }
    }

    private func ended() {
        guard process != nil else { return }
        process = nil
        if case .live = state { set(.failed("Tunnel closed")) } else if case .starting = state { set(.failed("Tunnel couldn't start")) }
    }

    private func set(_ s: State) {
        state = s
        debugLog("tunnel: \(s)")
        onChange(s)
    }
}
