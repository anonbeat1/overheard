// Apple Intelligence (Foundation Models, macOS 26+): riassunti e domande sul Mac, senza CLI né account.
// Il modello sul dispositivo ha un contesto piccolo (4096 token su macOS 26): i transcript lunghi
// vengono riassunti a pezzi, e alle domande si passano solo i riassunti e le righe che c'entrano.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleAI {
    struct Failure: LocalizedError { let errorDescription: String? }

    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Caratteri che stanno nel contesto lasciando spazio a istruzioni e risposta (~3 caratteri per token, prudente)
    static var budget: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return max(3000, (SystemLanguageModel.default.contextSize - 1500) * 3) }
        #endif
        return 3000
    }

    static func complete(_ prompt: String, instructions: String? = nil) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt).content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        throw Failure(errorDescription: String(localized: "Apple Intelligence non è disponibile su questo Mac"))
    }

    /// Transcript più lungo di `limit` → appunti pezzo per pezzo, ripetuto finché ci sta
    static func condense(_ text: String, to limit: Int) async throws -> String {
        var text = text
        while text.count > limit {
            var notes: [String] = []
            for chunk in chunks(text, size: budget) {
                notes.append(try await complete("""
                Notes on this part of a meeting transcript, in \(Prefs.uiLanguageName), as three short lists:
                Discussed: topics, facts, numbers.
                Decided: everything agreed or chosen, even small technical choices.
                To do: "Name: action (deadline)", only for concrete tasks someone takes on or is asked to do. \
                Never list people who are only mentioned.
                Keep people's names and [mm:ss] times. Write "none" for an empty list.

                \(chunk)
                """))
            }
            let joined = notes.joined(separator: "\n")
            guard joined.count < text.count else { return String(joined.prefix(limit)) } // non si accorcia più: taglia
            text = joined
        }
        return text
    }

    /// Righe intere, al massimo `size` caratteri per pezzo
    static func chunks(_ text: String, size: Int) -> [String] {
        var out: [String] = [], cur = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if cur.count + line.count + 1 > size, !cur.isEmpty { out.append(cur); cur = "" }
            cur += String(line.prefix(size)) + "\n"
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }

    /// Contesto per una domanda: il meeting intero se ci sta, altrimenti riassunti e righe con parole della domanda
    /// ponytail: ricerca per parole in comune, non semantica; con embedding se le domande vaghe rispondono male
    static func context(for question: String, meetings: [Meeting], limit: Int) -> String {
        func read(_ m: Meeting, _ file: String) -> String { (try? String(contentsOf: m.url.appendingPathComponent(file), encoding: .utf8)) ?? "" }
        func header(_ m: Meeting) -> String { "### \(m.app), \(m.date?.formatted(date: .abbreviated, time: .shortened) ?? m.id)" }
        if meetings.count == 1, let m = meetings.first {
            let full = header(m) + "\n" + read(m, "summary.md") + "\n" + read(m, "transcript.md")
            if full.count <= limit { return full }
        }
        var out = ""
        for m in meetings { // riassunti, dal più recente, fino a metà dello spazio
            let s = header(m) + "\n" + read(m, "summary.md") + "\n"
            if out.count + s.count > limit / 2 { break }
            out += s
        }
        let words = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.map(String.init))
        let lines = meetings.flatMap { m in
            read(m, "transcript.md").split(separator: "\n").map { line in
                (score: words.filter { line.lowercased().contains($0) }.count, text: "[\(m.app), \(m.when)] \(line)")
            }
        }
        out += "\nTranscript lines related to the question:\n"
        for l in lines.filter({ $0.score > 0 }).sorted(by: { $0.score > $1.score }) {
            if out.count + l.text.count > limit { break }
            out += l.text + "\n"
        }
        return out
    }
}

#if DEBUG
/// Self-check: `AppleAI.demo()` da un test o dal debugger
extension AppleAI {
    static func demo() {
        let c = chunks((1...100).map { "riga \($0)" }.joined(separator: "\n"), size: 50)
        assert(c.allSatisfy { $0.count <= 50 } && c.joined().contains("riga 100"))
    }
}
#endif
