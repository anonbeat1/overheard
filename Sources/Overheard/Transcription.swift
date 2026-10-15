// Trascrizione nell'app, dopo lo stop: ElevenLabs Scribe v2 (chiave nel Portachiavi) oppure, se scelto
// "Sul Mac", ~/.local/bin/meeting-transcriber (Cohere) se installato. Scrive transcript.md nel formato
// "**[mm:ss] Parlante:** testo" letto da TranscriptWindow, dai riassunti e dal server MCP.
// Mentre lavora tiene un file .transcribing, così altri strumenti che leggono ~/Meetings non lo trascrivono in parallelo.
import AVFoundation
import Foundation
import Security

// MARK: - Impostazioni condivise

enum Prefs {
    static var myName: String {
        let n = UserDefaults.standard.string(forKey: "myName")?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? "Io" : n
    }

    /// Etichetta personale per la sorgente (meet / teams / slack / altro), es. il nome dell'azienda. Vuota = solo il nome dell'app.
    static func label(_ source: String) -> String {
        UserDefaults.standard.string(forKey: "label.\(source)")?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// Riduzione dell'eco sul microfono (per chi usa gli altoparlanti); di default attiva
    static var echoReduction: Bool { UserDefaults.standard.object(forKey: "echoReduction") as? Bool ?? true }

    /// Lingua delle riunioni ("it", "en"…); vuota = automatica (ElevenLabs la riconosce, sul Mac si usa quella dell'interfaccia)
    static var language: String { UserDefaults.standard.string(forKey: "language") ?? "" }

    /// Lingua dell'interfaccia ("it" o "en") e il suo nome in inglese, per dire all'AI in che lingua scrivere
    static var uiLanguage: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var uiLanguageName: String { Locale(identifier: "en").localizedString(forLanguageCode: uiLanguage) ?? "English" }

    static var keyterms: [String] {
        (UserDefaults.standard.string(forKey: "keyterms") ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Chiave ElevenLabs nel Portachiavi di macOS (non in chiaro su disco).
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.anonbeat.overheard",
        kSecAttrAccount as String: "elevenlabs-api-key",
    ]

    static var elevenLabsKey: String? {
        read(service: query[kSecAttrService as String] as! String)
            ?? (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func read(service: String) -> String? {
        var q = query
        q[kSecAttrService as String] = service
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Ripiego se il Portachiavi rifiuta (es. voce creata da una build firmata diversamente, che questa app non può toccare)
    private static let fileURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Overheard/elevenlabs.key")

    /// Se c'è una chiave salvata, senza leggere il Portachiavi (che con una firma ad-hoc chiede il permesso a ogni build).
    static var hasElevenLabsKey: Bool { UserDefaults.standard.bool(forKey: "hasElevenLabsKey") }

    /// nil = salvata; altrimenti il motivo
    @discardableResult
    static func setElevenLabsKey(_ key: String?) -> String? {
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL)
        UserDefaults.standard.set(false, forKey: "hasElevenLabsKey")
        guard let key, !key.isEmpty else { return nil }
        let data = Data(key.utf8)
        var q = query
        q[kSecValueData as String] = data
        var status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
        if status != errSecSuccess || elevenLabsKey != key {
            // file leggibile solo dall'utente
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return String(localized: "Portachiavi errore \(status), e file non scrivibile")
            }
        }
        let ok = elevenLabsKey == key
        UserDefaults.standard.set(ok, forKey: "hasElevenLabsKey")
        return ok ? nil : String(localized: "Portachiavi errore \(status)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Trascrizione

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
}

enum Transcriber {
    /// meeting-transcriber incluso nell'app (Resources/transcriber); in sviluppo anche ~/.local/bin
    static var localTool: String {
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("transcriber/meeting-transcriber").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "\(home)/.local/bin/meeting-transcriber"
    }

    /// Trascrive la cartella e scrive transcript.md (o transcript.error). Ritorna l'esito per la notifica.
    static func run(dir: URL, engine: String) async -> Result<Void, Error> {
        let marker = dir.appendingPathComponent(".transcribing")
        FileManager.default.createFile(atPath: marker.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: marker) }
        do {
            let md: String
            if engine == "local" {
                md = try local(dir)
            } else if let key = Keychain.elevenLabsKey {
                do {
                    md = try await elevenLabs(dir, key: key)
                } catch {
                    // rete/credito/chiave: ripiega sul Mac se possibile
                    guard FileManager.default.isExecutableFile(atPath: localTool) else { throw error }
                    md = String(localized: "_Trascrizione locale (ElevenLabs non disponibile: \(error.localizedDescription))._\n\n") + (try local(dir))
                }
            } else {
                throw TranscriptionError.message(String(localized: "Chiave ElevenLabs non impostata (Impostazioni)"))
            }
            var head: [String] = []
            if let title = Meeting.at(dir).title { head.append(String(localized: "Titolo: \(title)")) }
            let invited = MeetingCalendar.attendees(dir)
            if !invited.isEmpty { head.append(String(localized: "Invitati: \(invited.joined(separator: ", "))")) }
            let marks = Bookmarks.load(dir)
            if !marks.isEmpty { head.append(String(localized: "Momenti segnati: ") + marks.map { "[\(Summarizer.stamp($0))]" }.joined(separator: ", ")) }
            let top = head.isEmpty ? "" : head.joined(separator: "\n") + "\n\n"
            try "# Transcript — \(dir.lastPathComponent)\n\n\(top)\(md)".write(to: dir.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            NotesExport.exportIfEnabled(dir)
            Task.detached { await Summarizer.runIfEnabled(dir) } // riassunto e cose da fare, poi riesporta la nota
            return .success(())
        } catch {
            try? (error.localizedDescription + "\n").write(to: dir.appendingPathComponent("transcript.error"), atomically: true, encoding: .utf8)
            return .failure(error)
        }
    }

    /// Riscrive transcript.md con il nuovo nome (righe "] Vecchio:**" e la riga "Partecipanti:"); ritorna il nuovo testo
    @discardableResult
    static func renameSpeaker(in dir: URL, from old: String, to name: String) -> String? {
        let url = dir.appendingPathComponent("transcript.md")
        guard var md = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        md = md.replacingOccurrences(of: "] \(old):**", with: "] \(name):**")
        md = md.components(separatedBy: "\n").map { l in
            guard let prefix = ["Partecipanti:", "Participants:"].first(where: l.hasPrefix) else { return l }
            return prefix + " " + l.dropFirst(prefix.count).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { $0 == old ? name : $0 }.joined(separator: ", ")
        }.joined(separator: "\n")
        try? md.write(to: url, atomically: true, encoding: .utf8)
        NotesExport.exportIfEnabled(dir)
        return md
    }

    /// "Partecipanti: …" + nota sulle voci non riconosciute, in cima al transcript
    static func participantsHeader(_ speakers: [String]) -> String {
        let present = Set(speakers.filter { !$0.isEmpty }).sorted()
        return String(localized: "Partecipanti: ") + present.map { $0 == Prefs.myName ? String(localized: "\($0) (microfono)") : $0 }.joined(separator: ", ") + "\n"
            + String(localized: "_Parlante N = voci della call, riconosciute automaticamente (l'etichetta non è il nome reale)._") + "\n\n"
    }

    private static func local(_ dir: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: localTool) else {
            throw TranscriptionError.message(String(localized: "Trascrizione sul Mac non installata (\(localTool))"))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: localTool)
        p.arguments = [dir.path, "--me", Prefs.myName, "--speaker", String(localized: "Parlante"),
                       "--language", Prefs.language.isEmpty ? Prefs.uiLanguage : Prefs.language]
        let mic = dir.appendingPathComponent("mic.wav"), clean = dir.appendingPathComponent(".mic-clean.wav")
        defer { try? FileManager.default.removeItem(at: clean) }
        if Prefs.echoReduction, FileManager.default.fileExists(atPath: mic.path) {
            let cleaned = EchoGate.clean(mic: try read16kMono(mic), sys: try read16kMono(dir.appendingPathComponent("recording.wav"))).out
            try writeWav(cleaned, to: clean)
            p.arguments! += ["--mic", clean.path]
        }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw TranscriptionError.message(msg.split(separator: "\n").last.map(String.init) ?? String(localized: "meeting-transcriber fallito"))
        }
        let md = String(decoding: data, as: UTF8.self)
        return participantsHeader(TranscriptLine.parse(md).map(\.speaker)) + md
    }

    // MARK: ElevenLabs

    private static func elevenLabs(_ dir: URL, key: String) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mr-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mic = dir.appendingPathComponent("mic.wav")
        let hasMic = FileManager.default.fileExists(atPath: mic.path)
        let env = try mixToM4A(sys: dir.appendingPathComponent("recording.wav"), mic: hasMic ? mic : nil, out: tmp)

        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1800
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let boundary = "mr-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var fields: [(String, String)] = [("model_id", "scribe_v2"), ("diarize", "true"),
                                          ("timestamps_granularity", "word"), ("tag_audio_events", "false"), ("no_verbatim", "true")]
        // lingua scelta nelle Impostazioni; per file e link importati (o se automatica) la riconosce ElevenLabs
        if Meeting.at(dir).source != "import", !Prefs.language.isEmpty { fields.append(("language_code", Prefs.language)) }
        fields += Prefs.keyterms.map { ("keyterms", $0) }
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"mix.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(try Data(contentsOf: tmp))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
            throw TranscriptionError.message(status == 401 ? String(localized: "Chiave ElevenLabs non valida") : String(localized: "ElevenLabs HTTP \(status): \(detail)"))
        }
        struct Word: Decodable { let text: String; let type: String?; let start: Double?; let end: Double?; let speaker_id: String? }
        struct Response: Decodable { let words: [Word] }
        let words = try JSONDecoder().decode(Response.self, from: data).words.filter { $0.type != "audio_event" }
        return format(words.map { ($0.text, $0.type ?? "word", $0.start, $0.end, $0.speaker_id ?? "speaker_0") }, env: env, hasMic: hasMic)
    }

