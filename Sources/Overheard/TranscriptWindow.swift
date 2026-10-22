// Finestra con il transcript di un meeting (stile del pannello: nero, card scure).
// Legge ~/Meetings/<cartella>/transcript.md, scritto da Transcriber (Transcription.swift):
// righe "**[mm:ss] Parlante:** testo".
import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptLine: Identifiable {
    let id: Int
    let time: String
    let speaker: String
    let text: String

    /// "mm:ss" o "h:mm:ss" → secondi
    var seconds: Double { time.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } }

    /// Intestazioni del transcript (scritte nella lingua dell'interfaccia, quindi in italiano o in inglese)
    static let headerPrefixes = ["# ", "Partecipanti:", "Participants:", "_Parlante", "_Speaker", "Titolo:", "Title:",
                                 "Invitati:", "Invited:", "Momenti segnati:", "Bookmarks:"]

    /// Righe "**[00:44] Parlante 1:** testo"; altre righe (intestazioni, transcript vecchi senza parlanti) come testo semplice.
    static func parse(_ md: String) -> [TranscriptLine] {
        let pattern = try! Regex(#"^\*\*\[([0-9:]+)\] (.+?):\*\* (.*)$"#).dotMatchesNewlines()
        return md.components(separatedBy: "\n\n").enumerated().compactMap { i, block in
            let b = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !b.isEmpty, !headerPrefixes.contains(where: b.hasPrefix) else { return nil }
            if let m = b.firstMatch(of: pattern) {
                return TranscriptLine(id: i, time: String(m.output[1].substring ?? ""), speaker: String(m.output[2].substring ?? ""), text: String(m.output[3].substring ?? ""))
            }
            return TranscriptLine(id: i, time: "", speaker: "", text: b)
        }
    }

    /// Secondi di parola per persona: da ogni intervento al successivo (l'ultimo stimato a ~2,5 parole/s).
    static func talkTime(_ lines: [TranscriptLine]) -> [(speaker: String, seconds: Double)] {
        let turns = lines.filter { !$0.speaker.isEmpty }
        var out: [String: Double] = [:]
        for (i, l) in turns.enumerated() {
            let next = i + 1 < turns.count ? turns[i + 1].seconds : l.seconds + Double(l.text.split(separator: " ").count) / 2.5
            out[l.speaker, default: 0] += max(0, next - l.seconds)
        }
        return out.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }
}

func speakerColor(_ name: String) -> Color {
    if name == Prefs.myName { return .orange }
    let palette: [Color] = [.teal, .indigo, .pink, .green, .purple, .yellow, .cyan, .mint]
    // "Parlante N" → colore N; nomi assegnati a mano → colore stabile dal nome
    let n = Int(name.filter(\.isNumber)) ?? name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[n % palette.count]
}

func duration(_ s: Double) -> String {
    let m = Int(s) / 60
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : m > 0 ? "\(m)m" : "\(Int(s))s"
}

/// Riascolto: audio della call (recording.wav) e microfono (mic.wav) suonati insieme e sincronizzati.
@MainActor
final class MeetingPlayer: ObservableObject {
    @Published var playing = false
    @Published var time: TimeInterval = 0
    private var players: [AVAudioPlayer] = []
    private var timer: Timer?

    init(dir: URL) {
        players = ["recording.wav", "mic.wav"].compactMap { try? AVAudioPlayer(contentsOf: dir.appendingPathComponent($0)) }
        players.forEach { $0.prepareToPlay() }
    }

    var available: Bool { !players.isEmpty }
    var duration: TimeInterval { players.map(\.duration).max() ?? 0 }

    func toggle() { playing ? pause() : play() }

    func play() {
        guard let first = players.first else { return }
        if time >= duration - 0.5 { time = 0 }
        let at = first.deviceCurrentTime + 0.05 // stesso istante per entrambe le tracce
        for p in players where time < p.duration {
            p.currentTime = time
            p.play(atTime: at)
        }
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        players.forEach { $0.pause() }
        timer?.invalidate()
        playing = false
    }

