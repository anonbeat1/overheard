// Calendario (titolo e invitati del meeting), segnalibri durante la call, riassunto con l'AI, condivisione PDF.
import AppKit
import Carbon.HIToolbox
import EventKit
import SwiftUI

private func readLines(_ url: URL) -> [String] {
    ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

// MARK: - Calendario

/// Evento del calendario di macOS in corso durante la registrazione → file "title" e "attendees" nella cartella del meeting.
enum MeetingCalendar {
    static let store = EKEventStore()
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "calendar.enabled") }
    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    private static func events(from: Date, to: Date) -> [EKEvent] {
        guard enabled, authorized else { return [] }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil)).filter { !$0.isAllDay }
    }

    /// Evento in corso (o che inizia entro 10 minuti) più vicino a `date`
    static func event(at date: Date) -> EKEvent? {
        events(from: date.addingTimeInterval(-4 * 3600), to: date.addingTimeInterval(15 * 60))
            .filter { $0.startDate <= date.addingTimeInterval(10 * 60) && $0.endDate > date }
            .min { abs($0.startDate.timeIntervalSince(date)) < abs($1.startDate.timeIntervalSince(date)) }
    }

    /// Prossimo evento entro un'ora (per il pannello)
    static func next(after date: Date = Date()) -> EKEvent? {
        events(from: date, to: date.addingTimeInterval(3600)).filter { $0.startDate > date }.min { $0.startDate < $1.startDate }
    }

    static func annotate(_ dir: URL, at date: Date) {
        let titleURL = dir.appendingPathComponent("title")
        guard !FileManager.default.fileExists(atPath: titleURL.path), let e = event(at: date), let title = e.title, !title.isEmpty else { return }
        try? (title + "\n").write(to: titleURL, atomically: true, encoding: .utf8)
        let people = (e.attendees ?? []).filter { !$0.isCurrentUser }.map { p in
            p.name ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        if !people.isEmpty {
            try? (people.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("attendees"), atomically: true, encoding: .utf8)
        }
    }

    static func attendees(_ dir: URL) -> [String] { readLines(dir.appendingPathComponent("attendees")) }
}

// MARK: - Segnalibri

/// Momenti segnati durante la registrazione: secondi dall'inizio, uno per riga in bookmarks.txt
enum Bookmarks {
    static func add(_ dir: URL, seconds: Double) {
        let url = dir.appendingPathComponent("bookmarks.txt")
        let line = String(format: "%.1f\n", seconds)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func load(_ dir: URL) -> [Double] { readLines(dir.appendingPathComponent("bookmarks.txt")).compactMap(Double.init).sorted() }
}

/// ⌃⌥M da qualsiasi app: segna il momento durante la registrazione (Carbon: nessun permesso richiesto)
enum HotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Recorder.shared.bookmark() } }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4D524543, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Riassunto

/// summary.md accanto al transcript: riassunto, decisioni, cose da fare (checklist) e momenti segnati,
/// scritto da Claude Code o Codex col login dell'utente.
enum Summarizer {
    static var auto: Bool { UserDefaults.standard.object(forKey: "summary.auto") as? Bool ?? true }
    static var autoNames: Bool { UserDefaults.standard.object(forKey: "speakers.autoName") as? Bool ?? true }

    static func runIfEnabled(_ dir: URL) async {
        guard auto else { return }
        _ = await run(dir)
    }

