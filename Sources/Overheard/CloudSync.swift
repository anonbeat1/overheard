import Foundation
import CryptoKit

struct CloudMeetingID: Codable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}
struct CloudFileVersion: Codable, Equatable, Sendable {
    let byteCount: Int64
    let sha256: String
}
struct CloudRemoteFile: Codable, Equatable, Sendable {
    let id: String
    let version: CloudFileVersion
    /// "alac" or "aac" when the cloud copy is a compressed encoding of the local WAV; nil when it is the file itself.
    var encoding: String? = nil
    /// For an encoded copy: SHA-256 of the local WAV it was made from (or decoded into, after a download).
    var source: CloudFileVersion? = nil
    /// For an encoded copy: the local WAV format, so a download is decoded back to the same format.
    var format: CloudAudioFormat? = nil
}

protocol CloudStorageProvider: Sendable {
    var id: String { get }
    func reserve(meeting: CloudMeetingID, name: String) async throws -> String
    func inspect(_ id: String) async throws -> CloudFileVersion?
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws
    func download(_ id: String, to destination: URL) async throws
    func remove(_ id: String) async throws

    // Optional capabilities. Defaults below keep a flat layout, SHA-256 and whole-file uploads.

    /// The digest this provider reports for stored content. Default: size and SHA-256.
    /// Dropbox reports its own block hash instead, so local files are fingerprinted the same way.
    func fingerprint(_ file: URL) throws -> CloudFileVersion
    /// Reserves the remote ID for one file of a meeting. Path-based providers build a readable path from it.
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String

    /// Reserves a stable ID for a per-meeting folder, or nil when the provider stores files flat.
    func reserveFolder() async throws -> String?
    /// Creates the reserved folder. Must succeed when the folder already exists (a retry after a lost response).
    func createFolder(id: String, name: String) async throws
    func folderExists(_ id: String) async throws -> Bool
    /// Size of a stored file, or nil when it is missing. A cheap presence check: providers that
    /// would download the file to inspect it (WebDAV, S3 objects without a digest) answer with a HEAD.
    func size(_ id: String) async throws -> Int64?
    /// Discards an unfinished upload session and whatever it stored (S3 keeps parts until aborted).
    func abandonUpload(session: String) async throws
    /// Whether the service confirms this copy has left the Mac. Network services: always (the file is
    /// on their servers). A synced folder: only when macOS reports the upload done.
    func isSafelyStored(_ id: String) async throws -> Bool
    /// After the WAV is freed, lets a synced folder drop its local copy too (no-op for network services).
    func releaseLocalCopy(_ id: String) async throws
    /// Removes a meeting's remote folder after a Move, only when nothing is left in it.
    /// `folder` is the meeting's folder name (path-based services), `id` its reserved folder ID (Drive).
    func removeMeetingFolder(_ folder: String, id: String?) async throws
    func upload(file: URL, id: String, name: String, parent: String?, replacing: Bool) async throws
    /// Last look right before a replacing upload: the stored file must still be what the engine just saw.
    /// Narrows the window in which another Mac's version could be overwritten from minutes (encoding, a long
    /// transfer) to a moment. Default: compare `inspect`; WebDAV compares sizes (inspect downloads the file).
    func expectUnchanged(_ id: String, _ expected: CloudFileVersion) async throws
    /// Opens a resumable upload session, or returns nil when the provider has none.
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String?
    /// Sends whatever part of the file the server has not stored yet. Throws `CloudUploadExpired` for a dead session.
    func resumeUpload(file: URL, session: String) async throws
}

protocol CloudLibraryProvider: CloudStorageProvider {
    func libraryMarkerID() async throws -> String?
    func createLibraryMarker(file: URL) async throws
}

struct CloudLibraryMarker: Codable {
    let schema: Int
    let id: UUID
}

extension CloudLibraryProvider {
    static var libraryMarkerName: String { ".overheard-library.json" }

