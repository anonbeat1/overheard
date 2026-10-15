// Registrazione nativa, senza ownscribe/ffmpeg:
// - audio di sistema (gli altri partecipanti): Core Audio process tap (macOS 14.2+) → recording.wav
// - tua voce: AVCaptureSession sul microfono scelto (di default quello integrato) → mic.wav
// Entrambe le catture si ricostruiscono da sole se qualcosa cambia (uscita, sample rate, dispositivo, stalli)
// e riempiono i buchi con silenzio: i file durano sempre quanto la registrazione e restano allineati.
// Durante la registrazione i file si chiamano *.tmp.wav: chi legge ~/Meetings sa che non sono ancora finiti.
import AVFoundation
import CoreAudio

enum CaptureError: LocalizedError {
    case status(String, OSStatus)
    var errorDescription: String? {
        if case let .status(what, s) = self { return String(localized: "\(what) fallito (OSStatus \(s))") }
        return nil
    }
}

private func check(_ what: String, _ s: OSStatus) throws {
    if s != noErr { throw CaptureError.status(what, s) }
}

/// WAV a formato fisso: converte qualsiasi formato in ingresso e riempie con silenzio quando l'audio manca.
/// Va usato sempre dalla stessa coda seriale.
final class PaddedWriter {
    let format: AVAudioFormat // formato di lavoro (float32), il file è PCM 16 bit
    private var file: AVAudioFile?
    private let started = Date()
    private var framesWritten: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private let log: (String) -> Void

    init(url: URL, label: String, sampleRate: Double, channels: AVAudioChannelCount, log: @escaping (String) -> Void) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.log = { log("\(label): \($0)") }
    }

    func write(_ buf: AVAudioPCMBuffer) {
        guard let file, buf.frameLength > 0 else { return }
        if converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: format)
            log("formato in ingresso: \(Int(buf.format.sampleRate)) Hz, \(buf.format.channelCount) canali")
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard out.frameLength > 0, (try? file.write(from: out)) != nil else { return }
        framesWritten += AVAudioFramePosition(out.frameLength)
    }

    /// Se il file è indietro di più di 0,5s rispetto al tempo reale, aggiunge silenzio.
    func padToNow() {
        guard let file else { return }
        let expected = AVAudioFramePosition(Date().timeIntervalSince(started) * format.sampleRate)
        var missing = expected - framesWritten
        guard missing > AVAudioFramePosition(format.sampleRate / 2) else { return }
        log(String(format: "aggiunti %.1fs di silenzio", Double(missing) / format.sampleRate))
        converter?.reset() // dopo un buco il converter non deve "ricordare" l'audio precedente
        while missing > 0 {
            let n = AVAudioFrameCount(min(missing, AVAudioFramePosition(format.sampleRate)))
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            silence.frameLength = n // buffer nuovo = zeri
            guard (try? file.write(from: silence)) != nil else { return }
            framesWritten += AVAudioFramePosition(n)
            missing -= AVAudioFramePosition(n)
        }
    }

    func close() {
        padToNow()
        file = nil
    }
}

/// Timer ogni secondo su una coda: controlla la salute della cattura.
private func watchdog(on queue: DispatchQueue, _ tick: @escaping () -> Void) -> DispatchSourceTimer {
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1, repeating: 1)
    t.setEventHandler(handler: tick)
    t.resume()
    return t
}

// MARK: - Audio di sistema

/// Process tap globale + aggregate device privato. Si ricostruisce se cambia l'uscita, il sample rate
/// (le call spesso passano a 24 kHz) o se non arriva audio per 2s.
final class SystemAudioCapture {
    private let queue = DispatchQueue(label: "system-audio")
    // IOProc su una coda sua: se girasse su `queue`, AudioDeviceStop (chiamato da `queue`) aspetterebbe
    // la callback in corso che a sua volta aspetta `queue` → deadlock, app bloccata su "Salvataggio…"
    private let ioQueue = DispatchQueue(label: "system-audio-io")
    private var writer: PaddedWriter? // usato solo da ioQueue
    private var log: (String) -> Void = { _ in }
    private var lastCallback = Date()
    private var timer: DispatchSourceTimer?

