import Foundation

/// Cloud copies of meetings that were deleted on the Mac, waiting to be moved to the service's trash.
/// The meeting's folder is gone by then, so what is needed to find and verify each file is kept here.
/// Overheard only ever moves files into the trash: emptying it is up to the person (or the service).
struct CloudTrashEntry: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        let name: String
        let id: String
        let version: CloudFileVersion
    }
    let meeting: CloudMeetingID
    let folder: String
    let destination: String
    let queuedAt: Date
    var items: [Item]
}

final class CloudTrashQueue: @unchecked Sendable {
    nonisolated(unsafe) static let shared = CloudTrashQueue()
    private let lock = NSLock()

    /// Next to the cloud map, so a test that points the map at a temporary folder gets its own queue.
    private var url: URL { CloudLedger.current.directory.deletingLastPathComponent().appendingPathComponent("cloud-trash-queue.json") }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    private func read() -> [CloudTrashEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([CloudTrashEntry].self, from: data)) ?? []
    }
    private func write(_ entries: [CloudTrashEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: url, options: [.atomic])
    }

    var entries: [CloudTrashEntry] { lock.withLock { read() } }

    /// Records the cloud files of a meeting that is about to be deleted. Returns false when there is nothing to do.
    @discardableResult
    func enqueue(manifest: CloudManifest, folder: String) throws -> Bool {
        let items = manifest.files.map { CloudTrashEntry.Item(name: $0.key, id: $0.value.id, version: $0.value.version) }
            .sorted { $0.name < $1.name }
        guard !items.isEmpty else { return false }
        try lock.withLock {
            var all = read().filter { !($0.meeting == manifest.meeting && $0.destination == manifest.destination) }
            all.append(CloudTrashEntry(meeting: manifest.meeting, folder: folder, destination: manifest.destination, queuedAt: Date(), items: items))
            try write(all)
        }
        return true
    }

    /// Forgets the entry queued for this meeting (the local deletion it belonged to did not happen).
    func cancel(manifest: CloudManifest) {
        lock.withLock {
            try? write(read().filter { !($0.meeting == manifest.meeting && $0.destination == manifest.destination) })
        }
    }

    func remove(_ entry: CloudTrashEntry) {
        lock.withLock {
            try? write(read().filter { !($0.meeting == entry.meeting && $0.destination == entry.destination) })
        }
    }
}