    /// (testo, tipo, inizio, fine, speaker) → markdown con nomi. "Il tuo nome" = la voce più forte nel mic.
    static func format(_ words: [(String, String, Double?, Double?, String)], env: (sys: [Float], mic: [Float]), hasMic: Bool) -> String {
        var energy: [String: (mic: Float, sys: Float)] = [:]
        for (_, type, start, end, sp) in words where type == "word" {
            guard let start, let end else { continue }
            let a = max(0, Int(start * 100)), b = Int(end * 100) + 1
            var e = energy[sp] ?? (0, 0)
            if a < env.mic.count { e.mic += env.mic[a..<min(b, env.mic.count)].reduce(0, +) }
            if a < env.sys.count { e.sys += env.sys[a..<min(b, env.sys.count)].reduce(0, +) }
            energy[sp] = e
        }
        let ratios = energy.mapValues { $0.mic / ($0.sys + 1e-6) }
        let me = hasMic ? ratios.filter { $0.value > 1.5 }.max { $0.value < $1.value }?.key : nil
        var names: [String: String] = [:]
        var others = 0
        for (_, _, _, _, sp) in words where names[sp] == nil {
            if sp == me { names[sp] = Prefs.myName } else { others += 1; names[sp] = String(localized: "Parlante \(others)") }
        }

        var turns: [(Double, String, String)] = []
        for (text, _, start, _, sp) in words {
            let who = names[sp] ?? String(localized: "Parlante \(1)")
            if let last = turns.last, last.1 == who { turns[turns.count - 1].2 += text } else { turns.append((start ?? 0, who, text)) }
        }
        var md = participantsHeader(turns.map(\.1))
        md += turns.compactMap { t, who, text in
            let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : "**[\(stamp(t))] \(who):** \(s)"
        }.joined(separator: "\n\n")
        return md + "\n"
    }