    // stato della cattura corrente (ricostruita a ogni cambio)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var inFormat: AVAudioFormat?
    private var outputUID = ""
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var pending: DispatchWorkItem?
    private var lastRebuild = Date.distantPast

    func start(to url: URL, log: @escaping (String) -> Void) throws {
        // 48 kHz stereo 16 bit (~690 MB/h)
        writer = try PaddedWriter(url: url, label: "audio di sistema", sampleRate: 48000, channels: 2, log: log)
        self.log = log
        try queue.sync {
            lastCallback = Date()
            try build()
        }
        timer = watchdog(on: queue) { [weak self] in self?.watchdogTick() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            pending?.cancel()
            pending = nil
            teardown()
            ioQueue.sync { writer?.close(); writer = nil }
        }
    }

    // MARK: tutto quello che segue gira su `queue`

    private func build() throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check("Creazione tap", AudioHardwareCreateProcessTap(desc, &tapID))

        // L'aggregate device prende il clock dall'uscita audio di default
        outputUID = try currentOutputUID()
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Overheard-Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        try check("Creazione aggregate device", AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggregateID))

        var asbd = AudioStreamBasicDescription()
        try getProp(tapID, kAudioTapPropertyFormat, &asbd)
        // Il tap dichiara sempre il suo rate (es. 48 kHz) ma i dati arrivano al rate reale del dispositivo
        // (24 kHz con le AirPods in call): senza questo l'audio risultava accelerato e lungo la metà.
        var deviceRate = Float64(0)
        try getProp(aggregateID, kAudioDevicePropertyNominalSampleRate, &deviceRate)
        if deviceRate > 0 { asbd.mSampleRate = deviceRate }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureError.status("Formato tap", -1) }
        inFormat = format

        try check("IOProc", AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.lastCallback = Date()
            if let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) { self.writer?.write(buf) }
        })
        try check("Avvio", AudioDeviceStart(aggregateID, procID))

        // Ricostruisci subito se cambia il formato del tap, il sample rate o l'uscita di default
        listen(tapID, kAudioTapPropertyFormat)
        listen(aggregateID, kAudioDevicePropertyNominalSampleRate)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, onlyIfOutputChanged: true)
        listen(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, onlyIfOutputChanged: true)
        log("audio di sistema: cattura avviata, uscita \(outputUID)")
    }

    private func teardown() {
        for (obj, addr, block) in listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
        }
        listeners = []
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
        inFormat = nil
    }

    /// Le cuffie Bluetooth, quando una call accende il loro mic, cambiano profilo e l'uscita di default
    /// rimbalza tra loro e gli altoparlanti per un attimo. Ricostruire a ogni notifica riapriva le cuffie
    /// nell'aggregate e provocava un altro cambio: un loop da decine di ricostruzioni al secondo che lasciava
    /// la call senza audio né microfono. Quindi si aspetta che la configurazione resti ferma per 1,5s.
    /// `onlyIfOutputChanged`: notifiche sull'uscita di default, inutili se alla fine l'uscita è la stessa e l'audio arriva
    private func scheduleRebuild(_ why: String, onlyIfOutputChanged: Bool = false) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            if onlyIfOutputChanged, self.aggregateID != kAudioObjectUnknown, Date().timeIntervalSince(self.lastCallback) < 1,
               (try? self.currentOutputUID()) == self.outputUID { return }
            self.rebuild(why)
        }
        pending = w
        queue.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func rebuild(_ why: String) {
        guard writer != nil else { return }
        lastRebuild = Date()
        log("audio di sistema: ricostruzione (\(why))")
        teardown()
        ioQueue.sync { writer?.padToNow() }
        do { try build() } catch { log("audio di sistema: ricostruzione fallita, riprovo tra 1s (\(error.localizedDescription))") }
        lastCallback = Date()
    }

    private func listen(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, onlyIfOutputChanged: Bool = false) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRebuild("proprietà \(sel) cambiata", onlyIfOutputChanged: onlyIfOutputChanged) }
        if AudioObjectAddPropertyListenerBlock(obj, &addr, queue, block) == noErr { listeners.append((obj, addr, block)) }
    }

    private func watchdogTick() {
        defer { ioQueue.sync { writer?.padToNow() } }
        // mentre i dispositivi si stanno assestando non si tocca niente (vedi scheduleRebuild)
        guard pending == nil, Date().timeIntervalSince(lastRebuild) > 2 else { return }
        if aggregateID == kAudioObjectUnknown {
            rebuild("cattura non attiva")
        } else if Date().timeIntervalSince(lastCallback) > 2 {
            rebuild("nessun audio da 2s")
        } else if let uid = try? currentOutputUID(), uid != outputUID {
            scheduleRebuild("uscita audio cambiata: \(uid)")
        }
    }

    private func currentOutputUID() throws -> String {
        var outID = AudioObjectID(kAudioObjectUnknown)
        try getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &outID)
        var uid: CFString = "" as CFString
        try getProp(outID, kAudioDevicePropertyDeviceUID, &uid)
        return uid as String
    }

    private func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) throws {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check("Lettura proprietà \(sel)", AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value))
    }
}

