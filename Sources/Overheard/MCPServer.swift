// Server MCP integrato: `Overheard --mcp` parla JSON-RPC su stdin/stdout (trasporto stdio, solo locale).
// Claude Code / Claude Desktop / Codex lo avviano da soli dopo "Collega a Claude" nelle Impostazioni.
// Legge ~/Meetings direttamente; le azioni sulla registrazione passano dall'app in esecuzione (URL scheme).
// Gli strumenti che modificano qualcosa sono attivi solo con l'opzione "mcp.write" (Impostazioni).
import AppKit
import AVFoundation

enum MCPServer {
    static let name = "overheard"
    static var writeEnabled: Bool { UserDefaults.standard.bool(forKey: "mcp.write") }

    // MARK: Trasporto

    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = msg["id"]
            let method = msg["method"] as? String ?? ""
            let params = msg["params"] as? [String: Any] ?? [:]
            guard let id else { continue } // notifiche (es. notifications/initialized): nessuna risposta
            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": name, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"],
                    "instructions": """
                    Meetings recorded and transcribed by Overheard on the user's Mac (\(Prefs.myName)). \
                    Use search_meetings to find where something was discussed, get_meeting for summary/decisions/action items/transcript, \
                    list_action_items for action items. In transcripts "Parlante N"/"Speaker N" are unidentified voices. \
                    Transcripts and summaries may be in Italian or English. Cite the date and minute [mm:ss].
                    """,
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools.filter { writeEnabled || !$0.write }.map(\.json)])
            case "tools/call":
                let tool = params["name"] as? String ?? ""
                let args = params["arguments"] as? [String: Any] ?? [:]
                do {
                    reply(id, result: ["content": [["type": "text", "text": try call(tool, args)]]])
                } catch {
                    reply(id, result: ["content": [["type": "text", "text": "Errore: \(error.localizedDescription)"]], "isError": true])
                }
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported method: \(method)"]])
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }

    private static func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    // MARK: Strumenti

    struct Tool {
        let name: String
        let description: String
        var properties: [String: [String: Any]] = [:]
        var required: [String] = []
        var write = false
        var json: [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required]]
        }
    }

    private static let str = { (d: String) -> [String: Any] in ["type": "string", "description": d] }
    private static let int = { (d: String) -> [String: Any] in ["type": "integer", "description": d] }

    static let tools: [Tool] = [
        Tool(name: "list_meetings", description: "Meetings (newest first) with date, title, duration, participants and whether a summary exists.",
             properties: ["from": str("Earliest date YYYY-MM-DD"), "to": str("Latest date YYYY-MM-DD"),
                          "filter": str("Text to match in title/app/label (e.g. Teams, a client name)"), "limit": int("Max results (default 20)")]),
        Tool(name: "search_meetings", description: "Search a word or phrase across all transcripts; returns matching lines with meeting and minute.",
             properties: ["query": str("Text to search for"), "limit": int("Max results (default 30)")], required: ["query"]),
        Tool(name: "get_meeting", description: "Summary, decisions, action items, bookmarks and full transcript of a meeting.",
             properties: ["id": str("Meeting id (e.g. 2026-10-13_153643) or \"latest\""),
                          "include_transcript": ["type": "boolean", "description": "Include the full transcript (default true)"]],
             required: ["id"]),
        Tool(name: "list_action_items", description: "Action items extracted from meeting summaries.",
             properties: ["status": ["type": "string", "enum": ["open", "done", "all"], "description": "default open"],
                          "from": str("Earliest date YYYY-MM-DD"), "person": str("Only those for this person")]),
        Tool(name: "complete_action_item", description: "Mark an action item done (or not done).",
             properties: ["meeting_id": str("Meeting id"), "line": int("Line number returned by list_action_items"),
                          "done": ["type": "boolean", "description": "default true"]],
             required: ["meeting_id", "line"], write: true),
        Tool(name: "start_recording", description: "Start recording a meeting (the app must be running).", write: true),
        Tool(name: "stop_recording", description: "Stop the current recording (transcription starts automatically).", write: true),
        Tool(name: "bookmark", description: "Bookmark the current moment of the ongoing recording as important.", write: true),
    ]

    private static func call(_ tool: String, _ a: [String: Any]) throws -> String {
        guard let t = tools.first(where: { $0.name == tool }) else { throw TranscriptionError.message("Unknown tool: \(tool)") }
        if t.write, !writeEnabled {
            throw TranscriptionError.message("Action disabled: enable it in Overheard → Settings → Claude & other AIs")
        }
        switch tool {
        case "list_meetings": return listMeetings(a)
        case "search_meetings": return search(a)
        case "get_meeting": return try getMeeting(a)
        case "list_action_items": return actionItems(a)
        case "complete_action_item": return try complete(a)
        case "start_recording": return recordingAction(start: true)
        case "stop_recording": return recordingAction(start: false)
        default:
            guard isRecording else { return "Not recording." }
            openURL("overheard://bookmark")
            return "Moment bookmarked."
        }
    }

    // MARK: Lettura

    private static func meetings(from: String?, to: String?) -> [Meeting] {
        Meeting.recent(.max).filter { m in
            let day = String(m.id.prefix(10))
            return (from.map { day >= $0 } ?? true) && (to.map { day <= $0 } ?? true)
        }
    }

    private static func describe(_ m: Meeting) -> String {
        let dir = m.url
        let people = Set(transcript(m).map(\.speaker).filter { !$0.isEmpty }).sorted()
        var parts = ["\(m.id)", m.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "", m.app]
        if let d = duration(dir) { parts.append(d) }
        if !people.isEmpty { parts.append("participants: " + people.joined(separator: ", ")) }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path) { parts.append("summary ✓") }
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path) { parts.append("no transcript") }
        return "- " + parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func transcript(_ m: Meeting) -> [TranscriptLine] {
        TranscriptLine.parse((try? String(contentsOf: m.url.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? "")
    }

    private static func duration(_ dir: URL) -> String? {
        guard let f = try? AVAudioFile(forReading: dir.appendingPathComponent("recording.wav")) else { return nil }
        return Overheard.duration(Double(f.length) / f.fileFormat.sampleRate)
    }

    private static func listMeetings(_ a: [String: Any]) -> String {
        let filter = a["filter"] as? String ?? ""
        let found = meetings(from: a["from"] as? String, to: a["to"] as? String)
            .filter { filter.isEmpty || $0.app.range(of: filter, options: MeetingSearch.options) != nil || $0.source == filter.lowercased() }
            .prefix(a["limit"] as? Int ?? 20)
        return found.isEmpty ? "No meetings found." : found.map(describe).joined(separator: "\n")
    }

    private static func search(_ a: [String: Any]) -> String {
        let q = a["query"] as? String ?? ""
        let hits = MeetingSearch.search(q, in: MeetingSearch.load())
        guard !hits.isEmpty else { return "No results for «\(q)»." }
        let shown = hits.prefix(a["limit"] as? Int ?? 30).map { h in
            "- \(h.meeting.id) · \(h.meeting.app) · \(h.meeting.date?.formatted(date: .abbreviated, time: .shortened) ?? "") · [\(h.line.time)] \(h.line.speaker): \(h.line.text)"
        }
        return "\(hits.count) matching lines in \(Set(hits.map(\.meeting.id)).count) meeting:\n" + shown.joined(separator: "\n")
    }

    private static func meeting(_ id: String) throws -> Meeting {
        let all = Meeting.recent(.max)
        guard let m = id == "latest" ? all.first : all.first(where: { $0.id == id }) else {
            throw TranscriptionError.message("Meeting \(id) not found (use list_meetings)")
        }
        return m
    }

    private static func getMeeting(_ a: [String: Any]) throws -> String {
        let m = try meeting(a["id"] as? String ?? "latest")
        let dir = m.url
        var out = "# \(m.app)\n" + describe(m) + "\n"
        let invited = MeetingCalendar.attendees(dir)
        if !invited.isEmpty { out += "Invited: \(invited.joined(separator: ", "))\n" }
        let marks = Bookmarks.load(dir)
        if !marks.isEmpty { out += "Bookmarks: " + marks.map { "[\(Summarizer.stamp($0))]" }.joined(separator: ", ") + "\n" }
        if let s = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) { out += "\n" + s + "\n" }
        if a["include_transcript"] as? Bool ?? true {
            let lines = transcript(m)
            out += "\n## Transcript\n" + (lines.isEmpty ? "(not available yet)" :
                lines.map { $0.speaker.isEmpty ? $0.text : "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n"))
        }
        return out
    }

    private static func actionItems(_ a: [String: Any]) -> String {
        let status = a["status"] as? String ?? "open"
        let person = a["person"] as? String ?? ""
        var out: [String] = []
        for m in meetings(from: a["from"] as? String, to: nil) {
            guard let s = try? String(contentsOf: m.url.appendingPathComponent("summary.md"), encoding: .utf8) else { continue }
            for l in SummaryLine.parse(s) {
                guard case let .todo(done) = l.kind, status == "all" || (status == "done") == done,
                      person.isEmpty || l.text.range(of: person, options: MeetingSearch.options) != nil else { continue }
                out.append("- [\(done ? "x" : " ")] \(l.text) — \(m.app), \(m.when) (meeting_id: \(m.id), line: \(l.id))")
            }
        }
        return out.isEmpty ? "No \(status == "open" ? "open " : "")action items." : out.joined(separator: "\n")
    }

    private static func complete(_ a: [String: Any]) throws -> String {
        let m = try meeting(a["meeting_id"] as? String ?? "")
        let url = m.url.appendingPathComponent("summary.md")
        let line = a["line"] as? Int ?? -1, done = a["done"] as? Bool ?? true
        var rows = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard rows.indices.contains(line), rows[line].contains("- [") else { throw TranscriptionError.message("Line \(line) is not an action item") }
        rows[line] = rows[line].replacingOccurrences(of: done ? "- [ ] " : "- [x] ", with: done ? "- [x] " : "- [ ] ")
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NotesExport.exportIfEnabled(m.url)
        return (done ? "Done: " : "Reopened: ") + rows[line].trimmingCharacters(in: .whitespaces)
    }

    // MARK: Registrazione (tramite l'app in esecuzione)

    /// Registrazione in corso = c'è un *.tmp.wav nel meeting più recente
    private static var isRecording: Bool {
        guard let m = Meeting.recent(1).first else { return false }
        return FileManager.default.fileExists(atPath: m.url.appendingPathComponent("recording.tmp.wav").path)
    }

    private static func openURL(_ s: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", s]
        try? p.run()
        p.waitUntilExit()
    }

    private static func recordingAction(start: Bool) -> String {
        if start == isRecording { return start ? "Already recording." : "Not recording." }
        openURL("overheard://toggle")
        return start ? "Recording started." : "Recording stopped: transcription starts automatically."
    }

    // MARK: Installazione nei client

    /// Collega il server a Claude Code, Codex e Claude Desktop; ritorna l'esito per ogni client
    static func install() -> [String] {
        guard let exe = Bundle.main.executablePath else { return [String(localized: "Eseguibile non trovato")] }
        var out: [String] = []
        let q = Importer.quote(exe)
        if AIChat.shell("command -v claude").status == 0 {
            _ = AIChat.shell("claude mcp remove --scope user \(name)")
            _ = AIChat.shell("claude mcp remove --scope user meeting-recorder") // vecchio nome dell'app
            out.append(AIChat.shell("claude mcp add --scope user \(name) -- \(q) --mcp").status == 0 ? "✓ Claude Code" : "✗ Claude Code")
        }
        if AIChat.shell("command -v codex").status == 0 {
            _ = AIChat.shell("codex mcp remove \(name)")
            _ = AIChat.shell("codex mcp remove meeting-recorder")
            out.append(AIChat.shell("codex mcp add \(name) -- \(q) --mcp").status == 0 ? "✓ Codex" : "✗ Codex")
        }
        // Claude Desktop: claude_desktop_config.json (copia di sicurezza accanto)
        let support = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Claude")
        if FileManager.default.fileExists(atPath: support.path) {
            let cfg = support.appendingPathComponent("claude_desktop_config.json")
            var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: cfg))) as? [String: Any] ?? [:]
            if FileManager.default.fileExists(atPath: cfg.path) {
                try? FileManager.default.removeItem(at: cfg.appendingPathExtension("bak-overheard"))
                try? FileManager.default.copyItem(at: cfg, to: cfg.appendingPathExtension("bak-overheard"))
            }
            var servers = json["mcpServers"] as? [String: Any] ?? [:]
            servers["meeting-recorder"] = nil
            servers[name] = ["command": exe, "args": ["--mcp"]]
            json["mcpServers"] = servers
            let ok = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes]))
                .map { (try? $0.write(to: cfg)) != nil } ?? false
            out.append(ok ? String(localized: "✓ Claude Desktop (riavvialo)") : "✗ Claude Desktop")
        }
        return out.isEmpty ? [String(localized: "Nessun client trovato: installa Claude Code, Codex o Claude Desktop")] : out
    }
}