    func seek(_ t: TimeInterval) {
        let wasPlaying = playing
        pause()
        time = max(0, min(t, duration))
        if wasPlaying { play() }
    }

    private func tick() {
        time = players.filter(\.isPlaying).map(\.currentTime).max() ?? time
        if !players.contains(where: \.isPlaying) { pause() }
    }
}

struct TranscriptView: View {
    let meeting: Meeting
    var highlight = ""
    @StateObject private var player: MeetingPlayer
    @State private var lines: [TranscriptLine] = []
    @State private var status = ""
    @State private var query = ""
    @State private var onlySpeaker: String?
    @State private var renaming: String?
    @State private var newName = ""
    @State private var editing: Int?        // id della card in modifica
    @State private var editText = ""
    @State private var exportStart: TranscriptLine? // inizio di una sezione audio da esportare
    @State private var exportStatus = ""
    @State private var tab = "transcript"           // "summary" | "transcript"
    @State private var summary: [SummaryLine] = []
    @State private var generating = false
    @State private var summaryError: String?
    @State private var bookmarks: [Double] = []
    @State private var onlyMarked = false
    @State private var attendees: [String] = []

    var startAt: Double?

    init(meeting: Meeting, highlight: String = "", startAt: Double? = nil) {
        self.startAt = startAt
        self.meeting = meeting
        self.highlight = highlight
        _player = StateObject(wrappedValue: MeetingPlayer(dir: meeting.url))
    }

    private var shown: [TranscriptLine] {
        lines.filter { l in
            (onlySpeaker == nil || l.speaker == onlySpeaker)
                && (!onlyMarked || marked.contains(l.id))
                && (query.isEmpty || l.text.localizedCaseInsensitiveContains(query) || l.speaker.localizedCaseInsensitiveContains(query))
        }
    }

    /// Interventi in corso quando è stato premuto ⭐ (3 s prima: si preme dopo aver sentito la frase)
    private var marked: Set<Int> {
        Set(bookmarks.compactMap { b in lines.last { !$0.speaker.isEmpty && $0.seconds <= max(0, b - 3) }?.id })
    }

    /// Riga in riproduzione: l'ultima iniziata prima della posizione attuale
    private var current: Int? {
        guard player.playing || player.time > 0 else { return nil }
        return lines.last { !$0.speaker.isEmpty && $0.seconds <= player.time + 0.3 }?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SourceIcon(source: meeting.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.app).font(.system(size: 18, weight: .bold))
                    HStack(spacing: 8) {
                        Text(meeting.when).font(.callout).foregroundStyle(.white.opacity(0.5))
                        EngineBadge(meeting: meeting)
                    }
                }
                Spacer()
                Menu {
                    Button("Condividi PDF…") { ShareExport.share(meeting) }
                    Button("Salva PDF…") { ShareExport.savePDF(meeting) }
                    Divider()
                    if !summary.isEmpty { Button("Copia riassunto") { copySummary() } }
                    Button("Copia transcript") { copy() }
                    Divider()
                    Button("Esporta nota (Obsidian…)") { exportNote() }
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Condividi, copia, esporta")
                RoundButton(icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }.help("Mostra nel Finder")
            }