// MARK: - Microfono

/// AVCaptureSession → campioni → PaddedWriter (16 kHz mono). Si adatta a qualsiasi formato del mic
/// (anche voice-processing a 24 kHz) e riparte se la sessione si ferma, va in errore, non arrivano
/// campioni per 2s o il mic preferito torna disponibile dopo essere sparito.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "mic")
    private var writer: PaddedWriter?
    private var log: (String) -> Void = { _ in }
    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private var preferredName = ""
    private var lastSample = Date()
    private var timer: DispatchSourceTimer?
    private var errorObserver: NSObjectProtocol?

    static func deviceNames() -> [String] { devices().map(\.localizedName) }

    static var builtInName: String? {
        devices().first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }?.localizedName
    }

    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
    }

    func start(to url: URL, deviceName: String, log: @escaping (String) -> Void) throws {
        writer = try PaddedWriter(url: url, label: "microfono", sampleRate: 16000, channels: 1, log: log)
        self.log = log
        preferredName = deviceName
        queue.sync { build() }
        timer = watchdog(on: queue) { [weak self] in self?.watchdogTick() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            teardown()
            writer?.close()
            writer = nil
        }
    }

    // MARK: tutto quello che segue gira su `queue`

    private func build() {
        lastSample = Date()
        guard let dev = Self.devices().first(where: { $0.localizedName == preferredName }) ?? AVCaptureDevice.default(for: .audio) else {
            log("microfono: nessun dispositivo disponibile, riprovo tra 1s")
            return
        }
        do {
            let s = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: dev)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: queue)
            guard s.canAddInput(input), s.canAddOutput(output) else { throw CaptureError.status("Sessione mic", -1) }
            s.addInput(input)
            s.addOutput(output)
            errorObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: s, queue: nil) { [weak self] n in
                let err = (n.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "?"
                self?.queue.async { self?.rebuild("errore sessione: \(err)") }
            }
            s.startRunning()
            session = s
            device = dev
            log("microfono: cattura avviata (\(dev.localizedName))")
        } catch {
            log("microfono: avvio fallito, riprovo tra 1s (\(error.localizedDescription))")
        }
    }

    private func teardown() {
        if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) }
        errorObserver = nil
        session?.stopRunning()
        session = nil
        device = nil
    }

    private func rebuild(_ why: String) {
        guard writer != nil else { return }
        log("microfono: ricostruzione (\(why))")
        teardown()
        writer?.padToNow()
        build()
    }

    private func watchdogTick() {
        if session == nil || session?.isRunning == false {
            rebuild("sessione non attiva")
        } else if Date().timeIntervalSince(lastSample) > 2 {
            rebuild("nessun campione da 2s")
        } else if device?.isConnected == false {
            rebuild("dispositivo scollegato")
        } else if device?.localizedName != preferredName, Self.devices().contains(where: { $0.localizedName == preferredName }) {
            rebuild("\(preferredName) di nuovo disponibile")
        }
        writer?.padToNow()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lastSample = Date()
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList) == noErr else { return }
        writer?.write(buf)
    }
}

