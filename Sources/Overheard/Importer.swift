// Import di file audio/video e link (YouTube, podcast… via yt-dlp se installato) come meeting:
// ~/Meetings/<data>/recording.wav + source "import" + title, poi la stessa trascrizione dei meeting registrati.
// Il marker .notified dice agli strumenti esterni che leggono ~/Meetings che non c'è niente da notificare.
import AVFoundation
import SwiftUI

extension Notification.Name {
    /// Un meeting è stato creato o trascritto (object: nome della cartella)
    static let meetingsChanged = Notification.Name("meetingsChanged")
}

@MainActor
final class Importer: ObservableObject {
    static let shared = Importer()
    @Published var status: String? // "Scarico…", "Converto…", "Trascrivo…"; nil = fermo

    static let types: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .mp3, .wav, .aiff]

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.types
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        Task { for url in panel.urls { await importFile(url) } }
    }

    func importFile(_ url: URL, title: String? = nil) async {
        let name = title ?? url.deletingPathExtension().lastPathComponent
        status = String(localized: "Converto «\(name)»…")
        let dir: URL
        do {
            dir = try await Task.detached { try Self.makeMeeting(from: url, title: name) }.value
        } catch {
            fail(String(localized: "Import non riuscito: \(error.localizedDescription)"))
            return
        }
        NotificationCenter.default.post(name: .meetingsChanged, object: dir.lastPathComponent)
        status = String(localized: "Trascrivo «\(name)»…")
        let engine = Recorder.shared.engine
        let result = await Task.detached { await Transcriber.run(dir: dir, engine: engine) }.value
        status = nil
        NotificationCenter.default.post(name: .meetingsChanged, object: dir.lastPathComponent)
        switch result {
        case .success: notify(String(localized: "Transcript pronto"), name)
        case let .failure(e): notify(String(localized: "Trascrizione non riuscita"), e.localizedDescription)
        }
    }

    func importLink(_ link: String) {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: link)?.scheme?.hasPrefix("http") == true else { return fail(String(localized: "Link non valido")) }
        status = String(localized: "Scarico l'audio…")
        Task {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mr-import-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let r = await Task.detached { () -> (Int32, String) in
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                // formati che AVFoundation sa leggere (m4a/mp4/mp3), niente playlist
                let cmd = "command -v yt-dlp >/dev/null || exit 127; cd \(Self.quote(tmp.path)) && yt-dlp --no-playlist -q --no-warnings "
                    + "-f 'bestaudio[ext=m4a]/bestaudio[ext=mp3]/best[ext=mp4]' -o '%(title).150B.%(ext)s' "
                    + "--print after_move:filepath --no-simulate \(Self.quote(link))"
                return AIChat.shell(cmd)
            }.value
            let path = r.1.split(separator: "\n").last.map(String.init) ?? ""
            guard r.0 == 0, FileManager.default.fileExists(atPath: path) else {
                return fail(r.0 == 127 ? String(localized: "Per i link serve yt-dlp: nel Terminale «brew install yt-dlp»") : String(localized: "Download non riuscito (link non supportato?)"))
            }
            let file = URL(fileURLWithPath: path)
            await importFile(file, title: file.deletingPathExtension().lastPathComponent)
        }
    }

    private func fail(_ message: String) {
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.status == message { self?.status = nil }
        }
    }

    nonisolated static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Nuova cartella meeting con recording.wav (mono 48 kHz, letto con AVFoundation anche dai video)
    nonisolated static func makeMeeting(from src: URL, title: String) throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        var date = Date(), dir: URL
        repeat { // due import nello stesso secondo
            dir = URL(fileURLWithPath: "\(home)/Meetings/\(f.string(from: date))")
            date += 1
        } while FileManager.default.fileExists(atPath: dir.path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try convert(src, to: dir.appendingPathComponent("recording.wav"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        try "import\n".write(to: dir.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        try (title + "\n").write(to: dir.appendingPathComponent("title"), atomically: true, encoding: .utf8)
        try "import\n".write(to: dir.appendingPathComponent(".notified"), atomically: true, encoding: .utf8)
        return dir
    }

    nonisolated static func convert(_ src: URL, to out: URL) throws {
        let asset = AVURLAsset(url: src)
        let sem = DispatchSemaphore(value: 0)
        var track: AVAssetTrack?
        Task { track = try? await asset.loadTracks(withMediaType: .audio).first; sem.signal() }
        sem.wait()
        guard let track else { throw TranscriptionError.message(String(localized: "Nessuna traccia audio nel file")) }
        let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                  AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                  AVLinearPCMIsNonInterleaved: false]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: out, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? TranscriptionError.message(String(localized: "Formato non supportato"))
        }
        writer.startSession(atSourceTime: .zero)
        while let buf = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard input.append(buf) else { throw writer.error ?? TranscriptionError.message(String(localized: "Scrittura audio fallita")) }
        }
        if reader.status == .failed { throw reader.error ?? TranscriptionError.message(String(localized: "Lettura audio fallita")) }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? TranscriptionError.message(String(localized: "Scrittura audio fallita")) }
    }
}
