// Pulizia automatica di ~/Meetings: registrazioni più vecchie di N giorni (impostazione "Conserva i meeting").
// Sposta nel Cestino (recuperabile), mai la registrazione in corso né un meeting in trascrizione.
import Foundation

enum Retention {
    /// 0 = mai
    static var days: Int { UserDefaults.standard.integer(forKey: "retentionDays") }
    /// "audio" = elimina solo i WAV (transcript e riassunti restano), "all" = elimina l'intera cartella
    static var mode: String { UserDefaults.standard.string(forKey: "retentionMode") ?? "audio" }

    /// Ritorna quanti meeting ha pulito.
    @discardableResult
    static func run(skipping active: URL?) -> Int {
        guard days > 0 else { return 0 }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "\(home)/Meetings")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let f = DateFormatter()
        var cleaned = 0
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = dir.lastPathComponent
            guard name.hasPrefix("20"), name != active?.lastPathComponent,
                  !fm.fileExists(atPath: dir.appendingPathComponent(".transcribing").path) else { continue }
            f.dateFormat = name.count > 15 ? "yyyy-MM-dd_HHmmss" : "yyyy-MM-dd_HHmm"
            guard let date = f.date(from: name), date < cutoff else { continue }
            if mode == "all" {
                if (try? fm.trashItem(at: dir, resultingItemURL: nil)) != nil { cleaned += 1 }
            } else {
                let wavs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "wav" }
                for w in wavs { try? fm.trashItem(at: w, resultingItemURL: nil) }
                if !wavs.isEmpty { cleaned += 1 }
            }
        }
        return cleaned
    }
}
