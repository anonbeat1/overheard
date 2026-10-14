// meeting-transcriber <cartella-meeting> [--me NOME] [--mic FILE]
// meeting-transcriber --prepare   scarica i modelli (~2,5 GB) e stampa "PROGRESS <0-100> <fase>" su stdout
//
// Transcript locale (niente cloud) di una registrazione di Overheard:
//   recording.wav (audio della call) → diarizzazione Community-1 → "Parlante 1", "Parlante 2", …
//   mic.wav (la tua voce)            → VAD pyannote              → NOME (default "Io")
// Ogni intervento viene trascritto con Cohere Transcribe (int8, italiano), modello caricato una volta.
// Stampa il markdown su stdout; avanzamento su stderr.
import AudioCommon
import CohereTranscribeASR
import Foundation
import SpeechVAD

struct Turn {
    var start: Float
    var end: Float
    let speaker: String
    var text = ""
}

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Il modello ha bisogno di contesto: spezzoni troppo brevi danno frasi senza senso.
let maxTurn: Float = 30 // lunghezza massima di un intervento trascritto in un colpo
let mergeGap: Float = 2.0 // pause più corte = stesso intervento
let minPiece: Float = 1.5 // frammenti più corti vengono assorbiti dall'intervento precedente
let pad: Float = 0.3
let hallucinations: Set<String> = ["grazie", "grazie a tutti", "grazie mille", "grazie per la visione", "sottotitoli a cura di qtss", "ciao"]

/// Segmenti di una traccia → interventi: i frammenti brevi passano al parlante precedente (la diarizzazione
/// li sbaglia spesso), poi si uniscono i segmenti vicini dello stesso parlante, max `maxTurn` secondi.
func turns(_ segs: [(Float, Float, String)]) -> [Turn] {
    var sorted = segs.sorted { $0.0 < $1.0 }
    for i in sorted.indices.dropFirst() where sorted[i].1 - sorted[i].0 < minPiece && sorted[i].0 - sorted[i - 1].1 < mergeGap {
        sorted[i].2 = sorted[i - 1].2
    }
    var out: [Turn] = []
    for (s, e, who) in sorted {
        if var last = out.last, last.speaker == who, s - last.end < mergeGap, e - last.start <= maxTurn {
            last.end = max(last.end, e)
            out[out.count - 1] = last
        } else {
            out.append(Turn(start: s, end: e, speaker: who))
        }
    }
    return out.flatMap { t -> [Turn] in
        stride(from: t.start, to: t.end, by: maxTurn).map { Turn(start: $0, end: min($0 + maxTurn, t.end), speaker: t.speaker) }
    }
}

func clip(_ audio: [Float], _ t: Turn) -> [Float] {
    let a = max(0, Int((t.start - pad) * 16000)), b = min(audio.count, Int((t.end + pad) * 16000))
    return a < b ? Array(audio[a..<b]) : []
}

