import AppKit
import Foundation

/// Exports the AI chat in the front browser tab as a portable package (zip):
///   HANDOFF.md        structured summary to read first (goal, decisions, patterns, anti-patterns, …)
///   IMPORT_PROMPT.md  what to paste into the next AI
///   transcript.md/.json  every message, the reference copy
///   images/, artifacts/, manifest.json
/// Transcript: claude.ai's own conversation data (full text, images, attachments, active branch only);
/// ChatGPT and Gemini are read from the page. HANDOFF.md: a handoff the chat wrote itself (via "Ask chat"),
/// else local `claude -p`, chunked and merged for long chats (lost-in-the-middle, context collapse).
@MainActor @Observable
final class ChatExporter {
    enum Phase: Equatable { case idle, working(String), done(URL), failed(String) }
    private(set) var phase: Phase = .idle

    struct Image { let name: String; let data: Data }
    struct Message { let role: String; let time: String; var text: String; let images: [Image]; let attachments: [(name: String, text: String)]; let files: [String] }
    struct Chat { let site: String; let url: String; let title: String; let model: String; var messages: [Message]; var artifacts: [(title: String, type: String, content: String)] }

    var busy: Bool { if case .working = phase { true } else { false } }

    func export(site: AIChatSite, browser: String, url: String) {
        guard !busy else { return }
        phase = .working("Reading chat…")
        Task {
            do {
                var chat = try await Self.capture(site: site, browser: browser, url: url)
                guard !chat.messages.isEmpty else { throw Fail("No messages found on this page") }
                Self.redact(&chat)
                let ownHandoff = chat.messages.last { $0.role == "assistant" && $0.text.contains("# HANDOFF") }?.text
                let handoff: String
                if let ownHandoff {
                    handoff = String(ownHandoff[ownHandoff.range(of: "# HANDOFF")!.lowerBound...])
                } else {
                    handoff = try await Self.writeHandoff(chat) { [weak self] in self?.phase = .working($0) }
                }
                phase = .working("Packing…")
                phase = .done(try await Self.pack(chat, handoff: handoff))
            } catch {
                phase = .failed((error as? Fail)?.message ?? error.localizedDescription)
            }
        }
    }

    struct Fail: Error { let message: String; init(_ m: String) { message = m } }

    // MARK: Capture

