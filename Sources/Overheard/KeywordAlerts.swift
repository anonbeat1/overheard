// Parole chiave dal vivo (opzionale, spento di default): durante la registrazione il riconoscimento vocale di
// Apple, solo sul Mac, ascolta l'audio della call (gli altri, non il microfono). Quando qualcuno dice una delle
// parole scelte arrivano una notifica e un segnalibro. Il testo riconosciuto non viene salvato.
import AVFoundation
import Speech

enum KeywordAlerts {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "keywords.enabled") }
    static var words: [String] {
        (UserDefaults.standard.string(forKey: "keywords.list") ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func requestAccess() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    /// Lingua delle riunioni se scelta, altrimenti quella dell'interfaccia
    static var locale: Locale { Locale(identifier: Prefs.language.isEmpty ? Prefs.uiLanguage : Prefs.language) }
    static var languageSupported: Bool { SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true }

    /// Quante volte compare ogni parola (parola intera, senza badare a maiuscole e accenti)
    static func counts(in text: String, words: [String]) -> [String: Int] {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let hay = fold(text)
        var out: [String: Int] = [:]
        for w in words {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: fold(w)) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            out[w] = re.numberOfMatches(in: hay, range: NSRange(hay.startIndex..., in: hay))
        }
        return out
    }
}

/// Un riconoscimento sull'audio della call. `append` arriva dalla coda dell'audio di sistema.
final class KeywordSpotter {
    private let words: [String]
    private let onHit: (String) -> Void
    private let recognizer: SFSpeechRecognizer
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var started = Date()
    private var seen: [String: Int] = [:]     // occorrenze già viste nel task attuale (i risultati parziali si ripetono)
    private var lastHit: [String: Date] = [:] // al massimo un avviso al minuto per parola
    private var converter: AVAudioConverter?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    /// nil se manca il permesso, non ci sono parole o la lingua non si riconosce sul Mac
    init?(words: [String], onHit: @escaping (String) -> Void) {
        guard !words.isEmpty, KeywordAlerts.authorized, let r = SFSpeechRecognizer(locale: KeywordAlerts.locale),
              r.supportsOnDeviceRecognition else { return nil }
        self.words = words
        self.onHit = onHit
        recognizer = r
        restart()
    }

    /// Un task alla volta, rinnovato ogni ~50 s: i task lunghi rallentano e prima o poi si chiudono da soli
    private func restart() {
        request?.endAudio()
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true // l'audio non lascia il Mac
        req.shouldReportPartialResults = true
        req.contextualStrings = words
        request = req
        seen = [:]
        started = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result { self.check(result.bestTranscription.formattedString) }
            if error != nil || result?.isFinal == true {
                // solo il task attuale si rinnova: quelli annullati da restart() o stop() finiscono qui con un errore
                self.lock.lock(); if self.request === req { self.restart() }; self.lock.unlock()
            }
        }
    }

    private func check(_ text: String) {
        lock.lock()
        var hits: [String] = []
        for (w, n) in KeywordAlerts.counts(in: text, words: words) where n > seen[w, default: 0] {
            seen[w] = n
            if Date().timeIntervalSince(lastHit[w] ?? .distantPast) >= 60 { lastHit[w] = Date(); hits.append(w) }
        }
        lock.unlock()
        hits.forEach(onHit)
    }

    func append(_ buf: AVAudioPCMBuffer) {
        // il formato del tap cambia quando cambia l'uscita (AirPods): convertitore nuovo
        if converter?.inputFormat != buf.format { converter = AVAudioConverter(from: buf.format, to: format) }
        guard let converter, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * 16000 / buf.format.sampleRate) + 16) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard error == nil, out.frameLength > 0 else { return }
        lock.lock()
        if Date().timeIntervalSince(started) > 50 { restart() }
        request?.append(out)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let req = request, t = task
        request = nil
        lock.unlock()
        req?.endAudio()
        t?.cancel()
    }
}