// MARK: - Registrazione

/// Una registrazione: cartella ~/Meetings/<data_ora>/ con recording.wav, mic.wav, source, capture.log.
final class MeetingCapture {
    let dir: URL
    let started = Date()
    private let system = SystemAudioCapture()
    private let mic = MicCapture()
    private(set) var micOK = true

    /// Microfono scelto nelle Impostazioni, altrimenti quello integrato: le cuffie Bluetooth come mic degradano l'audio (HFP)
    static var micDevice: String {
        let saved = UserDefaults.standard.string(forKey: "micDevice") ?? ""
        return saved.isEmpty ? MicCapture.builtInName ?? "" : saved
    }

    init(source: String) throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        dir = URL(fileURLWithPath: "\(home)/Meetings/\(f.string(from: started))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try setSource(source)
        do {
            try system.start(to: dir.appendingPathComponent("recording.tmp.wav"), log: log)
        } catch {
            system.stop()
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        micOK = AVCaptureDevice.authorizationStatus(for: .audio) != .denied
        do { try mic.start(to: dir.appendingPathComponent("mic.tmp.wav"), deviceName: Self.micDevice, log: log) } catch { micOK = false }
    }

    /// Eventi della cattura (ricostruzioni, silenzio aggiunto) in capture.log, per capire cosa è successo
    private func log(_ msg: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(msg)\n"
        let url = dir.appendingPathComponent("capture.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    var source: String {
        (try? String(contentsOf: dir.appendingPathComponent("source"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "altro"
    }

    func setSource(_ s: String) throws {
        try (s + "\n").write(to: dir.appendingPathComponent("source"), atomically: true, encoding: .utf8)
    }

    /// Chiude i file e li rinomina (prima il mic, poi recording.wav che segnala la registrazione finita).
    func stop(_ done: @escaping () -> Void) {
        DispatchQueue.global().async { [self] in
            system.stop()
            mic.stop()
            let fm = FileManager.default
            let micTmp = dir.appendingPathComponent("mic.tmp.wav"), micOut = dir.appendingPathComponent("mic.wav")
            if (try? MicLevel.normalize(micTmp, to: micOut)) != nil { try? fm.removeItem(at: micTmp) }
            else { try? fm.moveItem(at: micTmp, to: micOut) }
            try? fm.moveItem(at: dir.appendingPathComponent("recording.tmp.wav"), to: dir.appendingPathComponent("recording.wav"))
            DispatchQueue.main.async(execute: done)
        }
    }
}

/// Registrazioni rimaste a metà (app chiusa o crash durante la call): file .tmp.wav senza recording.wav
enum Recovery {
    static func orphans(skipping current: URL?) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "\(home)/Meetings"), includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { d in
            d != current && fm.fileExists(atPath: d.appendingPathComponent("recording.tmp.wav").path)
                && !fm.fileExists(atPath: d.appendingPathComponent("recording.wav").path)
        }
    }

    /// Audio chiuso ma mai trascritto (app uscita subito dopo lo stop), solo ultimi 2 giorni
    static func untranscribed(skipping current: URL?) -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "\(home)/Meetings"), includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { d in
            func has(_ f: String) -> Bool { fm.fileExists(atPath: d.appendingPathComponent(f).path) }
            let date = Meeting.at(d).date ?? .distantPast
            return d != current && has("recording.wav") && !has("transcript.md") && !has("transcript.error")
                && Date().timeIntervalSince(date) < 2 * 86400
        }
    }

    /// Ripara le intestazioni e rinomina come farebbe lo stop; false se non c'è audio utile
    static func finalize(_ dir: URL) -> Bool {
        let fm = FileManager.default
        let rec = dir.appendingPathComponent("recording.tmp.wav"), mic = dir.appendingPathComponent("mic.tmp.wav")
        for f in [rec, mic] where fm.fileExists(atPath: f.path) { repairWAV(f) }
        guard (try? AVAudioFile(forReading: rec))?.length ?? 0 > 0 else { return false }
        let micOut = dir.appendingPathComponent("mic.wav")
        if fm.fileExists(atPath: mic.path) {
            if (try? MicLevel.normalize(mic, to: micOut)) != nil { try? fm.removeItem(at: mic) } else { try? fm.moveItem(at: mic, to: micOut) }
        }
        return (try? fm.moveItem(at: rec, to: dir.appendingPathComponent("recording.wav"))) != nil
    }

    /// Dopo un crash le dimensioni nell'header WAV (RIFF e chunk "data") restano quelle iniziali: le ricalcola dalla lunghezza del file
    static func repairWAV(_ url: URL) {
        guard let h = try? FileHandle(forUpdating: url), let head = try? h.read(upToCount: 1 << 16), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func put(_ v: UInt64, at o: UInt64) {
            var le = UInt32(clamping: v).littleEndian
            try? h.seek(toOffset: o)
            h.write(Data(bytes: &le, count: 4))
        }
        var o = 12
        while o + 8 <= head.count {
            if head[o..<o + 4] == Data("data".utf8) {
                put(size - UInt64(o + 8), at: UInt64(o + 4))
                put(size - 8, at: 4)
                return
            }
            o += 8 + Int(u32(o + 4)) + Int(u32(o + 4) & 1)
        }
    }
}

/// Il mic del Mac arriva crudo (~-34 dBFS sul parlato) mentre la call è già normalizzata (~-17):
/// a fine registrazione alza il mic verso -18 dBFS sul parlato, con un limiter morbido sui picchi.
enum MicLevel {
    static func normalize(_ src: URL, to dst: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat // float32 non interleaved
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        // 1° passaggio: RMS ogni 100 ms, livello del parlato = media del 10% più forte
        let win = Int(format.sampleRate / 10)
        var rms: [Float] = [], acc: Float = 0, n = 0
        while input.framePosition < input.length {
            try input.read(into: buf, frameCount: chunk)
            for x in UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)) {
                acc += x * x; n += 1
                if n == win { rms.append((acc / Float(win)).squareRoot()); acc = 0; n = 0 }
            }
        }
        let top = rms.sorted().suffix(max(1, rms.count / 10))
        let speech = top.reduce(0, +) / Float(top.count)
        let gain = min(max(0.126 / max(speech, 1e-5), 1), 12) // -18 dBFS, al massimo +21 dB, mai abbassare
        // 2° passaggio: guadagno + limiter (sopra 0.7 comprime con tanh, non supera mai 1)
        let output = try AVAudioFile(forWriting: dst, settings: input.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        input.framePosition = 0
        while input.framePosition < input.length {
            try input.read(into: buf, frameCount: chunk)
            let p = buf.floatChannelData![0]
            for i in 0..<Int(buf.frameLength) {
                let y = p[i] * gain, a = abs(y)
                p[i] = a <= 0.7 ? y : (y < 0 ? -1 : 1) * (0.7 + 0.3 * tanh((a - 0.7) / 0.3))
            }
            try output.write(from: buf)
        }
    }
}
