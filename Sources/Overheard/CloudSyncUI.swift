import AppKit
import Combine
import Network
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CloudAudioUse {
    private static var counts: [String: Int] = [:]
    static func begin(_ directory: URL) { counts[directory.path, default: 0] += 1 }
    static func end(_ directory: URL) { counts[directory.path] = max(0, (counts[directory.path] ?? 0) - 1) }
    static func contains(_ directory: URL) -> Bool { (counts[directory.path] ?? 0) > 0 }
}

/// Coordinates cloud work on the main actor. One meeting is processed at a time. A background pass
/// yields between meetings so a user action (download and play, retranscribe, export) waits for at
/// most one meeting instead of being dropped or blocked behind an hours-long first upload.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()
    @Published private(set) var sweeping = false
    @Published private(set) var progress = ""
    @Published private(set) var sweepFraction: Double?
    @Published private(set) var syncProgress: CloudSyncEngine.SyncProgress? { didSet { sampleRate() } }
    /// Bytes per second of the transfer in progress, smoothed; nil until a second of it has been seen.
    @Published private(set) var transferRate: Double?
    private var rateSample: (file: String, at: Date, bytes: Int64)?
    private func sampleRate() {
        let current: (String, Int64)?
        switch syncProgress {
        case .uploading(let file, let sent?, _)?: current = (file, sent)
        case .downloading(let file, let received?, _)?: current = (file, received)
        default: current = nil
        }
        guard let (file, bytes) = current else { rateSample = nil; transferRate = nil; return }
        let now = Date()
        guard let sample = rateSample, sample.file == file, bytes >= sample.bytes else {
            rateSample = (file, now, bytes); transferRate = nil; return
        }
        let seconds = now.timeIntervalSince(sample.at)
        guard seconds >= 1 else { return }
        let instant = Double(bytes - sample.bytes) / seconds
        transferRate = transferRate.map { $0 * 0.6 + instant * 0.4 } ?? instant
        rateSample = (file, now, bytes)
    }
    @Published private(set) var statuses: [String: String] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var requested: Set<String> = [] // meetings with a user action queued or running
    @Published var message = ""
    /// Meetings stored at another destination, asked once per old destination: copy, move or keep.
    @Published private(set) var transferPrompt: TransferPrompt?
    /// Meetings still on another destination, for the summary in Settings.
    @Published private(set) var elsewhere: [Elsewhere] = []
    /// Prompts dismissed with "Decide later": not asked again until the app restarts.
    private var postponed: Set<String> = []
    /// A choice made while a pass was running: another pass runs right after.
    private var rerun = false
    /// Meetings whose audio is only in the cloud, and meetings kept on this Mac. Filled off the main
    /// thread, so views never read manifests while rendering.
    @Published private(set) var archivedPaths: Set<String> = []
    @Published private(set) var remoteTranscriptPaths: Set<String> = []
    @Published private(set) var pinnedPaths: Set<String> = []
    /// Cancels the transfer in flight (a sync or a transfer to another service).
    private var cancelCurrent: (() -> Void)?
    /// Whether the pass running now was asked for (Sync now): automatic pauses do not apply to it.
    private var manualPass = false
    private var processLock: Int32 = -1
    /// Retry delay for meetings whose transfer to another service failed (kept in memory: a restart retries).
    private var migrationRetry: [String: (attempts: Int, next: Date)] = [:]
    private var recordingWatch: AnyCancellable?
    private var lastPassEnded = Date.distantPast
    /// Meeting being transferred right now. Not published: it changes once per meeting during a pass.
    private(set) var active: URL?
    private let engine = CloudSyncEngine()
    private var monitor: NWPathMonitor?
    private var timer: Timer?
    private var metered = false
    private var stopRequested = false
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var enabled: Bool { UserDefaults.standard.bool(forKey: "cloud.enabled") }
    var running: Bool { sweeping || !requested.isEmpty || purging }
    /// Syncing is not over while macOS is still uploading what Overheard copied into an iCloud or synced folder.
    var inProgress: Bool { running || cloudUpload != nil }
    /// What the app is doing right now, shown next to a spinner in Settings and in the library.
    var activity: String? {
        let upload = cloudUpload.map { String(localized: "iCloud ha caricato \($0.doneFiles) file su \($0.files)") }
        if !progress.isEmpty { return [progress, upload].compactMap { $0 }.joined(separator: " · ") }
        if let task { return task }
        if purging { return String(localized: "Elimino le copie cloud…") }
        if exporting { return String(localized: "Esportazione in corso…") }
        if sweeping { return String(localized: "Controllo le riunioni…") }
        if !requested.isEmpty { return String(localized: "Trasferimento in corso…") }
        // The copy into the folder is done, but the sync is not: it ends when macOS has uploaded everything.
        return upload
    }
    /// What this pass has to upload, in bytes. The bar shows how much of it is done, not which meeting the pass is at:
    /// meetings already in the cloud cost nothing, so a new pass does not start over from zero.
    private struct PassBytes { var total: Int64; var done: Int64 = 0; var current: Int64 = 0 }
    @Published private var passBytes: PassBytes?

    /// The bar, from real numbers: bytes iCloud reports as uploaded; else bytes this pass has sent of those it has
    /// to send (the meeting in progress counts by how much of its current file went); else nothing is claimed.
    var activityFraction: Double? {
        if let cloudUpload { return cloudUpload.fraction }
        guard let pass = passBytes, pass.total > 0 else { return nil }
        var inProgress: Int64 = 0
        if case .uploading(_, let sent, let total)? = syncProgress, let sent, total > 0 {
            inProgress = Int64(Double(min(sent, total)) / Double(total) * Double(pass.current))
        }
        return min(1, Double(pass.done + inProgress) / Double(pass.total))
    }

    /// Bytes of a meeting still to upload: files never uploaded or changed since (what a pass would send).
    nonisolated static func pendingBytes(_ dir: URL, options: CloudOptions) -> Int64 {
        let manifest = manifest(dir)
        var total: Int64 = 0
        for name in (try? CloudFiles.names(in: dir, options: options)) ?? [] {
            guard manifest?.remoteDeleted?[name] == nil, let stamp = try? CloudLocalStamp.read(dir.appendingPathComponent(name)) else { continue }
            if manifest?.files[name] == nil || manifest?.pendingVersions[name] != nil || manifest?.localStamps[name] != stamp {
                total += Int64(stamp.bytes)
            }
        }
        return total
    }

    /// Upload state of the synced folder (iCloud Drive), while files are still waiting to leave the Mac.
    @Published private(set) var cloudUpload: LocalFolderProvider.UploadState?
    private var uploadWatch: Task<Void, Never>?
    /// Reads what macOS says about the files Overheard wrote, now and every few seconds until all are uploaded.
    func refreshCloudUpload() {
        uploadWatch?.cancel()
        uploadWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.enabled, let local = (try? await self.provider()) as? LocalFolderProvider else {
                    self?.cloudUpload = nil; return
                }
                let state = await Task.detached(priority: .utility) { local.uploadState() }.value
                self.cloudUpload = state.pendingFiles > 0 ? state : nil
                guard state.pendingFiles > 0 else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    var root: URL { URL(fileURLWithPath: "\(home)/Meetings") }

    func start() {
        guard monitor == nil else { return }
        // Meetings synced before the map existed join it once; afterwards every saved state does.
        let root = self.root
        Task.detached(priority: .utility) {
            // A rebuild interrupted by a crash leaves its hidden staging folder in ~/Meetings.
            for stale in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
                where stale.lastPathComponent.hasPrefix(".rebuild-") { try? FileManager.default.removeItem(at: stale) }
            CloudSync.fillMap(root)
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied, metered = path.isExpensive || path.isConstrained
            Task { @MainActor in
                let sync = CloudSync.shared
                sync.metered = metered
                // Wi-Fi gone, iPhone hotspot on: an automatic upload already running stops too.
                if metered { sync.pauseAutomatic() }
                if online { await sync.perform(.sync) }
            }
        }
        // A call is being recorded: its upload bandwidth is not ours to take.
        recordingWatch = Recorder.shared.$recording.sink { recording in
            if recording { Task { @MainActor in CloudSync.shared.pauseAutomatic() } }
        }
        monitor.start(queue: DispatchQueue(label: "overheard.cloud.network"))
        refreshCloudUpload() // files left uploading by an earlier run show up again after a restart
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await CloudSync.shared.perform(.sync) }
        }
    }
    /// Dropbox is the default: it connects in one click and only sees its own app folder.
    nonisolated static var kind: String { UserDefaults.standard.string(forKey: "cloud.provider") ?? "dropbox" }
    func provider(kind: String = CloudSync.kind) async throws -> any CloudStorageProvider {
        let defaults = UserDefaults.standard
        switch kind {
        case "webdav":
            guard let url = Self.webDAVURL(defaults.string(forKey: "cloud.webdav.url") ?? "") else {
                throw CloudError.message(String(localized: "Inserisci l'URL HTTPS della cartella WebDAV nelle impostazioni"))
            }
            let username = defaults.string(forKey: "cloud.webdav.user") ?? ""
            guard let data = try CloudKeychain.read(Self.webDAVAccount(url, username)), let password = String(data: data, encoding: .utf8) else {
                throw CloudError.message(String(localized: "Salva le credenziali WebDAV nelle impostazioni"))
            }
            return WebDAVProvider(endpoint: url, username: username, password: password)
        case "s3":
            let key = (defaults.string(forKey: "cloud.s3.key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = (defaults.string(forKey: "cloud.s3.bucket") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: (defaults.string(forKey: "cloud.s3.endpoint") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                  S3Provider.validEndpoint(url), S3Provider.validBucket(bucket), !key.isEmpty else {
                throw CloudError.message(String(localized: "Completa endpoint, bucket e chiave S3 nelle impostazioni"))
            }
            guard let data = try CloudKeychain.read("s3:\(key)"), let secret = String(data: data, encoding: .utf8) else {
                throw CloudError.message(String(localized: "Salva le credenziali S3 nelle impostazioni"))
            }
            return S3Provider(endpoint: url, region: (defaults.string(forKey: "cloud.s3.region") ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              bucket: bucket, prefix: defaults.string(forKey: "cloud.s3.prefix") ?? "Overheard", accessKey: key, secret: secret)
        case "onedrive":
            let credentials = try await OneDriveAccount.shared.credentials()
            return OneDriveProvider(accountID: credentials.accountID)
        case "icloud":
            return LocalFolderProvider.iCloud()
        case "folder":
            guard let path = defaults.string(forKey: "cloud.folder.path")?.nilIfEmpty else {
                throw CloudError.message(String(localized: "Scegli la cartella sincronizzata nelle impostazioni"))
            }
            return LocalFolderProvider(kind: .folder, base: URL(fileURLWithPath: path, isDirectory: true))
        case "drive":
            let credentials = try await DriveAccount.shared.credentials()
            guard let folder = defaults.string(forKey: "cloud.drive.folder")?.nilIfEmpty else {
                throw CloudError.destination(String(localized: "ID Google Drive non valido"))
            }
            return GoogleDriveProvider(folder: folder, accountID: credentials.accountID)
        default:
            let credentials = try await DropboxAccount.shared.credentials()
            return DropboxProvider(accountID: credentials.accountID)
        }
    }
    private func originalProvider(_ destination: String) async throws -> any CloudStorageProvider {
        if destination.hasPrefix("drive:") {
            let parts = destination.split(separator: ":", maxSplits: 2).map(String.init)
            let credentials = try await DriveAccount.shared.credentials()
            if parts.count == 3, credentials.accountID == parts[1] {
                return GoogleDriveProvider(folder: parts[2], accountID: credentials.accountID)
            }
        } else {
            let kind = String(destination.prefix(while: { $0 != ":" }))
            let candidate = try await provider(kind: kind)
            if candidate.id == destination { return candidate }
        }
        throw CloudError.message(String(localized: "Ricollega la destinazione cloud originale prima di trasferire le riunioni."))
    }

    struct TransferPrompt: Identifiable, Equatable {
        let source: String, target: String, sourceName: String, targetName: String, count: Int
        var id: String { target + "\n" + source }
    }
    struct Elsewhere: Identifiable, Equatable {
        let source: String, name: String, count: Int, choice: TransferChoice?
        var id: String { source }
    }
    enum TransferChoice: String, Sendable { case copy, move, keep }

    /// Choices are remembered per (current destination, old destination), so a transfer resumes after a
    /// restart without asking again, and "keep" is never asked again for that pair.
    nonisolated static func choice(target: String, source: String) -> TransferChoice? {
        let all = UserDefaults.standard.dictionary(forKey: "cloud.transfers") as? [String: String] ?? [:]
        return all[target + "\n" + source].flatMap(TransferChoice.init(rawValue:))
    }
    nonisolated static func setChoice(_ choice: TransferChoice?, target: String, source: String) {
        var all = UserDefaults.standard.dictionary(forKey: "cloud.transfers") as? [String: String] ?? [:]
        all[target + "\n" + source] = choice?.rawValue
        UserDefaults.standard.set(all, forKey: "cloud.transfers")
    }
    /// Where a meeting's files are: the destination its transfer started from, or the one it is tied to.
    nonisolated static func source(of manifest: CloudManifest) -> (destination: String, inProgress: Bool) {
        if let data = manifest.migrationSource, let original = try? JSONDecoder().decode(CloudManifest.self, from: data) {
            return (original.destination, true)
        }
        return (manifest.destination, false)
    }
    /// A destination as people know it: "Google Drive", "Dropbox", "the “Aruba Drive” folder"…
    nonisolated static func displayName(_ destination: String) -> String {
        let kind = String(destination.prefix(while: { $0 != ":" }))
        let rest = String(destination.dropFirst(kind.count + 1))
        switch kind {
        case "drive": return "Google Drive"
        case "dropbox": return "Dropbox"
        case "onedrive": return "OneDrive"
        case "icloud": return "iCloud Drive"
        case "folder": return String(localized: "la cartella “\(URL(fileURLWithPath: rest).lastPathComponent)”")
        case "webdav": return URL(string: rest.components(separatedBy: ":").prefix(2).joined(separator: ":"))?.host ?? "WebDAV"
        case "s3": return "S3"
        default: return String(localized: "un altro servizio")
        }
    }
    /// The name with the account, when it is the one connected now ("Google Drive (name@gmail.com)").
    private func describe(_ destination: String) async -> String {
        let name = Self.displayName(destination)
        let parts = destination.split(separator: ":", maxSplits: 2).map(String.init)
        var email: String?
        switch parts.first {
        case "drive": if let c = try? await DriveAccount.shared.credentials(), parts.count > 1, c.accountID == parts[1] { email = c.email }
        case "dropbox": if let c = try? await DropboxAccount.shared.credentials(), destination == "dropbox:\(c.accountID)" { email = c.email }
        case "onedrive": if let c = try? await OneDriveAccount.shared.credentials(), destination == "onedrive:\(c.accountID)" { email = c.email }
        default: break
        }
        return email.map { "\(name) (\($0))" } ?? name
    }

    private var meetingDirectories: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("20") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    /// The service that holds a meeting's cloud copies right now: the current one, or the one it stayed on.
    private func holder(of manifest: CloudManifest, current: (any CloudStorageProvider)?) async -> (any CloudStorageProvider)? {
        if let current, manifest.destination == current.id { return current }
        return try? await originalProvider(manifest.destination)
    }
    @Published private(set) var exporting = false

    /// Brings back to the Mac all the audio that is only in the cloud, for meetings on `source`
    /// (the current destination or one they stayed on). One meeting at a time, with a room check.
    func downloadAll(from source: String) async {
        let dirs = await Task.detached { [root] in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("20") && CloudSync.hasArchivedContent($0) && CloudSync.manifest($0)?.destination == source }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }.value
        guard !dirs.isEmpty else { message = String(localized: "Tutto l'audio è già sul Mac."); return }
        let needed = dirs.reduce(Int64(1_000_000_000)) { total, dir in
            total + CloudFiles.content.reduce(Int64(0)) { sum, name in
                guard let remote = Self.manifest(dir)?.files[name], !CloudFiles.exists(dir.appendingPathComponent(name)) else { return sum }
                return sum + remote.version.byteCount * (remote.encoding == CloudAudioEncoding.aac.rawValue ? 16 : remote.encoding == nil ? 1 : 5)
            }
        }
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard available >= needed else {
            message = String(localized: "Spazio insufficiente sul Mac per trasferire le riunioni: servono circa \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) liberi.")
            return
        }
        let current = try? await provider()
        var done = 0
        for (index, dir) in dirs.enumerated() {
            progress = String(localized: "Scarico l'audio sul Mac: riunione \(index + 1) di \(dirs.count)")
            guard let manifest = Self.manifest(dir), let holder = await holder(of: manifest, current: current) else { continue }
            requested.insert(dir.path)
            await acquire()
            active = dir
            let report = await engine.perform(.restore, directories: [dir], provider: holder, options: options, force: true, isActive: isActive)
            active = nil
            release()
            requested.remove(dir.path)
            apply(report); refreshFlags(dir)
            if let stopped = report.stopped { message = stopped; progress = ""; return }
            if !Self.hasArchivedContent(dir) { done += 1 }
        }
        progress = ""
        message = String(localized: "Audio scaricato sul Mac: \(done) riunioni su \(dirs.count).")
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }

    /// Writes all meetings (or those on `source`) to one ZIP, cloud-only audio included. ~/Meetings is untouched.
    func exportZip(to url: URL, source: String? = nil) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false; progress = "" }
        let all = meetingDirectories
        let dirs = source.map { source in all.filter { Self.manifest($0)?.destination == source } } ?? all
        guard !dirs.isEmpty else { message = String(localized: "Nessuna riunione da esportare."); return }
        let needed = await Task.detached { CloudExport.estimatedBytes(dirs) }.value
        let available = (try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard available >= needed else {
            message = String(localized: "Spazio insufficiente per lo ZIP: servono circa \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) liberi.")
            return
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("Overheard export " + UUID().uuidString, isDirectory: true)
        let folder = staging.appendingPathComponent("Overheard", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let current = try? await provider()
        var skipped = 0
        do {
            for (index, dir) in dirs.enumerated() {
                progress = String(localized: "Preparo lo ZIP: riunione \(index + 1) di \(dirs.count)")
                let manifest = Self.manifest(dir)
                var holder: (any CloudStorageProvider)?
                if let manifest { holder = await self.holder(of: manifest, current: current) }
                await acquire() // no cleanup can free this meeting's audio while it is being copied
                defer { release() }
                skipped += try await CloudExport.stage(dir, into: folder, manifest: manifest, provider: holder)
            }
            // The map of the recordings travels with them.
            let map = folder.appendingPathComponent(String(localized: "Mappa delle registrazioni"), isDirectory: true)
            if FileManager.default.fileExists(atPath: CloudLedger.current.directory.path) {
                try? FileManager.default.copyItem(at: CloudLedger.current.directory, to: map)
            }
            progress = String(localized: "Creazione dello ZIP…")
            try await Task.detached { try CloudExport.zip(folder, to: url) }.value
            message = skipped == 0
                ? String(localized: "Esportate \(dirs.count) riunioni in \(url.lastPathComponent).")
                : String(localized: "Esportate \(dirs.count) riunioni in \(url.lastPathComponent). \(skipped) file audio mancano: il loro servizio non è collegato.")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { message = error.localizedDescription }
    }

    @Published private(set) var purging = false

    /// "Remove from the cloud, keep everything on this Mac": for each meeting, the copies on every service
    /// it was ever synced to (or only on `only`) are deleted after checking the audio is on the Mac, and
    /// the meeting forgets them. Without `only`, cloud sync is turned off: Overheard keeps everything local.
    /// A meeting whose service is not connected, or whose audio is only in the cloud, is left as it is.
    func purgeCloud(only: String? = nil) async {
        guard !purging else { return }
        guard ownsProcessLock() else {
            message = String(localized: "Un'altra copia di Overheard aperta su questo Mac sta già sincronizzando. Chiudine una.")
            return
        }
        let current = try? await provider()
        if let only, only == current?.id {
            message = String(localized: "È il servizio in uso: spegni la sincronizzazione o scegline un altro, poi elimina da lì.")
            return
        }
        purging = true
        defer { purging = false; progress = "" }
        if only == nil { UserDefaults.standard.set(false, forKey: "cloud.enabled") } // no new uploads meanwhile
        stop()
        progress = String(localized: "Attendo la fine del trasferimento in corso…")
        let dirs = meetingDirectories
        var providers: [String: any CloudStorageProvider] = [:], unreachable: [String: String] = [:] // destination → reason
        var failures: [String: Int] = [:] // consecutive failures per destination
        var cleaned = 0, skipped: [String: String] = [:] // folder → reason
        let fm = FileManager.default
        meetings: for (index, dir) in dirs.enumerated() {
            // The whole meeting under the lock, records read inside it: a pass that held the lock first may
            // just have uploaded files, and nothing can upload between the deletions and the cleanup.
            requested.insert(dir.path)
            await acquire()
            active = dir
            defer { active = nil; release(); requested.remove(dir.path) }
            // Every record of copies: the current manifest, a transfer's origin, a Move still pending, old destinations.
            var records: [CloudManifest] = []
            let stored = Self.manifest(dir)
            if let stored {
                records.append(stored)
                for data in [stored.migrationSource, stored.pendingRemoval].compactMap({ $0 }) {
                    if let old = try? JSONDecoder().decode(CloudManifest.self, from: data) { records.append(old) }
                }
            }
            let archives = dir.appendingPathComponent(".overheard-cloud-destinations")
            for file in (try? fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)) ?? [] {
                if let old = try? JSONDecoder().decode(CloudManifest.self, from: Data(contentsOf: file)) { records.append(old) }
            }
            if let only { records = records.filter { $0.destination == only } }
            records = records.filter { !$0.files.isEmpty }
            guard !records.isEmpty else { continue }
            var complete = true
            for record in records {
                let name = Self.displayName(record.destination)
                progress = String(localized: "Elimino da \(name): riunione \(index + 1) di \(dirs.count)")
                var holder = providers[record.destination]
                if holder == nil, unreachable[record.destination] == nil {
                    do {
                        holder = current?.id == record.destination ? current : try await originalProvider(record.destination)
                        providers[record.destination] = holder
                    } catch { unreachable[record.destination] = CloudError.classify(error).localizedDescription }
                }
                guard let holder else { complete = false; continue }
                do {
                    let kept = try await engine.purge(dir, record: record, provider: holder, isActive: isActive)
                    failures[record.destination] = 0
                    if !kept.isEmpty {
                        complete = false
                        skipped[dir.lastPathComponent] = String(localized: "alcuni file esistono solo nel cloud o sono stati modificati lì: lasciati nel cloud")
                    }
                } catch is CancellationError {
                    complete = false
                    skipped[dir.lastPathComponent] = String(localized: "Sincronizzazione interrotta")
                    break meetings
                } catch {
                    complete = false
                    let error = CloudError.classify(error)
                    // The exact error goes into the map, so a failure can always be explained afterwards.
                    try? CloudLedger.current.note(record.meeting, folder: dir.lastPathComponent,
                                                  String(localized: "Eliminazione da \(name) non riuscita: \(String(describing: error))"))
                    failures[record.destination, default: 0] += 1
                    if let cloud = error as? CloudError, cloud.isBusy {
                        skipped[dir.lastPathComponent] = error.localizedDescription
                    } else if (error as? CloudError)?.affectsDestination == true || failures[record.destination, default: 0] >= 2 {
                        // Offline, signed out, the same failure twice in a row: the service is out for this run.
                        unreachable[record.destination] = error.localizedDescription
                        providers[record.destination] = nil
                    } else {
                        skipped[dir.lastPathComponent] = error.localizedDescription
                        set(dir.path, error.localizedDescription)
                    }
                }
            }
            guard complete else { continue }
            // Nothing of this meeting is left on those services: it forgets them.
            if let only {
                try? fm.removeItem(at: CloudManifest.archiveURL(dir, destination: only))
                if var stored = Self.manifest(dir) {
                    func references(_ data: Data?) -> Bool {
                        data.flatMap { try? JSONDecoder().decode(CloudManifest.self, from: $0) }?.destination == only
                    }
                    // A transfer or pending Move from the emptied service has nothing left to do.
                    if references(stored.migrationSource) { stored.migrationSource = nil; stored.rearchive = nil }
                    if references(stored.pendingRemoval) { stored.pendingRemoval = nil }
                    try? stored.save(dir)
                }
            } else {
                try? fm.removeItem(at: dir.appendingPathComponent(CloudManifest.filename))
                try? fm.removeItem(at: archives)
                try? fm.removeItem(at: dir.appendingPathComponent(CloudLedger.mirrorName))
            }
            statuses.removeValue(forKey: dir.path)
            failures.removeValue(forKey: dir.path)
            refreshFlags(dir)
            cleaned += 1
        }
        if only == nil { UserDefaults.standard.removeObject(forKey: "cloud.transfers") }
        else if let only, let target = current?.id { Self.setChoice(nil, target: target, source: only) }
        elsewhere.removeAll { only == nil || $0.source == only }
        transferPrompt = nil
        var text = String(localized: "Copie cloud eliminate per \(cleaned) riunioni. Tutto resta sul Mac.")
        for (destination, reason) in unreachable.sorted(by: { $0.key < $1.key }) {
            text += " " + String(localized: "Copie rimaste su \(Self.displayName(destination)): \(reason) Riprova più tardi: riparte da dove si è fermata.")
        }
        // Grouped by reason, so the cause is visible instead of a list of names.
        for (reason, folders) in Dictionary(grouping: skipped.keys, by: { skipped[$0] ?? "" }).sorted(by: { $0.value.count > $1.value.count }) {
            text += " " + String(localized: "Non eliminate (\(folders.count)): \(reason)")
        }
        message = text
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }

    /// Meetings in the map whose folder is no longer on the Mac but whose files are still in the cloud.
    struct Recoverable: Identifiable, Sendable {
        let entry: CloudLedger.Entry
        let placement: CloudLedger.Placement
        var id: UUID { entry.id }
        var name: String { CloudSync.displayName(placement.destination) }
    }
    func recoverable() async -> [Recoverable] {
        let root = self.root, current = try? await provider().id
        return await Task.detached {
            CloudLedger.current.entries().compactMap { entry -> Recoverable? in
                let folder = root.appendingPathComponent(entry.folder)
                if CloudSync.manifest(folder)?.meeting == entry.meeting { return nil }
                let places = entry.placements.values.filter { !$0.live.isEmpty }
                guard let place = places.first(where: { $0.destination == current }) ?? places.max(by: { $0.lastSeen < $1.lastSeen }) else { return nil }
                return Recoverable(entry: entry, placement: place)
            }
        }.value
    }
    func rebuild(_ item: Recoverable) async -> Bool {
        do {
            let current = try? await provider()
            let holder: any CloudStorageProvider = current?.id == item.placement.destination
                ? current! : try await originalProvider(item.placement.destination)
            await acquire()
            defer { release() }
            let folder = try await engine.rebuild(item.entry, from: item.placement, provider: holder, into: root)
            message = String(localized: "Riunione ripristinata: \(folder.lastPathComponent).")
            NotificationCenter.default.post(name: .meetingsChanged, object: nil)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    func chooseTransfer(_ choice: TransferChoice) async {
        guard let prompt = transferPrompt else { return }
        Self.setChoice(choice, target: prompt.target, source: prompt.source)
        transferPrompt = nil
        if sweeping { rerun = true; stopRequested = true; return } // the running pass stops between meetings, then this runs
        await sweep(manual: true)
    }
    func postponeTransfer() {
        if let prompt = transferPrompt { postponed.insert(prompt.id) }
        transferPrompt = nil
    }
    /// "Change" in Settings: forget the choice for that old destination and ask again.
    func reconsider(_ source: String) async {
        guard let target = try? await provider().id else { return }
        Self.setChoice(nil, target: target, source: source)
        postponed.remove(target + "\n" + source)
        let count = elsewhere.first { $0.source == source }?.count ?? 1
        transferPrompt = TransferPrompt(source: source, target: target, sourceName: await describe(source),
                                        targetName: Self.displayName(target), count: count)
    }
    private func ask(source: String, target: String, count: Int) async {
        guard transferPrompt == nil, !postponed.contains(target + "\n" + source) else { return }
        transferPrompt = TransferPrompt(source: source, target: target, sourceName: await describe(source),
                                        targetName: Self.displayName(target), count: count)
    }

    /// Opens the provider's authenticated folder view. This never makes a folder public.
    func openRemote(_ directory: URL, copyLink: Bool = false) async {
        do {
            let provider = try await provider()
            let manifest = try CloudManifest.load(directory, destination: provider.id)
            guard !manifest.files.isEmpty else { throw CloudError.message(String(localized: "In attesa di sincronizzazione")) }
            let url: URL?
            if let local = provider as? LocalFolderProvider {
                let folder = local.root.appendingPathComponent(directory.lastPathComponent)
                if copyLink { throw CloudError.message(String(localized: "Apri questa destinazione nel client del servizio cloud.")) }
                NSWorkspace.shared.activateFileViewerSelecting([CloudFiles.exists(folder) ? folder : local.root])
                return
            }
            if provider.id.hasPrefix("drive:"), let folder = manifest.folder {
                url = URL(string: "https://drive.google.com/drive/folders/" + folder)
            } else if provider.id.hasPrefix("dropbox:") {
                var components = URLComponents(string: "https://www.dropbox.com/home/Apps/Overheard/" + directory.lastPathComponent)
                components?.query = nil
                url = components?.url
            } else {
                throw CloudError.message(String(localized: "Apri questa destinazione nel client del servizio cloud."))
            }
            guard let url else { return }
            if copyLink {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                message = String(localized: "Link copiato. L'accesso richiede l'account cloud.")
            } else { NSWorkspace.shared.open(url) }
        } catch { message = error.localizedDescription }
    }
    /// Records every meeting's manifest, and the snapshots of destinations it lived on before, in the map.
    nonisolated static func fillMap(_ root: URL) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where dir.lastPathComponent.hasPrefix("20") {
            let archives = dir.appendingPathComponent(".overheard-cloud-destinations")
            for file in (try? fm.contentsOfDirectory(at: archives, includingPropertiesForKeys: nil)) ?? [] {
                if let old = try? JSONDecoder().decode(CloudManifest.self, from: Data(contentsOf: file)) {
                    try? CloudLedger.current.record(old, directory: dir)
                }
            }
            if let manifest = manifest(dir) { try? CloudLedger.current.record(manifest, directory: dir) }
        }
    }
    nonisolated static func webDAVURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    nonisolated static func webDAVAccount(_ url: URL, _ username: String) -> String { "webdav:\(url.absoluteString):\(username)" }

    private var options: CloudOptions {
        let defaults = UserDefaults.standard
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
        return CloudOptions(audio: flag("cloud.audio"), transcript: flag("cloud.transcript"), summary: flag("cloud.summary"),
                            bookmarks: flag("cloud.bookmarks"), otherText: flag("cloud.otherText"),
                            audioEncoding: { switch defaults.string(forKey: "cloud.audioFormat") {
                                case "wav": return nil
                                case "aac": return Self.kind == "folder" ? .aac : .alac
                                default: return .alac } }(),
                            cleanupDays: defaults.integer(forKey: "cloud.cleanupDays"), archiveAfterSync: Self.kind != "folder")
    }
    /// A pass stops as soon as the destination or the file selection changes under it.
    private var settings: String {
        let d = UserDefaults.standard
        return ["cloud.provider", "cloud.drive.folder", "cloud.folder.path", "cloud.webdav.url", "cloud.webdav.user", "cloud.s3.endpoint", "cloud.s3.region", "cloud.s3.bucket", "cloud.s3.prefix", "cloud.s3.key", "cloud.audio", "cloud.transcript", "cloud.summary", "cloud.bookmarks", "cloud.otherText", "cloud.audioFormat", "cloud.cleanupDays", "cloud.storageLimitGB"]
            .map { "\(d.object(forKey: $0) ?? "")" }.joined(separator: "|")
    }
    private let isActive: @Sendable (URL) async -> Bool = { dir in
        await MainActor.run { Recorder.shared.isRecording(dir) || CloudAudioUse.contains(dir) }
    }

    /// With a meeting: a user action, queued behind at most the meeting in transfer. Without: a background pass.
    func perform(_ action: CloudAction, meeting: URL? = nil, force: Bool = false, restoreOnly: Set<String>? = nil) async {
        guard enabled else { return }
        guard ownsProcessLock() else {
            message = String(localized: "Un'altra copia di Overheard aperta su questo Mac sta già sincronizzando. Chiudine una.")
            return
        }
        if let meeting {
            // Its own task, so this one action can be cancelled without touching the others.
            let id = UUID()
            let work = Task { await self.run(action, on: meeting, restoreOnly: restoreOnly) }
            actionTasks[id] = (meeting.path, work)
            await work.value
            actionTasks[id] = nil
        } else if action == .sync { await sweep(manual: force) }
    }
    /// Actions on one meeting, queued or running, by the meeting they act on.
    private var actionTasks: [UUID: (path: String, task: Task<Void, Never>)] = [:]
    /// Stops the pass, including the transfer in flight (resumable uploads continue next time).
    func stop() { stopRequested = true; cancelCurrent?() }
    /// Cancels what is queued or running for one meeting. A download stops and its partial file is dropped.
    func cancelAction(_ path: String) {
        for entry in actionTasks.values where entry.path == path { entry.task.cancel() }
    }
    /// Cancels every queued and running transfer, and the background pass.
    func cancelAllTransfers() {
        for entry in actionTasks.values { entry.task.cancel() }
        stop()
    }
    func isTransferring(_ directory: URL) -> Bool { active?.path == directory.path }

    /// Queued and running actions, the one in progress first, for the transfers list.
    struct Transfer: Identifiable { let id: String; let label: String; let isActive: Bool }
    var transfers: [Transfer] {
        tasks.map { Transfer(id: $0.key, label: $0.value, isActive: active?.path == $0.key) }
            .sorted { ($0.isActive ? 0 : 1, $0.id) < ($1.isActive ? 0 : 1, $1.id) }
    }
    /// Why an automatic pass should not run now: metered network or a recording in progress.
    private var automaticPause: String? {
        if Recorder.shared.recording {
            return String(localized: "Registrazione in corso: la sincronizzazione riprende quando finisce, per non togliere banda alla chiamata.")
        }
        if metered {
            return String(localized: "Rete a consumo o in risparmio dati: sincronizzazione automatica in pausa. Usa Sincronizza ora per forzarla.")
        }
        return nil
    }
    /// Stops an automatic pass in flight. Resumable uploads continue from where they stopped next time.
    func pauseAutomatic() {
        guard sweeping, !manualPass, let reason = automaticPause else { return }
        stop()
        message = reason
    }
    /// Two copies of the app on one Mac (an installed one and a test build) share ~/Meetings and the map:
    /// only the first one syncs. The lock goes away with its process, even after a crash.
    private func ownsProcessLock() -> Bool {
        if processLock >= 0 { return true }
        let directory = CloudLedger.current.directory.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent("cloud.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true } // cannot lock at all: do not block syncing
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
        processLock = fd
        return true
    }
    /// Statuses describe one destination: drop them when it changes, and let the library reload them.
    func resetStatuses() {
        statuses = [:]
        failures = [:]
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }
    func isArchived(_ directory: URL) -> Bool { archivedPaths.contains(directory.path) }
    func isPinned(_ directory: URL) -> Bool { pinnedPaths.contains(directory.path) }
    func refreshFlags(_ directory: URL) {
        let archived = Self.hasArchivedAudio(directory), pinned = Self.isPinned(directory), path = directory.path
        if archived != archivedPaths.contains(path) { if archived { archivedPaths.insert(path) } else { archivedPaths.remove(path) } }
        if pinned != pinnedPaths.contains(path) { if pinned { pinnedPaths.insert(path) } else { pinnedPaths.remove(path) } }
    }
    func isBusy(_ directory: URL) -> Bool { requested.contains(directory.path) || active?.path == directory.path }

    /// The account's authorization was revoked or expired: automatic passes stop (each one would only hit the
    /// token endpoint again) until the person reconnects. "Sync now" still tries, and clears it on success.
    @Published private(set) var needsReconnect = false
    func reconnected() { needsReconnect = false }

    /// A meeting is about to be deleted on the Mac: remember its cloud copies so they move to the service's
    /// trash (recoverable from there; Overheard never empties it). Call before the folder is moved away.
    /// It only records them; `drainTrashQueue()` runs once the local folder has really been moved.
    func queueRemoteTrash(_ directory: URL) {
        guard let manifest = Self.manifest(directory), !manifest.files.isEmpty else { return }
        try? CloudTrashQueue.shared.enqueue(manifest: manifest, folder: directory.lastPathComponent)
    }

    /// Moves queued cloud copies to the trash of the service they were uploaded to. Offline or signed out:
    /// they stay queued and are retried on the next pass.
    func drainTrashQueue() async {
        guard !purging, !CloudTrashQueue.shared.entries.isEmpty else { return }
        await acquire()
        defer { release() }
        for entry in CloudTrashQueue.shared.entries {
            guard let provider = try? await originalProvider(entry.destination) else { continue }
            do {
                try await engine.removeQueued(entry, provider: provider)
                CloudTrashQueue.shared.remove(entry)
            } catch {
                if (CloudError.classify(error) as? CloudError)?.affectsDestination == true { break }
            }
        }
    }

    private func acquire() async {
        if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
    }
    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } // hand over without unlocking
    }

    /// A user action on one meeting, for the spinner.
    /// One label per meeting being acted on, so two queued actions never clear each other's.
    @Published private(set) var tasks: [String: String] = [:]
    var task: String? { tasks.values.sorted().first }
    private func run(_ action: CloudAction, on dir: URL, restoreOnly: Set<String>?) async {
        requested.insert(dir.path)
        defer { requested.remove(dir.path) }
        switch action {
        case .sync, .reupload: tasks[dir.path] = String(localized: "Carico la riunione nel cloud…")
        case .evict, .reclaim: tasks[dir.path] = String(localized: "Libero l'audio sul Mac…")
        case .restore:
            tasks[dir.path] = restoreOnly == Set(CloudFiles.text)
                ? String(localized: "Scarico i testi dal cloud…")
                : String(localized: "Scarico l'audio dal cloud…")
        case .pin: tasks[dir.path] = String(localized: "Tengo la riunione sul Mac…")
        case .deleteRemote: tasks[dir.path] = String(localized: "Elimino la copia cloud…")
        }
        defer { tasks[dir.path] = nil }
        await acquire()
        defer { release() }
        // Cancelled while it waited its turn: nothing to do.
        guard !Task.isCancelled else { return }
        // Checked once the lock is held: an action queued before a deletion started must not re-upload.
        guard !purging else { message = String(localized: "Eliminazione dal cloud in corso: riprova tra poco."); return }
        active = dir
        defer { active = nil }
        do {
            let stored = Self.manifest(dir)
            var provider: any CloudStorageProvider
            if restoreOnly != nil, let stored {
                provider = try await originalProvider(stored.destination)
            } else {
                provider = try await self.provider()
            }
            if Self.kind != "folder", let library = provider as? any CloudLibraryProvider { try await engine.confirmLibrary(library, in: root) }
            if restoreOnly == nil, let stored, stored.destination != provider.id || stored.migrationSource != nil {
                let (source, inProgress) = Self.source(of: stored)
                switch Self.choice(target: provider.id, source: source) ?? (inProgress ? .copy : nil) {
                case nil:
                    await ask(source: source, target: provider.id, count: 1)
                    message = String(localized: "Scegli cosa fare con le riunioni su \(Self.displayName(source)).")
                    return
                case .keep?:
                    // Kept where it is: act on it there.
                    provider = try await originalProvider(source)
                    if let library = provider as? any CloudLibraryProvider { try await engine.confirmLibrary(library, in: root) }
                case let choice?:
                    try await engine.migrate(dir, from: try? await originalProvider(source), to: provider, move: choice == .move,
                                             options: options, isActive: isActive)
                    if action == .sync { apply(CloudReport(statuses: [dir.path: Self.storedStatus(dir, enabled: true) ?? ""])); refreshFlags(dir); return }
                }
            }
            let report = await engine.perform(action, directories: [dir], provider: provider, options: options,
                                              force: true, resume: action == .sync, restoreOnly: restoreOnly, isActive: isActive)
            apply(report)
            refreshFlags(dir)
            if let stopped = report.stopped { message = stopped }
            if report.authExpired { needsReconnect = true }
            // Local audio may have appeared or disappeared: let open views reload.
            NotificationCenter.default.post(name: .meetingsChanged, object: nil)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                message = String(localized: "Trasferimento annullato")
                return
            }
            // Raised before the engine ran (provider missing, signed out, other account): show it on the
            // meeting too, because the transcript view reads that status, not the global notice.
            message = error.localizedDescription
            _ = apply(CloudReport(statuses: [dir.path: error.localizedDescription], failures: [dir.path: error.localizedDescription]))
            if (error as? CloudError)?.needsReconnect == true { needsReconnect = true }
        }
    }

    private func sweep(manual: Bool) async {
        guard !sweeping, !purging else { return } // a deletion in progress must not see files uploaded again
        // Network changes come in bursts (Wi-Fi, VPN): one automatic pass is enough.
        if !manual, !rerun, Date().timeIntervalSince(lastPassEnded) < 20 { return }
        rerun = false
        await sweepPass(manual: manual)
        while rerun { rerun = false; await sweepPass(manual: true) }
        lastPassEnded = Date()
    }

    private func sweepPass(manual: Bool) async {
        guard !sweeping else { return }
        if !manual, let reason = automaticPause { message = reason; return }
        if !manual, needsReconnect { message = String(localized: "Accesso scaduto. Ricollega l'account cloud."); return }
        sweeping = true; stopRequested = false; manualPass = manual
        defer {
            sweeping = false
            manualPass = false
            progress = ""
            sweepFraction = nil
            syncProgress = nil
            passBytes = nil
            refreshCloudUpload() // the copy is done; for iCloud the upload may still be going
        }
        do {
            let provider = try await provider()
            await drainTrashQueue()
            let settings = self.settings, options = self.options, root = self.root, destination = provider.id
            if let webDAV = provider as? WebDAVProvider {
                await acquire()
                if purging || stopRequested || !enabled || self.settings != settings { release(); return }
                let work = Task { try await engine.pullCatalog(from: webDAV, into: root, isActive: isActive) }
                cancelCurrent = { work.cancel() }
                let result = await work.result
                cancelCurrent = nil
                release()
                if try result.get() { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
                guard enabled, self.settings == settings, !stopRequested else { return }
            }
            if !(provider is WebDAVProvider), options.archiveAfterSync, let library = provider as? any CloudLibraryProvider {
                await acquire()
                if purging || stopRequested || !enabled || self.settings != settings { release(); return }
                do { try await engine.confirmLibrary(library, in: root) }
                catch { release(); throw error }
                release()
                guard enabled, self.settings == settings, !stopRequested else { return }
            }
            let (directories, conflicts, transfers) = await Task.detached { () -> ([URL], [SyncConflict], [String: (destination: String, inProgress: Bool)]) in
                let conflicts = SyncConflicts.folderConflicts(in: root)
                let blocked = Set(conflicts.map(\.url.path))
                let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                let directories = folders.filter {
                    $0.lastPathComponent.hasPrefix("20") && !blocked.contains($0.path)
                        && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.sorted { $0.lastPathComponent > $1.lastPathComponent } // newest first
                // Meetings still tied to another destination, found here instead of on the main thread.
                var transfers: [String: (destination: String, inProgress: Bool)] = [:]
                for dir in directories {
                    guard let manifest = CloudSync.manifest(dir) else { continue }
                    // A Move still waiting to remove the old copies, keyed apart from transfers.
                    if let data = manifest.pendingRemoval, let old = try? JSONDecoder().decode(CloudManifest.self, from: data) {
                        transfers["pending:" + dir.path] = (old.destination, true)
                    }
                    guard manifest.destination != destination || manifest.migrationSource != nil else { continue }
                    transfers[dir.path] = CloudSync.source(of: manifest)
                }
                return (directories, conflicts, transfers)
            }.value
            let context = await engine.context(for: directories, destination: provider.id)
            // What this pass really has to send, so the bar can count it instead of counting meetings.
            let pendingByMeeting = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: directories.map { ($0.path, CloudSync.pendingBytes($0, options: options)) })
            }.value
            let pendingTotal = pendingByMeeting.values.reduce(0, +)
            passBytes = pendingTotal > 0 ? PassBytes(total: pendingTotal) : nil
            refreshCloudUpload()
            var changed = false
            var undecided: [String: Int] = [:], counts: [String: Int] = [:]
            for (key, found) in transfers where !key.hasPrefix("pending:") { counts[found.destination, default: 0] += 1 }
            elsewhere = counts.map { Elsewhere(source: $0.key, name: Self.displayName($0.key), count: $0.value,
                                               choice: Self.choice(target: provider.id, source: $0.key)) }.sorted { $0.count > $1.count }
            for (index, dir) in directories.enumerated() {
                if stopRequested { if !manual, let reason = automaticPause { message = reason } else { message = String(localized: "Sincronizzazione interrotta") }; return }
                if !manual, let reason = automaticPause { message = reason; return }
                guard enabled, self.settings == settings else { return }
                // Says what is happening to this meeting: moved, copied or just checked.
                let targetName = Self.displayName(provider.id)
                var doing = String(localized: "Sincronizzo con \(targetName)")
                if let found = transfers[dir.path],
                   let choice = Self.choice(target: provider.id, source: found.destination) ?? (found.inProgress ? .copy : nil), choice != .keep {
                    doing = choice == .move
                        ? String(localized: "Sposto da \(Self.displayName(found.destination)) a \(targetName)")
                        : String(localized: "Copio da \(Self.displayName(found.destination)) a \(targetName)")
                } else if transfers["pending:" + dir.path] != nil {
                    doing = String(localized: "Elimino le vecchie copie")
                }
                sweepFraction = Double(index) / Double(directories.count)
                passBytes?.current = pendingByMeeting[dir.path] ?? 0
                progress = String(localized: "\(doing): riunione \(index + 1) di \(directories.count)")
                await acquire()
                // The lock may have waited behind a deletion or a settings change.
                if purging || stopRequested || !enabled || self.settings != settings { release(); return }
                active = dir
                if let old = transfers["pending:" + dir.path], let source = try? await originalProvider(old.destination) {
                    // The old service is reachable again: finish the Move (old copies and emptied folder go).
                    if (try? await engine.finishMove(dir, source: source, target: provider, isActive: isActive)) != nil {
                        changed = set(dir.path, Self.storedStatus(dir, enabled: true) ?? "") || changed
                    }
                }
                if let found = transfers[dir.path], let stored = Self.manifest(dir),
                   stored.destination != provider.id || stored.migrationSource != nil {
                    // A transfer started before choices were remembered goes on as a copy: it never deletes.
                    let choice = Self.choice(target: provider.id, source: found.destination) ?? (found.inProgress ? .copy : nil)
                    guard let choice, choice != .keep else {
                        if choice == nil { undecided[found.destination, default: 0] += 1 }
                        else { changed = set(dir.path, String(localized: "Su \(Self.displayName(found.destination))")) || changed }
                        active = nil; release()
                        continue
                    }
                    let move = choice == .move
                    if !manual, let retry = migrationRetry[dir.path], retry.next > Date() {
                        active = nil; release()
                        continue
                    }
                    do {
                        let original = try stored.migrationSource.map { try JSONDecoder().decode(CloudManifest.self, from: $0) } ?? stored
                        // An unreachable old service still lets meetings that are fully on the Mac move over.
                        let source = try? await originalProvider(original.destination)
                        let engine = self.engine, isActive = self.isActive
                        let work = Task { try await engine.migrate(dir, from: source, to: provider, move: move, options: options, isActive: isActive) }
                        cancelCurrent = { work.cancel() }
                        defer { cancelCurrent = nil }
                        let leftBehind = try await work.value
                        migrationRetry[dir.path] = nil
                        let status = leftBehind
                            ? String(localized: "Copiata. Le copie nel servizio precedente sono rimaste: ricollegalo per rimuoverle.")
                            : CloudSync.manifest(dir).map(CloudSync.describe) ?? String(localized: "Sincronizzata")
                        changed = set(dir.path, status) || changed
                    } catch {
                        let error = CloudError.classify(error)
                        if error is CancellationError {
                            // Stopped (by the user, a recording or a metered network): resumes next time, no error.
                            active = nil; release()
                            if changed { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
                            return
                        }
                        changed = set(dir.path, error.localizedDescription) || changed
                        if (error as? CloudError)?.affectsDestination != true, (error as? CloudError)?.isBusy != true {
                            // One meeting's problem: wait longer each time, like a sync does (15 s … 1 h).
                            let attempts = (migrationRetry[dir.path]?.attempts ?? 0) + 1
                            migrationRetry[dir.path] = (attempts, Date().addingTimeInterval(min(3600, pow(2, Double(min(attempts, 10))) * 15)))
                        }
                        if let cloud = error as? CloudError, cloud.affectsDestination {
                            // Offline, authorization, quota or no room on the Mac: stop until it is fixed.
                            message = error.localizedDescription
                            active = nil; release()
                            if changed { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
                            return
                        }
                        // One meeting's problem stays on its row; the others keep moving.
                    }
                    active = nil; release()
                    continue
                }
                let engine = self.engine, isActive = self.isActive
                let missingText = CloudFiles.text.filter { !CloudFiles.exists(dir.appendingPathComponent($0)) }
                let work = Task { [weak self] in
                    await CloudSyncEngine.SyncProgress.$update.withValue({ [weak self = self] phase in
                        await self?.showSyncProgress(phase)
                    }) {
                        await engine.perform(.sync, directories: [dir], provider: provider, options: options,
                                             force: manual, context: context, isActive: isActive)
                    }
                }
                cancelCurrent = { work.cancel() }
                let report = await work.value
                syncProgress = nil
                cancelCurrent = nil
                active = nil
                release()
                if apply(report) { changed = true; refreshFlags(dir) }
                if var pass = passBytes { pass.done += pass.current; pass.current = 0; passBytes = pass }
                if missingText.contains(where: { CloudFiles.exists(dir.appendingPathComponent($0)) }) { changed = true }
                if let stopped = report.stopped {
                    message = stopped
                    if report.authExpired { needsReconnect = true }
                    if changed { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
                    return
                }
            }
            let limit = options.archiveAfterSync ? 0 : Int64(UserDefaults.standard.integer(forKey: "cloud.storageLimitGB")) * 1_000_000_000
            if limit > 0 {
                guard let reclaimed = await reclaim(directories, limit: limit, provider: provider, options: options,
                                                    context: context, settings: settings) else { return }
                changed = reclaimed || changed
            }
            for conflict in conflicts { changed = set(conflict.url.path, String(localized: "Possibile copia in conflitto")) || changed }
            if let (source, count) = undecided.max(by: { $0.value < $1.value }) {
                await ask(source: source, target: provider.id, count: count)
            }
            needsReconnect = false // a whole pass got through: the authorization works
            if let prompt = transferPrompt {
                message = String(localized: "Scegli cosa fare con le riunioni su \(prompt.sourceName).")
            } else if !failures.isEmpty {
                message = String(localized: "Riunioni con errori: \(failures.count)")
            } else {
                message = String(localized: "Ultimo controllo: \(Date().formatted(date: .omitted, time: .shortened))")
            }
            // Only on a real change: this notification reloads the library and rereads transcripts.
            if changed { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
        } catch { message = error.localizedDescription }
    }

    private func showSyncProgress(_ phase: CloudSyncEngine.SyncProgress) {
        syncProgress = phase
    }

    /// Frees verified audio, oldest meetings first, until local audio fits the limit.
    /// Returns nil when the pass stopped, otherwise whether any status changed.
    private func reclaim(_ directories: [URL], limit: Int64, provider: any CloudStorageProvider, options: CloudOptions,
                         context: CloudContext, settings: String) async -> Bool? {
        let sizes = await Task.detached { directories.map { ($0, CloudFiles.localAudioBytes($0)) } }.value
        var total = sizes.reduce(0) { $0 + $1.1 }
        var changed = false
        for (dir, bytes) in sizes.reversed() where bytes > 0 { // directories are newest first
            guard total > limit else { break }
            if stopRequested { message = String(localized: "Sincronizzazione interrotta"); return nil }
            guard enabled, self.settings == settings else { return nil }
            await acquire()
            active = dir
            let report = await engine.perform(.reclaim, directories: [dir], provider: provider, options: options,
                                              force: true, context: context, isActive: isActive)
            active = nil
            release()
            changed = apply(report) || changed
            if let stopped = report.stopped { message = stopped; return nil }
            total -= bytes - CloudFiles.localAudioBytes(dir)
        }
        if total > limit {
            let excess = ByteCountFormatter.string(fromByteCount: total - limit, countStyle: .file)
            message = String(localized: "Limite di spazio superato di \(excess): l'audio restante è fissato sul Mac, senza transcript o non ancora verificato nel cloud.")
            return changed
        }
        return changed
    }

    @discardableResult private func apply(_ report: CloudReport) -> Bool {
        var changed = false
        for (path, status) in report.statuses {
            changed = set(path, status) || changed
            if failures[path] != report.failures[path] { failures[path] = report.failures[path] }
        }
        return changed
    }
    @discardableResult private func set(_ path: String, _ status: String) -> Bool {
        guard statuses[path] != status else { return false }
        statuses[path] = status
        return true
    }

    /// Row statuses come from memory. The library fills them once, off the main thread.
    func status(_ directory: URL) -> String? { statuses[directory.path] }
    func loadStatuses(for directories: [URL]) async {
        let enabled = self.enabled
        let (loaded, archived, pinned, remoteTranscripts) = await Task.detached { () -> ([(String, String)], Set<String>, Set<String>, Set<String>) in
            let loaded = directories.compactMap { dir in Self.storedStatus(dir, enabled: enabled).map { (dir.path, $0) } }
            return (loaded, Set(directories.filter(Self.hasArchivedAudio).map(\.path)), Set(directories.filter(Self.isPinned).map(\.path)),
                    Set(directories.filter { Self.manifest($0)?.files["transcript.md"] != nil }.map(\.path)))
        }.value
        for (path, status) in loaded where statuses[path] == nil { statuses[path] = status }
        if archivedPaths != archived { archivedPaths = archived }
        if pinnedPaths != pinned { pinnedPaths = pinned }
        if remoteTranscriptPaths != remoteTranscripts { remoteTranscriptPaths = remoteTranscripts }
    }
    nonisolated static func manifest(_ directory: URL) -> CloudManifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(CloudManifest.filename)) else { return nil }
        return try? JSONDecoder().decode(CloudManifest.self, from: data)
    }
    nonisolated static func driveFolders(in root: URL, accountID: String) -> Set<String> {
        let prefix = "drive:\(accountID):"
        let directories = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return Set(directories.compactMap { directory in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let destination = Self.manifest(directory)?.destination, destination.hasPrefix(prefix),
                  destination.count > prefix.count else { return nil }
            return String(destination.dropFirst(prefix.count))
        })
    }
    nonisolated static func storedStatus(_ directory: URL, enabled: Bool) -> String? {
        guard let manifest = manifest(directory) else { return enabled ? String(localized: "In attesa di sincronizzazione") : nil }
        if manifest.syncDisabled { return String(localized: "Sincronizzazione sospesa per questa riunione") }
        return manifest.lastError ?? describe(manifest)
    }
    nonisolated static func describe(_ manifest: CloudManifest) -> String {
        if manifest.pendingRemoval != nil {
            return String(localized: "Copiata. Le copie nel servizio precedente sono rimaste: ricollegalo per rimuoverle.")
        }
        if manifest.remoteDeleted?.isEmpty == false {
            return String(localized: "Eliminata dal cloud. Carica di nuovo oppure tieni solo sul Mac.")
        }
        return describeSynced(manifest)
    }
    nonisolated static func describeSynced(_ manifest: CloudManifest) -> String {
        !manifest.archived.isEmpty ? String(localized: "Nel cloud")
            : manifest.pinned ? String(localized: "Conservata su questo Mac") : String(localized: "Sincronizzata")
    }
    nonisolated static func isPinned(_ directory: URL) -> Bool { manifest(directory)?.pinned ?? false }
    nonisolated static func hasArchivedContent(_ directory: URL) -> Bool {
        guard let manifest = manifest(directory) else { return false }
        return CloudFiles.content.contains { manifest.files[$0] != nil && !CloudFiles.exists(directory.appendingPathComponent($0)) }
    }
    nonisolated static func hasArchivedText(_ directory: URL) -> Bool {
        guard let manifest = manifest(directory) else { return false }
        return CloudFiles.text.contains { manifest.files[$0] != nil && !CloudFiles.exists(directory.appendingPathComponent($0)) }
    }
    nonisolated static func hasArchivedAudio(_ directory: URL) -> Bool {
        guard let manifest = manifest(directory) else { return false }
        return CloudFiles.audio.contains { manifest.files[$0] != nil && !CloudFiles.exists(directory.appendingPathComponent($0)) }
    }
}

/// "Delete meetings older than N days", kept in the same card as the cloud settings: with cloud storage on, the
/// rule works together with the cloud copy (everything is removed from the Mac and the cloud copy goes to the
/// service's trash; "audio only" is left to the verified cloud cleanup above).
struct RetentionRules: View {
    @ObservedObject private var rec = Recorder.shared
    @AppStorage("retentionDays") private var days = 0
    @AppStorage("retentionMode") private var mode = "audio"
    @AppStorage("cloud.enabled") private var cloudOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Elimina i meeting più vecchi di")
                Spacer()
                Picker("", selection: $days) {
                    Text("Mai").tag(0)
                    Text("7 giorni").tag(7)
                    Text("30 giorni").tag(30)
                    Text("90 giorni").tag(90)
                    Text("6 mesi").tag(180)
                    Text("1 anno").tag(365)
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: days) { _, _ in rec.cleanOld() }
            }
            if days > 0 {
                Picker("", selection: $mode) {
                    Text("Solo l'audio").tag("audio")
                    Text("Tutto").tag("all")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _, _ in rec.cleanOld() }
                Text(mode == "audio"
                     ? "Elimina le registrazioni audio (~700 MB/ora) e conserva transcript e riassunti."
                     : "Elimina l'intera cartella del meeting: audio, transcript e riassunto.")
                    .font(.caption).foregroundStyle(.secondary)
                if cloudOn {
                    Text(mode == "audio"
                         ? "Con il cloud attivo “Solo l'audio” non si applica: l'audio si libera con la regola del cloud, solo dopo la verifica della copia."
                         : "Con il cloud attivo anche le copie nel cloud vanno nel cestino del servizio, che Overheard non svuota mai.")
                        .font(.caption).foregroundStyle(mode == "audio" ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("I file vanno nel Cestino: si possono recuperare finché non lo svuoti. Controllo all'avvio e ogni ora.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CloudSettingsView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @AppStorage("cloud.enabled") private var enabled = false
    @AppStorage("cloud.provider") private var provider = "dropbox"
    @AppStorage("cloud.drive.folder") private var folder = "root"
    @AppStorage("cloud.webdav.url") private var endpoint = ""
    @AppStorage("cloud.webdav.user") private var username = ""
    @AppStorage("cloud.s3.endpoint") private var s3Endpoint = ""
    @AppStorage("cloud.s3.region") private var s3Region = ""
    @AppStorage("cloud.s3.bucket") private var s3Bucket = ""
    @AppStorage("cloud.s3.prefix") private var s3Prefix = "Overheard"
    @AppStorage("cloud.s3.key") private var s3Key = ""
    @AppStorage("cloud.audio") private var audio = true
    @AppStorage("cloud.transcript") private var transcript = true
    @AppStorage("cloud.summary") private var summary = true
    @AppStorage("cloud.bookmarks") private var bookmarks = true
    @AppStorage("cloud.otherText") private var otherText = true
    @AppStorage("cloud.audioFormat") private var audioFormat = "alac"
    @AppStorage("cloud.cleanupDays") private var cleanupDays = 0
    @AppStorage("cloud.storageLimitGB") private var storageLimit = 0
    @State private var folderName = "Overheard"
    @State private var clientID = ""
    @State private var secret = ""
    @State private var appKey = ""
    @State private var password = ""
    @State private var s3Secret = ""
    @State private var connecting = false
    @State private var attempt = 0 // only the latest sign-in may report back
    @State private var account: String?
    @State private var oneDriveClient = ""
    @AppStorage("cloud.folder.path") private var folderPath = ""
    @AppStorage("cloud.webdav.preset") private var preset = "custom"
    @AppStorage("cloud.webdav.server") private var webDAVServer = ""
    @AppStorage("cloud.webdav.region") private var pCloudRegion = "eu"
    @State private var checking = false
    @State private var showRecovery = false
    @State private var shownProvider: String?
    @AppStorage("cloud.drive.folderAccount") private var folderAccount = ""
    @State private var result = ""

    var body: some View {
        Card {
            HStack {
                Text("Archivio cloud").font(.headline)
                Spacer()
                Toggle("Sincronizza le riunioni", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        if value { Task { await cloud.perform(.sync, force: true) } } else { cloud.stop(); cloud.resetStatuses() }
                    }
                    // Nothing to sync to without an account: it cannot be switched on, only off.
                    .disabled(cloud.running || (needsAccount && !enabled))
            }
            if let account {
                HStack {
                    Label(String(localized: "Collegato: \(account)"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    if provider == "drive", let url = driveFolderURL {
                        Link("Apri in Google Drive", destination: url)
                    }
                }.font(.caption)
            }
            Group {
                DisclosureGroup("Dove salvare") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Dove salvare", selection: $provider) {
                            Text("Dropbox").tag("dropbox")
                            Text("Google Drive").tag("drive")
                            Text("OneDrive").tag("onedrive")
                            Text("iCloud Drive").tag("icloud")
                            if provider == "folder" { Text("Cartella sincronizzata (Aruba Drive, Synology…)").tag("folder") }
                            Text("Altro server WebDAV").tag("webdav")
                            if provider == "s3" { Text("S3 compatibile (avanzato)").tag("s3") }
                        }
                        .onChange(of: provider) { _, _ in if connecting { cancelSignIn(message: "") } }
                        switch provider {
                        case "drive": drive
                        case "onedrive": oneDrive
                        case "icloud": iCloud
                        case "folder": syncedFolder
                        case "webdav": webDAV
                        case "s3": s3
                        default: dropbox
                        }
                        // Right under the service, where the user just clicked: not at the bottom of the card.
                        if !result.isEmpty {
                            Text(result).font(.caption).foregroundStyle(account == nil ? .orange : .secondary).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.top, 6)
                }
                DisclosureGroup("Cosa caricare") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Audio delle registrazioni", isOn: $audio)
                        if audio {
                            Picker("Formato audio nel cloud", selection: Binding(get: { provider != "folder" && audioFormat == "aac" ? "alac" : audioFormat }, set: { audioFormat = $0 })) {
                                Text("Compresso senza perdita (consigliato)").tag("alac")
                                if provider == "folder" { Text("Massimo risparmio").tag("aac") }
                                Text("Originale WAV").tag("wav")
                            }
                            Text(provider == "folder" && audioFormat == "aac"
                                 ? "Circa 14 volte più piccolo, qualità adatta alla voce. Se liberi l'audio e poi lo scarichi, non torna identico all'originale."
                                 : audioFormat == "wav"
                                 ? "Copia identica, non compressa: occupa circa 4 volte più spazio di quella senza perdita."
                                 : "Circa 4 volte più piccolo. Quando lo scarichi, l'audio torna identico all'originale, bit per bit.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                            Toggle("Transcript", isOn: $transcript)
                            Toggle("Segnalibri", isOn: $bookmarks)
                            Toggle("Riassunto, decisioni e action item", isOn: $summary)
                        }
                        Text("Titolo e dati della riunione vengono sempre caricati. Se spegni una voce, le copie già nel cloud restano.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !audio { Text("Senza l'audio nel cloud non si può liberare spazio sul Mac.").font(.caption).foregroundStyle(.orange) }
                    }.padding(.top, 6)
                }
                if provider != "folder" {
                    Text("I testi restano disponibili sul Mac anche offline. L’audio viene archiviato nel cloud dopo la verifica e scaricato quando lo ascolti.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    DisclosureGroup("Libera audio locale dopo") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Libera audio locale dopo", selection: $cleanupDays) {
                                Text("Solo manualmente").tag(0)
                                Text("7 giorni").tag(7)
                                Text("30 giorni").tag(30)
                                Text("90 giorni").tag(90)
                            }
                            Picker("Spazio massimo per l'audio sul Mac", selection: $storageLimit) {
                                Text("Nessun limite").tag(0)
                                ForEach([5, 10, 25, 50, 100], id: \.self) { Text("\($0) GB").tag($0) }
                            }
                            Text("Oltre il limite, libera l'audio delle riunioni più vecchie. La pulizia cloud rimuove solo audio verificato e non fissato sul Mac. I testi restano disponibili offline. Le modifiche vengono riprovate quando torna la connessione e l'app è aperta.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Con il cloud attivo, la pulizia usa questa regola al posto della conservazione locale. I meeting già collegati al cloud restano esclusi dalla vecchia pulizia anche se disattivi il cloud.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 6)
                    }
                }
            }.disabled(cloud.running)
            Divider()
            RetentionRules()
            if enabled, needsAccount {
                Text("Nessun account collegato: la sincronizzazione è in pausa. Collega l'account oppure disattiva “Sincronizza le riunioni”.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(cloud.inProgress ? "Sincronizzazione in corso" : "Sincronizza ora") { Task { await cloud.perform(.sync, force: true) } }
                    .disabled(!enabled || needsAccount || cloud.inProgress || connecting)
                if cloud.sweeping { Button("Interrompi") { cloud.stop() } }
                Spacer()
                Menu("Altro") {
                    Button("Scarica tutto l'audio sul Mac") {
                        Task { if let id = try? await cloud.provider().id { await cloud.downloadAll(from: id) } }
                    }.disabled(!enabled)
                    Button("Esporta tutte le riunioni in ZIP…") { exportZip(source: nil) }
                    Divider()
                    Button("Riunioni recuperabili dal cloud…") { showRecovery = true }
                    Divider()
                    Button("Elimina tutto dal cloud e tieni sul Mac…", role: .destructive) { confirmPurgeAll = true }
                        .disabled(cloud.purging)
                    Button("Mostra la mappa delle registrazioni") {
                        let map = CloudLedger.current.directory
                        try? FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([map])
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(cloud.exporting)
                Link("Come funziona", destination: URL(string: "https://getoverheard.dev/cloud-storage/")!)
                    .font(.caption)
            }
            if let activity = cloud.activity {
                CloudActivityRow(text: activity, fraction: cloud.activityFraction, phase: cloud.syncProgress, rate: cloud.transferRate,
                                 onStop: cloud.running ? { cloud.cancelAllTransfers() } : nil)
            }
            CloudTransfersButton(cloud: cloud)
            if !cloud.message.isEmpty { CloudNotice(message: $cloud.message) }
            if enabled, !cloud.failures.isEmpty {
                DisclosureGroup {
                    ForEach(cloud.failures.keys.sorted(by: >), id: \.self) { path in
                        HStack(alignment: .top) {
                            let meeting = URL(fileURLWithPath: path)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.lastPathComponent).font(.caption.bold())
                                Text(cloud.failures[path] ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Riprova") { Task { await cloud.perform(.sync, meeting: meeting, force: true) } }
                                .disabled(cloud.isBusy(meeting))
                        }.padding(.vertical, 2)
                    }
                } label: {
                    Text("Riunioni con errori: \(cloud.failures.count)").foregroundStyle(.orange)
                }
            }
            ForEach(cloud.elsewhere) { place in
                HStack {
                    Text(Self.summary(place)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Gestisci") {
                        Button("Cambia scelta…") { Task { await cloud.reconsider(place.source) } }
                        Button(String(localized: "Scarica tutto da \(place.name) sul Mac")) { Task { await cloud.downloadAll(from: place.source) } }
                        Button("Esporta queste riunioni in ZIP…") { exportZip(source: place.source) }
                        Divider()
                        Button(String(localized: "Elimina da \(place.name), tieni sul Mac…"), role: .destructive) { purgeSource = place }
                    }.menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(cloud.exporting)
                }
            }
        }
        .sheet(isPresented: $showRecovery) { RecoveryView() }
        .confirmationDialog("Eliminare tutte le copie dal cloud?", isPresented: $confirmPurgeAll) {
            Button("Elimina dal cloud e tieni tutto sul Mac", role: .destructive) { Task { await cloud.purgeCloud() } }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Le copie delle riunioni vengono eliminate da tutti i servizi collegati (Google Drive e Dropbox le tengono nel cestino per 30 giorni) e la sincronizzazione si spegne. Sul Mac non viene toccato nulla. Una riunione con audio solo nel cloud viene saltata: scaricala prima.")
        }
        .confirmationDialog(purgeSource.map { String(localized: "Eliminare le riunioni da \($0.name)?") } ?? "",
                            isPresented: Binding(get: { purgeSource != nil }, set: { if !$0 { purgeSource = nil } }),
                            presenting: purgeSource) { place in
            Button(String(localized: "Elimina da \(place.name)"), role: .destructive) { Task { await cloud.purgeCloud(only: place.source) } }
            Button("Annulla", role: .cancel) {}
        } message: { place in
            Text(String(localized: "Le copie su \(place.name) vengono eliminate solo dopo aver controllato che l'audio sia sul Mac. Sul Mac non viene toccato nulla."))
        }
        .task(id: provider) {
            result = ""
            // Only a real change of service starts a pass: opening Settings does not.
            let switched = shownProvider != nil && shownProvider != provider
            shownProvider = provider
            await refreshAccount()
            if switched {
                cloud.resetStatuses()
                if enabled, account != nil { await cloud.perform(.sync, force: true) }
            }
        }
        .confirmationDialog(cloud.transferPrompt.map { String(localized: "Le tue riunioni su \($0.sourceName)") } ?? "",
                            isPresented: Binding(get: { cloud.transferPrompt != nil }, set: { if !$0 { cloud.postponeTransfer() } }),
                            presenting: cloud.transferPrompt) { prompt in
            Button(String(localized: "Copiale anche su \(prompt.targetName)")) { Task { await cloud.chooseTransfer(.copy) } }
            Button(String(localized: "Spostale su \(prompt.targetName)"), role: .destructive) { Task { await cloud.chooseTransfer(.move) } }
            Button(String(localized: "Lasciale su \(Self.short(prompt.sourceName))")) { Task { await cloud.chooseTransfer(.keep) } }
            Button("Decidi dopo", role: .cancel) { cloud.postponeTransfer() }
        } message: { prompt in
            Text(prompt.count == 1
                 ? String(localized: "Una riunione è salvata su \(prompt.sourceName). Le nuove riunioni andranno su \(prompt.targetName).")
                 : String(localized: "\(prompt.count) riunioni sono salvate su \(prompt.sourceName). Le nuove riunioni andranno su \(prompt.targetName).")
                 + "\n\n" + String(localized: "Copia: restano su entrambi.\nSposta: vengono tolte da \(Self.short(prompt.sourceName)) solo dopo il controllo su \(prompt.targetName).\nLascia: restano dove sono e puoi ancora scaricarle da lì."))
        }
    }

    @State private var confirmPurgeAll = false
    @State private var purgeSource: CloudSync.Elsewhere?

    private func exportZip(source: String?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "Overheard \(Date().formatted(.iso8601.year().month().day())).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await cloud.exportZip(to: url, source: source) }
    }
    /// "Google Drive (me@gmail.com)" → "Google Drive", for short button labels.
    static func short(_ name: String) -> String { name.components(separatedBy: " (").first ?? name }
    static func summary(_ place: CloudSync.Elsewhere) -> String {
        if place.count == 1 {
            switch place.choice {
            case .copy?: return String(localized: "Una riunione su \(place.name): copia in corso")
            case .move?: return String(localized: "Una riunione su \(place.name): spostamento in corso")
            case .keep?: return String(localized: "Una riunione resta su \(place.name)")
            case nil: return String(localized: "Una riunione su \(place.name): scelta in attesa")
            }
        }
        switch place.choice {
        case .copy?: return String(localized: "\(place.count) riunioni su \(place.name): copia in corso")
        case .move?: return String(localized: "\(place.count) riunioni su \(place.name): spostamento in corso")
        case .keep?: return String(localized: "\(place.count) riunioni restano su \(place.name)")
        case nil: return String(localized: "\(place.count) riunioni su \(place.name): scelta in attesa")
        }
    }

    @ViewBuilder private func connected(_ name: String, reconnect: (() -> Void)? = nil, disconnect: @escaping () async throws -> Void) -> some View {
        HStack {
            if cloud.needsReconnect {
                Label(String(localized: "Accesso scaduto: \(name)"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label(String(localized: "Collegato: \(name)"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Spacer()
            if cloud.needsReconnect, let reconnect {
                Button("Riconnetti") { reconnect() }.buttonStyle(.borderedProminent)
            }
            Button("Scollega") {
                Task {
                    do { try await disconnect(); enabled = false; result = String(localized: "Account scollegato. Copie cloud conservate.") }
                    catch { result = error.localizedDescription }
                    await refreshAccount()
                }
            }
        }
    }

    /// While the browser is open: what to do, and a way out if the sign-in fails there.
    @ViewBuilder private var signingIn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Completa l'accesso nel browser").font(.caption)
            }
            HStack {
                Button("Riapri la pagina") { OAuthLoopback.reopenCurrent() }
                Button("Annulla") { cancelSignIn(message: String(localized: "Accesso annullato")) }
            }
            Text("Hai chiuso la pagina o vedi un errore? Riaprila o annulla: non si perde nulla.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func cancelSignIn(message: String) {
        attempt += 1 // the cancelled attempt's own error is ignored
        connecting = false
        OAuthLoopback.cancelCurrent()
        result = message
    }

    @ViewBuilder private var dropbox: some View {
        if let account {
            connected(account, reconnect: {
                connect { try await DropboxAuthorization.connect(appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }) { try await DropboxAccount.shared.disconnect() }
        } else {
            if CloudAppKeys.dropbox == nil {
                TextField("App key della tua app Dropbox", text: $appKey).textFieldStyle(.roundedBorder)
                Text("Questa build non include una app Dropbox. Creane una su dropbox.com/developers con accesso “App folder” e redirect \(DropboxAuthorization.redirectURI).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if connecting { signingIn } else {
                Button("Collega Dropbox") {
                    connect { try await DropboxAuthorization.connect(appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }.disabled(CloudAppKeys.dropbox == nil && appKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        Text("I file vanno in Dropbox › Applicazioni › Overheard. Overheard non vede il resto del tuo Dropbox.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var driveFolderURL: URL? {
        let folderID = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderID == "root" { return URL(string: "https://drive.google.com/drive/my-drive") }
        guard folderID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://drive.google.com/drive/folders/" + folderID)
    }

    @ViewBuilder private var drive: some View {
        if let account {
            connected(account, reconnect: {
                connect {
                    try await DriveAuthorization.connect(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
                    secret = ""
                }
            }) { try await DriveAccount.shared.disconnect() }
        } else {
            if CloudAppKeys.google == nil {
                TextField("OAuth Desktop Client ID", text: $clientID).textFieldStyle(.roundedBorder)
                SecureField("OAuth Desktop Client Secret", text: $secret).textFieldStyle(.roundedBorder)
                Text("Questa build non include credenziali Google: servono credenziali OAuth di tipo Desktop con Drive API attiva.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if connecting { signingIn } else {
            Button("Collega Google Drive") {
                connect {
                    try await DriveAuthorization.connect(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                                         secret: secret.trimmingCharacters(in: .whitespacesAndNewlines))
                    secret = ""
                    let accountID = try await DriveAccount.shared.credentials().accountID
                    let root = cloud.root
                    let known = await Task.detached { CloudSync.driveFolders(in: root, accountID: accountID) }.value
                    if known.count == 1, let existing = known.first {
                        folder = existing
                    } else if known.count > 1 && !known.contains(folder) {
                        folder = ""
                        throw CloudError.destination(String(localized: "Conflitto remoto. Copie locali conservate."))
                    } else if known.isEmpty && (folder.isEmpty || folder == "root" || folderAccount != accountID) {
                        let drive = GoogleDriveProvider(folder: "root", accountID: accountID)
                        if let existing = try await drive.existingLibraryFolder() {
                            folder = existing
                        } else {
                            folder = try await drive.createFolder(name: "Overheard")
                        }
                    }
                    folderAccount = accountID
                    try await GoogleDriveProvider(folder: folder, accountID: accountID).validateLibraryFolder()
                }
            }.disabled(CloudAppKeys.google == nil && (clientID.trimmingCharacters(in: .whitespaces).isEmpty
                                                      || secret.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        Text("I file vanno in una cartella “Overheard” del tuo Drive. Overheard vede solo i file che crea.")
            .font(.caption).foregroundStyle(.secondary)
        DisclosureGroup("Cartella Drive (avanzato)") {
            TextField("ID cartella Drive (root per Il mio Drive)", text: $folder).textFieldStyle(.roundedBorder)
            HStack {
                TextField("Nome nuova cartella Drive", text: $folderName).textFieldStyle(.roundedBorder)
                Button("Crea cartella in Drive") {
                    connect { folder = try await createDriveFolder(folderName); result = String(localized: "Cartella Drive creata") }
                }.disabled(account == nil)
            }
        }.font(.caption)
    }

    @ViewBuilder private var oneDrive: some View {
        if let account {
            connected(account, reconnect: {
                connect { try await OneDriveAuthorization.connect(clientID: oneDriveClient.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }) { try await OneDriveAccount.shared.disconnect() }
        } else {
            if CloudAppKeys.oneDrive == nil {
                TextField("ID applicazione Microsoft della tua app", text: $oneDriveClient).textFieldStyle(.roundedBorder)
                Text("Questa build non include una app Microsoft. Registrane una in Microsoft Entra (piattaforma app desktop, reindirizzamento http://localhost).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if connecting { signingIn } else {
                Button("Collega OneDrive") {
                    connect { try await OneDriveAuthorization.connect(clientID: oneDriveClient.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }.disabled(CloudAppKeys.oneDrive == nil && oneDriveClient.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        Text("I file vanno in OneDrive › App › Overheard. Overheard non vede il resto del tuo OneDrive.")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var iCloud: some View {
        if LocalFolderProvider.iCloudAvailable {
            Label("iCloud Drive è pronto: non serve nessun accesso.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("I file vanno in iCloud Drive › Overheard. L'audio si libera dal Mac solo dopo che iCloud ha finito di caricarlo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            Label("iCloud Drive non è attivo su questo Mac.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("Accedi con il tuo Apple Account e attiva iCloud Drive in Impostazioni di Sistema.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var syncedFolder: some View {
        if !folderPath.isEmpty {
            Label(URL(fileURLWithPath: folderPath).lastPathComponent, systemImage: "folder").textSelection(.enabled)
        }
        HStack {
            Button(folderPath.isEmpty ? "Scegli cartella…" : "Cambia cartella…") { chooseFolder() }
            let apps = LocalFolderProvider.cloudStorageFolders
            if !apps.isEmpty {
                Menu("App cloud trovate") {
                    ForEach(apps, id: \.path) { app in Button(app.lastPathComponent) { folderPath = app.path; result = "" } }
                }.fixedSize()
            }
        }
        Text("Scegli la cartella che l'app del tuo servizio sincronizza, per esempio quella di Aruba Drive o Synology Drive. Overheard ci crea la cartella Overheard e l'app si occupa del caricamento.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !folderPath.isEmpty {
            if LocalFolderProvider.confirmsUploads(URL(fileURLWithPath: folderPath)) {
                Text("Questa app conferma i caricamenti: l'audio si libera dal Mac solo quando è davvero nel cloud.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Questa cartella non conferma i caricamenti: Overheard ci salva una copia di sicurezza, ma non libera spazio sul Mac.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Usa questa cartella")
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path; result = "" }
    }

    /// WebDAV address for each service, from what the user knows (email, server, kDrive number).
    private var presetURL: String {
        let server = webDAVServer.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch preset {
        case "pcloud": return pCloudRegion == "us" ? "https://webdav.pcloud.com/Overheard/" : "https://ewebdav.pcloud.com/Overheard/"
        case "koofr": return "https://app.koofr.net/dav/Koofr/Overheard/"
        case "kdrive": return "https://\(server).connect.kdrive.infomaniak.com/Overheard/"
        case "nextcloud":
            let user = username.trimmingCharacters(in: .whitespaces).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return "https://\(server)/remote.php/dav/files/\(user)/Overheard/"
        default: return endpoint
        }
    }

    @ViewBuilder private var webDAV: some View {
        // Existing presets retain their saved connection details; new connections use custom WebDAV.
        switch preset {
        case "pcloud":
            Picker("Regione dell'account", selection: $pCloudRegion) {
                Text("Europa").tag("eu"); Text("Stati Uniti").tag("us")
            }.pickerStyle(.segmented)
        case "kdrive":
            TextField("Numero del kDrive (dall'indirizzo web, es. 123456)", text: $webDAVServer).textFieldStyle(.roundedBorder)
        case "nextcloud":
            TextField("Indirizzo del server (es. cloud.esempio.it)", text: $webDAVServer).textFieldStyle(.roundedBorder)
        case "custom":
            TextField("URL HTTPS della cartella WebDAV", text: $endpoint).textFieldStyle(.roundedBorder)
        default: EmptyView()
        }
        TextField(preset == "custom" ? "Nome utente" : "Email o nome utente", text: $username).textFieldStyle(.roundedBorder)
        SecureField(preset == "koofr" || preset == "nextcloud" ? "Password per app" : "Password", text: $password).textFieldStyle(.roundedBorder)
        Text({ switch preset {
            case "pcloud": return String(localized: "Usa l'email e la password di pCloud. Su alcuni piani gratuiti pCloud non offre WebDAV.")
            case "koofr": return String(localized: "Serve una password per app: creala su Koofr in Preferenze › Password.")
            case "kdrive": return String(localized: "WebDAV non è incluso nei piani kSuite gratuiti e Standard.")
            case "nextcloud": return String(localized: "Crea una password per app in Impostazioni › Sicurezza di Nextcloud.")
            default: return String(localized: "Per NAS Synology o QNAP e altri server WebDAV: l'indirizzo completo della cartella.")
        } }()).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button(checking ? "Verifica in corso" : "Collega e verifica") {
                let address = presetURL
                guard let url = CloudSync.webDAVURL(address), !password.isEmpty, !username.trimmingCharacters(in: .whitespaces).isEmpty else {
                    result = String(localized: "Inserisci un URL HTTPS e una password validi"); return
                }
                checking = true
                Task {
                    defer { checking = false }
                    do {
                        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        try await WebDAVProvider(endpoint: url, username: user, password: password).prepare()
                        endpoint = url.absoluteString
                        try CloudKeychain.save(Data(password.utf8), account: CloudSync.webDAVAccount(url, user))
                        password = ""
                        result = String(localized: "Collegato. La cartella Overheard è pronta.")
                    } catch { result = error.localizedDescription }
                }
            }.disabled(checking)
            Button("Rimuovi credenziali WebDAV") {
                do {
                    if let url = CloudSync.webDAVURL(endpoint) { try CloudKeychain.save(nil, account: CloudSync.webDAVAccount(url, username)) }
                    enabled = false; result = String(localized: "Credenziali rimosse. Copie cloud conservate.")
                } catch { result = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private var s3: some View {
        TextField("Endpoint HTTPS (es. https://s3.eu-central-003.backblazeb2.com)", text: $s3Endpoint).textFieldStyle(.roundedBorder)
        TextField("Regione (es. eu-central-003; auto per Cloudflare R2)", text: $s3Region).textFieldStyle(.roundedBorder)
        TextField("Bucket", text: $s3Bucket).textFieldStyle(.roundedBorder)
        TextField("Cartella nel bucket", text: $s3Prefix).textFieldStyle(.roundedBorder)
        TextField("Access key ID", text: $s3Key).textFieldStyle(.roundedBorder)
        SecureField("Secret access key", text: $s3Secret).textFieldStyle(.roundedBorder)
        HStack {
            Button("Salva credenziali S3") {
                do {
                    let key = s3Key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), S3Provider.validEndpoint(url),
                          S3Provider.validBucket(s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)), !key.isEmpty, !s3Secret.isEmpty else {
                        throw CloudError.message(String(localized: "Completa endpoint HTTPS, bucket, access key e secret"))
                    }
                    try CloudKeychain.save(Data(s3Secret.utf8), account: "s3:\(key)")
                    s3Secret = ""; result = String(localized: "Credenziali S3 salvate.")
                } catch { result = error.localizedDescription }
            }
            Button("Rimuovi credenziali S3") {
                do {
                    try CloudKeychain.save(nil, account: "s3:\(s3Key.trimmingCharacters(in: .whitespacesAndNewlines))")
                    enabled = false; result = String(localized: "Credenziali rimosse. Copie cloud conservate.")
                } catch { result = error.localizedDescription }
            }
        }
        Text("Per Amazon S3, Cloudflare R2, Backblaze B2, Wasabi e MinIO. La chiave deve poter leggere, scrivere, elencare ed eliminare oggetti nel bucket. Il bucket deve già esistere.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func createDriveFolder(_ name: String) async throws -> String {
        let credentials = try await DriveAccount.shared.credentials()
        return try await GoogleDriveProvider(folder: "root", accountID: credentials.accountID).createFolder(name: name)
    }
    private func connect(_ work: @escaping () async throws -> Void) {
        attempt += 1
        let mine = attempt
        connecting = true
        result = ""
        Task {
            do {
                try await work()
                guard mine == attempt else { return }
                connecting = false
                cloud.reconnected()
                await refreshAccount()
                if enabled, account != nil { await cloud.perform(.sync, force: true) }
                if account != nil, !enabled { result = String(localized: "Collegato. Attiva “Sincronizza le riunioni” per iniziare.") }
            } catch {
                guard mine == attempt else { return } // superseded by a newer attempt or cancelled
                connecting = false
                result = error.localizedDescription
                await refreshAccount()
            }
        }
    }
    /// Drive, Dropbox and OneDrive sync to an account: with none connected there is nothing to sync to.
    /// (WebDAV, S3 and synced folders keep their own credentials, checked when they are set up.)
    private var needsAccount: Bool {
        !["icloud", "folder", "webdav", "s3"].contains(provider) && account == nil
    }

    private func refreshAccount() async {
        let current = provider
        let found: String?
        switch current {
        case "drive": found = (try? await DriveAccount.shared.credentials()).map { $0.email ?? String(localized: "account Google") }
        case "onedrive": found = (try? await OneDriveAccount.shared.credentials()).map { $0.email ?? String(localized: "account Microsoft") }
        case "icloud", "folder": found = nil
        case "webdav", "s3": found = nil
        default: found = (try? await DropboxAccount.shared.credentials()).map { $0.email ?? String(localized: "account Dropbox") }
        }
        // A slower lookup for a service the user already switched away from must not win.
        guard current == provider, !Task.isCancelled else { return }
        account = found
    }
}

struct ConflictReviewView: View {
    let directory: URL
    @State var conflicts: [SyncConflict]
    @State private var removal: URL?
    @State private var useCopy: SyncConflict?
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copie in conflitto").font(.title2)
            Text("Controlla entrambe le copie prima di scegliere. I file rimossi finiscono nel Cestino.")
            List(conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text(conflict.url.lastPathComponent).font(.headline)
                    HStack {
                        Button("Mostra copia") { NSWorkspace.shared.activateFileViewerSelecting([conflict.url]) }
                        Button("Cestina copia", role: .destructive) { removal = conflict.url }
                    }
                    if let original = conflict.original {
                        Text(original.lastPathComponent).foregroundStyle(.secondary)
                        HStack {
                            Button("Mostra originale") { NSWorkspace.shared.activateFileViewerSelecting([original]) }
                            Button("Cestina originale", role: .destructive) { removal = original }
                        }
                    }
                    if CloudSync.hasArchivedContent(conflict.url) {
                        Button("Scarica audio della copia") { Task { await CloudSync.shared.perform(.restore, meeting: conflict.url, force: true) } }
                            .disabled(!CloudSync.shared.enabled || CloudSync.shared.isBusy(conflict.url))
                    }
                    Button("Usa questa copia") { useCopy = conflict }
                    if !SyncConflicts.isManifestCopy(conflict.url.lastPathComponent) {
                        Button("Conserva entrambe") { keep(conflict) }
                    }
                }.padding(.vertical, 6)
            }
            if !error.isEmpty { Text(error).foregroundStyle(.orange) }
            Button("Chiudi") { dismiss() }
        }.padding(20).frame(width: 650, height: 460)
        .confirmationDialog("Spostare questo elemento nel Cestino?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("Sposta nel Cestino", role: .destructive) {
                guard let removal else { return }
                do {
                    guard !CloudSync.shared.running, !Recorder.shared.isRecording(directory), !CloudFiles.exists(directory.appendingPathComponent(".transcribing")) else { throw CloudError.message(String(localized: "Riunione in uso")) }
                    let target = (try? removal.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? removal : removal.deletingLastPathComponent()
                    guard !Recorder.shared.isRecording(target), !CloudAudioUse.contains(target), CloudFiles.eligible(target) else { throw CloudError.message(String(localized: "Riunione in uso")) }
                    try FileManager.default.trashItem(at: removal, resultingItemURL: nil)
                    refresh()
                } catch { self.error = error.localizedDescription }
                self.removal = nil
            }
        } message: { Text(removal?.lastPathComponent ?? "") }
        .confirmationDialog("Usare la copia al posto dell'originale?", isPresented: Binding(get: { useCopy != nil }, set: { if !$0 { useCopy = nil } })) {
            Button("Usa questa copia") {
                if let copy = useCopy { replace(copy) }
                useCopy = nil
            }
        } message: { Text("L'originale verrà spostato nel Cestino. La copia prenderà il suo posto.") }
    }
    private func refresh() {
        conflicts = SyncConflicts.scan(directory)
        NotificationCenter.default.post(name: .meetingsChanged, object: nil)
    }
    private func replace(_ conflict: SyncConflict) {
        do {
            guard !CloudSync.shared.running else { throw CloudError.message(String(localized: "Riunione in uso")) }
            let original = conflict.original ?? conflict.url.deletingLastPathComponent().appendingPathComponent(SyncConflicts.originalName(conflict.url.lastPathComponent) ?? conflict.url.lastPathComponent)
            guard original.path != conflict.url.path else { throw CloudError.message(String(localized: "Originale non identificato. Conserva entrambe le copie.")) }
            for url in [original, conflict.url] {
                let target = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? url : url.deletingLastPathComponent()
                guard !Recorder.shared.isRecording(target), !CloudAudioUse.contains(target),
                      !CloudFiles.exists(target.appendingPathComponent(".transcribing")),
                      !CloudFiles.exists(target.appendingPathComponent("recording.tmp.wav")) else { throw CloudError.message(String(localized: "Riunione in uso")) }
            }
            try SyncConflicts.useCopy(conflict)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func keep(_ conflict: SyncConflict) {
        do {
            guard !CloudSync.shared.running, !Recorder.shared.isRecording(directory), !CloudFiles.exists(directory.appendingPathComponent(".transcribing")) else { throw CloudError.message(String(localized: "Riunione in uso")) }
            let url = conflict.url
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let target = values.isDirectory == true ? url : url.deletingLastPathComponent()
            guard !Recorder.shared.isRecording(target), !CloudAudioUse.contains(target), CloudFiles.eligible(target) else { throw CloudError.message(String(localized: "Riunione in uso")) }
            try SyncConflicts.keepBoth(conflict)
            refresh()
        } catch { self.error = error.localizedDescription }
    }
}

/// Meetings that are no longer on the Mac but can be rebuilt from the cloud, thanks to the map.
struct RecoveryView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var items: [CloudSync.Recoverable] = []
    @State private var loading = true
    @State private var working: UUID?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Riunioni recuperabili dal cloud").font(.title2)
            Text("Riunioni che non sono più sul Mac, per esempio cestinate o perse, ma i cui file sono ancora nel cloud. Overheard le ricostruisce scaricando e verificando ogni file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if loading { ProgressView() }
            else if items.isEmpty {
                Text("Nessuna riunione da recuperare: tutto ciò che è nel cloud è anche sul Mac.").foregroundStyle(.secondary)
            } else {
                List(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.entry.title ?? item.entry.folder).lineLimit(1)
                            Text(String(localized: "\(item.entry.recordedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? item.entry.folder) · su \(item.name) · \(item.placement.live.count) file"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(working == item.id ? "Ripristino…" : "Ripristina") {
                            working = item.id
                            Task {
                                if await cloud.rebuild(item) { items.removeAll { $0.id == item.id } }
                                working = nil
                            }
                        }.disabled(working != nil)
                    }
                }
            }
            if !cloud.message.isEmpty { CloudNotice(message: $cloud.message) }
            HStack { Spacer(); Button("Chiudi") { dismiss() } }
        }
        .padding(20).frame(width: 560, height: 440)
        .task { items = await cloud.recoverable(); loading = false }
    }
}

/// Shows the library pass and, when available, the current file transfer.
struct CloudActivityRow: View {
    let text: String
    var fraction: Double? = nil
    var phase: CloudSyncEngine.SyncProgress? = nil
    var rate: Double? = nil
    /// Stops what is running. Absent when there is nothing to stop (macOS is uploading on its own).
    var onStop: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction) { Text(text) }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let onStop {
                    Button { onStop() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain).help("Interrompi").accessibilityLabel("Interrompi")
                }
            }
            if let phase { CloudPhaseView(phase: phase, rate: rate) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// What the transfer in progress is doing: file, size, share done, speed and time left.
struct CloudPhaseView: View {
    let phase: CloudSyncEngine.SyncProgress
    var rate: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch phase {
            case .preparing(let file):
                Text("Preparo \(file)")
            case .verifying(let file):
                Text("Verifico \(file)")
            case .uploading(let file, let sent, let total):
                if let sent {
                    Text("Carico \(file) · \(size(sent)) / \(size(total))")
                } else {
                    Text("Carico \(file) · \(size(total))")
                }
                detail(done: sent, total: total)
            case .downloading(let file, let received, let total):
                if let received {
                    Text("Scarico \(file) · \(size(received)) / \(size(total))")
                } else {
                    Text("Scarico \(file) · \(size(total))")
                }
                detail(done: received, total: total)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The file's own bar, with the share done, the speed and the time left.
    @ViewBuilder private func detail(done: Int64?, total: Int64) -> some View {
        if let done, total > 0 {
            ProgressView(value: min(1, Double(done) / Double(total)))
            Text(verbatim: Self.summary(done: done, total: total, rate: rate))
        }
    }
    static func summary(done: Int64, total: Int64, rate: Double?) -> String {
        var parts = ["\(Int(min(1, Double(done) / Double(total)) * 100))%"]
        if let rate, rate > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s")
            let left = Double(max(0, total - done)) / rate
            parts.append("~" + Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
        }
        return parts.joined(separator: " · ")
    }
    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Opens the list of queued and running transfers, each with its own Cancel.
struct CloudTransfersButton: View {
    @ObservedObject var cloud: CloudSync
    @State private var open = false

    var body: some View {
        if !cloud.transfers.isEmpty {
            Button { open.toggle() } label: {
                Label("Trasferimenti (\(cloud.transfers.count))", systemImage: "arrow.up.arrow.down.circle")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            .popover(isPresented: $open) { CloudTransfersList(cloud: cloud).padding(14).frame(width: 340) }
        }
    }
}

struct CloudTransfersList: View {
    @ObservedObject var cloud: CloudSync

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trasferimenti in corso").font(.headline)
            if cloud.transfers.isEmpty { Text("Nessun trasferimento").font(.caption).foregroundStyle(.secondary) }
            ForEach(cloud.transfers) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            let url = URL(fileURLWithPath: item.id)
                            Text(Meeting.at(url).title ?? url.lastPathComponent).lineLimit(1)
                            Text(item.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Annulla") { cloud.cancelAction(item.id) }.controlSize(.small)
                    }
                    if item.isActive, let phase = cloud.syncProgress { CloudPhaseView(phase: phase, rate: cloud.transferRate) }
                }
            }
            if cloud.transfers.count > 1 {
                Divider()
                Button("Interrompi tutto", role: .destructive) { cloud.cancelAllTransfers() }
            }
        }
    }
}

/// Keep operation results available without filling the settings panel indefinitely.
private struct CloudNotice: View {
    @Binding var message: String
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                if message.count > 160 {
                    Button(expanded ? "Nascondi dettagli" : "Mostra dettagli") { expanded.toggle() }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { message = "" } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Chiudi")
                .accessibilityLabel("Chiudi")
        }
        .onChange(of: message) { _, _ in expanded = false }
    }
}
