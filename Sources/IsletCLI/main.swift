// islet — tells Islet about background work.
//
//   islet run <command> [args…]      run a command, show it in the notch, chime when it ends
//   islet agent <state> [--name N] [--project P] [--id I] [--message M]
//                                    state: running | waiting | done | error | ended
//   islet hook claude                Claude Code hook (reads hook JSON on stdin)
//   islet hook codex <json>          Codex `notify` program
//   islet settings                   open the control panel
//
// Events are distributed notifications (com.yashtyagi.Islet.event) with string payloads.
// If Islet isn't running they are simply dropped; the CLI never blocks your command.
import Foundation
import Darwin

let eventName = Notification.Name("com.yashtyagi.Islet.event")

func post(_ info: [String: String]) {
    var info = info
    info["hostApp"] = info["hostApp"] ?? hostApp()
    DistributedNotificationCenter.default().postNotificationName(
        eventName, object: nil, userInfo: info, deliverImmediately: true)
}

/// Outermost .app bundle among our ancestor processes (Terminal, iTerm, VS Code, Cursor, …),
/// so the notch can jump back to the window that ran the agent or command.
func hostApp() -> String {
    var pid = getppid()
    var found = ""
    for _ in 0..<32 where pid > 1 {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if let r = path.range(of: ".app/") { found = String(path[..<r.lowerBound]) + ".app" }
        }
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { break }
        pid = pid_t(info.pbi_ppid)
    }
    // Outermost wins: the first match walking up can be a helper inside the real app.
    if let r = found.range(of: ".app/") { return String(found[..<r.lowerBound]) + ".app" }
    return found
}

func project(_ cwd: String?) -> String {
    URL(fileURLWithPath: cwd ?? FileManager.default.currentDirectoryPath).lastPathComponent
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: islet run <command> [args…]
           islet agent <running|waiting|done|error|ended> [--name N] [--project P] [--id I] [--message M]
           islet hook claude | islet hook codex <json>
           islet settings

    """.utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }
args.removeFirst()

switch cmd {
case "run":
    guard !args.isEmpty else { usage() }
    let id = UUID().uuidString
    let cwd = FileManager.default.currentDirectoryPath
    let command = args.joined(separator: " ")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args  // stdio is inherited: output stays in your terminal
    // Ctrl-C goes to the whole foreground process group, child included; we just wait for it.
    signal(SIGINT, SIG_IGN)
    do { try p.run() } catch {
        post(["kind": "task", "state": "finish", "id": id, "code": "127", "command": command])
        FileHandle.standardError.write(Data("islet: \(error.localizedDescription)\n".utf8))
        exit(127)
    }
    // Sent after launch so Islet knows the child pid (for its Stop button) and folder (for re-run).
    post(["kind": "task", "state": "start", "id": id, "command": command, "project": project(cwd),
          "pid": String(p.processIdentifier), "cwd": cwd])
    p.waitUntilExit()
    let code = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    post(["kind": "task", "state": "finish", "id": id, "code": String(code), "command": command])
    exit(code)

case "agent":
    guard let state = args.first,
          ["running", "waiting", "done", "error", "ended"].contains(state) else { usage() }
    post(["kind": "agent", "state": state,
          "id": option("--id", in: args) ?? "\(getppid())",
          "name": option("--name", in: args) ?? "agent",
          "project": option("--project", in: args) ?? project(nil),
          "message": option("--message", in: args) ?? ""])

case "hook":
    switch args.first {
    case "claude":
        // https://docs.claude.com/en/docs/claude-code/hooks — JSON on stdin.
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let event = j["hook_event_name"] as? String ?? ""
        let state: String? = switch event {
        case "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse": "running"
        case "Notification": "waiting"   // permission request or idle prompt
        case "Stop": "done"
        case "SessionEnd": "ended"
        default: nil
        }
        if let state {
            post(["kind": "agent", "state": state, "name": "Claude Code",
                  "id": j["session_id"] as? String ?? "\(getppid())",
                  "project": project(j["cwd"] as? String),
                  "message": j["message"] as? String ?? ""])
        }
    case "codex":
        // Codex `notify = ["islet", "hook", "codex"]` passes one JSON argument per finished turn.
        let j = args.dropFirst().last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any] ?? [:]
        if (j["type"] as? String) == "agent-turn-complete" {
            post(["kind": "agent", "state": "done", "name": "Codex", "id": "codex-\(project(nil))",
                  "project": project(nil), "message": j["last-assistant-message"] as? String ?? ""])
        }
    default:
        usage()
    }

case "media":
    media(args)

case "usage":
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .secondsSince1970
    let w = UsageParser().scan()
    FileHandle.standardOutput.write((try? enc.encode(w)) ?? Data("null".utf8))

case "settings":
    post(["kind": "settings"])

default:
    usage()
}
