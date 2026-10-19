import AppKit
import SwiftUI

// MARK: Event bus (fed by the `islet` CLI and agent hooks)

/// Listens for `com.yashtyagi.Islet.event` distributed notifications. Zero cost when idle:
/// no polling, no sockets, no files. Payloads are capped so a misbehaving sender can't bloat memory.
@MainActor
final class EventBus {
    static let name = Notification.Name("com.yashtyagi.Islet.event")
    var onAgent: ([String: String]) -> Void = { _ in }
    var onTask: ([String: String]) -> Void = { _ in }
    var onSettings: () -> Void = {}

    func start() {
        DistributedNotificationCenter.default().addObserver(forName: Self.name, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo as? [String: String] ?? [:]
            let info = raw.mapValues { String($0.prefix(300)) }
            MainActor.assumeIsolated {
                guard let self else { return }
                debugLog("event: \(info["kind"] ?? "?") \(info["state"] ?? "")")
                switch info["kind"] {
                case "agent": self.onAgent(info)
                case "task": self.onTask(info)
                case "settings": self.onSettings()
                default: break
                }
            }
        }
    }
}

/// Brings the app that ran an agent or command (Terminal, iTerm, VS Code, Cursor…) to the front.
func jump(toApp path: String) {
    guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else { return }
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
}

// MARK: Agents

enum AgentState: String {
    case running, waiting, done, error

    var symbol: String {
        switch self { case .running: "circle.dotted"; case .waiting: "hand.raised.fill"; case .done: "checkmark.circle.fill"; case .error: "xmark.octagon.fill" }
    }
    var color: Color {
        switch self { case .running: .purple; case .waiting: .orange; case .done: .green; case .error: .red }
    }
    var label: String {
        switch self { case .running: "Running"; case .waiting: "Needs you"; case .done: "Done"; case .error: "Error" }
    }
}

struct Agent: Identifiable, Equatable {
    let id: String
    var name: String
    var project: String
    var state: AgentState
    var message: String
    var hostApp: String
    var updated: Date
}

@MainActor @Observable
final class AgentStore {
    /// Needs-you first, then running, errors, done; newest first within a group.
    private(set) var agents: [Agent] = []
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private var sweeper: Timer?

    /// Done/error rows fade after 30 min; running/waiting rows with no update for 30 min are
    /// treated as dead sessions (closed terminal without SessionEnd).
    private static let ttl: TimeInterval = 30 * 60
    /// Hard cap on rows kept (finished ones are dropped first).
    private static let maxAgents = 40

    init(center: ActivityCenter) { self.center = center }

    func apply(_ info: [String: String]) {
        guard let id = info["id"], let raw = info["state"] else { return }
        if raw == "ended" {
            agents.removeAll { $0.id == id }
            sync()
            return
        }
        guard let state = AgentState(rawValue: raw) else { return }
        let old = agents.first { $0.id == id }
        let agent = Agent(id: id, name: info["name"] ?? old?.name ?? "Agent",
                          project: info["project"] ?? old?.project ?? "",
                          state: state, message: info["message"] ?? "",
                          hostApp: info["hostApp"].flatMap { $0.isEmpty ? nil : $0 } ?? old?.hostApp ?? "",
                          updated: .now)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            agents.removeAll { $0.id == id }
            agents.append(agent)
        }
        if old?.state != state {
            switch state {
            case .waiting: center.chime("Funk")
            case .done where old?.state == .running:
                center.show(.agentDone(name: agent.name, project: agent.project, ok: true), for: 5)
                center.chime("Glass")
            case .error:
                center.show(.agentDone(name: agent.name, project: agent.project, ok: false), for: 6)
                center.chime("Basso")
            default: break
            }
        }
        sync()
    }

    func dismiss(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { agents.removeAll { $0.id == id } }
        sync()
    }

    func clearFinished() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            agents.removeAll { $0.state == .done || $0.state == .error }
        }
        sync()
    }

    private func sync() {
        let now = Date.now
        agents.removeAll { now.timeIntervalSince($0.updated) > Self.ttl }
        let order: [AgentState: Int] = [.waiting: 0, .running: 1, .error: 2, .done: 3]
        agents.sort { (order[$0.state]!, $1.updated) < (order[$1.state]!, $0.updated) }
        if agents.count > Self.maxAgents { agents.removeLast(agents.count - Self.maxAgents) }
        center.waitingAgents = agents.filter { $0.state == .waiting }
        center.runningAgents = agents.filter { $0.state == .running }.count
        // Only tick while there is something to expire.
        if agents.isEmpty {
            sweeper?.invalidate()
            sweeper = nil
        } else if sweeper == nil {
            sweeper = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
    }
}

