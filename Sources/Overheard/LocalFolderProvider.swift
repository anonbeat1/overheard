import Foundation

/// A folder another app keeps in the cloud: iCloud Drive, or the folder synced by an official client
/// such as Aruba Drive, Synology Drive, OneDrive or Google Drive for desktop. Overheard writes into
/// `<folder>/Overheard/<meeting>/` and that app does the upload, under its own terms.
///
/// Freeing space needs proof that the copy left the Mac: macOS reports it for iCloud Drive and for
/// File Provider apps (`ubiquitousItemIsUploaded`). A folder that cannot report it is a backup copy
/// only: Overheard never frees audio on the strength of a plain local copy.
struct LocalFolderProvider: CloudLibraryProvider {
    enum Kind: String, Sendable { case icloud, folder }
    let kind: Kind
    /// The folder the user chose (or iCloud Drive). It must exist; Overheard creates its own subfolder.
    let base: URL
    var trashOnRemove = true
    var root: URL { base.appendingPathComponent("Overheard", isDirectory: true) }
    var id: String { "\(kind.rawValue):\(base.standardizedFileURL.path)" }

    static var iCloudDrive: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    static var iCloudAvailable: Bool { CloudFiles.exists(iCloudDrive) }
    static func iCloud() -> LocalFolderProvider { LocalFolderProvider(kind: .icloud, base: iCloudDrive) }
    /// Folders of cloud apps built on File Provider (OneDrive, Google Drive, Dropbox, Box…), offered as quick picks.
    static var cloudStorageFolders: [URL] {
        let parent = URL(fileURLWithPath: NSHomeDirectory() + "/Library/CloudStorage", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Whether macOS can confirm uploads for this folder (iCloud Drive, File Provider apps).
    static func confirmsUploads(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    private func available() throws {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &directory), directory.boolValue else {
            // Signed out of iCloud, app uninstalled, external disk unplugged: not a reason to re-upload everything.
            throw CloudError.destination(kind == .icloud
                ? String(localized: "iCloud Drive non è disponibile. Controlla di aver effettuato l'accesso a iCloud.")
                : String(localized: "La cartella sincronizzata non è disponibile. Controlla che l'app del servizio sia attiva."))
        }
    }
    private func url(_ id: String) throws -> URL {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard !id.isEmpty, !id.hasPrefix("/"), id.utf8.count < 1024,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw CloudError.message(String(localized: "Percorso remoto non valido"))
        }
        try available()
        let url = root.appendingPathComponent(id)
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw CloudError.message(String(localized: "Percorso remoto non valido"))
        }
        return url
    }

    func libraryMarkerID() async throws -> String? { Self.libraryMarkerName }
    func createLibraryMarker(file: URL) async throws {
        let target = try url(Self.libraryMarkerName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(contentsOf: file).write(to: target, options: .withoutOverwriting)
    }

    /// Library markers the folder's sync client set aside as conflict copies (`…(conflicted copy …).json`, `… 2.json`).
    /// Two Macs connecting to the same empty folder before it synced each wrote a marker: one of them lives on here.
    func markerCopyIDs() -> [UUID] {
        let kept = Self.libraryMarkerName
        let base = (kept as NSString).deletingPathExtension
        return ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 != kept && $0.hasPrefix(base) && $0.hasSuffix(".json") }
            .compactMap { name -> UUID? in
                guard let url = try? url(name), CloudFiles.exists(url),
                      let data = try? Data(contentsOf: url), data.count <= 4096,
                      let marker = try? JSONDecoder().decode(CloudLibraryMarker.self, from: data), marker.schema == 1 else { return nil }
                return marker.id
            }
    }