    /// nil se tutto ok, altrimenti il messaggio d'errore
    static func run(_ dir: URL) async -> String? {
        guard let md = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8) else { return String(localized: "Transcript mancante") }
        let preferred = UserDefaults.standard.string(forKey: "ai.engine") ?? "claude"
        guard let engine = [preferred, "claude", "codex", "apple"].first(where: AIChat.installed().contains) else {
            return String(localized: "Serve Claude Code o Codex installato (con il login fatto nel Terminale), oppure Apple Intelligence attiva")
        }
        let apple = engine == "apple"
        let m = Meeting.at(dir)
        let marks = Bookmarks.load(dir).map { "[\(stamp($0))]" }
        var context = "Meeting: \(m.app), \(m.date.map { $0.formatted(date: .long, time: .shortened) } ?? m.id)\n"
        let invited = MeetingCalendar.attendees(dir)
        if !invited.isEmpty { context += "Invited: \(invited.joined(separator: ", "))\n" }
        if !marks.isEmpty { context += "Moments the user bookmarked as important (recording time): \(marks.joined(separator: ", "))\n" }
        // titoli delle sezioni nella lingua dell'interfaccia: sono quelli che si vedono nell'app
        let h = [String(localized: "Riassunto"), String(localized: "Decisioni"), String(localized: "Cose da fare"), String(localized: "Momenti segnati")]
        let speaker = String(localized: "Parlante")
        let unnamed = md.contains("] \(speaker) ")
        // il modello di Apple vede solo appunti a pezzi: non può essere sicuro di chi sia chi
        let naming = autoNames && unnamed && !apple ? """
        First line of your reply: NAMES: followed by a JSON object mapping each "\(speaker) N" label to the person's real name, \
        only when the transcript makes it certain (they introduce themselves, or are called by name and answer). \
        Omit any voice you are not sure about; write NAMES: {} if none. Then the minutes, using those names.

        """ : ""
        let titling = m.title == nil ? """
        Line before the minutes: TITLE: a 2-6 word title in \(Prefs.uiLanguageName) naming what the meeting was about (topic, client or project), no date, no app name.

        """ : ""
        let prompt = """
        \(naming)\(titling)Write the minutes of the meeting below in \(Prefs.uiLanguageName), as markdown, with exactly these sections:
        ## \(h[0])
        3-6 sentences on what was discussed and how it ended.
        ## \(h[1])
        - one line per decision taken (if none, a single line saying no explicit decision was made)
        ## \(h[2])
        - [ ] Person: concrete action (deadline, if mentioned)
        \(marks.isEmpty ? "" : "## \(h[3])\n- [mm:ss] why that moment matters (one per bookmarked moment)\n")
        Reply with the markdown only, no preamble. "\(Prefs.myName)" is the user; "\(String(localized: "Parlante")) N" are unidentified voices.

        \(context)
        \(apple ? "" : md)
        """
        let out: String?
        if apple {
            do {
                let body = try await AppleAI.condense(md, to: AppleAI.budget - prompt.count)
                // il modello piccolo copia "Person:" dal formato e salta la riga TITLE: titolo con una domanda a parte
                var text = try await AppleAI.complete(prompt + "Only list action items with a concrete action.\n\n" + body).replacingOccurrences(of: "- [ ] Person: ", with: "- [ ] ")
                if !titling.isEmpty, !text.contains("TITLE:") {
                    text = "TITLE: " + (try await AppleAI.complete("A 2-6 word title in \(Prefs.uiLanguageName) for the meeting summarized below: topic, client or project, no date. Reply with the title only.\n\n" + text)) + "\n" + text
                }
                out = text
            } catch { return error.localizedDescription }
        } else {
            out = AIChat.complete(prompt, engine: engine)
        }
        guard let text = out, let start = text.range(of: "## ") else { return String(localized: "L'AI non ha risposto") }
        if !naming.isEmpty { applyNames(text, dir: dir, label: speaker) }
        if !titling.isEmpty, let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("TITLE:") }) {
            let title = line.dropFirst(6).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"*#")))
            if !title.isEmpty, title.count < 80 { try? (title + "\n").write(to: dir.appendingPathComponent("title"), atomically: true, encoding: .utf8) }
        }
        try? String(text[start.lowerBound...]).write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        NotesExport.exportIfEnabled(dir)
        DispatchQueue.main.async { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
        return nil
    }

    /// "NAMES: {"Parlante 1": "Marco"}" → rinomina nel transcript (non tocca nomi già dati né il tuo)
    static func applyNames(_ reply: String, dir: URL, label: String) {
        guard let line = reply.components(separatedBy: .newlines).first(where: { $0.hasPrefix("NAMES:") }),
              let json = line.dropFirst(6).data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: json) else { return }
        var md = (try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        for (old, new) in map.sorted(by: { $0.key < $1.key }) {
            let name = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
            // due voci con lo stesso nome si fonderebbero: tiene solo la prima
            guard old.hasPrefix(label + " "), !name.isEmpty, name.count < 40, !md.contains("] \(name):**") else { continue }
            md = Transcriber.renameSpeaker(in: dir, from: old, to: name) ?? md
        }
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// Riga di summary.md: titolo di sezione, voce di checklist, punto elenco o testo
struct SummaryLine: Identifiable {
    enum Kind { case heading, todo(done: Bool), bullet, text }
    let id: Int // indice della riga nel file (per spuntare le cose da fare)
    let kind: Kind
    let text: String

    static func parse(_ md: String) -> [SummaryLine] {
        md.components(separatedBy: "\n").enumerated().compactMap { i, raw in
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { return nil }
            if l.hasPrefix("#") { return SummaryLine(id: i, kind: .heading, text: l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)) }
            for (p, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where l.hasPrefix(p) {
                return SummaryLine(id: i, kind: .todo(done: done), text: String(l.dropFirst(p.count)))
            }
            if l.hasPrefix("- ") || l.hasPrefix("* ") { return SummaryLine(id: i, kind: .bullet, text: String(l.dropFirst(2))) }
            return SummaryLine(id: i, kind: .text, text: l)
        }
    }

    /// "[12:34]" all'inizio del testo → secondi
    var seconds: Double? {
        guard text.hasPrefix("["), let end = text.firstIndex(of: "]") else { return nil }
        let parts = text[text.index(after: text.startIndex)..<end].split(separator: ":").compactMap { Double($0) }
        return parts.count >= 2 ? parts.reduce(0) { $0 * 60 + $1 } : nil
    }
}

// MARK: - Condivisione (PDF)

@MainActor
enum ShareExport {
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ s: String) -> String {
        // **grassetto** del markdown → <b>
        esc(s).replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
    }

    static func html(_ m: Meeting) -> String {
        let dir = m.url
        let lines = TranscriptLine.parse((try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? "")
        let people = Array(Set(lines.map(\.speaker).filter { !$0.isEmpty })).sorted()
        var h = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #1d1d1f; }
        h1 { font-size: 20pt; margin-bottom: 2pt; } h2 { font-size: 13pt; color: #e8590c; margin-top: 18pt; }
        .meta { color: #6e6e73; } p { margin: 4pt 0; } .t { color: #6e6e73; font-size: 9pt; }
        </style></head><body>
        <h1>\(esc(m.app))</h1>
        <p class="meta">\(esc(m.date?.formatted(date: .long, time: .shortened) ?? m.id))\(people.isEmpty ? "" : " · " + esc(people.joined(separator: ", ")))</p>
        """
        if let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) {
            for l in SummaryLine.parse(summary) {
                switch l.kind {
                case .heading: h += "<h2>\(inline(l.text))</h2>"
                case let .todo(done): h += "<p>\(done ? "☑" : "☐") \(inline(l.text))</p>"
                case .bullet: h += "<p>• \(inline(l.text))</p>"
                case .text: h += "<p>\(inline(l.text))</p>"
                }
            }
        }
        h += "<h2>Transcript</h2>"
        for l in lines {
            h += l.speaker.isEmpty ? "<p>\(esc(l.text))</p>" : "<p><span class=\"t\">\(l.time)</span> <b>\(esc(l.speaker)):</b> \(esc(l.text))</p>"
        }
        return h + "</body></html>"
    }

    /// PDF A4 impaginato (testo selezionabile)
    static func pdf(_ m: Meeting, to url: URL) throws {
        let data = Data(html(m).utf8)
        let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                 .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 48; info.bottomMargin = 48; info.leftMargin = 50; info.rightMargin = 50
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595 - 100, height: 842))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.sizeToFit()
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw TranscriptionError.message(String(localized: "Creazione PDF non riuscita")) }
    }

    static func fileName(_ m: Meeting) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(m.date.map(f.string) ?? m.id) \(m.app)".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
    }

    /// Menu Condividi di macOS (Mail, Messaggi, AirDrop…) con il PDF
    static func share(_ m: Meeting) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName(m) + ".pdf")
        do { try pdf(m, to: url) } catch { return }
        guard let view = NSApp.keyWindow?.contentView else { return }
        let anchor = NSRect(x: view.bounds.maxX - 120, y: view.bounds.maxY - 60, width: 1, height: 1)
        NSSharingServicePicker(items: [url]).show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    static func savePDF(_ m: Meeting) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = fileName(m) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pdf(m, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