// MARK: Long tasks (`islet run …`)

struct RunningTask: Identifiable, Equatable {
    let id: String
    let command: String
    let project: String
    let hostApp: String
    let start: Date
    var pid: Int32 = 0
    var cwd: String = ""
}

struct FinishedTask: Identifiable, Equatable, Codable {
    let id: String
    let command: String
    let project: String
    let hostApp: String
    let ok: Bool
    let code: Int
    let duration: TimeInterval
    let end: Date
    var cwd: String = ""
}

@MainActor @Observable
final class TaskStore {
    private(set) var running: [RunningTask] = []
    /// Last 15 finished tasks, kept across restarts (tiny JSON).
    private(set) var finished: [FinishedTask] = []
    @ObservationIgnored private let center: ActivityCenter
    @ObservationIgnored private let file = appSupportFile("tasks.json")
    static let keep = 15

    init(center: ActivityCenter) {
        self.center = center
        if let d = try? Data(contentsOf: file), let f = try? JSONDecoder().decode([FinishedTask].self, from: d) { finished = f }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Coalesced: one small write a second at most, however many tasks finish (e.g. 60 at once).
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            if let d = try? JSONEncoder().encode(self.finished) { try? d.write(to: self.file, options: .atomic) }
        }
    }

    /// Stop a running `islet run` task: Ctrl-C first, then terminate if it ignores that.
    func stop(_ t: RunningTask) {
        guard t.pid > 0 else { return }
        Darwin.kill(t.pid, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if Darwin.kill(t.pid, 0) == 0 { Darwin.kill(t.pid, SIGTERM) } }
    }

    /// Run a finished command again in its folder, in the background (shown as a task with a chime).
    func rerun(_ t: FinishedTask) {
        let dir = t.cwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : t.cwd
        shell(t.command, cwd: dir, project: t.project, tasks: self)
    }

    func apply(_ info: [String: String]) {
        guard let id = info["id"] else { return }
        switch info["state"] {
        case "start":
            let t = RunningTask(id: id, command: info["command"] ?? "task", project: info["project"] ?? "",
                                hostApp: info["hostApp"] ?? "", start: .now,
                                pid: Int32(info["pid"] ?? "") ?? 0, cwd: info["cwd"] ?? "")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                running.append(t)
                if running.count > 30 { running.removeFirst(running.count - 30) }  // cap; finishes still alert
            }
        case "finish":
            let started = running.first { $0.id == id }
            let code = Int(info["code"] ?? "") ?? 1
            let duration = started.map { Date.now.timeIntervalSince($0.start) } ?? 0
            let f = FinishedTask(id: id, command: started?.command ?? info["command"] ?? "task",
                                 project: started?.project ?? "", hostApp: started?.hostApp ?? info["hostApp"] ?? "",
                                 ok: code == 0, code: code, duration: duration, end: .now, cwd: started?.cwd ?? "")
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                running.removeAll { $0.id == id }
                finished.insert(f, at: 0)
                if finished.count > Self.keep { finished.removeLast(finished.count - Self.keep) }
            }
            save()
            center.show(.taskDone(command: f.command, ok: f.ok, duration: duration), for: 6)
            center.chime(f.ok ? "Glass" : "Basso")
        default:
            return
        }
        center.runningTasks = running
    }

    func clearFinished() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { finished.removeAll() }
        save()
    }
}

