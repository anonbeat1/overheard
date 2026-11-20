import Foundation

/// "Export to ZIP": every meeting in one file, including audio that only exists in the cloud.
/// Local files are hard-linked into a staging folder (no extra space on the same disk); cloud-only
/// audio is downloaded there as its cloud copy (.m4a when compressed) and verified; macOS's `ditto`
/// then writes the archive. Nothing in ~/Meetings is changed.
enum CloudExport {
    /// Stages one meeting under `folder/<meeting>/`. Returns how many cloud-only files could not be
    /// fetched because their service is not connected (they are skipped, not fatal).
    static func stage(_ dir: URL, into folder: URL, manifest: CloudManifest?,
                      provider: (any CloudStorageProvider)?) async throws -> Int {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, !file.lastPathComponent.hasSuffix(".tmp.wav") else { continue }
            let copy = target.appendingPathComponent(file.lastPathComponent)
            do { try fm.linkItem(at: file, to: copy) } catch { try fm.copyItem(at: file, to: copy) }
        }
        var skipped = 0
        for name in CloudFiles.content {
            guard let remote = manifest?.files[name], !CloudFiles.exists(dir.appendingPathComponent(name)) else { continue }
            guard let provider else { skipped += 1; continue }
            let destination = target.appendingPathComponent(CloudSyncEngine.remoteName(name, encoded: remote.encoding != nil))
            try await provider.download(remote.id, to: destination)
            guard CloudVerification.matches(local: try provider.fingerprint(destination), remote: remote.version) else {
                try? fm.removeItem(at: destination)
                throw CloudError.message(String(localized: "Audio scaricato non valido. Riprova."))
            }
        }
        return skipped
    }

    /// Bytes the export needs on the Mac: the archive is about as large as what goes into it.
    static func estimatedBytes(_ dirs: [URL]) -> Int64 {
        dirs.reduce(Int64(0)) { total, dir in
            let local = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                .reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            let cloud = CloudFiles.content.reduce(Int64(0)) { sum, name in
                guard let remote = CloudSync.manifest(dir)?.files[name], !CloudFiles.exists(dir.appendingPathComponent(name)) else { return sum }
                return sum + 2 * remote.version.byteCount // downloaded copy + its place in the archive
            }
            return total + local + cloud
        }
    }

    /// Zips `folder` (kept as the top-level folder inside the archive) with macOS's ditto.
    static func zip(_ folder: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: destination)
            throw CloudError.message(String(localized: "Creazione dello ZIP non riuscita."))
        }
    }
}