    static func stamp(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Mixa call + mic in un m4a mono 16 kHz (~20 MB/h) e calcola l'inviluppo (media |x| ogni 10 ms) di ciascuna traccia.
    static func mixToM4A(sys: URL, mic: URL?, out: URL) throws -> (sys: [Float], mic: [Float]) {
        let a = try read16kMono(sys)
        var b = try mic.map(read16kMono) ?? []
        if Prefs.echoReduction, !b.isEmpty { b = EchoGate.clean(mic: b, sys: a).out }
        let n = max(a.count, b.count)
        var mix = [Float](repeating: 0, count: n)
        for i in 0..<a.count { mix[i] += a[i] }
        for i in 0..<b.count { mix[i] += b[i] }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48000]
        let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var pos = 0
        while pos < n {
            let len = min(16000 * 10, n - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(len))!
            buf.frameLength = AVAudioFrameCount(len)
            mix.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress! + pos, count: len) }
            try file.write(from: buf)
            pos += len
        }
        return (envelope(a), envelope(b))
    }

    private static func envelope(_ x: [Float]) -> [Float] {
        stride(from: 0, to: x.count, by: 160).map { i in x[i..<min(i + 160, x.count)].reduce(0) { $0 + abs($1) } / 160 }
    }

    static func writeWav(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard !samples.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
    }

    static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: file.processingFormat, to: target) else { throw TranscriptionError.message(String(localized: "Formato audio non supportato")) }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 1024)
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        var done = false
        while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65536)!
            var error: NSError?
            let status = conv.convert(to: outBuf, error: &error) { _, st in
                if done { st.pointee = .endOfStream; return nil }
                do { try file.read(into: inBuf) } catch { done = true; st.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { done = true; st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if let error { throw error }
            out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            if status == .endOfStream || (status == .inputRanDry && done) || outBuf.frameLength == 0 && done { break }
        }
        return out
    }
}