// MARK: Work tab (agents + long tasks)

struct WorkView: View {
    let agents: AgentStore
    let tasks: TaskStore
    let downloads: DownloadWatcher
    let openSettings: () -> Void

    var body: some View {
        let hasFinishedAgents = agents.agents.contains { $0.state == .done || $0.state == .error }
        let clearAgents: (() -> Void)? = hasFinishedAgents ? { agents.clearFinished() } : nil
        let clearTasks: (() -> Void)? = tasks.finished.isEmpty ? nil : { tasks.clearFinished() }
        HStack(alignment: .top, spacing: 12) {
            column("Agents", symbol: "sparkles", clear: clearAgents) {
                if agents.agents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        hint("No agents reporting yet")
                        Button("Connect Claude Code…", action: openSettings)
                            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.purple)
                    }
                }
                ForEach(agents.agents) { a in AgentRow(agent: a, dismiss: { agents.dismiss(a.id) }) }
            }
            column("Tasks", symbol: "terminal", clear: clearTasks) {
                if tasks.running.isEmpty && tasks.finished.isEmpty && downloads.items.isEmpty { hint("Prefix a command with `islet run` to watch it here") }
                ForEach(downloads.items) { d in
                    row(symbol: d.airDrop ? "dot.radiowaves.left.and.right" : "arrow.down.circle", color: .blue,
                        title: d.name, subtitle: d.airDrop ? "AirDrop" : "Downloading", app: "") {
                        ProgressView(value: d.fraction).frame(width: 50).tint(.blue)
                    }
                }
                ForEach(tasks.running) { t in
                    row(symbol: "circle.dotted", color: .green, title: t.command, subtitle: t.project, app: t.hostApp) {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(ActivityWings.clock(ctx.date.timeIntervalSince(t.start)))
                        }
                    }
                }
                ForEach(tasks.finished) { t in
                    row(symbol: t.ok ? "checkmark.circle.fill" : "xmark.octagon.fill", color: t.ok ? .green : .red,
                        title: t.command, subtitle: t.ok ? t.project : "exit \(t.code) · \(t.project)", app: t.hostApp) {
                        Text(ActivityWings.clock(t.duration))
                    }
                }
            }
        }
    }

    private func column<C: View>(_ title: String, symbol: String, clear: (() -> Void)?, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                if let clear {
                    Button("Clear", action: clear).buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
            ScrollView(showsIndicators: false) { LazyVStack(alignment: .leading, spacing: 3) { content() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row<T: View>(symbol: String, color: Color, title: String, subtitle: String, app: String,
                              @ViewBuilder trailing: () -> T) -> some View {
        Button { jump(toApp: app) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                    Text(subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 4)
                trailing().font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.isEmpty ? title : "Open \(URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent)")
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 4)
    }
}

private struct AgentRow: View {
    let agent: Agent
    let dismiss: () -> Void

    var body: some View {
        Button { jump(toApp: agent.hostApp) } label: {
            HStack(spacing: 7) {
                Image(systemName: agent.state.symbol).foregroundStyle(agent.state.color).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(agent.name) · \(agent.project)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(agent.message.isEmpty ? agent.state.label : agent.message)
                        .font(.system(size: 9)).foregroundStyle(agent.state == .waiting ? .orange : .white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(agent.updated, style: .relative).font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                if agent.state == .done || agent.state == .error {
                    Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(height: 28)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(agent.state == .waiting ? .orange.opacity(0.14) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(agent.hostApp.isEmpty ? agent.state.label : "Jump to \(URL(fileURLWithPath: agent.hostApp).deletingPathExtension().lastPathComponent)")
    }
}
