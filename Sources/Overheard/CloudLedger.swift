import Foundation

/// The map of every recording that ever went to the cloud, kept per Mac outside the meeting folders
/// (~/Library/Application Support/Overheard/Cloud map/<meeting>.json, included in Time Machine).
///
/// A meeting folder carries its own manifest, but a trashed folder or a lost disk takes that manifest
/// with it. The map keeps, for each meeting, every destination it lived on, every file's remote ID,
/// digest and audio format, and a short history. It only grows: files are marked removed, never
/// forgotten, and nothing deletes an entry. With it a meeting can be rebuilt from the cloud.
struct CloudLedger: Sendable {
    struct Placement: Codable, Equatable, Sendable {
        var destination: String
        var files: [String: CloudRemoteFile] = [:]
        /// Files removed from this destination (Move, Remove cloud copy), with the date.
        var removed: [String: Date] = [:]
        var folder: String?
        var firstSeen: Date
        var lastSeen: Date
        /// Files still stored there as far as Overheard knows.
        var live: [String: CloudRemoteFile] { files.filter { removed[$0.key] == nil } }
    }
    struct Event: Codable, Equatable, Sendable {
        let date: Date
        let text: String
    }
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        let meeting: CloudMeetingID
        var folder: String
        var title: String?
        var recordedAt: Date?
        var placements: [String: Placement] = [:]
        var events: [Event] = []
        var id: UUID { meeting.rawValue }
    }

    let directory: URL
    static var standard: CloudLedger {
        CloudLedger(directory: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Overheard/Cloud map", isDirectory: true))
    }
    /// The map the app writes to. Tests point it at a temporary folder.
    nonisolated(unsafe) static var current = CloudLedger.standard
    private static let lock = NSLock()

    /// The meeting's map entry, also kept in its folder so it travels to the cloud with the meeting:
    /// lose the Mac and each cloud folder still says what belonged to it and where its copies were.
    static let mirrorName = "overheard-map.json"

    private func url(_ meeting: CloudMeetingID) -> URL { directory.appendingPathComponent(meeting.rawValue.uuidString + ".json") }
    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static func decodeEntry(_ data: Data) throws -> Entry {
        try decoder.decode(Entry.self, from: data)
    }

    func importRemote(_ entry: Entry, folder: String) throws {
        try update(entry.meeting, folder: folder) { local in
            local.folder = folder
            local.title = entry.title
            local.recordedAt = entry.recordedAt
        }
    }

    func entry(_ meeting: CloudMeetingID) -> Entry? {
        guard let data = try? Data(contentsOf: url(meeting)) else { return nil }
        return try? Self.decoder.decode(Entry.self, from: data)
    }
    func entries() -> [Entry] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Entry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.folder > $1.folder }
    }
    private func write(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entry).write(to: url(entry.meeting), options: [.atomic])
        try? CloudProvenance.record(url(entry.meeting))
    }
    private func update(_ meeting: CloudMeetingID, folder: String, _ change: (inout Entry) -> Void) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var entry = self.entry(meeting) ?? Entry(meeting: meeting, folder: folder)
        let before = entry
        change(&entry)
        if entry.events.count > 300 { entry.events.removeFirst(entry.events.count - 300) }
        if entry != before { try write(entry) }
    }

    /// Called whenever a meeting's manifest is saved: adds what is new, never drops what was known.
    func record(_ manifest: CloudManifest, directory dir: URL) throws {
        let now = Date()
        try update(manifest.meeting, folder: dir.lastPathComponent) { entry in
            entry.folder = dir.lastPathComponent
            if let title = (try? String(contentsOf: dir.appendingPathComponent("title"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { entry.title = title }
            entry.recordedAt = entry.recordedAt ?? CloudFiles.meetingDate(dir)
            var placement = entry.placements[manifest.destination]
                ?? Placement(destination: manifest.destination, firstSeen: now, lastSeen: now)
            let name = CloudSync.displayName(manifest.destination)
            for (file, remote) in manifest.files where file != Self.mirrorName && placement.files[file] != remote {
                entry.events.append(Event(date: now, text: placement.files[file] == nil
                    ? String(localized: "\(file) caricato su \(name)") : String(localized: "\(file) aggiornato su \(name)")))
                placement.files[file] = remote
                placement.removed[file] = nil
            }
            if let folder = manifest.folder { placement.folder = folder }
            if placement != entry.placements[manifest.destination] { placement.lastSeen = now }
            entry.placements[manifest.destination] = placement
        }
    }
    /// Files deliberately removed from a destination (Move, Remove cloud copy).
    func markRemoved(_ meeting: CloudMeetingID, folder: String, destination: String, files: [String]) throws {
        let now = Date()
        try update(meeting, folder: folder) { entry in
            guard var placement = entry.placements[destination] else { return }
            for file in files where placement.files[file] != nil && placement.removed[file] == nil {
                placement.removed[file] = now
                entry.events.append(Event(date: now, text: String(localized: "\(file) rimosso da \(CloudSync.displayName(destination))")))
            }
            entry.placements[destination] = placement
        }
    }
    /// Writes the meeting's entry into its folder (only when it changed), so the next sync uploads it.
    func mirror(_ meeting: CloudMeetingID, into dir: URL) throws {
        guard let entry = entry(meeting), entry.placements.values.contains(where: { !$0.files.isEmpty }) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)
        let target = dir.appendingPathComponent(Self.mirrorName)
        if (try? Data(contentsOf: target)) == data { return }
        try data.write(to: target, options: [.atomic])
        try? CloudProvenance.record(target)
    }
    /// Plain history notes (freed, restored, rebuilt).
    func note(_ meeting: CloudMeetingID, folder: String, _ text: String) throws {
        try update(meeting, folder: folder) { $0.events.append(Event(date: Date(), text: text)) }
    }
}
