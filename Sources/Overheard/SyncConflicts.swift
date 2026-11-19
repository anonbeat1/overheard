import Foundation

struct SyncConflict: Identifiable, Hashable {
    let url: URL
    let original: URL?
    var id: String { url.path }
}

/// Flags evidence, never merges or deletes on a filename heuristic.
enum SyncConflicts {
    static func originalName(_ name: String) -> String? {
        for pattern in [#"\.sync-conflict-[^.]+"#, #" \([^)]*conflicted copy[^)]*\)"#] {
            if let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return name.replacingCharacters(in: range, with: "")
            }
        }
        return nil
    }

    /// ` 2`, ` 3`… (Finder, Dropbox) and ` (1)`, ` (2)`… (Google Drive, browsers) before the extension.
    /// Ambiguous on its own: callers also require matching content or an explicit meeting timestamp.
    static let numericSuffix = #" (?:[2-9]|[1-9][0-9]+|\([1-9][0-9]*\))(?=\.[^.]+$|$)"#

    static func isManifestCopy(_ name: String) -> Bool {
        name != CloudManifest.filename && (originalName(name) == CloudManifest.filename
            || name.range(of: #"^\.overheard-cloud [0-9]+\.json$"#, options: .regularExpression) != nil)
    }

    static func scan(_ directory: URL) -> [SyncConflict] {
        let fm = FileManager.default
        let siblings = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return siblings.compactMap { file in
            let name = file.lastPathComponent
            if name.hasPrefix(".") {
                // Hidden files are ignored except copies of the cloud manifest: two manifests mean two
                // views of which audio is archived where, and cleanup must wait until one is chosen.
                guard isManifestCopy(name) else { return nil }
                let manifest = directory.appendingPathComponent(CloudManifest.filename)
                return SyncConflict(url: file, original: fm.fileExists(atPath: manifest.path) ? manifest : nil)
            }
            if let original = originalName(file.lastPathComponent) {
                let candidate = directory.appendingPathComponent(original)
                return SyncConflict(url: file, original: fm.fileExists(atPath: candidate.path) ? candidate : nil)
            }
            // A numeric suffix is ambiguous. Require matching content or an explicit start timestamp.
            guard let range = name.range(of: Self.numericSuffix, options: .regularExpression) else { return nil }
            let original = directory.appendingPathComponent(name.replacingCharacters(in: range, with: ""))
            guard fm.fileExists(atPath: original.path), sameMeeting(file, original) else { return nil }
            return SyncConflict(url: file, original: original)
        }
    }

    static func sameMeeting(_ a: URL, _ b: URL) -> Bool {
        let av = try? a.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let bv = try? b.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard av?.isSymbolicLink != true, bv?.isSymbolicLink != true else { return false }
        if av?.isDirectory == true, bv?.isDirectory == true {
            for name in ["recording.wav", "transcript.md"] {
                if sameMeeting(a.appendingPathComponent(name), b.appendingPathComponent(name)) { return true }
            }
            return false
        }
        guard av?.isDirectory == false, bv?.isDirectory == false else { return false }
        if let x = try? CloudFiles.version(a), let y = try? CloudFiles.version(b), x.byteCount > 0, x == y { return true }
        guard a.pathExtension == "md", b.pathExtension == "md" else { return false }
        func timestamp(_ url: URL) -> String? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            let text = String(data: (try? handle.read(upToCount: 2048)) ?? Data(), encoding: .utf8) ?? ""
            // A title or a relative transcript offset is not a meeting identity. Transcripts start with
            // "# Transcript — 2026-11-17_121641" (the folder name); ISO "2026-11-17T12:16:41" is accepted too.
            // Only the digits are compared, so both spellings of the same instant match.
            let pattern = #"20[0-9]{2}-[0-9]{2}-[0-9]{2}[T _](?:[0-9]{2}:[0-9]{2}(?::[0-9]{2})?|[0-9]{4}(?:[0-9]{2})?)(?![0-9])"#
            guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
            return String(text[range].filter(\.isNumber))
        }
        return timestamp(a).map { $0 == timestamp(b) } ?? false
    }

    /// Keeps the copy as a separate item; a folder copy must never reuse remote IDs.
    @discardableResult
    static func keepBoth(_ conflict: SyncConflict) throws -> URL {
        let url = conflict.url
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CloudError.message(String(localized: "File non valido")) }
        var freshManifest: CloudManifest?
        if values.isDirectory == true, let data = try? Data(contentsOf: url.appendingPathComponent(CloudManifest.filename)) {
            let old = try JSONDecoder().decode(CloudManifest.self, from: data)
            for name in CloudFiles.content where old.files[name] != nil {
                guard CloudFiles.exists(url.appendingPathComponent(name)) else { throw CloudError.message(String(localized: "Scarica prima l'audio della copia per conservarla come nuova riunione.")) }
            }
            freshManifest = CloudManifest(destination: old.destination)
        }
        let cleanName = originalName(url.lastPathComponent)
            ?? url.lastPathComponent.replacingOccurrences(of: Self.numericSuffix, with: "", options: .regularExpression)
        let cleanURL = url.deletingLastPathComponent().appendingPathComponent(cleanName)
        let suffix = "-kept-" + UUID().uuidString.prefix(8)
        let name = values.isDirectory == true ? cleanURL.lastPathComponent + suffix : cleanURL.deletingPathExtension().lastPathComponent + suffix + (cleanURL.pathExtension.isEmpty ? "" : "." + cleanURL.pathExtension)
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: destination)
        if let freshManifest {
            try freshManifest.save(destination)
            // The kept folder is a new meeting: drop records that still point at the original's cloud identity.
            let fm = FileManager.default
            try? fm.removeItem(at: destination.appendingPathComponent(".overheard-cloud-destinations"))
            // The map copy names the original meeting: the new one gets its own.
            try? fm.removeItem(at: destination.appendingPathComponent(CloudLedger.mirrorName))
            for file in (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? []
            where isManifestCopy(file.lastPathComponent) { try? fm.removeItem(at: file) }
        }
        return destination
    }

    @discardableResult
    static func useCopy(_ conflict: SyncConflict, trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws -> URL {
        let original = conflict.original ?? conflict.url.deletingLastPathComponent().appendingPathComponent(originalName(conflict.url.lastPathComponent) ?? conflict.url.lastPathComponent)
        guard original.path != conflict.url.path else { throw CloudError.message(String(localized: "Originale non identificato. Conserva entrambe le copie.")) }
        guard CloudFiles.exists(conflict.url), (try? conflict.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw CloudError.message(String(localized: "File non valido")) }
        if CloudFiles.exists(original) { try trash(original) }
        try FileManager.default.moveItem(at: conflict.url, to: original)
        // The person chose this version: its receipt follows, or the meeting would stay "not verified".
        try? CloudProvenance.record(original)
        return original
    }

    static func folderConflicts(in root: URL) -> [SyncConflict] { scan(root) }
}
