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
    static func run(skipping active: URL?, root customRoot: URL? = nil, days customDays: Int? = nil, mode customMode: String? = nil,
                    cloudEnabled: Bool? = nil,
                    trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Int {
        let days = customDays ?? Self.days, mode = customMode ?? Self.mode
        let cloud = cloudEnabled ?? UserDefaults.standard.bool(forKey: "cloud.enabled")
        // With cloud sync on, freeing audio belongs to the verified cloud cleanup: the legacy "audio only" mode must
        // not bypass it. "Delete everything" deletes the meeting, so its cloud copies go to the service's trash too.
        guard days > 0, !(cloud && mode != "all") else { return 0 }
        let fm = FileManager.default
        let root = customRoot ?? URL(fileURLWithPath: "\(home)/Meetings")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let f = DateFormatter()
        var cleaned = 0
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let name = dir.lastPathComponent
            guard name.hasPrefix("20"), name != active?.lastPathComponent else { continue }
            f.dateFormat = name.count > 15 ? "yyyy-MM-dd_HHmmss" : "yyyy-MM-dd_HHmm"
            // The date test is free; folder checks run only for meetings old enough to clean.
            guard let date = f.date(from: name), date < cutoff,
                  !fm.fileExists(atPath: dir.appendingPathComponent(".transcribing").path),
                  cloud || !fm.fileExists(atPath: dir.appendingPathComponent(CloudManifest.filename).path),
                  CloudFiles.eligible(dir), SyncConflicts.scan(dir).isEmpty,
                  SyncConflicts.originalName(name) == nil else { continue }
            if mode == "all" {
                // The folder (and its manifest) is gone once trashed: queue the cloud copies first, undo if it fails.
                let manifest = cloud ? CloudSync.manifest(dir) : nil
                if let manifest { _ = try? CloudTrashQueue.shared.enqueue(manifest: manifest, folder: name) }
                if (try? trash(dir)) != nil { cleaned += 1 }
                else if let manifest { CloudTrashQueue.shared.cancel(manifest: manifest) }
            } else {
                let wavs = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "wav" }
                for w in wavs { try? fm.trashItem(at: w, resultingItemURL: nil) }
                if !wavs.isEmpty { cleaned += 1 }
            }
        }
        return cleaned
    }
}