            if lines.isEmpty {
                Spacer()
                Text(status).font(.callout).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity)
                if FileManager.default.fileExists(atPath: meeting.url.appendingPathComponent("transcript.error").path) {
                    Button("Riprova") { retry() }.frame(maxWidth: .infinity).padding(.top, 6)
                }
                Spacer()
            } else {
                Picker("", selection: $tab) {
                    Text("Riassunto").tag("summary")
                    Text("Transcript").tag("transcript")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }

            if !lines.isEmpty, tab == "summary" {
                summaryView
                if player.available { playerBar }
            } else if !lines.isEmpty {
                speakers
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("Cerca nel transcript", text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(shown) { line in row(line).id(line.id) }
                        }
                    }
                    .onAppear {
                        // aperto da un risultato di ricerca: audio pronto su quell'intervento
                        if let t = startAt, let id = lines.last(where: { !$0.speaker.isEmpty && $0.seconds <= t })?.id {
                            player.seek(t)
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChange(of: current) { _, id in
                        if let id, player.playing { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
                if player.available { playerBar }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 38) // spazio per i pulsanti della finestra (barra del titolo trasparente)
        .padding(.bottom, 22)
        .frame(minWidth: 460, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onAppear {
            query = highlight
            load()
            // con un riassunto si parte da lì, tranne quando si arriva da una ricerca
            if FileManager.default.fileExists(atPath: meeting.url.appendingPathComponent("summary.md").path), highlight.isEmpty, startAt == nil { tab = "summary" }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingsChanged)) { _ in load() }
        .onDisappear { player.pause() }
        .alert("Rinomina \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Rinomina") { rename() }
            // invitati dal calendario non ancora usati
            ForEach(attendees.filter { a in !lines.contains { $0.speaker == a } }.prefix(5), id: \.self) { a in
                Button(a) { newName = a; rename() }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Cambia il nome in tutto il transcript di questa riunione.")
        }
    }

    /// Persone con tempo di parola: clic = solo i suoi interventi, clic destro = rinomina
    private var speakers: some View {
        let talk = TranscriptLine.talkTime(lines)
        let total = max(1, talk.reduce(0) { $0 + $1.seconds })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !bookmarks.isEmpty {
                    Button { onlyMarked.toggle() } label: {
                        Label("\(bookmarks.count)", systemImage: "star.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.yellow)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(onlyMarked ? Color.yellow.opacity(0.25) : Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain).help("Solo i momenti segnati")
                }
                ForEach(talk, id: \.speaker) { t in
                    let on = onlySpeaker == t.speaker
                    Button { onlySpeaker = on ? nil : t.speaker } label: {
                        HStack(spacing: 6) {
                            Circle().fill(speakerColor(t.speaker)).frame(width: 8, height: 8)
                            Text(t.speaker).font(.callout.weight(.semibold))
                            Text("\(duration(t.seconds)) · \(Int(t.seconds / total * 100))%").font(.caption).foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? speakerColor(t.speaker).opacity(0.3) : Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Clic: solo i suoi interventi · Clic destro: rinomina")
                    .contextMenu {
                        Button("Rinomina…") { newName = t.speaker.hasPrefix("Parlante") || t.speaker.hasPrefix("Speaker") ? "" : t.speaker; renaming = t.speaker }
                    }
                }
            }
        }
    }

    private func row(_ line: TranscriptLine) -> some View {
        let playingNow = line.id == current
        return VStack(alignment: .leading, spacing: 4) {
            if !line.speaker.isEmpty {
                HStack(spacing: 6) {
                    Text(line.speaker).font(.callout.weight(.semibold)).foregroundStyle(speakerColor(line.speaker))
                    if marked.contains(line.id) { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                    if player.available {
                        Button { player.seek(line.seconds); if !player.playing { player.play() } } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "play.fill").font(.system(size: 8))
                                Text(line.time).font(.caption.monospacedDigit())
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                        .help("Ascolta da qui")
                    } else {
                        Text(line.time).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            if editing == line.id {
                TextEditor(text: $editText)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 220)
                    .padding(6)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Spacer()
                    Button("Annulla") { editing = nil }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    Button("Salva") { saveEdit(line) }.buttonStyle(.plain).foregroundStyle(.orange).keyboardShortcut(.return, modifiers: .command)
                }
                .font(.callout.weight(.semibold))
            } else {
                Text(highlighted(line.text, query)).font(.body).lineSpacing(3) // niente selezione: il clic sulla card fa partire l'audio (per il testo c'è Copia)
            }
            if exportStart?.id == line.id {
                Label("Inizio sezione da esportare · clic destro su un'altra card per la fine", systemImage: "scissors")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(playingNow ? 0.13 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(playingNow ? speakerColor(line.speaker).opacity(0.7) : marked.contains(line.id) ? Color.yellow.opacity(0.45) : .clear, lineWidth: 1.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // clic sulla card: ascolta da lì; sulla card in riproduzione: pausa/riprendi
        .contextMenu { if !line.speaker.isEmpty { menu(line) } }
        .onTapGesture {
            guard player.available, !line.speaker.isEmpty, editing != line.id else { return }
            if playingNow { player.toggle() } else { player.seek(line.seconds); if !player.playing { player.play() } }
        }
        .onHover { inside in if player.available, !line.speaker.isEmpty { (inside ? NSCursor.pointingHand : NSCursor.arrow).set() } }
    }

    private var playerBar: some View {
        HStack(spacing: 12) {
            RoundButton(icon: player.playing ? "pause.fill" : "play.fill") { player.toggle() }
            Text(stamp(player.time)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
            Slider(value: Binding(get: { player.time }, set: { player.seek($0) }), in: 0...max(player.duration, 1))
                .tint(.orange)
            Text(stamp(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private func load() {
        let dir = meeting.url
        summary = SummaryLine.parse((try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)) ?? "")
        bookmarks = Bookmarks.load(dir)
        attendees = MeetingCalendar.attendees(dir)
        if let md = try? String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8) {
            lines = TranscriptLine.parse(md)
        } else if let err = try? String(contentsOf: dir.appendingPathComponent("transcript.error"), encoding: .utf8) {
            status = String(localized: "Trascrizione fallita: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else if FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.wav").path) {
            status = String(localized: "Trascrizione in corso…")
        } else if Recorder.shared.isRecording(dir) {
            status = String(localized: "Registrazione in corso")
        } else {
            status = String(localized: "Registrazione interrotta: viene recuperata al prossimo avvio dell'app")
        }
    }

    private func rename() {
        guard let old = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        renaming = nil
        guard !name.isEmpty, name != old else { return }
        guard let md = Transcriber.renameSpeaker(in: meeting.url, from: old, to: name) else { return }
        if onlySpeaker == old { onlySpeaker = name }
        lines = TranscriptLine.parse(md)
    }

    @ViewBuilder private func menu(_ line: TranscriptLine) -> some View {
        Button("Modifica testo") { editText = line.text; editing = line.id }
        Button("Copia intervento") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line.text, forType: .string)
        }
        if player.available {
            Divider()
            Button("Esporta audio di questo intervento…") { exportAudio(from: line, to: line) }
            if let start = exportStart, start.id != line.id {
                let (a, b) = start.seconds <= line.seconds ? (start, line) : (line, start)
                Button("Esporta audio da \(a.time) a fine \(b.time)…") { exportAudio(from: a, to: b); exportStart = nil }
                Button("Annulla sezione") { exportStart = nil }
            } else {
                Button("Inizia sezione audio da qui") { exportStart = line }
            }
        }
    }

    /// Trascrizione fallita (chiave mancante, rete…): riprova con il motore attuale
    private func retry() {
        let dir = meeting.url, engine = Recorder.shared.engine
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.error"))
        status = String(localized: "Trascrizione in corso…")
        Task.detached {
            _ = await Transcriber.run(dir: dir, engine: engine)
            await MainActor.run { load() }
        }
    }

    /// Riscrive il blocco della card in transcript.md (gli id sono gli indici dei blocchi separati da riga vuota)
    private func saveEdit(_ line: TranscriptLine) {
        editing = nil
        let text = editText.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let url = meeting.url.appendingPathComponent("transcript.md")
        guard !text.isEmpty, text != line.text, let md = try? String(contentsOf: url, encoding: .utf8) else { return }
        var blocks = md.components(separatedBy: "\n\n")
        guard blocks.indices.contains(line.id) else { return }
        let trailing = blocks[line.id].hasSuffix("\n") ? "\n" : ""
        blocks[line.id] = "**[\(line.time)] \(line.speaker):** \(text)" + trailing
        let out = blocks.joined(separator: "\n\n")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        lines = TranscriptLine.parse(out)
        NotesExport.exportIfEnabled(meeting.url)
    }

    private func exportNote() {
        if NotesExport.folder == nil, SettingsView.chooseNotesFolder() == nil { return }
        do {
            NSWorkspace.shared.activateFileViewerSelecting([try NotesExport.export(meeting.url)])
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Esportazione non riuscita")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// Sezione di audio (call + microfono mixati) da inizio di `a` a fine di `b`, salvata in .m4a dove sceglie l'utente.
    private func exportAudio(from a: TranscriptLine, to b: TranscriptLine) {
        let start = max(0, a.seconds - 0.3)
        let end = lines.first { !$0.speaker.isEmpty && $0.seconds > b.seconds }?.seconds ?? player.duration
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "\(meeting.app) \(meeting.when) [\(a.time)-\(stamp(end))].m4a"
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let dir = meeting.url
        Task {
            do {
                try await AudioExport.run(dir: dir, start: start, end: end, out: out)
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "Esportazione non riuscita")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Riassunto

    /// Sezioni del riassunto (titolo → righe), ognuna nella sua card
    private var sections: [(title: String, lines: [SummaryLine])] {
        var out: [(String, [SummaryLine])] = []
        for l in summary {
            if case .heading = l.kind { out.append((l.text, [])) } else if out.isEmpty { out.append(("", [l])) } else { out[out.count - 1].1.append(l) }
        }
        return out
    }

    private var summaryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !bookmarks.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text("Momenti segnati").font(.callout.weight(.semibold))
                        ForEach(bookmarks, id: \.self) { b in
                            Button { player.seek(max(0, b - 10)); player.play() } label: {
                                Label(Summarizer.stamp(b), systemImage: "play.fill").font(.caption.monospacedDigit())
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.yellow.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain).help("Ascolta da 10 secondi prima")
                        }
                    }
                }
                if summary.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.badge.star").font(.system(size: 30)).foregroundStyle(.orange)
                        Text(generating ? "Scrivo il riassunto…" : "Ancora nessun riassunto").font(.headline)
                        Text("Riassunto, decisioni e cose da fare scritti dall'AI (Claude Code o Codex) leggendo il transcript.")
                            .font(.callout).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                        if generating { ProgressView().controlSize(.small) } else {
                            Button("Genera riassunto") { generate() }.buttonStyle(.borderedProminent).tint(.orange)
                        }
                        if let e = summaryError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                    .padding(24).frame(maxWidth: .infinity)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.title.isEmpty {
                            Text(section.title).font(.headline).foregroundStyle(.orange)
                        }
                        ForEach(section.lines) { summaryRow($0) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !summary.isEmpty {
                    HStack {
                        if generating { ProgressView().controlSize(.small); Text("Riscrivo…").font(.caption) }
                        else { Button("Rigenera riassunto") { generate() }.buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                        if let e = summaryError { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
    }

    private func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    @ViewBuilder private func summaryRow(_ l: SummaryLine) -> some View {
        switch l.kind {
        case let .todo(done):
            Button { toggleTodo(l) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .white.opacity(0.5))
                    Text(md(l.text)).strikethrough(done).opacity(done ? 0.5 : 1).multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.white.opacity(0.4))
                Text(md(l.text))
                if let t = l.seconds, player.available {
                    Button { player.seek(max(0, t - 5)); player.play() } label: { Image(systemName: "play.circle.fill").foregroundStyle(.yellow) }
                        .buttonStyle(.plain).help("Ascolta")
                }
            }
        default:
            Text(md(l.text)).lineSpacing(3)
        }
    }

    private func toggleTodo(_ l: SummaryLine) {
        let url = meeting.url.appendingPathComponent("summary.md")
        guard let md = try? String(contentsOf: url, encoding: .utf8) else { return }
        var rows = md.components(separatedBy: "\n")
        guard rows.indices.contains(l.id) else { return }
        let r = rows[l.id]
        rows[l.id] = r.contains("- [ ] ") ? r.replacingOccurrences(of: "- [ ] ", with: "- [x] ")
            : r.replacingOccurrences(of: "- [x] ", with: "- [ ] ").replacingOccurrences(of: "- [X] ", with: "- [ ] ")
        try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        summary = SummaryLine.parse(rows.joined(separator: "\n"))
        NotesExport.exportIfEnabled(meeting.url)
    }

    private func generate() {
        generating = true
        summaryError = nil
        let dir = meeting.url
        Task {
            let err = await Task.detached { await Summarizer.run(dir) }.value
            generating = false
            summaryError = err
            load()
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((try? String(contentsOf: meeting.url.appendingPathComponent("summary.md"), encoding: .utf8)) ?? "", forType: .string)
    }

    private func copy() {
        let text = lines.map { $0.speaker.isEmpty ? $0.text : "[\($0.time)] \($0.speaker): \($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Archivio: tutti i meeting a sinistra (per giorno, con ricerca anche dentro i transcript), transcript a destra.
/// Con cosa è stato trascritto il meeting e com'è andata (file "engine", transcript.error, .transcribing)
struct EngineBadge: View {
    let meeting: Meeting

    private var info: (String, Color)? {
        let fm = FileManager.default
        func has(_ f: String) -> Bool { fm.fileExists(atPath: meeting.url.appendingPathComponent(f).path) }
        if has(".transcribing") { return (String(localized: "In corso"), .gray) }
        if has("transcript.error") { return (String(localized: "Fallita"), .red) }
        let engine = (try? String(contentsOf: meeting.url.appendingPathComponent("engine"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch engine {
        case "elevenlabs": return ("ElevenLabs", .green)
        case "local": return (String(localized: "Sul Mac"), .green)
        case "fallback": return (String(localized: "Sul Mac · ElevenLabs fallito"), .orange)
        default: return nil // meeting di prima dei badge
        }
    }

    var body: some View {
        if let (label, color) = info {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color == .gray ? .white.opacity(0.6) : color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .lineLimit(1).fixedSize()
        }
    }
}

struct LibraryView: View {
    @State var selected: String?
    @State var query = ""
    @State var startAt: Double?
    var ask: String?
    var openChat = false
    var openLink = false
    @State private var meetings: [Meeting] = []
    @State private var texts: [String: String] = [:] // transcript per cartella, per la ricerca
    @StateObject private var chat = AIChat()
    @ObservedObject private var importer = Importer.shared
    @State private var askLink = false
    @State private var link = ""
    @State private var dropping = false
    @AppStorage("ai.visible") private var showChat = false
    @State private var toDelete: [Meeting] = []
    @State private var picking = false               // modalità selezione multipla
    @State private var picked: Set<String> = []

    private var filtered: [Meeting] {
        guard !query.isEmpty else { return meetings }
        return meetings.filter { m in
            "\(m.app) \(m.when)".localizedCaseInsensitiveContains(query) || (texts[m.id] ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private var days: [(String, [Meeting])] {
        var out: [(String, [Meeting])] = []
        for m in filtered {
            let day = m.date.map { d in
                Calendar.current.isDateInToday(d) ? "Oggi" : Calendar.current.isDateInYesterday(d) ? "Ieri"
                    : d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
            } ?? "Altro"
            if out.last?.0 == day { out[out.count - 1].1.append(m) } else { out.append((day, [m])) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Riunioni").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Menu {
                        Button("Importa file audio o video…") { importer.pickFiles() }
                        Button("Importa da link (YouTube, podcast…)…") { link = ""; askLink = true }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.1), in: Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Importa file o link")
                    Button { showChat.toggle() } label: {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(showChat ? Color.orange.opacity(0.3) : Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain).help("Chiedi all'AI sui meeting")
                    Button { picking.toggle(); picked = [] } label: {
                        Image(systemName: "checklist").font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(picking ? Color.orange.opacity(0.3) : Color.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain).help("Seleziona più riunioni")
                }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("Cerca riunioni e transcript", text: $query).textFieldStyle(.plain)
                }
                .padding(9)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                if let status = importer.status {
                    HStack(spacing: 8) {
                        if status.hasSuffix("…") { ProgressView().controlSize(.small) }
                        Text(status).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(days, id: \.0) { day, items in
                            Text(day.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.45))
                                .padding(.top, 10).padding(.leading, 6)
                            ForEach(items) { m in row(m) }
                        }
                        if filtered.isEmpty {
                            Text(query.isEmpty ? "Nessuna riunione" : "Nessun risultato").font(.callout)
                                .foregroundStyle(.white.opacity(0.5)).padding(.top, 20)
                        }
                    }
                }

                if picking {
                    HStack {
                        Button(picked.count == filtered.filter { !busy($0) }.count && !picked.isEmpty ? LocalizedStringKey("Deseleziona tutte") : "Seleziona tutte") {
                            let all = Set(filtered.filter { !busy($0) }.map(\.id))
                            picked = picked == all ? [] : all
                        }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.7))
                        Spacer()
                        Button("Annulla") { picking = false; picked = [] }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(.white.opacity(0.7))
                        Button { toDelete = meetings.filter { picked.contains($0.id) } } label: {
                            Label("\(picked.count)", systemImage: "trash").font(.caption.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.red.opacity(picked.isEmpty ? 0.1 : 0.3), in: Capsule())
                        }
                        .buttonStyle(.plain).disabled(picked.isEmpty).help("Sposta nel Cestino…")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 38)
            .padding(.bottom, 14)
            .frame(width: 270)
            .background(Color.white.opacity(0.04))

            if let m = meetings.first(where: { $0.id == selected }) {
                TranscriptView(meeting: m, highlight: query, startAt: startAt).id(m.id)
            } else {
                Text("Seleziona una riunione").foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showChat {
                AIChatView(chat: chat, meeting: meetings.first { $0.id == selected })
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .onAppear {
            load()
            if let ask { showChat = true; chat.ask(ask, meeting: nil) }
            if openChat { showChat = true }
            if openLink { link = ""; askLink = true }
        }
        .onChange(of: selected) { _, _ in startAt = nil }
        .onReceive(NotificationCenter.default.publisher(for: .meetingsChanged)) { n in
            load()
            if let id = n.object as? String { selected = id }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in await Importer.shared.importFile(url) } }
                }
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(Label("Rilascia per importare e trascrivere", systemImage: "square.and.arrow.down")
                        .font(.title3.weight(.semibold)).foregroundStyle(.orange))
                    .padding(12)
            }
        }
        .confirmationDialog(toDelete.count == 1 ? Text("Spostare questa riunione nel Cestino?") : Text("Spostare \(toDelete.count) riunioni nel Cestino?"),
                            isPresented: Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } }), presenting: toDelete) { ms in
            Button("Sposta nel Cestino", role: .destructive) { trash(ms) }
        } message: { ms in
            if ms.count == 1, let m = ms.first {
                Text("\(m.app) · audio, transcript e riassunto. Puoi recuperarla dal Cestino.")
            } else {
                Text("Audio, transcript e riassunti. Puoi recuperarle dal Cestino.")
            }
        }
        .alert("Importa da link", isPresented: $askLink) {
            TextField("https://…", text: $link)
            Button("Importa") { importer.importLink(link) }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("YouTube, podcast e gli altri siti supportati da yt-dlp. Spotify non funziona (audio protetto).")
        }
    }

    private func row(_ m: Meeting) -> some View {
        let isSel = m.id == selected
        let isPicked = picked.contains(m.id)
        let time = m.date?.formatted(date: .omitted, time: .shortened) ?? m.id
        let missing = texts[m.id] == nil
        return Button {
            // ⌘-clic entra in selezione multipla partendo dalla riunione aperta
            if !picking, NSEvent.modifierFlags.contains(.command) {
                picking = true
                picked = Set([selected, m.id].compactMap { $0 }.filter { id in meetings.contains { $0.id == id && !busy($0) } })
            } else if picking {
                if busy(m) { return }
                if isPicked { picked.remove(m.id) } else { picked.insert(m.id) }
            } else {
                selected = m.id
            }
        } label: {
            HStack(spacing: 10) {
                if picking {
                    Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isPicked ? Color.orange : .white.opacity(busy(m) ? 0.2 : 0.5))
                }
                SourceIcon(source: m.source)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.app).lineLimit(1)
                    Text(missing ? String(localized: "\(time) · senza transcript") : time).font(.caption).foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(isPicked ? Color.orange.opacity(0.15) : isSel ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([m.url]) }
            Divider()
            if isPicked && picked.count > 1 {
                Button("Sposta \(picked.count) riunioni nel Cestino…", role: .destructive) { toDelete = meetings.filter { picked.contains($0.id) } }
            } else {
                Button("Sposta nel Cestino…", role: .destructive) { toDelete = [m] }
                    .disabled(busy(m))
            }
        }
    }

    /// In registrazione o in trascrizione: non si può cestinare
    private func busy(_ m: Meeting) -> Bool {
        Recorder.shared.isRecording(m.url) || FileManager.default.fileExists(atPath: m.url.appendingPathComponent(".transcribing").path)
    }

    private func trash(_ ms: [Meeting]) {
        for m in ms where !busy(m) {
            guard (try? FileManager.default.trashItem(at: m.url, resultingItemURL: nil)) != nil else { continue }
            picked.remove(m.id)
            if selected == m.id { selected = nil }
        }
        if picked.isEmpty { picking = false }
        load()
    }

    private func load() {
        meetings = Meeting.recent(.max)
        if selected == nil { selected = meetings.first?.id }
        // ponytail: legge tutti i transcript in memoria per la ricerca; ok fino a qualche migliaio di meeting
        DispatchQueue.global().async {
            var t: [String: String] = [:]
            for m in meetings {
                t[m.id] = try? String(contentsOf: m.url.appendingPathComponent("transcript.md"), encoding: .utf8)
            }
            DispatchQueue.main.async { texts = t }
        }
    }
}

@MainActor
enum TranscriptWindow {
    private static var window: NSWindow?

    /// `nil` = apre l'archivio sull'ultima riunione
    static func show(_ meeting: Meeting?, query: String = "", at: Double? = nil, ask: String? = nil, chat: Bool = false, importLink: Bool = false) {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.title = "Riunioni"
            w.center()
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: LibraryView(selected: meeting?.id, query: query, startAt: at, ask: ask, openChat: chat, openLink: importLink))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Taglia e mixa recording.wav + mic.wav (tracce sovrapposte in una composizione) in un .m4a AAC.
enum AudioExport {
    static func run(dir: URL, start: Double, end: Double, out: URL) async throws {
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        for name in ["recording.wav", "mic.wav"] {
            let asset = AVURLAsset(url: dir.appendingPathComponent(name))
            guard let src = try? await asset.loadTracks(withMediaType: .audio).first,
                  let len = try? await asset.load(.duration) else { continue }
            let r = CMTimeRangeGetIntersection(range, otherRange: CMTimeRange(start: .zero, duration: len))
            guard r.duration > .zero else { continue }
            let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(r, of: src, at: r.start - range.start)
        }
        guard !comp.tracks.isEmpty, let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.message(String(localized: "Audio non disponibile"))
        }
        try? FileManager.default.removeItem(at: out)
        session.outputURL = out
        session.outputFileType = .m4a
        await session.export()
        if let error = session.error { throw error }
    }
}