    /// Runs `js` in the browser's front tab. Passed as an argument, so the JS needs no AppleScript escaping.
    static func runJS(_ browser: String, _ js: String, timeout: TimeInterval = 20) async -> String? {
        let script = """
        on run argv
          using terms from application "Google Chrome"
            tell application (item 1 of argv) to return execute active tab of front window javascript (item 2 of argv)
          end using terms from
        end run
        """
        return await runTool("/usr/bin/osascript", ["-e", script, browser, js], timeout: timeout)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Images are fetched inside the page (with your login) and come back as data URLs.
    static let commonJS = """
    async function b64(u){const r=await fetch(u);const b=await r.blob();if(b.size>8e6)return null;
      return await new Promise(res=>{const f=new FileReader();f.onload=()=>res(f.result);f.readAsDataURL(b);});}
    """

    static let claudeJS = commonJS + """
    (async()=>{try{
      const org=document.cookie.match(/lastActiveOrg=([^;]+)/)[1], id=location.pathname.split('/')[2];
      const j=await (await fetch(`/api/organizations/${org}/chat_conversations/${id}?tree=True&rendering_mode=messages&render_all_tools=true`)).json();
      const by={}; j.chat_messages.forEach(m=>by[m.uuid]=m);
      let path=[], cur=by[j.current_leaf_message_uuid];
      while(cur){path.unshift(cur);cur=by[cur.parent_message_uuid];}
      if(!path.length) path=j.chat_messages;
      const msgs=[], artifacts=[];
      for(const m of path){
        const parts=m.content||[];
        let text=parts.filter(c=>c.type==='text').map(c=>c.text).join('\\n\\n')||m.text||'';
        for(const c of parts){ if(c.type==='tool_use'&&c.input&&c.input.content){artifacts.push({title:c.input.title||c.input.id||'artifact',type:c.input.type||c.input.language||'',content:c.input.content});} }
        const images=[];
        for(const f of (m.files||m.files_v2||[])){ if(f.file_kind==='image'&&f.preview_url){ try{const d=await b64(f.preview_url); if(d)images.push({name:f.file_name||'image',data:d});}catch(e){} } }
        msgs.push({role:m.sender==='human'?'user':'assistant',time:m.created_at||'',text,images,
          attachments:(m.attachments||[]).map(a=>({name:a.file_name||'attachment',text:a.extracted_content||''})),
          files:(m.files||m.files_v2||[]).filter(f=>f.file_kind!=='image').map(f=>f.file_name)});
      }
      window.__isletExport=JSON.stringify({ok:true,title:j.name||document.title,model:j.model||'',messages:msgs,artifacts});
    }catch(e){window.__isletExport=JSON.stringify({ok:false,error:String(e)});}})();'started'
    """

    /// ChatGPT / Gemini: messages from the page, converted to Markdown (code fences, headings, lists, links).
    static let pageJS = commonJS + """
    function md(n){
      if(n.nodeType===3)return n.textContent; if(n.nodeType!==1)return '';
      const t=n.tagName; if(['BUTTON','svg','SVG','STYLE','SCRIPT'].includes(t)||n.getAttribute('aria-hidden')==='true')return '';
      if(t==='PRE'){const c=n.querySelector('code');const l=((c&&c.className)||'').match(/language-([\\w+#-]+)/);
        return '\\n```'+(l?l[1]:'')+'\\n'+((c||n).innerText||'').replace(/\\n$/,'')+'\\n```\\n';}
      const s=[...n.childNodes].map(md).join('');
      if(t==='CODE')return '`'+s+'`'; if(/^H[1-6]$/.test(t))return '\\n'+'#'.repeat(+t[1])+' '+s.trim()+'\\n';
      if(t==='LI')return '\\n- '+s.trim(); if(t==='P')return '\\n'+s+'\\n'; if(t==='BR')return '\\n';
      if(t==='A')return '['+s+']('+n.href+')'; if(t==='STRONG'||t==='B')return '**'+s+'**';
      if(t==='TABLE')return '\\n'+n.innerText+'\\n'; return s;}
    (async()=>{try{
      const h=location.host; let nodes=[];
      if(h==='chatgpt.com') nodes=[...document.querySelectorAll('[data-message-author-role]')].map(e=>({role:e.getAttribute('data-message-author-role')==='user'?'user':'assistant',el:e}));
      else nodes=[...document.querySelectorAll('user-query, model-response')].map(e=>({role:e.tagName.toLowerCase()==='user-query'?'user':'assistant',el:e}));
      const msgs=[];
      for(const x of nodes){
        const images=[]; let k=0;
        for(const img of x.el.querySelectorAll('img')){ if(img.naturalWidth<64)continue; try{const d=await b64(img.src); if(d)images.push({name:'image-'+(++k),data:d});}catch(e){} }
        msgs.push({role:x.role,time:'',text:md(x.el).replace(/\\n{3,}/g,'\\n\\n').trim(),images,attachments:[],files:[]});
      }
      window.__isletExport=JSON.stringify({ok:true,title:document.title,model:'',messages:msgs,artifacts:[]});
    }catch(e){window.__isletExport=JSON.stringify({ok:false,error:String(e)});}})();'started'
    """

    static func capture(site: AIChatSite, browser: String, url: String) async throws -> Chat {
        _ = await runJS(browser, "window.__isletExport=null;'ok'")
        guard await runJS(browser, site.host == "claude.ai" ? claudeJS : pageJS) == "started" else {
            throw Fail("Couldn't run in \(browser). Turn on View → Developer → Allow JavaScript from Apple Events.")
        }
        var raw: String?
        for _ in 0..<120 {  // up to 60 s for big chats with images
            try? await Task.sleep(for: .milliseconds(500))
            if let r = await runJS(browser, "window.__isletExport||''", timeout: 60), !r.isEmpty, r != "missing value" { raw = r; break }
        }
        _ = await runJS(browser, "window.__isletExport=null;'ok'")
        guard let raw, let j = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { throw Fail("Reading the chat timed out") }
        guard j["ok"] as? Bool == true else { throw Fail("Couldn't read the chat: \(j["error"] as? String ?? "unknown")") }
        let messages = (j["messages"] as? [[String: Any]] ?? []).map { m in
            Message(role: m["role"] as? String ?? "assistant", time: m["time"] as? String ?? "", text: m["text"] as? String ?? "",
                    images: (m["images"] as? [[String: Any]] ?? []).compactMap { i in
                        guard let d = i["data"] as? String, let comma = d.firstIndex(of: ","), let data = Data(base64Encoded: String(d[d.index(after: comma)...])) else { return nil }
                        return Image(name: i["name"] as? String ?? "image", data: data)
                    },
                    attachments: (m["attachments"] as? [[String: Any]] ?? []).map { ($0["name"] as? String ?? "", $0["text"] as? String ?? "") },
                    files: m["files"] as? [String] ?? [])
        }
        let artifacts = (j["artifacts"] as? [[String: Any]] ?? []).map { ($0["title"] as? String ?? "artifact", $0["type"] as? String ?? "", $0["content"] as? String ?? "") }
        let title = ChatWatcher.site(host: site.host, title: j["title"] as? String ?? "").1
        return Chat(site: site.name, url: url, title: title, model: j["model"] as? String ?? "", messages: messages, artifacts: artifacts)
    }

    /// Secrets never leave the Mac or land in the package.
    static func redact(_ chat: inout Chat) {
        func clean(_ s: String) -> String {
            var s = s
            for p in TextTools.secrets { s = s.replacingOccurrences(of: p.pattern, with: "[REDACTED \(p.name)]", options: .regularExpression) }
            return s
        }
        for i in chat.messages.indices { chat.messages[i].text = clean(chat.messages[i].text) }
        chat.artifacts = chat.artifacts.map { ($0.title, $0.type, clean($0.content)) }
    }

    // MARK: Transcript

    static func imageName(_ m: Int, _ k: Int, _ img: Image) -> String {
        let ext = img.data.starts(with: [0x89, 0x50]) ? "png" : img.data.starts(with: [0xFF, 0xD8]) ? "jpg"
            : img.data.starts(with: [0x47, 0x49]) ? "gif" : img.data.starts(with: [0x52, 0x49]) ? "webp" : "png"
        return "m\(m)-\(k).\(ext)"
    }

    /// `[m3] user` headers: HANDOFF.md cites messages by these numbers.
    static func transcript(_ chat: Chat, attachmentText: Bool = true) -> String {
        var out = "# \(chat.title)\n\n\(chat.site) · \(chat.url)\(chat.model.isEmpty ? "" : " · \(chat.model)")\n"
        for (i, m) in chat.messages.enumerated() {
            out += "\n---\n\n## [m\(i + 1)] \(m.role)\(m.time.isEmpty ? "" : " · \(m.time)")\n\n\(m.text)\n"
            for (k, img) in m.images.enumerated() { out += "\n![\(img.name)](images/\(imageName(i + 1, k + 1, img)))\n" }
            for f in m.files { out += "\n_Attached file: \(f)_\n" }
            for a in m.attachments {
                out += "\n_Attached: \(a.name)_\n"
                if attachmentText && !a.text.isEmpty { out += "\n```\n\(a.text.prefix(20_000))\n```\n" }
            }
        }
        return out
    }

    // MARK: Handoff (local claude -p)

    static let template = """
    # HANDOFF: <chat title>

    > Read this first. Full history: transcript.md; [m12] = message 12 there.

    ## 1. Goal and current state
    ## 2. Decisions (each with its reason)
    ## 3. Patterns: what worked
    ## 4. Anti-patterns: tried and failed, or rejected (do not repeat)
    ## 5. Constraints and preferences (stack, versions, style, format)
    ## 6. Facts vs assumptions (who said it: user-stated or AI-assumed)
    ## 7. Artifacts (final versions; mark superseded ones)
    ## 8. Images (what each shows, which message)
    ## 9. Open questions
    ## 10. Next steps (resume here)
    """

    static let rules = """
    Rules: one self-contained bullet per item. Keep exact strings: commands, file paths, versions, names, numbers, \
    error messages, settings. Cite messages as [m#]. No generic advice and nothing that isn't in the chat. \
    When the chat changed its mind, keep the latest and mark the earlier as superseded. \
    Empty section: "None." Stay under 2,500 words. Output only the Markdown.
    """

    static var handoffPrompt: String {
        "Write a handoff of this whole conversation so another AI can continue it without the history. "
            + "Use exactly this structure and start with the line \"# HANDOFF: <title>\":\n\n\(template)\n\n\(rules)"
    }

    nonisolated static func claude(_ prompt: String, input: String, model: String = "sonnet") async -> String? {
        guard let claude = findTool("claude") else { return nil }
        return await Task.detached {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("islet-ai-\(UUID().uuidString.prefix(6))")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.currentDirectoryURL = dir
            p.arguments = ["-p", "--setting-sources", "local", "--strict-mcp-config", "--model", model,
                           "--tools", "", "--no-session-persistence", prompt]
            let stdin = Pipe(), out = Pipe()
            p.standardInput = stdin
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: killer)
            DispatchQueue.global().async {
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return p.terminationStatus == 0 && !text.isEmpty ? text : nil
        }.value
    }

    /// One pass for short chats. Long chats: notes per chunk (in parallel), then one merge into the template,
    /// so nothing sits in the middle of a huge input and the summary isn't rewritten into mush.
    static func writeHandoff(_ chat: Chat, progress: @escaping @MainActor (String) -> Void) async throws -> String {
        guard findTool("claude") != nil else { throw Fail("Needs Claude Code (the `claude` command) to write the handoff") }
        let chunkChars = 60_000
        var chunks: [(from: Int, to: Int, text: String)] = []
        var cur = "", from = 1
        for (i, m) in chat.messages.enumerated() {
            let block = "## [m\(i + 1)] \(m.role)\n\n\(m.text)\n"
                + m.images.indices.map { "[image m\(i + 1)-\($0 + 1)]\n" }.joined()
                + m.attachments.map { "[attached: \($0.name)]\n\($0.text.prefix(4_000))\n" }.joined() + "\n"
            if !cur.isEmpty && cur.count + block.count > chunkChars { chunks.append((from, i, cur)); cur = ""; from = i + 1 }
            cur += block
        }
        chunks.append((from, chat.messages.count, cur))
        let header = "Chat: \(chat.title) (\(chat.site), \(chat.messages.count) messages)\n\n"
        if chunks.count == 1 {
            progress("Writing handoff…")
            guard let h = await claude(handoffPrompt, input: header + chunks[0].text) else { throw Fail("Claude couldn't write the handoff") }
            return h
        }
        progress("Reading \(chunks.count) parts…")
        let notesPrompt = """
        This is one part of a longer chat. Extract notes under these headings: Goal/state, Decisions (with reason), \
        Worked, Failed or rejected (with why), Constraints/preferences, Facts (user-stated) vs assumptions (AI-assumed), \
        Artifacts (name, message, replaced later?), Images, Open questions. \(rules)
        """
        let inputs = chunks.enumerated().map { i, c in header + "Part \(i + 1) of \(chunks.count), messages [m\(c.from)]–[m\(c.to)]:\n\n" + c.text }
        let notes = await withTaskGroup(of: (Int, String?).self) { group in
            for (i, input) in inputs.enumerated() {
                group.addTask { (i, await ChatExporter.claude(notesPrompt, input: input)) }
            }
            var out = [String?](repeating: nil, count: chunks.count)
            for await (i, n) in group { out[i] = n }
            return out
        }
        guard notes.allSatisfy({ $0 != nil }) else { throw Fail("Claude couldn't read part of the chat") }
        progress("Merging…")
        let merged = notes.enumerated().map { "### Part \($0.offset + 1)\n\n\($0.element!)" }.joined(separator: "\n\n")
        let mergePrompt = """
        These are notes from consecutive parts of one chat, in order. Merge them into one handoff. Later parts win when \
        they conflict (mark the earlier one superseded). Remove duplicates but keep every distinct specific. \
        Use exactly this structure and start with the line "# HANDOFF: <title>":

        \(template)

        \(rules)
        """
        guard let h = await claude(mergePrompt, input: header + merged) else { throw Fail("Claude couldn't merge the handoff") }
        return h
    }

    // MARK: Package

    static func pack(_ chat: Chat, handoff: String) async throws -> URL {
        let fm = FileManager.default
        let stamp = Date.now.formatted(.iso8601.year().month().day())
        let slug = String("\(chat.site)-\(chat.title)".lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").joined(separator: "-").prefix(60)
        let out = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("Islet chat exports")
        let dir = out.appendingPathComponent("\(slug)-\(stamp)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        func write(_ name: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }

        try write("HANDOFF.md", handoff + "\n")
        try write("transcript.md", transcript(chat))
        try write("IMPORT_PROMPT.md", """
        I'm continuing a conversation from \(chat.site): "\(chat.title)". Attached:
        - HANDOFF.md: the summary. Read it first.
        - transcript.md: the full history, for looking things up ([m12] = message 12).
        - images/ and artifacts/: files from the chat.

        Treat the Decisions and Anti-patterns in HANDOFF.md as settled; ask me before going against them.
        Start by telling me in three lines where we are and what's next.
        """)
        var imageCount = 0
        var json: [[String: Any]] = []
        for (i, m) in chat.messages.enumerated() {
            var names: [String] = []
            for (k, img) in m.images.enumerated() {
                let n = imageName(i + 1, k + 1, img)
                try img.data.write(to: dir.appendingPathComponent("images/\(n)"))
                names.append("images/\(n)"); imageCount += 1
            }
            json.append(["index": i + 1, "role": m.role, "time": m.time, "text": m.text, "images": names,
                         "files": m.files, "attachments": m.attachments.map { ["name": $0.name, "text": $0.text] }])
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])
            .write(to: dir.appendingPathComponent("transcript.json"))
        // Artifacts: Claude's artifacts plus every fenced code block from replies, named by message.
        let art = dir.appendingPathComponent("artifacts")
        var files: [(String, String)] = chat.artifacts.enumerated().map { i, a in
            ("artifact-\(i + 1)-\(a.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))" + ext(a.type), a.content)
        }
        for (i, m) in chat.messages.enumerated() where m.role == "assistant" {
            for (k, block) in m.text.matches(of: /```([\w+#-]*)\n([\s\S]*?)```/).enumerated() where block.2.count > 40 {
                files.append(("m\(i + 1)-\(k + 1)" + ext(String(block.1)), String(block.2)))
            }
        }
        if !files.isEmpty {
            try fm.createDirectory(at: art, withIntermediateDirectories: true)
            for (n, c) in files { try c.write(to: art.appendingPathComponent(String(n)), atomically: true, encoding: .utf8) }
        }
        if imageCount == 0 { try? fm.removeItem(at: dir.appendingPathComponent("images")) }
        try JSONSerialization.data(withJSONObject: [
            "format": "islet-chat/1", "site": chat.site, "url": chat.url, "title": chat.title, "model": chat.model,
            "exported": ISO8601DateFormatter().string(from: .now), "messages": chat.messages.count,
            "images": imageCount, "artifacts": files.count,
        ], options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: dir.appendingPathComponent("manifest.json"))

        let zip = out.appendingPathComponent("\(dir.lastPathComponent).zip")
        try? fm.removeItem(at: zip)
        guard await runTool("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", dir.path, zip.path], timeout: 60) != nil else {
            throw Fail("Couldn't create the zip")
        }
        do { try fm.removeItem(at: dir) } catch { debugLog("export: couldn't remove \(dir.path): \(error)") }
        return zip
    }

    static func ext(_ lang: String) -> String {
        let l = lang.lowercased()
        let map = ["swift": ".swift", "python": ".py", "py": ".py", "javascript": ".js", "js": ".js", "typescript": ".ts", "ts": ".ts",
                   "tsx": ".tsx", "jsx": ".jsx", "bash": ".sh", "sh": ".sh", "shell": ".sh", "zsh": ".sh", "json": ".json", "html": ".html",
                   "css": ".css", "sql": ".sql", "go": ".go", "rust": ".rs", "yaml": ".yml", "yml": ".yml", "markdown": ".md", "md": ".md",
                   "application/vnd.ant.code": ".txt", "text/markdown": ".md", "text/html": ".html", "application/vnd.ant.react": ".jsx",
                   "image/svg+xml": ".svg", "application/vnd.ant.mermaid": ".mmd"]
        return map[l] ?? ".txt"
    }

    // MARK: Option A: ask the chat itself

    /// Types the handoff request into the chat's message box (not sent). Once its reply is in, Export uses it.
    static func askChat(browser: String) async -> Bool {
        let js = """
        (()=>{const e=document.querySelector('#prompt-textarea, div.ProseMirror[contenteditable=true], rich-textarea .ql-editor, [contenteditable=true]');
        if(!e)return 'none'; e.focus(); document.execCommand('insertText',false,\(TextTools.q(handoffPrompt))); return 'ok';})()
        """
        return await runJS(browser, js) == "ok"
    }

    static func selfTest() {
        precondition(ext("TypeScript") == ".ts" && ext("weird") == ".txt")
        var chat = Chat(site: "Claude", url: "https://claude.ai/chat/x", title: "T", model: "", messages: [
            Message(role: "user", time: "", text: "key AKIAIOSFODNN7EXAMPLE here", images: [], attachments: [], files: []),
        ], artifacts: [])
        redact(&chat)
        precondition(chat.messages[0].text == "key [REDACTED AWS access key] here")
        precondition(transcript(chat).contains("## [m1] user"))
        precondition(!claudeJS.contains("\\\\n") && pageJS.contains("```"))
    }
}