    func reserve(meeting: CloudMeetingID, name: String) async throws -> String { "\(meeting.rawValue.uuidString)-\(name)" }
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String {
        let id = "\(folder)/\(file)"
        _ = try url(id)
        return id
    }
    /// Reading a file that the sync app has offloaded downloads it first (macOS does this on access).
    func inspect(_ id: String) async throws -> CloudFileVersion? {
        let url = try url(id)
        guard CloudFiles.exists(url) else { return nil }
        try await ensureDownloaded(url)
        return try CloudFiles.version(url)
    }
    /// An iCloud file the system offloaded is downloaded first, with a way out. A plain read would block, offline,
    /// until the network came back, and nothing (not even "Interrompi") could end it while the engine stayed busy.
    private func ensureDownloaded(_ url: URL, timeout: TimeInterval = 180) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if (try? url.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus == .current { return }
        }
        throw CloudError.destination(String(localized: "iCloud non ha ancora scaricato il file: la sincronizzazione riprenderà quando sarà disponibile."))
    }
    /// Size from metadata, without reading (or downloading) the file.
    func size(_ id: String) async throws -> Int64? {
        let url = try url(id)
        guard CloudFiles.exists(url) else { return nil }
        return (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        let target = try url(id)
        let fm = FileManager.default
        if !replacing, CloudFiles.exists(target) { throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate.")) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Half-written copies left by a crash would otherwise be synced by the folder's app.
        // The age is in the name: a copy keeps the source's modification date, so a big recording made hours
        // ago would look "stale" from the first second, and another Mac would delete this one's partial file.
        for stale in (try? fm.contentsOfDirectory(at: target.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where Self.isStaleUpload(stale) {
            try? fm.removeItem(at: stale)
        }
        // Copy beside the target, then swap: the sync app never uploads a half-written file.
        let partial = target.deletingLastPathComponent()
            .appendingPathComponent(".overheard-upload-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }
        let before = replacing ? Self.signature(target) : nil
        try fm.copyItem(at: file, to: partial)
        if CloudFiles.exists(target) {
            // The sync client may have delivered another Mac's version while the copy ran: never swap it away.
            if replacing, Self.signature(target) != before {
                throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
            }
            _ = try fm.replaceItemAt(target, withItemAt: partial)
        } else { try fm.moveItem(at: partial, to: target) }
    }
    /// Size and modification date: enough to notice that the sync client replaced the file, without hashing it.
    private static func signature(_ url: URL) -> [AnyHashable]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return [values.fileSize, values.contentModificationDate]
    }
    /// `.overheard-upload-<epoch>-<uuid>`: stale an hour after it was made. Older names (no epoch) fall back
    /// to the modification date.
    static func isStaleUpload(_ url: URL, now: Date = Date()) -> Bool {
        let name = url.lastPathComponent, prefix = ".overheard-upload-"
        guard name.hasPrefix(prefix) else { return false }
        if let epoch = name.dropFirst(prefix.count).split(separator: "-").first.flatMap({ Double($0) }), epoch > 1_000_000_000 {
            return now.timeIntervalSince1970 - epoch > 3600
        }
        return ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < now.addingTimeInterval(-3600)
    }
    func download(_ id: String, to destination: URL) async throws {
        let source = try url(id)
        guard CloudFiles.exists(source) else { throw CloudError.message(String(localized: "File cloud non trovato. Copie locali conservate.")) }
        try await ensureDownloaded(source)
        try FileManager.default.copyItem(at: source, to: destination)
    }
    /// Moved to the Trash (iCloud Drive keeps it in Recently Deleted), never deleted outright.
    func remove(_ id: String) async throws {
        let url = try url(id)
        guard CloudFiles.exists(url) else { return }
        if trashOnRemove { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        else { try FileManager.default.removeItem(at: url) }
    }
    /// Removes the meeting's folder only when it is empty (Finder's .DS_Store aside).
    func removeMeetingFolder(_ folder: String, id: String?) async throws {
        let url = try url(folder)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0 != ".DS_Store" }
        guard CloudFiles.exists(url), left.isEmpty else { return }
        // rmdir fails on a non-empty directory, so a file the sync client delivers meanwhile survives.
        try? FileManager.default.removeItem(at: url.appendingPathComponent(".DS_Store"))
        if rmdir(url.path) != 0, errno != ENOTEMPTY, errno != ENOENT {
            throw CocoaError(.fileWriteUnknown)
        }
    }
    /// How much of what Overheard wrote here has actually left the Mac, as macOS reports it. Files in a folder
    /// macOS does not track (a plain folder) are not counted: nothing can be said about them.
    struct UploadState: Equatable, Sendable {
        var files = 0, pendingFiles = 0
        var bytes: Int64 = 0, pendingBytes: Int64 = 0
        var doneFiles: Int { files - pendingFiles }
        /// Share of the bytes already uploaded.
        var fraction: Double { bytes > 0 ? Double(bytes - pendingBytes) / Double(bytes) : 1 }
    }
    func uploadState() -> UploadState {
        var state = UploadState()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return state }
        for case let file as URL in walker {
            guard !file.lastPathComponent.hasPrefix(".overheard-upload-"),
                  let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isUbiquitousItem == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            state.files += 1; state.bytes += size
            if values.ubiquitousItemIsUploaded != true { state.pendingFiles += 1; state.pendingBytes += size }
        }
        return state
    }

    /// True only when macOS reports the file as uploaded by iCloud or the File Provider app.
    func isSafelyStored(_ id: String) async throws -> Bool {
        let values = try url(id).resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
        return values.isUbiquitousItem == true && values.ubiquitousItemIsUploaded == true
    }
    /// Once uploaded, the synced copy can leave the Mac too; it downloads again when opened.
    func releaseLocalCopy(_ id: String) async throws {
        let url = try url(id)
        guard try await isSafelyStored(id) else { return }
        try FileManager.default.evictUbiquitousItem(at: url)
    }
}