// MARK: - Modelli per la trascrizione sul Mac

/// Scarica i modelli di Cohere Transcribe + diarizzazione (~2,5 GB, una volta sola) con `meeting-transcriber --prepare`.
@MainActor
final class LocalModels: ObservableObject {
    static let shared = LocalModels()

    @Published var ready = UserDefaults.standard.bool(forKey: "localModelsReady")
    @Published var progress: Double?
    @Published var phase = ""
    @Published var error: String?

    /// La libreria speech-swift richiede macOS 15
    static var supported: Bool { ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) }

    func download() {
        guard progress == nil else { return }
        progress = 0
        error = nil
        let tool = Transcriber.localTool
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = ["--prepare"]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
                for try await line in out.fileHandleForReading.bytes.lines {
                    let parts = line.split(separator: " ", maxSplits: 2)
                    guard parts.count >= 2, parts[0] == "PROGRESS", let pct = Double(parts[1]) else { continue }
                    let phase = parts.count > 2 ? String(parts[2]) : ""
                    await MainActor.run { LocalModels.shared.progress = pct / 100; LocalModels.shared.phase = phase }
                }
                p.waitUntilExit()
                let ok = p.terminationStatus == 0
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                await MainActor.run { LocalModels.shared.finish(ok, msg) }
            } catch {
                await MainActor.run { LocalModels.shared.finish(false, error.localizedDescription) }
            }
        }
    }

    private func finish(_ ok: Bool, _ msg: String) {
        progress = nil
        ready = ok
        UserDefaults.standard.set(ok, forKey: "localModelsReady")
        if !ok { error = msg.split(separator: "\n").last.map(String.init) ?? String(localized: "download non riuscito") }
    }
}

// MARK: - Riduzione dell'eco