func stamp(_ t: Float) -> String {
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

let args = CommandLine.arguments

/// Avanzamento leggibile dall'app Overheard: le tre fasi pesano in proporzione alla dimensione dei modelli.
func progress(_ base: Double, _ weight: Double, _ label: String) -> (Double, String) -> Void {
    var last = -1
    return { frac, _ in
        let pct = Int((base + weight * min(max(frac, 0), 1)) * 100)
        if pct != last {
            last = pct
            print("PROGRESS \(pct) \(label)")
            fflush(stdout)
        }
    }
}

if args.dropFirst().first == "--prepare" {
    let done = DispatchSemaphore(value: 0)
    var code: Int32 = 0
    Task {
        do {
            _ = try await Community1DiarizationPipeline.fromPretrained(progressHandler: progress(0, 0.05, "riconoscimento voci"))
            _ = try await PyannoteVADModel.fromPretrained(progressHandler: progress(0.05, 0.02, "rilevamento parlato"))
            let cohere = progress(0.07, 0.93, "Cohere Transcribe")
            _ = try await CohereTranscribeModel.load(CohereTranscribeVariant.int8.modelId, progressHandler: { cohere($0, "") })
            print("PROGRESS 100 pronto")
        } catch {
            log("errore: \(error)")
            code = 1
        }
        done.signal()
    }
    done.wait()
    exit(code)
}

guard args.count >= 2 else {
    log("uso: meeting-transcriber <cartella-meeting> [--me NOME] [--speaker PAROLA] [--language CODICE]")
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
let me = option("--me") ?? "Io"
let speakerWord = option("--speaker") ?? "Parlante" // voci della call: "Parlante 1", "Speaker 1"…
let language = option("--language") ?? "it"
let sysURL = dir.appendingPathComponent("recording.wav")
// --mic: microfono già ripulito dall'eco dall'app (default mic.wav della cartella)
let micURL = args.firstIndex(of: "--mic").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    ?? dir.appendingPathComponent("mic.wav")

let done = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    do {
        let t0 = Date()
        let sys = try AudioFileLoader.load(url: sysURL, targetSampleRate: 16000)
        let mic = FileManager.default.fileExists(atPath: micURL.path) ? try AudioFileLoader.load(url: micURL, targetSampleRate: 16000) : []
        log("audio: call \(Int(Float(sys.count) / 16000))s, mic \(Int(Float(mic.count) / 16000))s")

        let diarizer = try await Community1DiarizationPipeline.fromPretrained()
        let others = try diarizer.diarize(audio: sys, sampleRate: 16000, speakerBounds: Community1SpeakerBounds())
        var segs = others.segments.map { ($0.startTime, $0.endTime, "\(speakerWord) \($0.speakerId + 1)") }
        log("diarizzazione: \(others.numSpeakers) parlanti, \(others.segments.count) segmenti")

        if !mic.isEmpty {
            let vad = try await PyannoteVADModel.fromPretrained()
            let speech = vad.detectSpeech(audio: mic, sampleRate: 16000)
            segs += speech.map { ($0.startTime, $0.endTime, me) }
            log("microfono: \(speech.count) segmenti di parlato")
        }
        // ponytail: se usi gli altoparlanti (non le cuffie) il mic sente anche gli altri e alcune frasi
        // possono comparire due volte; servirebbe una cancellazione dell'eco sul mic.

        // turni separati per traccia (mic e call si sovrappongono nel tempo), poi in ordine di tempo
        var all = (turns(segs.filter { $0.2 == me }) + turns(segs.filter { $0.2 != me })).sorted { $0.start < $1.start }

        let asr = try await CohereTranscribeModel.load(CohereTranscribeVariant.int8.modelId)
        for i in all.indices {
            let audio = clip(all[i].speaker == me ? mic : sys, all[i])
            guard all[i].end - all[i].start >= 0.4 else { continue } // spezzoni troppo corti: solo rumore
            let text = asr.transcribe(audio: audio, sampleRate: 16000, language: language).trimmingCharacters(in: .whitespacesAndNewlines)
            // Su spezzoni brevi quasi muti il modello "inventa" formule tipiche dei sottotitoli
            if all[i].end - all[i].start < 2, hallucinations.contains(text.lowercased().trimmingCharacters(in: .punctuationCharacters)) { continue }
            all[i].text = text
        }
        log(String(format: "trascritti %d interventi in %.0fs", all.count, Date().timeIntervalSince(t0)))

        // stampa, unendo interventi consecutivi dello stesso parlante (l'intestazione con i partecipanti la scrive l'app)
        var md = ""
        var current: Turn?
        for t in all where !t.text.isEmpty && t.text.contains(where: \.isLetter) {
            if current?.speaker == t.speaker {
                current!.text += " " + t.text
            } else {
                if let c = current { md += "**[\(stamp(c.start))] \(c.speaker):** \(c.text)\n\n" }
                current = t
            }
        }
        if let c = current { md += "**[\(stamp(c.start))] \(c.speaker):** \(c.text)\n" }
        print(md, terminator: "")
    } catch {
        log("errore: \(error)")
        exitCode = 1
    }
    done.signal()
}
done.wait()
exit(exitCode)
