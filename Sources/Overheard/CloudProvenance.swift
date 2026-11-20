import Foundation

/// Local receipts written only by app producers. Missing receipts never imply ownership.
/// Protects against incidental foreign files, not an attacker who can rewrite app data.
enum CloudProvenance {
    static let filename = ".overheard-generated.json"
    private static let lock = NSLock()
    static let names: Set<String> = ["recording.wav", "mic.wav", "transcript.md", "summary.md", "bookmarks.txt", "source", "title", "engine", "attendees", "overheard-map.json"]
    private static func read(_ directory: URL) throws -> [String: CloudFileVersion] {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadCorruptFile) }
        return try JSONDecoder().decode([String: CloudFileVersion].self, from: Data(contentsOf: url))
    }
    static func record(_ url: URL) throws {
        guard names.contains(url.lastPathComponent) else { return }
        lock.lock(); defer { lock.unlock() }
        // The app and the MCP server are separate processes writing the same file: a file lock keeps one
        // from overwriting the other's receipt (the NSLock above only covers this process).
        // One lock file beside the cloud map, not one per meeting: nothing is added to the meeting folders (which a
        // sync app may be watching). The app and the MCP server resolve the same path.
        let lockDirectory = CloudLedger.current.directory.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        let descriptor = open(lockDirectory.appendingPathComponent("receipts.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if descriptor >= 0 { flock(descriptor, LOCK_EX) }
        defer { if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) } }
        var receipts = try read(url.deletingLastPathComponent())
        receipts[url.lastPathComponent] = try CloudFiles.version(url)
        try JSONEncoder().encode(receipts).write(to: url.deletingLastPathComponent().appendingPathComponent(filename), options: .atomic)
    }
    /// Explicit sync can enroll a recording made before the app started saving receipts.
    /// Never refresh existing receipts or adopt arbitrary attachments.
    static func enrollLegacyRecording(_ directory: URL) throws {
        guard CloudFiles.meetingDate(directory) != nil,
              CloudFiles.audio.contains(where: { CloudFiles.exists(directory.appendingPathComponent($0)) }) else { return }
        let marker = directory.appendingPathComponent("capture.log")
        let imported = directory.appendingPathComponent("source")
        let capture = (try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        let source = (try? imported.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        guard (capture?.isRegularFile == true && capture?.isSymbolicLink != true)
            || (source?.isRegularFile == true && source?.isSymbolicLink != true
                && (try? String(contentsOf: imported, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == "import") else { return }
        lock.lock(); defer { lock.unlock() }
        let receipt = directory.appendingPathComponent(filename)
        guard !CloudFiles.exists(receipt), (try? FileManager.default.destinationOfSymbolicLink(atPath: receipt.path)) == nil else { return }
        var versions: [String: CloudFileVersion] = [:]
        for name in CloudFiles.content {
            let file = directory.appendingPathComponent(name)
            if CloudFiles.exists(file) { versions[name] = try CloudFiles.version(file) }
        }
        let staged = directory.appendingPathComponent(".cloud-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try JSONEncoder().encode(versions).write(to: staged, options: .withoutOverwriting)
        try FileManager.default.linkItem(at: staged, to: receipt)
    }

    static func validate(_ directory: URL) throws {
        // Older builds did not record a receipt for attendees. Leave those files local.
        for name in names where name != "overheard-map.json" && name != "attendees" {
            let url = directory.appendingPathComponent(name)
            if CloudFiles.exists(url), !accepts(url) {
                throw CloudError.message(String(localized: "File della riunione non verificato. Reimporta la registrazione per sincronizzarla."))
            }
        }
    }
    static func accepts(_ url: URL) -> Bool {
        guard names.contains(url.lastPathComponent) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let receipts = try? read(url.deletingLastPathComponent()), let expected = receipts[url.lastPathComponent],
              let actual = try? CloudFiles.version(url) else { return false }
        return actual == expected
    }
}