/// Con gli altoparlanti il microfono sente anche la call, e nel transcript alcune frasi degli altri finiscono
/// attribuite a te o compaiono due volte. Avendo la call registrata a parte, dove il microfono sente solo
/// l'eco della call lo silenziamo. Quanta eco arriva al microfono si stima dal meeting stesso: con le cuffie
/// non c'è eco e non cambia niente.
// ponytail: è un "gate" sull'energia, non una vera cancellazione dell'eco: se parli sopra gli altri resta tutto
// (anche l'eco). Upgrade: filtro adattivo NLMS con recording.wav come riferimento.
enum EchoGate {
    static func clean(mic: [Float], sys: [Float]) -> (out: [Float], removed: Double) {
        let hop = 160 // 10 ms a 16 kHz
        let n = mic.count / hop
        guard n > 500, !sys.isEmpty else { return (mic, 0) }
        func envelope(_ x: [Float]) -> [Float] {
            (0..<n).map { i in
                let a = i * hop
                return a < x.count ? x[a..<min(a + hop, x.count)].reduce(0) { $0 + abs($1) } / Float(hop) : 0
            }
        }
        let m = envelope(mic), raw = envelope(sys)
        // l'audio della call arriva al microfono in ritardo (casse → aria → mic): massimo su ±150 ms
        let w = 15
        let s = (0..<n).map { i in raw[max(0, i - w)...min(n - 1, i + w)].max() ?? 0 }

        // eco tipica = mediana del rapporto mic/call quando la call è forte (di solito parlano solo gli altri)
        let loud = max(s.sorted()[n * 4 / 5], 1e-4)
        let ratios = (0..<n).filter { s[$0] >= loud }.map { m[$0] / s[$0] }.sorted()
        guard ratios.count > 100 else { return (mic, 0) }
        let echo = ratios[ratios.count / 2]
        guard echo > 0.05 else { return (mic, 0) } // cuffie: il microfono non sente la call

        var out = mic
        var keepUntil = -1, removed = 0, considered = 0
        for i in 0..<n {
            // la tua voce: molto più forte di quanto l'eco da sola spiegherebbe (200 ms di coda per non mangiare le parole)
            if m[i] > 2.5 * echo * s[i] + 1e-4 { keepUntil = i + 20 }
            if s[i] >= loud { considered += 1 }
            if i > keepUntil {
                for j in i * hop..<(i + 1) * hop { out[j] = 0 }
                removed += 1
            }
        }
        return (out, considered > 0 ? Double(removed) / Double(n) : 0)
    }
}

// MARK: - Export note (Obsidian, Logseq, Notion…)

/// Copia transcript.md in una cartella di note scelta dall'utente (es. un vault Obsidian), con frontmatter.
enum NotesExport {
    static var folder: URL? {
        UserDefaults.standard.string(forKey: "notes.folder").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
    static var auto: Bool { UserDefaults.standard.object(forKey: "notes.auto") as? Bool ?? true }

    static func exportIfEnabled(_ dir: URL) {
        guard auto, folder != nil else { return }
        _ = try? export(dir)
    }

    /// Scrive (o sovrascrive) la nota del meeting e ne ritorna il percorso
    @discardableResult
    static func export(_ dir: URL) throws -> URL {
        guard let folder else { throw TranscriptionError.message(String(localized: "Scegli la cartella delle note nelle Impostazioni")) }
        let m = Meeting.at(dir)
        let md = try String(contentsOf: dir.appendingPathComponent("transcript.md"), encoding: .utf8)
        let lines = TranscriptLine.parse(md)
        let people = Array(Set(lines.map(\.speaker).filter { !$0.isEmpty })).sorted()
        let date = m.date ?? Date()
        let seconds = (try? AVAudioFile(forReading: dir.appendingPathComponent("recording.wav"))).map { Double($0.length) / $0.fileFormat.sampleRate }
        let label = Prefs.label(m.source)

        func yaml(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var note = "---\n"
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm" // ora locale, come Obsidian se l'aspetta
        note += "date: \(f.string(from: date))\n"
        note += "source: \(m.source)\n"
        if !label.isEmpty { note += "label: \(yaml(label))\n" }
        note += "participants: [\(people.map(yaml).joined(separator: ", "))]\n"
        if let seconds { note += "duration: \(duration(seconds))\n" }
        note += "tags: [meeting\(label.isEmpty ? "" : ", " + yaml(label.lowercased().replacingOccurrences(of: " ", with: "-")))]\n"
        note += "---\n\n"
        note += "# \(m.app) — \(date.formatted(date: .long, time: .shortened))\n\n"
        if !people.isEmpty { note += String(localized: "**Partecipanti:** \(people.joined(separator: ", "))") + "\n\n" }
        if let summary = try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8) {
            note += summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        note += "## Transcript\n\n"
        note += lines.map { $0.speaker.isEmpty ? $0.text : "**[\($0.time)] \($0.speaker):** \($0.text)" }.joined(separator: "\n\n") + "\n"

        f.dateFormat = "yyyy-MM-dd HH.mm"
        let name = "\(f.string(from: date)) \(m.app)"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent(name + ".md")
        try note.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