    func libraryIdentity(createIfMissing: Bool) async throws -> UUID {
        func read() async throws -> CloudLibraryMarker? {
            guard let id = try await libraryMarkerID(), let version = try await inspect(id) else { return nil }
            guard version.byteCount <= 4096 else {
                throw CloudError.destination(String(localized: "Risposta cloud non valida"))
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try await download(id, to: file)
            guard try fingerprint(file) == version,
                  let marker = try? JSONDecoder().decode(CloudLibraryMarker.self, from: Data(contentsOf: file)),
                  marker.schema == 1 else {
                throw CloudError.destination(String(localized: "Risposta cloud non valida"))
            }
            return marker
        }
        if let marker = try await read() { return marker.id }
        guard createIfMissing else {
            throw CloudError.destination(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(CloudLibraryMarker(schema: 1, id: UUID())).write(to: file)
        do { try await createLibraryMarker(file: file) }
        catch {
            if let marker = try await read() { return marker.id }
            throw error
        }
        guard let marker = try await read() else {
            throw CloudError.destination(String(localized: "Risposta cloud non valida"))
        }
        return marker.id
    }
}

extension CloudStorageProvider {
    func expectUnchanged(_ id: String, _ expected: CloudFileVersion) async throws {
        guard let current = try await inspect(id), current == expected else {
            throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
        }
    }
    func fingerprint(_ file: URL) throws -> CloudFileVersion { try CloudFiles.version(file) }
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String {
        try await reserve(meeting: meeting, name: "\(folder)-\(file)")
    }
    func reserveFolder() async throws -> String? { nil }
    func createFolder(id: String, name: String) async throws {}
    func folderExists(_ id: String) async throws -> Bool { true }
    func size(_ id: String) async throws -> Int64? { try await inspect(id)?.byteCount }
    func abandonUpload(session: String) async throws {}
    func isSafelyStored(_ id: String) async throws -> Bool { true }
    func releaseLocalCopy(_ id: String) async throws {}
    func removeMeetingFolder(_ folder: String, id: String?) async throws {}
    func upload(file: URL, id: String, name: String, parent: String?, replacing: Bool) async throws {
        try await upload(file: file, id: id, name: name, replacing: replacing)
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? { nil }
    func resumeUpload(file: URL, session: String) async throws { throw CloudUploadExpired() }
}

/// The server no longer knows the upload session: start a new one.
struct CloudUploadExpired: LocalizedError {
    var errorDescription: String? { String(localized: "Sessione di caricamento scaduta: il caricamento ripartirà da capo.") }
}

/// Open resumable sessions, kept per Mac in Application Support rather than in the meeting manifest:
/// a session URL is a short-lived upload capability and must not travel through a synced ~/Meetings,
/// and progress must not rewrite the manifest.
struct CloudUploadSessions: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let id: String
        let session: String
        let version: CloudFileVersion
        let created: Date
    }
    static let lifetime: TimeInterval = 6 * 86400 // Drive keeps a session for about a week
    let url: URL
    static var standard: CloudUploadSessions {
        CloudUploadSessions(url: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Overheard/cloud-uploads.json"))
    }
    func load() -> [String: Entry] {
        loadAll().filter { $0.value.created > Date().addingTimeInterval(-Self.lifetime) }
    }
    /// Including sessions too old to resume, which may still hold stored parts to discard.
    func loadAll() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url), let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }
    func save(_ entries: [String: Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func key(_ meeting: CloudMeetingID, _ name: String) -> String { "\(meeting.rawValue.uuidString)/\(name)" }
}

enum CloudError: LocalizedError, Equatable {
    /// A problem with one meeting: it gets its own retry backoff.
    case message(String)
    /// A problem with the network or the destination (offline, authorization, quota, outage):
    /// it stops the pass and is not charged to any meeting.
    case destination(String)
    /// The account's authorization is gone (revoked, expired): retrying cannot help, the person must reconnect.
    case authExpired(String)
    var errorDescription: String? {
        switch self { case .message(let text), .destination(let text), .authExpired(let text): return text }
    }
    var affectsDestination: Bool {
        switch self { case .destination, .authExpired: return true; case .message: return false }
    }
    var needsReconnect: Bool { if case .authExpired = self { return true }; return false }
    /// The meeting is being recorded, transcribed, played or exported: try again later, no penalty.
    static var busy: CloudError { .message(String(localized: "Riunione in uso. Riprova quando la registrazione o la trascrizione è terminata.")) }
    var isBusy: Bool { self == .busy }
    static var offline: CloudError { .destination(String(localized: "Nessuna connessione. La sincronizzazione riprenderà automaticamente.")) }
    static func classify(_ error: Error) -> Error {
        let offline: Set<URLError.Code> = [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                                           .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
                                           .cannotLoadFromNetwork, .callIsActive]
        if let error = error as? URLError, offline.contains(error.code) { return CloudError.offline }
        // A proxy, a network that intercepts encrypted traffic or a login page: the network, not a meeting.
        let network: Set<URLError.Code> = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                                           .serverCertificateHasUnknownRoot, .clientCertificateRejected, .badServerResponse,
                                           .cannotParseResponse, .httpTooManyRedirects, .userAuthenticationRequired]
        if let error = error as? URLError, network.contains(error.code) {
            return CloudError.destination(String(localized: "Connessione al servizio non riuscita: la rete o un proxy la bloccano. La sincronizzazione riprenderà da sola."))
        }
        // The Mac's disk is full: stop the pass, it is no meeting's fault.
        let nsError = error as NSError
        if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
            || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) {
            return CloudError.destination(String(localized: "Poco spazio libero sul Mac: il caricamento dell'audio riprenderà quando ci sarà più spazio."))
        }
        // A cancelled task makes URLSession throw URLError.cancelled, not CancellationError: it is a stop,
        // never a failure of the meeting (no retry delay, no error on its row).
        if let error = error as? URLError, error.code == .cancelled { return CancellationError() }
        return error
    }
}

enum CloudVerification {
    static func matches(local: CloudFileVersion, remote: CloudFileVersion) -> Bool {
        local.byteCount >= 0 && remote.byteCount >= 0 && isSHA256(local.sha256) && isSHA256(remote.sha256)
            && local.byteCount == remote.byteCount && local.sha256.lowercased() == remote.sha256.lowercased()
    }
    /// A hex digest: SHA-256 (32 bytes) or OneDrive's QuickXorHash (20 bytes).
    private static func isSHA256(_ value: String) -> Bool {
        (value.utf8.count == 64 || value.utf8.count == 40) && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }
}

enum CloudFiles {
    static let audio = ["recording.wav", "mic.wav"]
    static let text = ["transcript.md", "summary.md", "bookmarks.txt", "attendees"]
    static let content = audio + text + ["source", "title", "engine"]
    static func version(_ url: URL) throws -> CloudFileVersion {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudError.message(String(localized: "File non valido")) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data); size += Int64(data.count)
        }
        return CloudFileVersion(byteCount: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Remote folder name: the local folder plus the meeting title when there is one.
    static func displayName(_ directory: URL) -> String {
        let title = (try? String(contentsOf: directory.appendingPathComponent("title"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").prefix(120) ?? ""
        return title.isEmpty ? directory.lastPathComponent : "\(directory.lastPathComponent) – \(title)"
    }
    static func localAudioBytes(_ directory: URL) -> Int64 {
        audio.reduce(0) { total, name in
            total + Int64((try? directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    /// Recording time from the folder name (yyyy-MM-dd_HHmm[ss]), the most reliable meeting age.
    static func meetingDate(_ directory: URL) -> Date? {
        let name = directory.lastPathComponent
        guard let range = name.range(of: #"^20[0-9]{2}-[0-9]{2}-[0-9]{2}_[0-9]{4}(?:[0-9]{2})?"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = name[range].count > 15 ? "yyyy-MM-dd_HHmmss" : "yyyy-MM-dd_HHmm"
        return formatter.date(from: String(name[range]))
    }
    static func eligible(_ directory: URL) -> Bool {
        let v = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink != true
            && !exists(directory.appendingPathComponent(".transcribing"))
            && !exists(directory.appendingPathComponent("recording.tmp.wav"))
            && !exists(directory.appendingPathComponent("mic.tmp.wav"))
    }
    static func names(in directory: URL, options: CloudOptions) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter { url in
                let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard v?.isRegularFile == true, v?.isSymbolicLink != true, SyncConflicts.originalName(url.lastPathComponent) == nil else { return false }
                let name = url.lastPathComponent
                guard CloudProvenance.accepts(url) else { return false }
                switch name {
                case _ where Self.audio.contains(name): return options.audio
                case "transcript.md": return options.transcript
                case "summary.md": return options.summary
                case "bookmarks.txt": return options.bookmarks
                case "source", "title", "engine", "attendees", CloudLedger.mirrorName: return true
                default: return false // Arbitrary local attachments are never cloud input.
                }
            }.map(\.lastPathComponent).sorted()
    }
}

struct CloudLocalStamp: Codable, Equatable {
    let bytes: Int
    let modified: Date
    static func read(_ url: URL) throws -> Self {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let bytes = values.fileSize, let modified = values.contentModificationDate else { throw CloudError.message(String(localized: "Metadati file non disponibili")) }
        return Self(bytes: bytes, modified: modified)
    }
}

struct CloudManifest: Codable, Equatable {
    static let filename = ".overheard-cloud.json"
    var schema = 1
    var meeting = CloudMeetingID()
    var destination: String
    var files: [String: CloudRemoteFile] = [:]
    var localStamps: [String: CloudLocalStamp] = [:]
    var pendingVersions: [String: CloudFileVersion] = [:]
    var syncDisabled = false
    var pending: [String: String] = [:] // reserved IDs survive a crash before upload completes
    var archived: Set<String> = []
    var pinned = false
    var attempts = 0
    var nextAttempt: Date?
    var lastError: String?
    var catalogDirty: Bool?
    var syncedAt: Date?
    var restoredAt: Date? // a fresh download restarts the automatic cleanup clock
    var folder: String?   // per-meeting remote folder, reserved before creation so a retry cannot duplicate it
    var folderReady: Bool?
    /// Original recovery record while copying to another destination; retained across interruptions.
    var migrationSource: Data?
    /// Audio that was only in the cloud when a transfer started; it is freed again once copied.
    var rearchive: Set<String>?
    /// A Move whose old service was unreachable: the old copies to remove once it is back.
    var pendingRemoval: Data?
    /// Earlier versions this Mac started uploading for a file and never recorded (an interrupted upload
    /// may have committed any of them): finding one of them remotely is our own work, not someone's edit.
    var pushed: [String: [CloudFileVersion]]?
    /// Files that were uploaded and are now gone from the cloud (deleted or trashed there). They are not
    /// uploaded again until the user chooses to: a deletion on the cloud side is respected.
    var remoteDeleted: [String: Date]?

    static func archiveURL(_ directory: URL, destination: String) -> URL {
        let key = SHA256.hash(data: Data(destination.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(".overheard-cloud-destinations").appendingPathComponent(key + ".json")
    }

    func archive(_ directory: URL) throws {
        let url = Self.archiveURL(directory, destination: destination)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var snapshot = self
        snapshot.migrationSource = nil
        try JSONEncoder().encode(snapshot).write(to: url, options: [.atomic])
    }

    static func load(_ directory: URL, destination: String) throws -> Self {
        let url = directory.appendingPathComponent(filename)
        guard CloudFiles.exists(url) else { return Self(destination: destination) }
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw CloudError.message(String(localized: "Archivio cloud locale non valido"))
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard manifest.schema == 1 else { throw CloudError.message(String(localized: "Versione archivio cloud non supportata")) }
        guard manifest.destination == destination else { throw CloudError.message(String(localized: "Questa riunione usa un'altra destinazione cloud. Ripristina la destinazione precedente per gestirla.")) }
        return manifest
    }
    func save(_ directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent(Self.filename), options: [.atomic])
        // Every saved state also lands in the map outside the meeting folder (see CloudLedger).
        try? CloudLedger.current.record(self, directory: directory)
    }
}

/// What to upload, by kind of meeting file. Metadata (source, title, engine) always goes along.
/// Turning a kind off stops future uploads; copies already in the cloud are kept.
struct CloudOptions: Sendable {
    var audio = true
    var transcript = true
    var summary = true      // summary.md: summary, decisions and action items
    var bookmarks = true    // bookmarks.txt
    var otherText = true    // any other .md/.txt/.json kept in the meeting folder
    /// How audio goes to the cloud; nil uploads the WAV itself. The Mac always keeps WAV.
    var audioEncoding: CloudAudioEncoding? = .alac
    var cleanupDays = 0
    var archiveAfterSync = false
}
extension CloudOptions {
    /// All text kinds at once.
    init(audio: Bool = true, text: Bool, cleanupDays: Int = 0) {
        self.init(audio: audio, transcript: text, summary: text, bookmarks: text, otherText: text, audioEncoding: .alac, cleanupDays: cleanupDays)
    }
}

/// `reclaim` is the storage-limit cleanup: it frees audio only where automatic cleanup would be safe.
enum CloudAction: Sendable, Equatable { case sync, evict, restore, pin, deleteRemote, reclaim, reupload }

struct CloudReport: Sendable {
    var statuses: [String: String] = [:]
    var failures: [String: String] = [:]
    /// Set when the destination itself failed (offline, authorization, quota, outage): the pass stops
    /// and per-meeting retry state is left untouched, because no single meeting is at fault.
    var stopped: String?
    /// The stop is a revoked or expired authorization: automatic passes wait until the person reconnects.
    var authExpired = false
}

/// Precomputed once per pass so a library of N meetings costs O(N), not O(N²), to check.
struct CloudContext: Sendable {
    var folderConflicts: Set<String> = []
    var identityCounts: [CloudMeetingID: Int] = [:]
}

/// Serializes all transfers and local cleanup. No local absence is ever a remote delete request.
actor CloudSyncEngine {
    private var running = false
    private var verifiedAt: [String: Date] = [:]
    private let sessions: CloudUploadSessions
    private let audioCache: CloudAudioCache
    init(sessions: CloudUploadSessions = .standard, audioCache: CloudAudioCache = .standard) {
        self.sessions = sessions; self.audioCache = audioCache
    }

    /// Copies all tracked files, recovering missing local files from the authenticated original provider.
    /// Source deletion is a separate, explicitly selected mode and happens only after full verification.
    /// - Parameter source: the original destination, or nil when it can no longer be reached. Without it a
    ///   meeting is copied from the Mac only when every tracked file is still there, and nothing is removed.
    /// - Returns: true when a move left the original copies behind because the source was unavailable.
    @discardableResult
    func migrate(_ dir: URL, from source: (any CloudStorageProvider)?, to target: any CloudStorageProvider,
                 move: Bool, options: CloudOptions,
                 isActive: @escaping @Sendable (URL) async -> Bool = { _ in false }) async throws -> Bool {
        guard !running else { throw CloudError.message(String(localized: "Sincronizzazione in corso")) }
        running = true
        defer { running = false }
        verifiedAt.removeAll()
        try await check(dir, isActive)
        guard SyncConflicts.scan(dir).isEmpty, SyncConflicts.originalName(dir.lastPathComponent) == nil else {
            throw CloudError.message(String(localized: "Risolvi le copie in conflitto prima di sincronizzare"))
        }
        let current = try CloudManifest.load(dir, destination: CloudSync.manifest(dir)?.destination ?? source?.id ?? target.id)
        var original = try current.migrationSource.map { try JSONDecoder().decode(CloudManifest.self, from: $0) } ?? current
        if let source {
            guard original.destination == source.id else {
                throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
            }
        } else {
            // Nothing can be fetched from the old service: every tracked file must still be on the Mac.
            guard original.files.keys.allSatisfy({ CloudFiles.exists(dir.appendingPathComponent($0)) }) else {
                throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
            }
        }
        // Audio freed before the transfer is downloaded, copied and freed again: one meeting at a time,
        // so the Mac never needs room for the whole archive.
        // Recorded once, before anything is downloaded, so a resumed transfer still frees the audio again.
        if original.rearchive == nil {
            original.rearchive = original.archived.filter { !CloudFiles.exists(dir.appendingPathComponent($0)) }
            if current.migrationSource == nil, current.destination == original.destination { try original.save(dir) }
        }
        let archivedBefore = original.rearchive ?? []
        if source != nil, !archivedBefore.isEmpty {
            let needed = archivedBefore.reduce(Int64(1_000_000_000)) { total, name in
                guard let remote = original.files[name] else { return total }
                let factor: Int64 = remote.encoding == CloudAudioEncoding.aac.rawValue ? 16 : remote.encoding == CloudAudioEncoding.alac.rawValue ? 5 : 2
                return total + remote.version.byteCount * factor
            }
            let available = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
            guard available >= needed else {
                throw CloudError.destination(String(localized: "Spazio insufficiente sul Mac per trasferire le riunioni: servono circa \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) liberi."))
            }
        }
        let context = context(for: [dir], destination: current.destination)
        guard !context.folderConflicts.contains(Self.key(dir)), (context.identityCounts[current.meeting] ?? 0) <= 1 else {
            throw CloudError.message(String(localized: "Risolvi le copie in conflitto prima di sincronizzare"))
        }
        if current.destination != original.destination { try current.archive(dir) }
        // Restore never replaces a local edit. Audio is decoded and verified by the existing restore path.
        if let source {
            // Restore persists its recovery state. During a retry, keep the partially uploaded
            // destination authoritative even if recovery fails before the transfer can resume.
            defer { if current.destination == target.id { try? current.save(dir) } }
            try await restore(dir, manifest: &original, provider: source, isActive: isActive)
            try original.archive(dir)
        }
        // Choosing the original provider again cancels the pending transfer without deleting the
        // partial new copy. Reconcile the original from local files rather than copying onto itself.
        if let source, source.id == target.id {
            original.migrationSource = nil
            try original.save(dir)
            try await sync(dir, manifest: &original, provider: target, options: options, isActive: isActive)
            try original.save(dir)
            return false
        }
        if let source { for (name, remote) in original.files where !CloudFiles.audio.contains(name) {
            guard CloudProvenance.names.contains(name) else { throw CloudError.message(String(localized: "File non valido")) }
            guard CloudProvenance.names.contains(name), name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
                throw CloudError.message(String(localized: "File non valido"))
            }
            let local = dir.appendingPathComponent(name)
            if CloudFiles.exists(local) { continue }
            guard let version = try await source.inspect(remote.id), CloudVerification.matches(local: remote.version, remote: version) else {
                throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. Download interrotto."))
            }
            let temporary = dir.appendingPathComponent(".migration-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await source.download(remote.id, to: temporary)
            guard CloudVerification.matches(local: try source.fingerprint(temporary), remote: remote.version) else {
                throw CloudError.message(String(localized: "Verifica del caricamento fallita. Copia locale conservata."))
            }
            try await check(dir, isActive)
            try FileManager.default.moveItem(at: temporary, to: local)
                try CloudProvenance.record(local)
        } }
        try original.archive(dir)
        var destination: CloudManifest
        if current.destination == target.id { destination = current }
        else if let data = try? Data(contentsOf: CloudManifest.archiveURL(dir, destination: target.id)) {
            destination = try JSONDecoder().decode(CloudManifest.self, from: data)
            guard destination.destination == target.id, destination.meeting == original.meeting else {
                throw CloudError.message(String(localized: "Archivio cloud locale non valido"))
            }
        } else {
            destination = CloudManifest(meeting: original.meeting, destination: target.id)
            destination.pinned = original.pinned
        }
        destination.migrationSource = try JSONEncoder().encode(original)
        try destination.save(dir)
        // A transfer copies every previously tracked file, regardless of the new destination's filters.
        var transferOptions = options
        transferOptions.audio = true; transferOptions.transcript = true; transferOptions.summary = true
        transferOptions.bookmarks = true; transferOptions.otherText = true; transferOptions.cleanupDays = 0
        try await sync(dir, manifest: &destination, provider: target, options: transferOptions, isActive: isActive)
        for name in original.files.keys {
            guard let remote = destination.files[name], let verified = try await target.inspect(remote.id),
                  CloudVerification.matches(local: remote.version, remote: verified) else {
                throw CloudError.message(String(localized: "Verifica del caricamento fallita. Copia locale conservata."))
            }
        }
        if move, let source {
            // Check every source before deleting any. An externally edited original is never removed.
            for remote in original.files.values {
                if let verified = try await source.inspect(remote.id), !CloudVerification.matches(local: remote.version, remote: verified) {
                    throw CloudError.message(String(localized: "Il file cloud è cambiato. Rimozione interrotta."))
                }
            }
            // Retain the recovery map until all meeting files have been accounted for.
            let names = original.files.keys.filter { $0 != CloudLedger.mirrorName }.sorted() + [CloudLedger.mirrorName]
            for name in names {
                guard let remote = original.files[name] else { continue }
                try await check(dir, isActive)
                guard let copy = destination.files[name], let verifiedCopy = try await target.inspect(copy.id),
                      CloudVerification.matches(local: copy.version, remote: verifiedCopy) else {
                    throw CloudError.message(String(localized: "Verifica del caricamento fallita. Copia locale conservata."))
                }
                if let verified = try await source.inspect(remote.id) {
                    guard CloudVerification.matches(local: remote.version, remote: verified) else {
                        throw CloudError.message(String(localized: "Il file cloud è cambiato. Rimozione interrotta."))
                    }
                    try await source.remove(remote.id)
                }
                // File by file: a Move interrupted halfway leaves an exact map of what is gone.
                try? CloudLedger.current.markRemoved(original.meeting, folder: dir.lastPathComponent, destination: source.id, files: [name])
            }
            // Cut and paste: the emptied meeting folder and the local record of the old destination go too.
            try? await source.removeMeetingFolder(dir.lastPathComponent, id: original.folderReady == true ? original.folder : nil)
            try? FileManager.default.removeItem(at: CloudManifest.archiveURL(dir, destination: source.id))
        } else if move {
            // The old service could not be reached: finish the Move when it is back (finishMove).
            destination.pendingRemoval = try JSONEncoder().encode(original)
        }
        destination.migrationSource = nil
        // Audio that was only in the cloud goes back to the cloud: the new copy was verified above.
        let reArchive = Set(archivedBefore.filter { destination.files[$0] != nil && CloudFiles.exists(dir.appendingPathComponent($0)) })
        if !reArchive.isEmpty, !destination.pinned {
            try destination.save(dir)
            try await evict(dir, manifest: &destination, provider: target, isActive: isActive, only: reArchive)
        } else if !reArchive.isEmpty {
            destination.restoredAt = Date() // pinned: the download stays, and is not cleaned up at once
        }
        destination.attempts = 0; destination.nextAttempt = nil; destination.lastError = nil
        try destination.save(dir)
        return move && source == nil
    }

    /// Completes a Move whose old service was unreachable: once it is back, removes the old copies that
    /// are still exactly as copied (a copy edited there in the meantime is kept) and the emptied folder.
    /// "Remove from the cloud, keep on this Mac": deletes the copies `record` lists on `provider` and its
    /// emptied meeting folder. Local files are never touched. Refuses while any of its audio exists only
    /// in the cloud; a remote file changed by someone else is left there (returned as kept).
    func purge(_ dir: URL, record: CloudManifest, provider: any CloudStorageProvider,
               isActive: @escaping @Sendable (URL) async -> Bool = { _ in false }) async throws -> [String] {
        guard !running else { throw CloudError.message(String(localized: "Sincronizzazione in corso")) }
        running = true
        defer { running = false }
        try await check(dir, isActive)
        guard record.destination == provider.id else {
            throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
        }
        for name in CloudFiles.audio where record.files[name] != nil {
            let local = dir.appendingPathComponent(name)
            guard CloudFiles.exists(local), (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 else {
                throw CloudError.message(String(localized: "Scarica prima tutto l'audio. La copia cloud è l'unica disponibile."))
            }
        }
        var kept: [String] = []
        for (name, remote) in record.files.sorted(by: { $0.key < $1.key }) {
            try await check(dir, isActive)
            // A transcript or note deleted on the Mac may exist only in the cloud: never its last copy.
            if name != CloudLedger.mirrorName, !CloudFiles.exists(dir.appendingPathComponent(name)) { kept.append(name); continue }
            if let current = try await provider.inspect(remote.id) {
                guard CloudVerification.matches(local: remote.version, remote: current) else { kept.append(name); continue }
                try await provider.remove(remote.id)
            }
            // Recorded file by file: an interruption halfway leaves an exact map of what is gone.
            try? CloudLedger.current.markRemoved(record.meeting, folder: dir.lastPathComponent, destination: provider.id, files: [name])
        }
        try? CloudLedger.current.note(record.meeting, folder: dir.lastPathComponent,
                                      String(localized: "Copie rimosse da \(CloudSync.displayName(provider.id)), file tenuti sul Mac"))
        if kept.isEmpty { try? await provider.removeMeetingFolder(dir.lastPathComponent, id: record.folderReady == true ? record.folder : nil) }
        try? await forgetSessions(record, provider: provider)
        return kept
    }

    func finishMove(_ dir: URL, source: any CloudStorageProvider, target: any CloudStorageProvider,
                    isActive: @escaping @Sendable (URL) async -> Bool = { _ in false }) async throws {
        guard !running else { throw CloudError.message(String(localized: "Sincronizzazione in corso")) }
        running = true
        defer { running = false }
        try await check(dir, isActive)
        var manifest = try CloudManifest.load(dir, destination: target.id)
        guard let data = manifest.pendingRemoval else { return }
        let original = try JSONDecoder().decode(CloudManifest.self, from: data)
        guard original.destination == source.id else {
            throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
        }
        for (name, remote) in original.files {
            try await check(dir, isActive)
            // The new copy must still be there before the old one goes.
            guard let copy = manifest.files[name], let verified = try await target.inspect(copy.id),
                  CloudVerification.matches(local: copy.version, remote: verified) else {
                throw CloudError.message(String(localized: "Verifica del caricamento fallita. Copia locale conservata."))
            }
            if let old = try await source.inspect(remote.id) {
                // A copy edited there in the meantime is kept, and stays in the map.
                guard CloudVerification.matches(local: remote.version, remote: old) else { continue }
                try await source.remove(remote.id)
            }
            try? CloudLedger.current.markRemoved(original.meeting, folder: dir.lastPathComponent, destination: source.id, files: [name])
        }
        try? await source.removeMeetingFolder(dir.lastPathComponent, id: original.folderReady == true ? original.folder : nil)
        try? FileManager.default.removeItem(at: CloudManifest.archiveURL(dir, destination: source.id))
        manifest.pendingRemoval = nil
        try manifest.save(dir)
    }

    /// Rebuilds a meeting that is no longer on the Mac from one of its places in the map: every file is
    /// downloaded and verified against its recorded digest, compressed audio is decoded back to WAV, and
    /// a manifest is written so the meeting is synced again. Assembled in a hidden folder, then moved in.
    func rebuild(_ entry: CloudLedger.Entry, from placement: CloudLedger.Placement, provider: any CloudStorageProvider,
                 into root: URL) async throws -> URL {
        guard !running else { throw CloudError.message(String(localized: "Sincronizzazione in corso")) }
        running = true
        defer { running = false }
        guard placement.destination == provider.id, !placement.live.isEmpty else {
            throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
        }
        let fm = FileManager.default
        var target = root.appendingPathComponent(entry.folder, isDirectory: true)
        if fm.fileExists(atPath: target.path) {
            if CloudSync.manifest(target)?.meeting == entry.meeting {
                throw CloudError.message(String(localized: "Questa riunione è già sul Mac."))
            }
            target = root.appendingPathComponent(entry.folder + String(localized: " (ripristinata)"), isDirectory: true)
            guard !fm.fileExists(atPath: target.path) else { throw CloudError.message(String(localized: "Questa riunione è già sul Mac.")) }
        }
        let staging = root.appendingPathComponent(".rebuild-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var manifest = CloudManifest(meeting: entry.meeting, destination: provider.id)
        manifest.folder = placement.folder
        manifest.folderReady = placement.folder == nil ? nil : true
        for (name, remote) in placement.live {
            try Task.checkCancellation()
            guard CloudProvenance.names.contains(name), name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else { throw CloudError.message(String(localized: "File non valido")) }
            guard try await provider.inspect(remote.id) == remote.version else { throw CloudError.message(String(localized: "File non valido")) }
            let download = staging.appendingPathComponent(".download-" + UUID().uuidString)
            try await provider.download(remote.id, to: download)
            guard CloudVerification.matches(local: try provider.fingerprint(download), remote: remote.version) else {
                throw CloudError.message(String(localized: "Audio scaricato non valido. Riprova."))
            }
            let local = staging.appendingPathComponent(name)
            var file = remote
            if remote.encoding != nil, CloudFiles.audio.contains(name) {
                guard let format = remote.format else { throw CloudError.message(String(localized: "Audio scaricato non valido. Riprova.")) }
                let m4a = download.appendingPathExtension("m4a")
                try fm.moveItem(at: download, to: m4a)
                defer { try? fm.removeItem(at: m4a) }
                try CloudAudio.decode(m4a, to: local, format: format)
                try CloudProvenance.record(local)
                file.source = try CloudFiles.version(local) // the cloud copy now stands for this WAV
            } else {
                try fm.moveItem(at: download, to: local)
                try CloudProvenance.record(local)
            }
            manifest.files[name] = file
            manifest.localStamps[name] = try CloudLocalStamp.read(local)
        }
        try fm.moveItem(at: staging, to: target)
        try manifest.save(target)
        try? CloudLedger.current.note(entry.meeting, folder: target.lastPathComponent,
                                      String(localized: "Riunione ricostruita da \(CloudSync.displayName(provider.id))"))
        return target
    }

    func confirmLibrary(_ provider: any CloudLibraryProvider, in root: URL) async throws {
        if let drive = provider as? GoogleDriveProvider { try await drive.validateLibraryFolder() }
        let hash = SHA256.hash(data: Data(provider.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let marker = root.appendingPathComponent(".overheard-library-" + hash)
        let pinned = CloudFiles.exists(marker)
        let identity = try await provider.libraryIdentity(createIfMissing: !pinned)
        if pinned {
            let pinnedID = try String(contentsOf: marker, encoding: .utf8)
            if pinnedID != identity.uuidString {
                // Our own marker, set aside as a conflict copy, proves two Macs connected to this folder at once
                // before it synced: the surviving marker is the same library, so adopt it. Anything else
                // (a replaced or different folder) stays a conflict.
                guard let local = provider as? LocalFolderProvider,
                      local.markerCopyIDs().contains(where: { $0.uuidString == pinnedID }) else {
                    throw CloudError.destination(String(localized: "Conflitto remoto. Copie locali conservate."))
                }
                try identity.uuidString.write(to: marker, atomically: true, encoding: .utf8)
            }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try identity.uuidString.write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    /// Pull the published revisions. An empty device keeps only a local library index.
    /// If a file also exists locally, leave both versions available instead of overwriting either.
    func pullCatalog(from provider: WebDAVProvider, into root: URL,
                     isActive: @Sendable (URL) async -> Bool = { _ in false }) async throws -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        try await confirmLibrary(provider, in: root)
        let fm = FileManager.default
        let directories = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var indexed: [CloudMeetingID: URL] = [:]
        for directory in directories {
            if CloudFiles.eligible(directory), let manifest = CloudSync.manifest(directory),
               manifest.destination == provider.id { indexed[manifest.meeting] = directory }
        }
        var changed = false
        for id in try await provider.remoteMaps() {
            try Task.checkCancellation()
            let (entry, version) = try await provider.readMap(id)
            guard CloudFiles.meetingDate(URL(fileURLWithPath: "/" + entry.folder)) != nil,
                  entry.folder == (entry.folder as NSString).lastPathComponent,
                  id == "\(entry.meeting.rawValue.uuidString)-\(entry.folder)-\(CloudLedger.mirrorName)",
                  let placement = entry.placements[provider.id], !placement.live.isEmpty,
                  placement.live.allSatisfy({ name, file in
                      CloudFiles.content.contains(name) && !file.id.contains("/") && !file.id.contains("\\")
                          && file.id.hasPrefix(entry.meeting.rawValue.uuidString + "-")
                  }) else { continue }

            let directory = indexed[entry.meeting] ?? root.appendingPathComponent(entry.folder, isDirectory: true)
            let known = indexed[entry.meeting] != nil
            if known {
                guard CloudFiles.eligible(directory), !(await isActive(directory)) else { continue }
            } else {
                guard !CloudFiles.exists(directory) else { continue }
            }
            var manifest = known ? try CloudManifest.load(directory, destination: provider.id)
                : CloudManifest(meeting: entry.meeting, destination: provider.id)
            guard !manifest.syncDisabled, manifest.migrationSource == nil, manifest.pendingVersions.isEmpty,
                  manifest.catalogDirty != true,
                  manifest.files[CloudLedger.mirrorName]?.version != version else { continue }
            // Never publish a catalog against an incomplete revision or discard a local edit.
            let incoming = placement.live.filter { manifest.files[$0.key]?.version != $0.value.version }
            guard incoming.keys.allSatisfy({ !CloudFiles.exists(directory.appendingPathComponent($0)) }) else { continue }
            for (name, file) in incoming {
                manifest.files[name] = file
                manifest.archived.insert(name)
            }
            manifest.files[CloudLedger.mirrorName] = CloudRemoteFile(id: id, version: version)
            if known {
                try manifest.save(directory)
            } else {
                let staging = root.appendingPathComponent(".rebuild-" + UUID().uuidString, isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(CloudManifest.filename), options: .atomic)
                try fm.moveItem(at: staging, to: directory)
                try manifest.save(directory)
                indexed[entry.meeting] = directory
            }
            try CloudLedger.current.importRemote(entry, folder: directory.lastPathComponent)
            changed = true
        }
        return changed
    }

    func context(for directories: [URL], destination: String) -> CloudContext {
        var context = CloudContext()
        let parents = Set(directories.map { $0.deletingLastPathComponent() })
        context.folderConflicts = Set(parents.flatMap { SyncConflicts.folderConflicts(in: $0) }.map { Self.key($0.url) })
        let candidates = directories + parents.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        let folders = Dictionary(candidates.map { (Self.key($0), $0) }, uniquingKeysWith: { first, _ in first }).values
        for folder in folders {
            if let manifest = try? CloudManifest.load(folder, destination: destination) {
                context.identityCounts[manifest.meeting, default: 0] += 1
            }
        }
        return context
    }

    /// - Parameters:
    ///   - force: ignores the retry backoff (a user asked for this now).
    ///   - resume: restarts uploads for a meeting whose cloud copy was explicitly removed. Only a per-meeting request may set it.
    enum SyncProgress: Sendable {
        case preparing(String)
        case uploading(String, sent: Int64?, total: Int64)
        case downloading(String, received: Int64?, total: Int64)
        case verifying(String)

        @TaskLocal static var uploadBytes: (@Sendable (Int64, Int64) async -> Void)?
        @TaskLocal static var downloadBytes: (@Sendable (Int64, Int64) async -> Void)?
        @TaskLocal static var update: (@Sendable (SyncProgress) async -> Void)?
    }

    func perform(_ action: CloudAction, directories: [URL], provider: any CloudStorageProvider,
                 options: CloudOptions, force: Bool = false, resume: Bool = false, context: CloudContext? = nil,
                 restoreOnly: Set<String>? = nil,
                 isActive: @escaping @Sendable (URL) async -> Bool = { _ in false }) async -> CloudReport {
        guard !running else { return CloudReport() }
        running = true
        defer { running = false }
        if force {
            // Sync now on one meeting re-checks that meeting, not the whole library.
            if directories.count == 1, let id = CloudSync.manifest(directories[0])?.meeting.rawValue.uuidString {
                verifiedAt = verifiedAt.filter { !$0.key.contains(id) }
            } else { verifiedAt.removeAll() }
        }
        let context = context ?? self.context(for: directories, destination: provider.id)
        audioCache.purge()
        removeStaleWork()
        var report = CloudReport()
        for dir in directories {
            do {
                guard CloudFiles.eligible(dir), !(await isActive(dir)) else {
                    report.statuses[dir.path] = String(localized: "Riunione in uso")
                    continue
                }
                Self.removeStaleTemporaries(dir)
                let loaded = try CloudManifest.load(dir, destination: provider.id)
                var manifest = loaded
                if action != .restore && action != .pin {
                    guard !context.folderConflicts.contains(Self.key(dir)),
                          SyncConflicts.originalName(dir.lastPathComponent) == nil,
                          SyncConflicts.scan(dir).isEmpty else { throw CloudError.message(String(localized: "Risolvi le copie in conflitto prima di sincronizzare")) }
                    guard (context.identityCounts[manifest.meeting] ?? 0) <= 1 else { throw CloudError.message(String(localized: "Identità cloud duplicata. Controlla le copie della riunione.")) }
                }
                if case .sync = action, manifest.syncDisabled, !resume { report.statuses[dir.path] = String(localized: "Sincronizzazione sospesa per questa riunione"); continue }
                if !force, let retry = manifest.nextAttempt, retry > Date() {
                    report.statuses[dir.path] = manifest.lastError ?? String(localized: "In attesa di connessione")
                    report.failures[dir.path] = manifest.lastError
                    continue
                }
                do {
                    switch action {
                    case .sync:
                        if resume { manifest.syncDisabled = false }
                        if force { try CloudProvenance.enrollLegacyRecording(dir) }
                        if options.archiveAfterSync {
                            try await restore(dir, manifest: &manifest, provider: provider, only: Set(CloudFiles.text), isActive: isActive)
                        }
                        try await sync(dir, manifest: &manifest, provider: provider, options: options, isActive: isActive)
                        if options.archiveAfterSync, !manifest.pinned,
                           (manifest.restoredAt ?? .distantPast) < Date().addingTimeInterval(-86400) {
                            let selected = try CloudFiles.names(in: dir, options: options)
                            let verifiedCandidates = Set(selected.filter { name in
                                CloudFiles.audio.contains(name) && manifest.files[name]?.encoding != CloudAudioEncoding.aac.rawValue
                            })
                            if !verifiedCandidates.isEmpty {
                                try await cleanUp(dir, manifest: &manifest, provider: provider, isActive: isActive, only: verifiedCandidates)
                            }
                        } else if !options.archiveAfterSync, cleanupDue(dir, manifest: manifest, options: options) {
                            try await cleanUp(dir, manifest: &manifest, provider: provider, isActive: isActive)
                        }
                    case .evict: try await evict(dir, manifest: &manifest, provider: provider, isActive: isActive)
                    case .reupload:
                        // The user chose to put the files deleted on the cloud back: forget the old records
                        // so each one is uploaded as a new file. Only files still on the Mac can be uploaded.
                        for name in (manifest.remoteDeleted ?? [:]).keys where CloudFiles.exists(dir.appendingPathComponent(name)) {
                            manifest.files[name] = nil; manifest.localStamps[name] = nil
                            manifest.pending[name] = nil; manifest.pendingVersions[name] = nil; manifest.pushed?[name] = nil
                            manifest.remoteDeleted?[name] = nil
                        }
                        if manifest.remoteDeleted?.isEmpty == true { manifest.remoteDeleted = nil }
                        try manifest.save(dir)
                        try await sync(dir, manifest: &manifest, provider: provider, options: options, isActive: isActive)
                    case .reclaim:
                        if reclaimable(dir, manifest: manifest, options: options) {
                            try await cleanUp(dir, manifest: &manifest, provider: provider, isActive: isActive)
                        }
                    case .restore: try await restore(dir, manifest: &manifest, provider: provider, only: restoreOnly, isActive: isActive)
                    case .pin:
                        manifest.pinned.toggle()
                        try manifest.save(dir)
                        if manifest.pinned { try await restore(dir, manifest: &manifest, provider: provider, isActive: isActive) }
                    case .deleteRemote:
                        guard !CloudFiles.content.contains(where: { manifest.files[$0] != nil && !CloudFiles.exists(dir.appendingPathComponent($0)) }) else {
                            throw CloudError.message(String(localized: "Scarica prima tutto l'audio. La copia cloud è l'unica disponibile."))
                        }
                        // Only delete committed objects whose bytes still match our local record.
                        // Pending IDs may now refer to somebody else's file on path-based providers.
                        var removable: [String] = []
                        for remote in manifest.files.values {
                            if let current = try await provider.inspect(remote.id) {
                                guard CloudVerification.matches(local: remote.version, remote: current) else {
                                    throw CloudError.message(String(localized: "Il file cloud è cambiato. Rimozione interrotta."))
                                }
                                removable.append(remote.id)
                            }
                        }
                        for id in Set(removable) { try await provider.remove(id) }
                        try? CloudLedger.current.markRemoved(manifest.meeting, folder: dir.lastPathComponent, destination: provider.id,
                                                            files: manifest.files.filter { removable.contains($0.value.id) }.map(\.key))
                        // Never recursively remove the folder: it may contain unrelated user files.
                        try await forgetSessions(manifest, provider: provider)
                        // Keep local files. Archived audio must be restored first.
                        manifest.files = [:]; manifest.localStamps = [:]; manifest.pending = [:]; manifest.pendingVersions = [:]; manifest.pushed = nil
                        manifest.folder = nil; manifest.folderReady = nil
                        manifest.syncDisabled = true; manifest.archived = []; manifest.lastError = nil
                        manifest.attempts = 0; manifest.nextAttempt = nil
                        try manifest.save(dir)
                        report.statuses[dir.path] = String(localized: "Copia cloud rimossa. File locali conservati.")
                        continue
                    }
                    manifest.attempts = 0; manifest.nextAttempt = nil; manifest.lastError = nil
                    // An unchanged meeting is not rewritten: a periodic write would churn Dropbox/iCloud/Syncthing
                    // and create the very conflict copies that block sync.
                    if manifest != loaded { try manifest.save(dir) }
                    report.statuses[dir.path] = CloudSync.describe(manifest)
                } catch {
                    let error = CloudError.classify(error)
                    // In use or cancelled: not this meeting's fault. No backoff, no manifest rewrite.
                    if error is CancellationError || (error as? CloudError)?.isBusy == true {
                        if manifest != loaded { try? manifest.save(dir) }
                        report.statuses[dir.path] = (error as? CloudError)?.localizedDescription ?? String(localized: "Sincronizzazione interrotta")
                        if error is CancellationError { return report }
                        continue
                    }
                    if let cloud = error as? CloudError, cloud.affectsDestination {
                        if manifest != loaded { try? manifest.save(dir) }
                        report.statuses[dir.path] = cloud.localizedDescription
                        report.stopped = cloud.localizedDescription
                        report.authExpired = cloud.needsReconnect
                        return report
                    }
                    manifest.attempts += 1
                    manifest.nextAttempt = Date().addingTimeInterval(min(3600, pow(2, Double(min(manifest.attempts, 10))) * 15))
                    manifest.lastError = error.localizedDescription
                    try manifest.save(dir)
                    throw error
                }
            } catch {
                report.statuses[dir.path] = error.localizedDescription
                report.failures[dir.path] = error.localizedDescription
            }
        }
        return report
    }

    /// The cloud holds a version of `name` this Mac did not upload, while the local file differs too.
    /// Neither is overwritten: the cloud's version is downloaded next to ours as a conflict copy, which the
    /// existing review ("Controlla copie in conflitto") lets the person resolve. Sync of the meeting waits
    /// for that, so the cloud's version is never replaced behind anyone's back. Always throws.
    private func keepRemoteVersion(_ dir: URL, name: String, old: CloudRemoteFile, remote: CloudFileVersion,
                                   manifest: inout CloudManifest, provider: any CloudStorageProvider,
                                   isActive: @Sendable (URL) async -> Bool) async throws {
        let remoteFile = Self.remoteName(name, encoded: old.encoding != nil)
        let ext = (remoteFile as NSString).pathExtension, base = (remoteFile as NSString).deletingPathExtension
        let host = String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "Mac")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let stamp = CloudTrash.stamp()
        let copyName = "\(base) (conflicted copy \(host.isEmpty ? "Mac" : host) \(stamp.prefix(8))-\(stamp.suffix(6)))" + (ext.isEmpty ? "" : "." + ext)
        let target = dir.appendingPathComponent(copyName)
        let temporary = dir.appendingPathComponent(".cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await provider.download(old.id, to: temporary)
        guard CloudVerification.matches(local: try provider.fingerprint(temporary), remote: remote) else {
            throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
        }
        try await check(dir, isActive)
        try FileManager.default.moveItem(at: temporary, to: target)
        // The cloud's version is now the known one: choosing the copy makes local match it, keeping both lets
        // the local file replace it knowingly, because the other version is safe in its own copy.
        manifest.files[name] = CloudRemoteFile(id: old.id, version: remote, encoding: old.encoding, source: old.source, format: old.format)
        try manifest.save(dir)
        try? CloudLedger.current.note(manifest.meeting, folder: dir.lastPathComponent,
                                      String(localized: "\(name) è cambiato anche nel cloud: la versione del cloud è stata salvata come \(copyName)"))
        throw CloudError.message(String(localized: "Un altro Mac ha modificato questo file nel cloud. Le due versioni sono conservate: controlla le copie in conflitto."))
    }

    /// Moves the cloud copies of a meeting deleted on the Mac to the service's trash. A file is removed only
    /// while its bytes still match what this Mac uploaded: somebody else's edit stays where it is.
    /// Errors leave the entry queued, to be retried on the next pass.
    func removeQueued(_ entry: CloudTrashEntry, provider: any CloudStorageProvider) async throws {
        var removed: [String] = []
        for item in entry.items {
            guard let current = try await provider.inspect(item.id) else { continue } // already gone
            guard CloudVerification.matches(local: item.version, remote: current) else { continue } // changed by someone else
            try await provider.remove(item.id)
            removed.append(item.name)
        }
        try? CloudLedger.current.markRemoved(entry.meeting, folder: entry.folder, destination: entry.destination, files: removed)
    }

    /// Automatic cleanup: when the audio is not ready to be freed (upload pending, changed), skip it
    /// this time instead of charging the meeting a retry delay that would also hold back its upload.
    private func cleanUp(_ dir: URL, manifest: inout CloudManifest, provider: any CloudStorageProvider,
                         isActive: @Sendable (URL) async -> Bool, only: Set<String>? = nil) async throws {
        // A cleanup that could not happen is not retried every minute: verifying means hashing gigabytes.
        let key = provider.id + "/" + manifest.meeting.rawValue.uuidString + "/cleanup"
        if let tried = verifiedAt[key], Date().timeIntervalSince(tried) < 6 * 3600 { return }
        do { try await evict(dir, manifest: &manifest, provider: provider, isActive: isActive, only: only) }
        catch let error as CloudError where !error.affectsDestination && !error.isBusy { verifiedAt[key] = Date() }
    }

    /// Partial downloads left by a crash or a forced quit: hidden, possibly gigabytes, synced by Dropbox
    /// or iCloud if left behind. The engine is serialized, so anything older than a few minutes is stale.
    static func removeStaleTemporaries(_ dir: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix(".cloud-") || file.lastPathComponent.hasPrefix(".migration-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < Date().addingTimeInterval(-600) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Automatic cleanup is conservative: audio must be uploaded, the meeting must stay readable offline
    /// (a transcript exists), and the age counts from the latest of recording, folder creation and last download.
    private func cleanupDue(_ dir: URL, manifest: CloudManifest, options: CloudOptions) -> Bool {
        guard options.cleanupDays > 0, options.audio, !manifest.pinned,
              CloudFiles.exists(dir.appendingPathComponent("transcript.md")),
              CloudFiles.audio.contains(where: { CloudFiles.exists(dir.appendingPathComponent($0)) }) else { return false }
        let created = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
        let dates = [CloudFiles.meetingDate(dir), created, manifest.restoredAt].compactMap { $0 }
        guard let reference = dates.max() else { return false }
        return reference < Date().addingTimeInterval(-Double(options.cleanupDays) * 86400)
    }

    /// Storage-limit cleanup follows the automatic-cleanup rules except age. Audio downloaded in the
    /// last day is kept, so a limit cannot undo a download the user just asked for.
    private func reclaimable(_ dir: URL, manifest: CloudManifest, options: CloudOptions) -> Bool {
        guard options.audio, !manifest.pinned,
              CloudFiles.exists(dir.appendingPathComponent("transcript.md")),
              CloudFiles.audio.contains(where: { CloudFiles.exists(dir.appendingPathComponent($0)) }) else { return false }
        return (manifest.restoredAt ?? .distantPast) < Date().addingTimeInterval(-86400)
    }

    /// Forgets a meeting's open upload sessions and discards what they stored (S3 bills unfinished parts).
    private func forgetSessions(_ manifest: CloudManifest, provider: any CloudStorageProvider) async throws {
        var entries = sessions.load()
        let prefix = manifest.meeting.rawValue.uuidString + "/"
        guard entries.keys.contains(where: { $0.hasPrefix(prefix) }) else { return }
        for (key, entry) in entries where key.hasPrefix(prefix) { try? await provider.abandonUpload(session: entry.session) }
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
        try sessions.save(entries)
    }

    /// Creates the meeting's own remote folder before its first file, when the provider supports folders.
    /// Meetings uploaded flat by an earlier version stay flat.
    private func prepareFolder(_ dir: URL, manifest: inout CloudManifest, provider: any CloudStorageProvider) async throws -> String? {
        if manifest.folder == nil, manifest.files.isEmpty, manifest.pending.isEmpty, let id = try await provider.reserveFolder() {
            manifest.folder = id
            try manifest.save(dir)
        }
        guard let folder = manifest.folder else { return nil }
        if manifest.folderReady != true {
            try await provider.createFolder(id: folder, name: CloudFiles.displayName(dir))
            manifest.folderReady = true
            try manifest.save(dir)
        }
        return folder
    }

    /// Uploads through a resumable session when the provider has one. A session survives errors and
    /// restarts, so the next attempt continues from the last byte the server stored.
    private func transfer(_ snapshot: URL, name: String, remoteName: String, id: String, parent: String?, replacing: Bool,
                          version: CloudFileVersion, manifest: CloudManifest, provider: any CloudStorageProvider) async throws {
        let key = CloudUploadSessions.key(manifest.meeting, name)
        var entries = sessions.load()
        if entries[key] == nil, let expired = sessions.loadAll()[key] {
            // Too old to resume: discard what it stored (S3 keeps and bills unfinished parts) and forget it.
            try? await provider.abandonUpload(session: expired.session)
            try sessions.save(entries)
        }
        if let open = entries[key], open.id == id, open.version == version {
            do { try await provider.resumeUpload(file: snapshot, session: open.session); return clear(key) }
            catch is CloudUploadExpired { entries[key] = nil; try sessions.save(entries) }
        } else if let stale = entries[key] {
            // The file changed since that session opened: discard its stored parts.
            try? await provider.abandonUpload(session: stale.session)
            entries[key] = nil; try sessions.save(entries)
        }
        if let session = try await provider.beginUpload(id: id, name: remoteName, parent: parent, replacing: replacing, version: version) {
            entries[key] = .init(id: id, session: session, version: version, created: Date())
            try sessions.save(entries)
            try await provider.resumeUpload(file: snapshot, session: session)
            return clear(key)
        }
        try await provider.upload(file: snapshot, id: id, name: remoteName, parent: parent, replacing: replacing)
    }
    private func clear(_ key: String) {
        var entries = sessions.load()
        if entries.removeValue(forKey: key) != nil { try? sessions.save(entries) }
    }

    /// Upload snapshots live here, so ones left by a crash can be found and removed.
    static let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("Overheard cloud", isDirectory: true)
    /// Snapshots and half-made encodings left by a crash or a forced quit: possibly gigabytes each.
    /// Runs before a pass, when the engine (serialized, one app copy per Mac) has nothing in flight.
    private func removeStaleWork() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-3600)
        let candidates = ((try? fm.contentsOfDirectory(at: Self.snapshots, includingPropertiesForKeys: nil)) ?? [])
            + ((try? fm.contentsOfDirectory(at: audioCache.directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".") }
        for file in candidates where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < old {
            try? fm.removeItem(at: file)
        }
    }

    /// Free space kept for recordings when the cloud needs room on the Mac.
    nonisolated(unsafe) static var reservedSpace: Int64 = 2_000_000_000

    private func check(_ dir: URL, _ active: @Sendable (URL) async -> Bool) async throws {
        try Task.checkCancellation()
        guard CloudFiles.eligible(dir), !(await active(dir)) else { throw CloudError.busy }
    }

    private func sync(_ dir: URL, manifest: inout CloudManifest, provider: any CloudStorageProvider,
                      options: CloudOptions, isActive: @Sendable (URL) async -> Bool) async throws {
        try CloudProvenance.validate(dir)
        // Repair checks run at most once a day per meeting and file; Sync now (force) runs them at once.
        let day: TimeInterval = 86400
        let folderKey = provider.id + "/" + manifest.meeting.rawValue.uuidString + "/folder"
        let folderDue = Date().timeIntervalSince(verifiedAt[folderKey] ?? .distantPast) >= day
        var folderExists = true
        if folderDue, let folder = manifest.folder { folderExists = try await provider.folderExists(folder) }
        if folderDue, manifest.folder != nil, folderExists { verifiedAt[folderKey] = Date() }
        if !folderExists {
            manifest.folder = nil; manifest.folderReady = nil
            if let id = try await provider.reserveFolder() {
                manifest.folder = id
                try manifest.save(dir)
                _ = try await prepareFolder(dir, manifest: &manifest, provider: provider)
            }
        }
        // A copy of this meeting's map travels with it. It goes last, written once the other files are
        // recorded, so the copy uploaded in this pass is already current (and rewritten only when it changed).
        let names = try CloudFiles.names(in: dir, options: options).filter { $0 != CloudLedger.mirrorName }
        let publishesCatalog = options.archiveAfterSync && provider is WebDAVProvider
        for name in names + [CloudLedger.mirrorName] {
            if name == CloudLedger.mirrorName {
                if publishesCatalog, manifest.files[name] != nil, manifest.catalogDirty != true { continue }
                try? CloudLedger.current.mirror(manifest.meeting, into: dir)
                guard CloudFiles.exists(dir.appendingPathComponent(name)) else { continue }
            }
            try await check(dir, isActive)
            let local = dir.appendingPathComponent(name)
            let stamp = try CloudLocalStamp.read(local)
            let known = manifest.files[name]
            // Deleted on the cloud side: wait for the user's choice instead of checking and uploading again.
            if known != nil, manifest.pending[name] == nil, manifest.remoteDeleted?[name] != nil { continue }
            let verificationKey = provider.id + "/" + manifest.meeting.rawValue.uuidString + "/" + name
            if known != nil, manifest.pendingVersions[name] == nil, manifest.localStamps[name] == stamp,
               let checked = verifiedAt[verificationKey], Date().timeIntervalSince(checked) < day { continue }
            var observed: CloudFileVersion?
            if let known {
                // Presence first (size only); the full digest only when something looks off.
                if let size = try await provider.size(known.id), size == known.version.byteCount { observed = known.version }
                else { observed = try await provider.inspect(known.id) }
                if observed == nil, manifest.pending[name] == nil {
                    var deleted = manifest.remoteDeleted ?? [:]
                    deleted[name] = deleted[name] ?? Date()
                    manifest.remoteDeleted = deleted
                    try manifest.save(dir)
                    continue
                }
            }
            if let known, observed == known.version, manifest.pendingVersions[name] == nil, manifest.localStamps[name] == stamp {
                verifiedAt[verificationKey] = Date()
                continue
            }
            if CloudFiles.audio.contains(name) {
                // The upload works on a snapshot, and encoding adds the compressed copy and a decoded check:
                // never at the cost of the room a recording needs.
                let encoded = manifest.files[name].map { $0.encoding != nil } ?? (options.audioEncoding != nil)
                let bytes = Int64(stamp.bytes) * (encoded ? 3 : 1) + Self.reservedSpace
                if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   free < bytes {
                    throw CloudError.destination(String(localized: "Poco spazio libero sul Mac: il caricamento dell'audio riprenderà quando ci sarà più spazio."))
                }
            }
            await SyncProgress.update?(.preparing(name))
            try FileManager.default.createDirectory(at: Self.snapshots, withIntermediateDirectories: true)
            let snapshot = Self.snapshots.appendingPathComponent(UUID().uuidString + ".wav")
            try FileManager.default.copyItem(at: local, to: snapshot)
            defer { try? FileManager.default.removeItem(at: snapshot) }
            guard CloudProvenance.accepts(local), try CloudFiles.version(snapshot) == CloudFiles.version(local) else { throw CloudError.message(String(localized: "File non valido")) }
            let old = manifest.files[name]
            // A file keeps the form it was first uploaded in. New audio follows the setting; when it
            // cannot be encoded (unknown format), the WAV itself is uploaded.
            var upload = snapshot, source: CloudFileVersion?, format: CloudAudioFormat?
            let encoding: CloudAudioEncoding? = old.map { $0.encoding.flatMap(CloudAudioEncoding.init(rawValue:)) } ?? options.audioEncoding
            var used: CloudAudioEncoding?
            if CloudFiles.audio.contains(name), let encoding {
                let wav = try CloudFiles.version(snapshot)
                if let old, observed == old.version, old.source == wav, manifest.pendingVersions[name] == nil {
                    manifest.localStamps[name] = stamp // touched, not changed: nothing to upload
                    manifest.archived.remove(name)
                    try manifest.save(dir)
                    continue
                }
                do {
                    (upload, format) = try audioCache.encoded(snapshot, source: wav, name: name, as: encoding)
                    source = wav
                    used = encoding
                } catch where old == nil {
                    upload = snapshot // not encodable: upload the original instead
                }
            }
            let version = try provider.fingerprint(upload)
            let id: String
            var fresh = false
            if let existing = (observed != nil ? old?.id : nil) ?? manifest.pending[name] { id = existing }
            else {
                _ = try await prepareFolder(dir, manifest: &manifest, provider: provider)
                id = try await provider.reserve(meeting: manifest.meeting, folder: dir.lastPathComponent, file: Self.remoteName(name, encoded: source != nil))
                manifest.pending[name] = id
                try manifest.save(dir)
                fresh = true
            }
            // A just-reserved ID cannot exist remotely yet. On WebDAV the probe would be a full GET.
            let remote = fresh ? nil : try await provider.inspect(id)
            if remote != version {
                let ours = remote.map { $0 == manifest.pendingVersions[name] || manifest.pushed?[name]?.contains($0) == true } ?? false
                if old == nil, remote != nil, !ours {
                    throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
                }
                if let old, let remote, remote != old.version, !ours {
                    // Another Mac (or person) changed this file in the cloud: keep both versions.
                    try await keepRemoteVersion(dir, name: name, old: old, remote: remote, manifest: &manifest, provider: provider, isActive: isActive)
                }
                if let previous = manifest.pendingVersions[name], previous != version {
                    var history = manifest.pushed ?? [:]
                    history[name] = Array(((history[name] ?? []) + [previous]).suffix(8))
                    manifest.pushed = history
                }
                manifest.pendingVersions[name] = version
                try manifest.save(dir)
                // Inside its own folder a file keeps its plain name. Flat layouts need the meeting in the name.
                let parent = manifest.folderReady == true ? manifest.folder : nil
                let file = Self.remoteName(name, encoded: source != nil)
                let remoteName = parent == nil ? "\(dir.lastPathComponent)-\(manifest.meeting.rawValue.uuidString)-\(file)" : file
                await SyncProgress.update?(.uploading(file, sent: nil, total: version.byteCount))
                // Encoding and snapshots took time: make sure nobody replaced the file meanwhile.
                if let remote { try await provider.expectUnchanged(id, remote) }
                if let webDAV = provider as? WebDAVProvider, let remote, options.archiveAfterSync {
                    try await webDAV.replace(file: upload, id: id, expected: remote)
                } else {
                    let update = SyncProgress.update
                    try await SyncProgress.$uploadBytes.withValue({ sent, total in
                        await update?(.uploading(file, sent: sent, total: total))
                    }) {
                        try await transfer(upload, name: name, remoteName: remoteName, id: id, parent: parent, replacing: remote != nil,
                                           version: version, manifest: manifest, provider: provider)
                    }
                }
            }
            await SyncProgress.update?(.verifying(name))
            guard let verified = try await provider.inspect(id), CloudVerification.matches(local: version, remote: verified) else {
                throw CloudError.message(String(localized: "Verifica del caricamento fallita. Copia locale conservata."))
            }
            let unchanged = try source.map { try CloudFiles.version(local) == $0 } ?? (try provider.fingerprint(local) == version)
            guard unchanged else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            manifest.files[name] = CloudRemoteFile(id: id, version: verified, encoding: used?.rawValue, source: source, format: format)
            if let source, let used { audioCache.remove(source, name: name, encoding: used) }
            manifest.localStamps[name] = stamp
            manifest.pending.removeValue(forKey: name)
            manifest.pendingVersions.removeValue(forKey: name)
            manifest.pushed?[name] = nil
            if manifest.pushed?.isEmpty == true { manifest.pushed = nil }
            clear(CloudUploadSessions.key(manifest.meeting, name)) // a lost response may have left its session behind
            manifest.archived.remove(name)
            if publishesCatalog { manifest.catalogDirty = name == CloudLedger.mirrorName ? nil : true }
            manifest.syncedAt = Date()
            verifiedAt[verificationKey] = Date()
            try manifest.save(dir)
        }
        for name in CloudFiles.content where manifest.files[name] != nil && !CloudFiles.exists(dir.appendingPathComponent(name)) {
            manifest.archived.insert(name)
            let archivedKey = provider.id + "/" + manifest.meeting.rawValue.uuidString + "/" + name + "/archived"
            if let checked = verifiedAt[archivedKey], Date().timeIntervalSince(checked) < day { continue }
            if let remote = manifest.files[name] {
                guard let size = try await provider.size(remote.id), size == remote.version.byteCount else {
                    // Not stamped: a missing only-copy keeps being reported until it is resolved.
                    throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. Download interrotto."))
                }
            }
            verifiedAt[archivedKey] = Date()
        }
    }

    private func evict(_ dir: URL, manifest: inout CloudManifest, provider: any CloudStorageProvider,
                       isActive: @Sendable (URL) async -> Bool, only: Set<String>? = nil) async throws {
        guard !manifest.pinned else { throw CloudError.message(String(localized: "Questa riunione deve restare su questo Mac")) }
        var verified: [(URL, String, CloudFileVersion)] = []
        for name in CloudFiles.content where only?.contains(name) ?? CloudFiles.audio.contains(name) {
            let url = dir.appendingPathComponent(name)
            guard CloudFiles.exists(url) else { continue }
            // Cheap first: a synced folder that has not uploaded yet needs no hashing to say no.
            if let remote = manifest.files[name], try await !provider.isSafelyStored(remote.id) {
                throw CloudError.message(String(localized: "Il servizio non ha ancora confermato il caricamento: l'audio resta sul Mac. Riprova più tardi."))
            }
            guard let remote = manifest.files[name], let current = try await provider.inspect(remote.id),
                  CloudVerification.matches(local: remote.version, remote: current),
                  try represents(url, remote, current, provider) else { throw CloudError.message(String(localized: "Audio non verificato nel cloud. Sincronizza prima di liberare spazio.")) }
            verified.append((url, name, current))
        }
        try await check(dir, isActive)
        // Save recovery information before removing any audio, including after a crash.
        for (_, name, _) in verified { manifest.archived.insert(name) }
        try manifest.save(dir)
        // If a check below stops the cleanup, audio still on the Mac must not stay marked as freed.
        defer {
            let kept = Set(verified.map(\.1).filter { CloudFiles.exists(dir.appendingPathComponent($0)) })
            if !kept.isEmpty, !kept.isDisjoint(with: manifest.archived) {
                manifest.archived.subtract(kept)
                try? manifest.save(dir)
            }
        }
        for (url, name, version) in verified {
            try await check(dir, isActive)
            guard let remote = manifest.files[name], try represents(url, remote, version, provider) else { throw CloudError.message(String(localized: "Audio modificato. Pulizia interrotta.")) }
            // Verification of the other track may take minutes: confirm the copy is still there now.
            guard let size = try await provider.size(remote.id), size == version.byteCount else {
                throw CloudError.message(String(localized: "Audio non verificato nel cloud. Sincronizza prima di liberare spazio."))
            }
            // A synced folder only counts once its app has uploaded the copy.
            guard try await provider.isSafelyStored(remote.id) else {
                throw CloudError.message(String(localized: "Il servizio non ha ancora confermato il caricamento: l'audio resta sul Mac. Riprova più tardi."))
            }
            try await check(dir, isActive)
            guard try represents(url, remote, version, provider) else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            try FileManager.default.removeItem(at: url)
            try? await provider.releaseLocalCopy(remote.id)
        }
        if !verified.isEmpty {
            try? CloudLedger.current.note(manifest.meeting, folder: dir.lastPathComponent,
                                          String(localized: "Audio liberato dal Mac, al sicuro su \(CloudSync.displayName(provider.id))"))
        }
    }

    /// Whether the local file is exactly what the verified cloud copy stands for: the same bytes, or
    /// for a compressed copy, the WAV it was encoded from.
    private func represents(_ local: URL, _ remote: CloudRemoteFile, _ current: CloudFileVersion, _ provider: any CloudStorageProvider) throws -> Bool {
        if remote.encoding != nil {
            guard let source = remote.source else { return false }
            return try CloudFiles.version(local) == source
        }
        return try provider.fingerprint(local) == current
    }
    static func remoteName(_ name: String, encoded: Bool) -> String {
        encoded ? (name as NSString).deletingPathExtension + ".m4a" : name
    }

    private func restore(_ dir: URL, manifest: inout CloudManifest, provider: any CloudStorageProvider,
                         only: Set<String>? = nil, isActive: @Sendable (URL) async -> Bool) async throws {
        // Downloading and decoding needs room for both copies: never at the cost of a recording in progress.
        let needed = CloudFiles.content.reduce(Self.reservedSpace) { sum, name in
            guard only?.contains(name) ?? true, let remote = manifest.files[name],
                  !CloudFiles.exists(dir.appendingPathComponent(name)) else { return sum }
            let factor: Int64 = remote.encoding == CloudAudioEncoding.aac.rawValue ? 16 : remote.encoding == nil ? 1 : 5
            return sum + remote.version.byteCount * (factor + 1)
        }
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw CloudError.destination(String(localized: "Poco spazio libero sul Mac: il download riprenderà quando ci sarà più spazio."))
        }
        for name in CloudFiles.content where only?.contains(name) ?? true {
            guard let remote = manifest.files[name] else { continue }
            let target = dir.appendingPathComponent(name)
            if CloudFiles.exists(target) { manifest.archived.remove(name); continue }
            guard let current = try await provider.inspect(remote.id),
                  CloudVerification.matches(local: remote.version, remote: current) else {
                throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. Download interrotto."))
            }
            let temporary = dir.appendingPathComponent(".cloud-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            // Size known up front, bytes received as they arrive (providers that stream report them).
            let shown = Self.remoteName(name, encoded: remote.encoding != nil), expected = remote.version.byteCount
            let update = SyncProgress.update
            await update?(.downloading(shown, received: nil, total: expected))
            try await SyncProgress.$downloadBytes.withValue({ received, total in
                await update?(.downloading(shown, received: received, total: total > 0 ? total : expected))
            }) {
                try await provider.download(remote.id, to: temporary)
            }
            await update?(.verifying(shown))
            guard CloudVerification.matches(local: try provider.fingerprint(temporary), remote: remote.version) else { throw CloudError.message(String(localized: "Audio scaricato non valido. Riprova.")) }
            var installed = temporary
            if remote.encoding != nil, CloudFiles.audio.contains(name) {
                guard let format = remote.format else { throw CloudError.message(String(localized: "Audio scaricato non valido. Riprova.")) }
                let m4a = temporary.appendingPathExtension("m4a"), wav = temporary.appendingPathExtension("wav")
                defer { try? FileManager.default.removeItem(at: m4a); try? FileManager.default.removeItem(at: wav) }
                try FileManager.default.moveItem(at: temporary, to: m4a)
                await update?(.preparing(name)) // rebuilding the original WAV from the lossless copy
                try CloudAudio.decode(m4a, to: wav, format: format)
                installed = wav
                try await check(dir, isActive)
                try FileManager.default.moveItem(at: installed, to: target)
                try CloudProvenance.record(target)
                // The cloud copy now stands for this decoded WAV: it is not uploaded again.
                var updated = remote
                updated.source = try CloudFiles.version(target)
                manifest.files[name] = updated
                manifest.localStamps[name] = try CloudLocalStamp.read(target)
            } else {
                try await check(dir, isActive)
                // moveItem fails if another writer has created the destination in the meantime.
                try FileManager.default.moveItem(at: installed, to: target)
                try CloudProvenance.record(target)
                manifest.localStamps[name] = try CloudLocalStamp.read(target)
            }
            manifest.archived.remove(name)
            if CloudFiles.audio.contains(name) { manifest.restoredAt = Date() }
            try manifest.save(dir)
            try? CloudLedger.current.note(manifest.meeting, folder: dir.lastPathComponent,
                                          String(localized: "\(name) riscaricato da \(CloudSync.displayName(provider.id))"))
        }
    }
}
