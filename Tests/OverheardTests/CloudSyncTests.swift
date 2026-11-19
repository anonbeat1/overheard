import AVFoundation
import XCTest
@testable import Overheard

actor MemoryCloud: CloudStorageProvider {
    nonisolated let id: String
    /// Reports Dropbox-style content hashes instead of SHA-256, like DropboxProvider.
    nonisolated let dropboxHashes: Bool
    init(dropboxHashes: Bool = false, id: String = "test-provider") { self.dropboxHashes = dropboxHashes; self.id = id }
    nonisolated func fingerprint(_ file: URL) throws -> CloudFileVersion {
        dropboxHashes ? try DropboxContentHash.version(file) : try CloudFiles.version(file)
    }
    var data: [String: Data] = [:]
    var reserves = 0
    var uploads = 0
    var failUpload = false
    var failDownload = false
    var corruptDownload = false
    var downloads = 0
    var removals: [String] = []
    var failAfterUpload = false
    var failure: Error?
    var folders: [String: String] = [:]      // id -> name
    var parents: [String: String] = [:]      // file id -> folder id
    var sessions: [String: (id: String, received: Data)] = [:]
    var begins = 0
    var resumedFrom: [Int] = []
    var useFolders = false
    var useSessions = false
    var dropAfterBytes: Int?                 // a resumable transfer loses the connection after this many bytes
    func enable(folders: Bool = false, sessions: Bool = false) { useFolders = folders; useSessions = sessions }
    func setDrop(_ bytes: Int?) { dropAfterBytes = bytes }
    func reserveFolder() async throws -> String? { useFolders ? "folder-\(folders.count + 1)" : nil }
    func createFolder(id: String, name: String) async throws { folders[id] = name }
    func folderExists(_ id: String) async throws -> Bool { folders[id] != nil }
    func loseFolder(_ id: String) {
        folders[id] = nil
        for (file, parent) in parents where parent == id { data[file] = nil }
    }
    func upload(file: URL, id: String, name: String, parent: String?, replacing: Bool) async throws {
        try await upload(file: file, id: id, name: name, replacing: replacing)
        if let parent { parents[id] = parent }
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? {
        guard useSessions else { return nil }
        begins += 1
        let session = "session-\(begins)"
        sessions[session] = (id, Data())
        if let parent { parents[id] = parent }
        return session
    }
    func resumeUpload(file: URL, session: String) async throws {
        guard var open = sessions[session] else { throw CloudUploadExpired() }
        let whole = try Data(contentsOf: file)
        resumedFrom.append(open.received.count)
        let end = min(whole.count, dropAfterBytes.map { open.received.count + $0 } ?? whole.count)
        open.received.append(whole[open.received.count..<end])
        sessions[session] = open
        guard end == whole.count else { throw URLError(.networkConnectionLost) }
        data[open.id] = open.received; uploads += 1
        sessions[session] = nil
    }
    func expireSessions() { sessions = [:] }
    func reserve(meeting: CloudMeetingID, name: String) async throws -> String { reserves += 1; return "\(meeting.rawValue)-\(name)" }
    var probes = 0
    var removedFolders: [String] = []
    func removeMeetingFolder(_ folder: String, id: String?) async throws { removedFolders.append(folder) }
    func inspect(_ id: String) async throws -> CloudFileVersion? {
        probes += 1
        guard let data = data[id] else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try data.write(to: file)
        return try fingerprint(file)
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        if let failure { throw failure }
        if failUpload { throw CloudError.message("offline") }
        data[id] = try Data(contentsOf: file); uploads += 1
        if failAfterUpload { throw CloudError.message("connection lost after remote commit") }
    }
    func download(_ id: String, to destination: URL) async throws {
        downloads += 1
        guard let data = data[id] else { throw CloudError.message("missing remote") }
        try (corruptDownload ? Data("corrupt".utf8) : data).write(to: destination)
        if failDownload { throw CloudError.message("download interrupted") }
    }
    var removeLimit: Int?                    // the connection drops after this many removals
    func setRemoveLimit(_ value: Int?) { removeLimit = value }
    func remove(_ id: String) async throws {
        if let removeLimit, removals.count >= removeLimit { throw URLError(.networkConnectionLost) }
        removals.append(id); data.removeValue(forKey: id)
    }
    func setDownloadOffline(_ value: Bool) { failDownload = value }
    func setOffline(_ value: Bool) { failUpload = value }
    func setFailure(_ value: Error?) { failure = value }
    func setCorrupt(_ value: Bool) { corruptDownload = value }
    func setFailAfterUpload(_ value: Bool) { failAfterUpload = value }
    func replace(_ id: String, with value: Data?) { data[id] = value }
}

final class CloudSyncTests: XCTestCase {
    func testScanRecreatesMissingMeetingFolder() async throws {
        let cloud = MemoryCloud()
        await cloud.enable(folders: true)
        await run(.sync, cloud)
        let folder = try XCTUnwrap(manifest(cloud).folder)
        await cloud.loseFolder(folder)
        await run(.sync, cloud)
        // A meeting folder deleted on the cloud side is respected, not silently recreated and refilled.
        let after = try manifest(cloud)
        XCTAssertNil(after.lastError)
        XCTAssertEqual(Set(after.remoteDeleted?.keys ?? [:].keys), Set(after.files.keys))
        XCTAssertFalse(after.files.isEmpty)
        // The user chooses to put it back: everything is uploaded again and verified.
        await run(.reupload, cloud)
        let repaired = try manifest(cloud)
        XCTAssertNil(repaired.remoteDeleted)
        XCTAssertNil(repaired.lastError)
        for file in repaired.files.values {
            let version = try await cloud.inspect(file.id)
            XCTAssertEqual(version, file.version)
        }
    }
    func testFileDeletedOnTheCloudIsNotUploadedAgainUnlessAsked() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let old = try XCTUnwrap(manifest(cloud).files["transcript.md"])
        await cloud.replace(old.id, with: nil)
        await run(.sync, cloud)
        await run(.sync, cloud)
        var state = try manifest(cloud)
        XCTAssertNotNil(state.remoteDeleted?["transcript.md"])
        XCTAssertEqual(CloudSync.describe(state), String(localized: "Eliminata dal cloud. Carica di nuovo oppure tieni solo sul Mac."))
        let missing = try await cloud.inspect(old.id)
        XCTAssertNil(missing)
        // Even a local edit waits for the choice: nothing is uploaded or overwritten silently.
        try write("transcript.md", "# Meeting\n\nedited after the deletion")
        await run(.sync, cloud)
        state = try manifest(cloud)
        XCTAssertNotNil(state.remoteDeleted?["transcript.md"])
        let stillMissing = try await cloud.inspect(old.id)
        XCTAssertNil(stillMissing)
        await run(.reupload, cloud)
        state = try manifest(cloud)
        XCTAssertNil(state.remoteDeleted)
        let restored = try XCTUnwrap(state.files["transcript.md"])
        let remote = try await cloud.inspect(restored.id)
        XCTAssertEqual(remote, restored.version)
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("transcript.md"), encoding: .utf8), "# Meeting\n\nedited after the deletion")
    }
    func testScanDoesNotReplaceRemoteEdits() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let remote = try XCTUnwrap(manifest(cloud).files["transcript.md"])
        let edit = Data("edited remotely".utf8)
        await cloud.replace(remote.id, with: edit)
        await run(.sync, cloud)
        let data = await cloud.data
        XCTAssertEqual(data[remote.id], edit)
        XCTAssertNotNil(try manifest(cloud).lastError)
    }

    func testCopyDestinationRecoversArchivedAudioAndKeepsOriginals() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        await run(.evict, source)
        XCTAssertFalse(exists("recording.wav"))
        let original = try manifest(source)
        try await makeEngine().migrate(meeting, from: source, to: target, move: false, options: CloudOptions())
        let copied = try CloudManifest.load(meeting, destination: target.id)
        XCTAssertEqual(copied.files.count, original.files.count)
        XCTAssertNil(copied.migrationSource)
        // Audio that was only in the cloud is freed again once the new copy is verified.
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav"))
        XCTAssertEqual(copied.archived, ["recording.wav", "mic.wav"])
        let remaining = await source.data
        XCTAssertEqual(remaining.count, original.files.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: CloudManifest.archiveURL(meeting, destination: source.id).path))
    }

    func testAudioFreedBeforeAMoveComesBackFromTheNewDestination() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source); await run(.evict, source)
        try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
        XCTAssertFalse(exists("recording.wav"))
        let remaining = await source.data
        XCTAssertTrue(remaining.isEmpty)
        await makeEngine().perform(.restore, directories: [meeting], provider: target, options: CloudOptions(), force: true)
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("recording.wav")), "system audio")
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("mic.wav")), "microphone audio")
    }
    func testUnreachableOldServiceStillCopiesMeetingsThatAreOnTheMac() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let count = try manifest(source).files.count
        let leftBehind = try await makeEngine().migrate(meeting, from: nil, to: target, move: true, options: CloudOptions())
        XCTAssertTrue(leftBehind)                      // a move could not remove the old copies
        let copies = await target.data, originals = await source.data
        XCTAssertEqual(copies.count, count)
        XCTAssertEqual(originals.count, count)          // nothing touched on the unreachable service
        XCTAssertNil(try CloudManifest.load(meeting, destination: target.id).migrationSource)
    }
    func testUnreachableOldServiceCannotTransferAudioThatIsOnlyInTheCloud() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source); await run(.evict, source)
        do {
            try await makeEngine().migrate(meeting, from: nil, to: target, move: false, options: CloudOptions())
            XCTFail("Audio only in the old service cannot be copied without it")
        } catch {}
        let copies = await target.data
        XCTAssertTrue(copies.isEmpty)
        XCTAssertEqual(try manifest(source).archived, ["recording.wav", "mic.wav"])
    }
    func testRepairChecksRunOncePerDayUnlessSyncNowIsPressed() async throws {
        let cloud = MemoryCloud()
        let engine = makeEngine()
        await run(.sync, cloud, engine: engine)
        let afterFirst = await cloud.probes
        await run(.sync, cloud, engine: engine, force: false) // the minute timer
        await run(.sync, cloud, engine: engine, force: false)
        let afterTimer = await cloud.probes
        XCTAssertEqual(afterTimer, afterFirst)
        await run(.sync, cloud, engine: engine, force: true)  // Sync now
        let afterManual = await cloud.probes
        XCTAssertGreaterThan(afterManual, afterTimer)
    }
    func testFailedDestinationUploadKeepsOriginalsAndRecoveryRecord() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let original = try manifest(source)
        await target.setOffline(true)
        do {
            try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
            XCTFail("Transfer must fail")
        } catch { }
        let remaining = await source.data
        XCTAssertEqual(remaining.count, original.files.count)
        XCTAssertNotNil(try CloudManifest.load(meeting, destination: target.id).migrationSource)
        await target.setOffline(false)
        try await makeEngine().migrate(meeting, from: source, to: target, move: false, options: CloudOptions())
        XCTAssertNil(try CloudManifest.load(meeting, destination: target.id).migrationSource)
    }

    func testMoveDestinationRemovesOnlyVerifiedOriginalFiles() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let count = try manifest(source).files.count
        try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
        let remaining = await source.data
        let copies = await target.data
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(copies.count, count)
    }

    func testReturningToOriginalDestinationAfterInterruptedCopy() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        await target.setOffline(true)
        do {
            try await makeEngine().migrate(meeting, from: source, to: target, move: false, options: CloudOptions())
            XCTFail("Transfer must fail")
        } catch { }
        try await makeEngine().migrate(meeting, from: source, to: source, move: false, options: CloudOptions())
        XCTAssertNil(try manifest(source).migrationSource)
        XCTAssertFalse(try manifest(source).files.isEmpty)
    }

    func testPendingPathOccupiedByForeignFileIsNotOverwrittenOrRemoved() async throws {
        let cloud = MemoryCloud()
        var stored = CloudManifest(destination: cloud.id)
        stored.pending["recording.wav"] = "occupied"
        try stored.save(meeting)
        let foreign = Data("unrelated content".utf8)
        await cloud.replace("occupied", with: foreign)
        await run(.sync, cloud)
        var data = await cloud.data
        XCTAssertEqual(data["occupied"], foreign)
        XCTAssertNil(try manifest(cloud).files["recording.wav"])
        await run(.deleteRemote, cloud)
        data = await cloud.data
        XCTAssertEqual(data["occupied"], foreign)
    }

    func testSymlinkManifestIsRejected() throws {
        let external = root.appendingPathComponent("external.json")
        try JSONEncoder().encode(CloudManifest(destination: "test-provider")).write(to: external)
        try FileManager.default.createSymbolicLink(at: meeting.appendingPathComponent(CloudManifest.filename), withDestinationURL: external)
        XCTAssertThrowsError(try CloudManifest.load(meeting, destination: "test-provider"))
    }

    func testForeignCloudObjectsAreIgnoredAndFolderIsPreserved() async throws {
        let cloud = MemoryCloud()
        await cloud.enable(folders: true)
        await run(.sync, cloud)
        let folder = try XCTUnwrap(manifest(cloud).folder)
        await cloud.replace("unrelated", with: Data("user document".utf8))
        await run(.evict, cloud)
        await run(.restore, cloud)
        let downloads = await cloud.downloads
        XCTAssertEqual(downloads, 2)
        await run(.deleteRemote, cloud)
        let data = await cloud.data, removals = await cloud.removals
        XCTAssertEqual(data["unrelated"], Data("user document".utf8))
        XCTAssertFalse(removals.contains(folder))
        XCTAssertFalse(removals.contains("unrelated"))
    }

    func testChangedObjectIsNeitherDownloadedNorDeleted() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let remote = try XCTUnwrap(manifest(cloud).files["recording.wav"])
        await run(.evict, cloud)
        await cloud.replace(remote.id, with: Data("foreign replacement".utf8))
        await run(.restore, cloud)
        let downloads = await cloud.downloads
        XCTAssertEqual(downloads, 0)
        XCTAssertFalse(exists("recording.wav"))
        try write("recording.wav", "system audio")
        try write("mic.wav", "microphone audio")
        await run(.deleteRemote, cloud)
        let removals = await cloud.removals
        XCTAssertTrue(removals.isEmpty)
        XCTAssertFalse(try manifest(cloud).files.isEmpty)
    }

    var root: URL!
    var meeting: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        meeting = root.appendingPathComponent("2026-11-17_130000")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        CloudLedger.current = CloudLedger(directory: root.appendingPathComponent("map")) // never the real map
        try write("recording.wav", "system audio")
        try write("mic.wav", "microphone audio")
        try write("transcript.md", "# Meeting\n\n**[00:01] Speaker:** Hello")
    }
    override func tearDownWithError() throws {
        CloudLedger.current = CloudLedger(directory: FileManager.default.temporaryDirectory.appendingPathComponent("unused-map-\(UUID().uuidString)"))
        try FileManager.default.removeItem(at: root)
    }
    func makeEngine() -> CloudSyncEngine {
        CloudSyncEngine(sessions: CloudUploadSessions(url: root.appendingPathComponent("sessions.json")),
                        audioCache: CloudAudioCache(directory: root.appendingPathComponent("cache")))
    }
    /// A real WAV: a tone, 16-bit PCM.
    func writeTone(_ name: String, seconds: Double = 2, rate: Double = 48000, channels: AVAudioChannelCount = 1, frequency: Double = 440) throws {
        let url = meeting.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        defer { try? CloudProvenance.record(url) }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) { samples[i] = Float(0.3 * sin(2 * .pi * frequency * Double(i) / rate)) }
        }
        try file.write(from: buffer)
    }
    func size(_ name: String) throws -> Int { try meeting.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    func write(_ name: String, _ value: String) throws { try Data(value.utf8).write(to: meeting.appendingPathComponent(name)); try CloudProvenance.record(meeting.appendingPathComponent(name)) }
    func exists(_ name: String) -> Bool { CloudFiles.exists(meeting.appendingPathComponent(name)) }
    func manifest(_ cloud: MemoryCloud) throws -> CloudManifest { try CloudManifest.load(meeting, destination: cloud.id) }
    @discardableResult func run(_ action: CloudAction, _ cloud: MemoryCloud, engine: CloudSyncEngine? = nil,
                                force: Bool = true, resume: Bool = true, options: CloudOptions = CloudOptions()) async -> [String: String] {
        await (engine ?? makeEngine()).perform(action, directories: [meeting], provider: cloud, options: options, force: force, resume: resume).statuses
    }
    /// Moves the fixture meeting to an old recording date.
    func age(days: Double) throws {
        let old = root.appendingPathComponent("2020-01-01_090000")
        try FileManager.default.moveItem(at: meeting, to: old)
        meeting = old
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-days * 86400)], ofItemAtPath: meeting.path)
    }
    func testLibraryIdentityIsSharedAndCannotBeReplacedForKnownClient() async throws {
        let base = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var provider = LocalFolderProvider(kind: .icloud, base: base)
        provider.trashOnRemove = false
        let first = root.appendingPathComponent("client-a")
        let second = root.appendingPathComponent("client-b")
        let engine = makeEngine()
        try await engine.confirmLibrary(provider, in: first)
        let original = try await provider.libraryIdentity(createIfMissing: false)
        try await engine.confirmLibrary(provider, in: second)
        let shared = try await provider.libraryIdentity(createIfMissing: false)
        XCTAssertEqual(shared, original)
        try await provider.remove(".overheard-library.json")
        do {
            try await engine.confirmLibrary(provider, in: first)
            XCTFail("A known library silently recreated its missing marker")
        } catch {}
        let replacement = try await provider.libraryIdentity(createIfMissing: true)
        XCTAssertNotEqual(replacement, original)
        do {
            try await engine.confirmLibrary(provider, in: second)
            XCTFail("The client accepted a different library identity")
        } catch {}
    }

    func testTwoMacsConnectingToAnEmptyFolderAtOnceEndUpOnTheSameLibrary() async throws {
        let base = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var provider = LocalFolderProvider(kind: .icloud, base: base)
        provider.trashOnRemove = false
        let mine = root.appendingPathComponent("client-a")
        let engine = makeEngine()
        try await engine.confirmLibrary(provider, in: mine) // this Mac created and pinned its marker
        let marker = base.appendingPathComponent("Overheard/.overheard-library.json")
        let ours = try Data(contentsOf: marker)
        let pin = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: mine, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix(".overheard-library-") })
        // The other Mac's marker won; the sync client kept ours aside as a conflict copy.
        let theirs = UUID()
        try JSONEncoder().encode(CloudLibraryMarker(schema: 1, id: theirs)).write(to: marker)
        try ours.write(to: base.appendingPathComponent("Overheard/.overheard-library (conflicted copy Mac-B 2026-11-19).json"))
        try await engine.confirmLibrary(provider, in: mine) // adopts, does not stay stuck
        XCTAssertEqual(try String(contentsOf: pin, encoding: .utf8), theirs.uuidString)
        // A different library with no trace of ours is still a conflict.
        try JSONEncoder().encode(CloudLibraryMarker(schema: 1, id: UUID())).write(to: marker)
        try FileManager.default.removeItem(at: base.appendingPathComponent("Overheard/.overheard-library (conflicted copy Mac-B 2026-11-19).json"))
        do { try await engine.confirmLibrary(provider, in: mine); XCTFail("must not adopt an unrelated library") } catch {}
    }

    func testManualSyncEnrollsLegacyRecordingAndClearsFailure() async throws {
        try FileManager.default.removeItem(at: meeting.appendingPathComponent(CloudProvenance.filename))
        try Data("Old Overheard capture".utf8).write(to: meeting.appendingPathComponent("capture.log"))
        let cloud = MemoryCloud()
        let engine = makeEngine()

        let automatic = await engine.perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions())
        XCTAssertNotNil(automatic.failures[meeting.path])
        XCTAssertTrue(exists("recording.wav"))

        let manual = await engine.perform(.sync, directories: [meeting], provider: cloud,
                                          options: CloudOptions(archiveAfterSync: true), force: true)
        XCTAssertTrue(manual.failures.isEmpty)
        XCTAssertEqual(try manifest(cloud).archived, Set(CloudFiles.audio))
        XCTAssertTrue(exists("capture.log"))
    }

    func testManualLegacySyncRejectsSymbolicLinks() async throws {
        try FileManager.default.removeItem(at: meeting.appendingPathComponent(CloudProvenance.filename))
        try Data().write(to: meeting.appendingPathComponent("capture.log"))
        let foreign = root.appendingPathComponent("foreign")
        try Data("private".utf8).write(to: foreign)
        let transcript = meeting.appendingPathComponent("transcript.md")
        try FileManager.default.removeItem(at: transcript)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: foreign)

        let cloud = MemoryCloud()
        let report = await makeEngine().perform(.sync, directories: [meeting], provider: cloud,
                                                options: CloudOptions(archiveAfterSync: true), force: true)
        XCTAssertNotNil(report.failures[meeting.path])
        let uploaded = await cloud.data
        XCTAssertTrue(uploaded.isEmpty)
        XCTAssertTrue(exists("recording.wav"))
    }

    func testRemoteArchiveRestoresAndSynchronizesEdits() async throws {
        let cloud = MemoryCloud()
        let engine = makeEngine()
        let options = CloudOptions(archiveAfterSync: true)
        try write("summary.md", "Summary")
        try write("bookmarks.txt", "12")
        try write("title", "Cloud meeting")
        let contents = Set(["recording.wav", "mic.wav", "transcript.md", "summary.md", "bookmarks.txt", "title"])

        await run(.sync, cloud, engine: engine, options: options)
        let archived = try manifest(cloud)
        XCTAssertEqual(archived.archived, Set(CloudFiles.audio))
        XCTAssertTrue(CloudFiles.audio.allSatisfy { !exists($0) })
        XCTAssertTrue(exists("transcript.md"))

        // Existing libraries had their text removed after upload. An ordinary sync repopulates it.
        for name in ["transcript.md", "summary.md", "bookmarks.txt"] {
            try FileManager.default.removeItem(at: meeting.appendingPathComponent(name))
        }
        let textRestore = await engine.perform(.sync, directories: [meeting], provider: cloud, options: options)
        XCTAssertTrue(textRestore.failures.isEmpty)
        XCTAssertTrue(exists("transcript.md"))
        XCTAssertTrue(exists("summary.md"))
        XCTAssertTrue(exists("bookmarks.txt"))
        XCTAssertFalse(exists("recording.wav"))
        XCTAssertFalse(exists("mic.wav"))

        await run(.deleteRemote, cloud, engine: engine, options: options)
        let removals = await cloud.removals
        XCTAssertTrue(removals.isEmpty)

        await run(.restore, cloud, engine: engine, options: options)
        XCTAssertTrue(contents.allSatisfy { exists($0) })
        try write("transcript.md", "Updated from the Mac")
        await run(.sync, cloud, engine: engine, options: options)
        let updated = try manifest(cloud)
        let transcriptID = try XCTUnwrap(updated.files["transcript.md"]?.id)
        let remote = await cloud.data[transcriptID]
        XCTAssertEqual(remote, Data("Updated from the Mac".utf8))
        XCTAssertTrue(exists("transcript.md"))

        var aged = updated
        aged.restoredAt = Date().addingTimeInterval(-86500)
        try aged.save(meeting)
        await run(.sync, cloud, engine: engine, options: options)
        XCTAssertEqual(try manifest(cloud).archived, Set(CloudFiles.audio))
        XCTAssertTrue(exists("transcript.md"))
        await run(.restore, cloud, engine: engine, options: options)
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("transcript.md"), encoding: .utf8),
                       "Updated from the Mac")
    }

    func testRemoteArchiveKeepsFilesWhenUploadFails() async throws {
        let cloud = MemoryCloud()
        await cloud.setFailure(URLError(.notConnectedToInternet))
        await run(.sync, cloud, options: CloudOptions(archiveAfterSync: true))
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertTrue(exists("mic.wav"))
        XCTAssertTrue(exists("transcript.md"))
    }

    func testUploadEvictRestoreBothTracksAndKeepTranscript() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let stored = try manifest(cloud)
        XCTAssertEqual(stored.files.count, 4) // three files and the map copy
        await run(.evict, cloud)
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav")); XCTAssertTrue(exists("transcript.md"))
        await run(.restore, cloud)
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("recording.wav")), "system audio")
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("mic.wav")), "microphone audio")
        XCTAssertTrue(try manifest(cloud).archived.isEmpty)
    }
    func testOfflineRetryPersistsIDAcrossEngineRestart() async throws {
        let cloud = MemoryCloud()
        await cloud.setOffline(true)
        await run(.sync, cloud)
        let before = try manifest(cloud)
        XCTAssertEqual(before.pending.count, 1)
        XCTAssertNotNil(before.nextAttempt)
        await cloud.setOffline(false)
        await run(.sync, cloud, engine: makeEngine())
        XCTAssertTrue(try manifest(cloud).pending.isEmpty)
        let reserves = await cloud.reserves
        XCTAssertEqual(reserves, 4)
    }
    func testLostResponseAfterRemoteCommitDoesNotDuplicateUpload() async throws {
        let cloud = MemoryCloud()
        await cloud.setFailAfterUpload(true)
        await run(.sync, cloud)
        await cloud.setFailAfterUpload(false)
        await run(.sync, cloud)
        let uploads = await cloud.uploads
        let reserves = await cloud.reserves
        XCTAssertEqual(uploads, 4); XCTAssertEqual(reserves, 4) // three files and the map copy
    }
    func testLocalEditAfterInterruptedUpdateRecovers() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        try write("transcript.md", "first edit")
        await cloud.setFailAfterUpload(true)
        await run(.sync, cloud)
        try write("transcript.md", "second edit")
        await cloud.setFailAfterUpload(false)
        await run(.sync, cloud)
        XCTAssertNil(try manifest(cloud).lastError)
        XCTAssertEqual(try manifest(cloud).files["transcript.md"]?.version, try CloudFiles.version(meeting.appendingPathComponent("transcript.md")))
    }
    func testTwoInterruptedUpdatesInARowStillConverge() async throws {
        // Edit, upload committed but the reply lost; edit again, upload cut off; then the line comes back.
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        try write("transcript.md", "first edit")
        await cloud.setFailAfterUpload(true)
        await run(.sync, cloud)
        await cloud.setFailAfterUpload(false)
        try write("transcript.md", "second edit")
        await cloud.setFailure(URLError(.networkConnectionLost))
        await run(.sync, cloud)
        await cloud.setFailure(nil)
        await run(.sync, cloud)
        let stored = try manifest(cloud)
        XCTAssertNil(stored.lastError)
        XCTAssertNil(stored.pushed)
        let file = try XCTUnwrap(stored.files["transcript.md"])
        XCTAssertEqual(file.version, try CloudFiles.version(meeting.appendingPathComponent("transcript.md")))
        let remote = await cloud.data[file.id]
        XCTAssertEqual(remote, Data("second edit".utf8))
    }
    func testRemoteMutationBlocksEviction() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try XCTUnwrap(manifest(cloud).files["recording.wav"]?.id)
        await cloud.replace(id, with: Data("remote edit".utf8))
        await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testMissingRemoteBlocksEvictionAndDoesNotDeleteText() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try XCTUnwrap(manifest(cloud).files["mic.wav"]?.id)
        await cloud.replace(id, with: nil)
        await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav")); XCTAssertTrue(exists("transcript.md"))
    }
    func testLocalMutationBlocksEviction() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        try write("mic.wav", "new audio")
        await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testCorruptRestoreDoesNotInstallAudio() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud)
        await cloud.setCorrupt(true)
        await run(.restore, cloud)
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav"))
        XCTAssertNotNil(try manifest(cloud).lastError)
        await cloud.setCorrupt(false)
        await run(.restore, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testPinRestoresAndBlocksCleanup() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud); await run(.pin, cloud); await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(try manifest(cloud).pinned)
    }
    func testActiveRecordingAndTranscriptionAreSkipped() async throws {
        let cloud = MemoryCloud()
        let result = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), isActive: { _ in true })
        XCTAssertNotNil(result.statuses[meeting.path])
        XCTAssertTrue(result.failures.isEmpty)
        try write(".transcribing", "")
        await run(.sync, cloud)
        let uploads = await cloud.uploads
        XCTAssertEqual(uploads, 0)
        XCTAssertFalse(exists(CloudManifest.filename))
    }
    func testCopiedCloudIdentityBlocksEvenSingleMeetingAction() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let copy = root.appendingPathComponent("2026-11-18_130000")
        try FileManager.default.copyItem(at: meeting, to: copy)
        let result = await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertTrue(result[meeting.path]?.contains("duplicata") == true)
    }
    func testRemoteDeletionRefusesOnlyCopyAndSuspendsFutureSync() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud); await run(.deleteRemote, cloud)
        XCTAssertFalse(try manifest(cloud).files.isEmpty)
        await run(.restore, cloud); await run(.deleteRemote, cloud)
        XCTAssertTrue(try manifest(cloud).syncDisabled)
        XCTAssertTrue(exists("recording.wav"))
        await run(.sync, cloud, force: false, resume: false)
        XCTAssertTrue(try manifest(cloud).files.isEmpty)
    }
    func testBulkForcedSyncDoesNotResumeExplicitlyRemovedCloudCopy() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.deleteRemote, cloud)
        await run(.sync, cloud, force: true, resume: false) // Settings > Sync now
        XCTAssertTrue(try manifest(cloud).syncDisabled)
        XCTAssertTrue(try manifest(cloud).files.isEmpty)
        await run(.sync, cloud, force: true, resume: true)  // Sync now on this meeting
        XCTAssertFalse(try manifest(cloud).syncDisabled)
        XCTAssertEqual(try manifest(cloud).files.count, 4)
    }
    func testUnchangedMeetingManifestIsNotRewritten() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let url = meeting.appendingPathComponent(CloudManifest.filename)
        let before = try Data(contentsOf: url)
        let stamp = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try await Task.sleep(nanoseconds: 20_000_000)
        await run(.sync, cloud, force: false)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, stamp)
    }
    func testOfflineStopsPassWithoutChargingMeetingBackoff() async throws {
        let cloud = MemoryCloud()
        await cloud.setFailure(URLError(.notConnectedToInternet))
        let report = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), force: true)
        XCTAssertNotNil(report.stopped)
        let stored = try manifest(cloud)
        XCTAssertEqual(stored.attempts, 0)
        XCTAssertNil(stored.nextAttempt)
        XCTAssertEqual(stored.pending.count, 1) // the reserved ID survives for the next pass
    }
    func testAStoppedTransferIsNotAFailureOfTheMeeting() async throws {
        // Stop, a recording starting or a metered network cancel the task: URLSession throws URLError.cancelled.
        let cloud = MemoryCloud()
        await cloud.setFailure(URLError(.cancelled))
        let report = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), force: true)
        XCTAssertNil(report.stopped)
        let stored = try manifest(cloud)
        XCTAssertEqual(stored.attempts, 0)
        XCTAssertNil(stored.nextAttempt)
        XCTAssertNil(stored.lastError)
        await cloud.setFailure(nil)
        await run(.sync, cloud, force: false) // no retry delay was charged: the next pass uploads at once
        XCTAssertNil(try manifest(cloud).lastError)
        XCTAssertTrue(try manifest(cloud).pending.isEmpty)
    }
    func testAWiFiLoginPageStopsThePassInsteadOfFailingEveryMeeting() throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files")!
        for code in [302, 307, 408] {
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try CloudHTTP.check(response)) { error in
                XCTAssertEqual((error as? CloudError)?.affectsDestination, true, "HTTP \(code)")
            }
        }
    }
    func testLowDiskSpacePausesAudioUploadsWithoutChargingTheMeeting() async throws {
        let reserved = CloudSyncEngine.reservedSpace
        CloudSyncEngine.reservedSpace = Int64.max / 2 // no Mac has this much free
        defer { CloudSyncEngine.reservedSpace = reserved }
        let cloud = MemoryCloud()
        let report = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), force: true)
        XCTAssertNotNil(report.stopped)
        XCTAssertEqual(try manifest(cloud).attempts, 0)
        XCTAssertNil(try manifest(cloud).files["recording.wav"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: meeting.appendingPathComponent("recording.wav").path))
    }
    func testAnInterruptedMoveKeepsAnExactMapOfWhatLeftTheOldService() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let id = try manifest(source).meeting
        await source.setRemoveLimit(1) // the line drops after the first old copy is removed
        do { try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions()); XCTFail("expected a lost connection") }
        catch {}
        let placement = try XCTUnwrap(CloudLedger.current.entry(id)?.placements[source.id])
        let left = await source.data
        XCTAssertEqual(placement.removed.count, 1)
        // The map says exactly what is still there (its own copy is not listed in itself).
        XCTAssertEqual(Set(placement.live.values.map(\.id)), Set(left.keys.filter { !$0.hasSuffix(CloudLedger.mirrorName) }))
        await source.setRemoveLimit(nil)
        try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
        let empty = await source.data
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(try XCTUnwrap(CloudLedger.current.entry(id)?.placements[source.id]).live.isEmpty)
    }
    func testAFinishedMoveKeepsACopyEditedOnTheOldServiceInTheMap() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let original = try manifest(source)
        try await makeEngine().migrate(meeting, from: nil, to: target, move: true, options: CloudOptions())
        let edited = try XCTUnwrap(original.files["transcript.md"]?.id)
        await source.replace(edited, with: Data("edited on the old service".utf8))
        try await makeEngine().finishMove(meeting, source: source, target: target)
        let placement = try XCTUnwrap(CloudLedger.current.entry(original.meeting)?.placements[source.id])
        XCTAssertEqual(Array(placement.live.keys), ["transcript.md"])
    }
    func testQuotaErrorIsReportedForTheWholeDestination() async throws {
        let cloud = MemoryCloud()
        await cloud.setFailure(CloudError.destination("full"))
        let report = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), force: true)
        XCTAssertEqual(report.stopped, "full")
        XCTAssertNil(try manifest(cloud).nextAttempt)
    }
    func testConflictPreventsAutomaticUpload() async throws {
        let cloud = MemoryCloud()
        try write("transcript.sync-conflict-20261117-130000-ABCD.md", "other version")
        await run(.sync, cloud)
        let uploads = await cloud.uploads
        XCTAssertEqual(uploads, 0)
    }
    func testSymlinkAudioCannotBeUploaded() async throws {
        let cloud = MemoryCloud()
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("recording.wav"))
        try FileManager.default.createSymbolicLink(at: meeting.appendingPathComponent("recording.wav"), withDestinationURL: meeting.appendingPathComponent("transcript.md"))
        await run(.sync, cloud)
        XCTAssertNil(try manifest(cloud).files["recording.wav"])
    }
    func testConflictPatternsAndAmbiguousNumberedFiles() throws {
        try write("transcript.sync-conflict-20261117-130000-ABCD.md", "different")
        try write("summary (Mac's conflicted copy).md", "different")
        try write("transcript 2.md", "unrelated document")
        XCTAssertEqual(SyncConflicts.scan(meeting).count, 2)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("transcript 2.md"))
        try FileManager.default.copyItem(at: meeting.appendingPathComponent("transcript.md"), to: meeting.appendingPathComponent("transcript 2.md"))
        XCTAssertEqual(SyncConflicts.scan(meeting).count, 3)
    }
    func testEditedICloudCopyIsRecognisedByTheTranscriptStartTime() throws {
        // The real header Overheard writes: the folder name, no colons.
        try write("transcript.md", "# Transcript — 2026-11-17_121641\n\n**[00:00] Speaker 1:** original")
        try write("transcript 2.md", "# Transcript — 2026-11-17_121641\n\n**[00:00] Speaker 1:** edited on the other Mac")
        try write("summary 2.md", "# Weekly\n\nNo start time in here")
        try write("summary.md", "# Weekly\n\nDifferent")
        XCTAssertEqual(SyncConflicts.scan(meeting).map(\.url.lastPathComponent), ["transcript 2.md"])
        try write("transcript 2.md", "# Transcript — 2026-11-18_090000\n\nanother meeting")
        XCTAssertTrue(SyncConflicts.scan(meeting).isEmpty)
        try write("transcript 2.md", "# Transcript — 2026-11-17T12:16:41\n\nsame instant, ISO spelling")
        XCTAssertEqual(SyncConflicts.scan(meeting).count, 1)
    }
    func testNumberedFolderNeedsMatchingRecordingOrTranscript() throws {
        let copy = root.appendingPathComponent("2026-11-17_130000 2")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        XCTAssertTrue(SyncConflicts.scan(root).isEmpty)
        try FileManager.default.copyItem(at: meeting.appendingPathComponent("recording.wav"), to: copy.appendingPathComponent("recording.wav"))
        XCTAssertEqual(SyncConflicts.scan(root).map { $0.url.lastPathComponent }, [copy.lastPathComponent])
    }
    func testInterruptedDownloadRecoversWithoutInstallingPartialAudio() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud)
        await cloud.setDownloadOffline(true)
        await run(.restore, cloud)
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav"))
        await cloud.setDownloadOffline(false)
        await run(.restore, cloud, engine: makeEngine())
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testAutomaticCleanupAndTextSelection() async throws {
        let cloud = MemoryCloud()
        try age(days: 10)
        _ = await makeEngine().perform(.sync, directories: [meeting], provider: cloud,
                                            options: CloudOptions(audio: true, text: false, cleanupDays: 7), force: true)
        XCTAssertFalse(exists("recording.wav")); XCTAssertTrue(exists("transcript.md"))
        XCTAssertNil(try manifest(cloud).files["transcript.md"])
    }
    func testAutomaticCleanupUsesRecordingDateNotOnlyFolderCreation() async throws {
        let cloud = MemoryCloud()
        // Folder recreated long ago is not enough: this meeting was recorded today.
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: meeting.path)
        await run(.sync, cloud, options: CloudOptions(cleanupDays: 7))
        XCTAssertTrue(exists("recording.wav"))
    }
    func testAutomaticCleanupKeepsAudioOfMeetingWithoutTranscript() async throws {
        let cloud = MemoryCloud()
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("transcript.md"))
        try age(days: 10)
        await run(.sync, cloud, options: CloudOptions(cleanupDays: 7))
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testAutomaticCleanupIgnoredWhenAudioIsNotSynced() async throws {
        let cloud = MemoryCloud()
        try age(days: 10)
        await run(.sync, cloud, options: CloudOptions(audio: false, text: true, cleanupDays: 7))
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertNil(try manifest(cloud).lastError)
    }
    func testDownloadedAudioIsNotCleanedUpAgainImmediately() async throws {
        let cloud = MemoryCloud()
        try age(days: 10)
        await run(.sync, cloud, options: CloudOptions(cleanupDays: 7))
        XCTAssertFalse(exists("recording.wav"))
        await run(.restore, cloud)
        await run(.sync, cloud, options: CloudOptions(cleanupDays: 7))
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testConflictCopyOfHiddenManifestBlocksSync() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let copy = meeting.appendingPathComponent(".overheard-cloud.sync-conflict-20261117-130000-ABCD.json")
        try FileManager.default.copyItem(at: meeting.appendingPathComponent(CloudManifest.filename), to: copy)
        XCTAssertEqual(SyncConflicts.scan(meeting).map(\.url.lastPathComponent), [copy.lastPathComponent])
        let result = await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertNotNil(result[meeting.path])
        XCTAssertTrue(SyncConflicts.isManifestCopy(".overheard-cloud 2.json"))
        XCTAssertFalse(SyncConflicts.isManifestCopy(CloudManifest.filename))
        XCTAssertFalse(SyncConflicts.isManifestCopy(".cloud-1234"))
    }
    func testInterruptedResumableUploadContinuesFromStoredBytesAcrossRestart() async throws {
        let cloud = MemoryCloud()
        await cloud.enable(sessions: true)
        try write("recording.wav", String(repeating: "a", count: 100))
        await cloud.setDrop(40)
        await run(.sync, cloud, options: CloudOptions(audio: true, text: false)) // mic.wav (16 bytes) completes, recording.wav stops at 40
        await cloud.setDrop(nil)
        await run(.sync, cloud, engine: makeEngine(), options: CloudOptions(audio: true, text: false)) // a new engine: app restarted
        let resumed = await cloud.resumedFrom, begins = await cloud.begins
        XCTAssertEqual(begins, 3)                 // one session per file (map copy included), none reopened
        XCTAssertTrue(resumed.contains(40))       // continued at byte 40, not from zero
        let id = try XCTUnwrap(manifest(cloud).files["recording.wav"]?.id)
        let stored = await cloud.data[id]
        XCTAssertEqual(stored, Data(String(repeating: "a", count: 100).utf8))
        XCTAssertTrue(CloudUploadSessions(url: root.appendingPathComponent("sessions.json")).load().isEmpty)
    }
    func testExpiredUploadSessionStartsANewOne() async throws {
        let cloud = MemoryCloud()
        await cloud.enable(sessions: true)
        await cloud.setDrop(4)
        await run(.sync, cloud, options: CloudOptions(audio: true, text: false))
        await cloud.expireSessions()
        await cloud.setDrop(nil)
        await run(.sync, cloud, options: CloudOptions(audio: true, text: false))
        XCTAssertNil(try manifest(cloud).lastError)
        XCTAssertEqual(try manifest(cloud).files.count, 3)
    }
    func testEachMeetingGetsItsOwnRemoteFolder() async throws {
        let cloud = MemoryCloud()
        await cloud.enable(folders: true)
        try write("title", "Weekly / sync")
        await run(.sync, cloud)
        let stored = try manifest(cloud)
        let folder = try XCTUnwrap(stored.folder)
        XCTAssertEqual(stored.folderReady, true)
        let names = await cloud.folders, parents = await cloud.parents
        XCTAssertEqual(names[folder], "\(meeting.lastPathComponent) – Weekly - sync")
        XCTAssertTrue(stored.files.values.allSatisfy { parents[$0.id] == folder })
        await run(.deleteRemote, cloud)
        XCTAssertNil(try manifest(cloud).folder)
    }
    func testMeetingUploadedFlatStaysFlat() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        await cloud.enable(folders: true)
        try write("notes.md", "added later")
        await run(.sync, cloud)
        XCTAssertNil(try manifest(cloud).folder)
        XCTAssertNil(try manifest(cloud).files["notes.md"])
    }
    func testStorageLimitReclaimFollowsSafeCleanupRules() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        await run(.reclaim, cloud)
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav")); XCTAssertTrue(exists("transcript.md"))
        await run(.restore, cloud)
        await run(.reclaim, cloud)              // downloaded today: kept
        XCTAssertTrue(exists("recording.wav"))
    }
    func testStorageLimitReclaimSkipsPinnedAndUntranscribed() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.pin, cloud); await run(.reclaim, cloud)
        XCTAssertTrue(exists("recording.wav"))
        await run(.pin, cloud)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("transcript.md"))
        await run(.reclaim, cloud)
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertEqual(CloudFiles.localAudioBytes(meeting), Int64("system audio".utf8.count + "microphone audio".utf8.count))
    }
    func testProviderSpecificHashDrivesUploadEvictionAndRestore() async throws {
        let cloud = MemoryCloud(dropboxHashes: true)
        await run(.sync, cloud)
        XCTAssertEqual(try manifest(cloud).files["recording.wav"]?.version,
                       try DropboxContentHash.version(meeting.appendingPathComponent("recording.wav")))
        await run(.evict, cloud)
        XCTAssertFalse(exists("recording.wav"))
        await run(.restore, cloud)
        XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent("recording.wav")), "system audio")
    }
    func testReplacementWithCanonicalNameIsNotTrusted() throws {
        let url = meeting.appendingPathComponent("transcript.md")
        XCTAssertTrue(CloudProvenance.accepts(url))
        try Data("foreign replacement".utf8).write(to: url)
        XCTAssertFalse(CloudProvenance.accepts(url))
        XCTAssertFalse(try CloudFiles.names(in: meeting, options: CloudOptions()).contains("transcript.md"))
        try CloudProvenance.record(url) // explicit app output registration
        XCTAssertTrue(CloudProvenance.accepts(url))
    }
    func testProvenanceRejectsSymlinkReceipt() throws {
        let receipt = meeting.appendingPathComponent(CloudProvenance.filename)
        let saved = meeting.appendingPathComponent("saved-receipt.json")
        try FileManager.default.moveItem(at: receipt, to: saved)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: saved)
        XCTAssertFalse(CloudProvenance.accepts(meeting.appendingPathComponent("transcript.md")))
    }
    func testUnregisteredCanonicalFileIsNotTrusted() throws {
        let url = meeting.appendingPathComponent("summary.md")
        try Data("foreign summary".utf8).write(to: url)
        XCTAssertFalse(CloudProvenance.accepts(url))
    }
    func testArbitraryAttachmentsAreNeverUploadedEvenWithLegacyOptionEnabled() async throws {
        for name in ["foreign.md", "foreign.txt", "foreign.json", "recording.wav.json"] {
            try write(name, "unrelated user content")
        }
        let cloud = MemoryCloud()
        await run(.sync, cloud, options: CloudOptions(otherText: true))
        let stored = try manifest(cloud)
        for name in ["foreign.md", "foreign.txt", "foreign.json", "recording.wav.json"] {
            XCTAssertNil(stored.files[name])
            XCTAssertEqual(try String(contentsOf: meeting.appendingPathComponent(name)), "unrelated user content")
        }
    }
    func testEachKindOfMeetingFileCanBeChosenSeparately() async throws {
        try write("summary.md", "# Summary\n\n- [ ] action item")
        try write("bookmarks.txt", "00:42 important")
        try write("notes.md", "my notes")
        try write("source", "meet")
        try write("title", "Weekly")
        try write("engine", "local")
        try write("capture.log", "debug output")
        let only = { (options: CloudOptions) in try CloudFiles.names(in: self.meeting, options: options) }
        let metadata = ["engine", "source", "title"]
        XCTAssertEqual(try only(CloudOptions(audio: false, transcript: false, summary: false, bookmarks: false, otherText: false)), metadata)
        XCTAssertEqual(try only(CloudOptions(audio: false, transcript: false, summary: true, bookmarks: false, otherText: false)), ["engine", "source", "summary.md", "title"])
        XCTAssertEqual(try only(CloudOptions(audio: false, transcript: false, summary: false, bookmarks: true, otherText: false)), ["bookmarks.txt"] + metadata)
        XCTAssertEqual(try only(CloudOptions(audio: false, transcript: true, summary: false, bookmarks: false, otherText: false)), ["engine", "source", "title", "transcript.md"])
        XCTAssertEqual(try only(CloudOptions(audio: false, transcript: false, summary: false, bookmarks: false, otherText: true)), ["engine", "source", "title"])
        XCTAssertEqual(try only(CloudOptions(audio: true, transcript: false, summary: false, bookmarks: false, otherText: false)), ["engine", "mic.wav", "recording.wav", "source", "title"])
        XCTAssertFalse(try only(CloudOptions()).contains("capture.log"))
        // Turning a kind off later keeps what is already in the cloud.
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try XCTUnwrap(manifest(cloud).files["summary.md"]?.id)
        try write("summary.md", "edited")
        await run(.sync, cloud, options: CloudOptions(audio: true, transcript: true, summary: false, bookmarks: true, otherText: true))
        let remote = await cloud.data[id]
        XCTAssertEqual(remote, Data("# Summary\n\n- [ ] action item".utf8))
    }
    func testLosslessRoundTripRebuildsTheOriginalSamplesExactly() async throws {
        try writeTone("recording.wav", channels: 2)
        try writeTone("mic.wav", rate: 16000, frequency: 220)
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        for name in CloudFiles.audio { try FileManager.default.copyItem(at: meeting.appendingPathComponent(name), to: originals.appendingPathComponent(name)) }
        let wavBytes = try size("recording.wav")
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let stored = try XCTUnwrap(manifest(cloud).files["recording.wav"])
        XCTAssertEqual(stored.encoding, "alac")
        XCTAssertEqual(try manifest(cloud).files["mic.wav"]?.encoding, "alac")
        XCTAssertEqual(stored.format, CloudAudioFormat(sampleRate: 48000, channels: 2, bits: 16, float: false))
        XCTAssertEqual(stored.source, try CloudFiles.version(meeting.appendingPathComponent("recording.wav")))
        let fetched = await cloud.data[stored.id]
        let remote = try XCTUnwrap(fetched)
        XCTAssertEqual(String(decoding: remote[4..<8], as: UTF8.self), "ftyp") // an MPEG-4 container
        XCTAssertLessThan(remote.count, wavBytes)

        await run(.evict, cloud)
        XCTAssertFalse(exists("recording.wav")); XCTAssertFalse(exists("mic.wav"))
        await run(.restore, cloud)
        let restored = try AVAudioFile(forReading: meeting.appendingPathComponent("recording.wav"))
        XCTAssertEqual(restored.fileFormat.sampleRate, 48000)
        XCTAssertEqual(restored.fileFormat.channelCount, 2)
        XCTAssertEqual(restored.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(restored.length, 96000)
        for name in CloudFiles.audio {
            XCTAssertTrue(try CloudAudio.samplesEqual(originals.appendingPathComponent(name), meeting.appendingPathComponent(name)), name)
        }

        // The decoded WAV is what the cloud copy now stands for: no second upload, and it can be freed again.
        let uploads = await cloud.uploads
        await run(.sync, cloud)
        let after = await cloud.uploads
        XCTAssertEqual(after, uploads + 1) // only the map copy, which gained the history
        await run(.evict, cloud)
        XCTAssertFalse(exists("recording.wav"))
        XCTAssertNil(try manifest(cloud).lastError)
    }
    func testMaximumSavingsUsesAACAndSaysItIsNotIdentical() async throws {
        try writeTone("recording.wav", seconds: 3, channels: 2)
        let original = root.appendingPathComponent("original.wav")
        try FileManager.default.copyItem(at: meeting.appendingPathComponent("recording.wav"), to: original)
        let wavBytes = try size("recording.wav")
        let cloud = MemoryCloud()
        var options = CloudOptions()
        options.audioEncoding = .aac
        await run(.sync, cloud, options: options)
        let stored = try XCTUnwrap(manifest(cloud).files["recording.wav"])
        XCTAssertEqual(stored.encoding, "aac")
        let remote = await cloud.data[stored.id]
        XCTAssertLessThan((remote?.count ?? .max) * 5, wavBytes)
        await run(.evict, cloud); await run(.restore, cloud)
        XCTAssertFalse(try CloudAudio.samplesEqual(original, meeting.appendingPathComponent("recording.wav")))
        // A file keeps the form of its first upload, even if the setting changes later.
        await run(.sync, cloud, options: CloudOptions())
        XCTAssertEqual(try manifest(cloud).files["recording.wav"]?.encoding, "aac")
    }
    func testFloatWAVIsUploadedAsItIsWhenLosslessIsChosen() async throws {
        let url = meeting.appendingPathComponent("recording.wav")
        try FileManager.default.removeItem(at: url)
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                                           AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800))
            buffer.frameLength = 4800
            for i in 0..<4800 { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 10)) * 0.2 }
            try file.write(from: buffer)
        }
        try CloudProvenance.record(url)
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let stored = try XCTUnwrap(manifest(cloud).files["recording.wav"])
        XCTAssertNil(stored.encoding)
        let remote = await cloud.data[stored.id]
        XCTAssertEqual(remote, try Data(contentsOf: url))
    }
    func testCompressedCopyNeverFreesADifferentWAV() async throws {
        try writeTone("recording.wav")
        try writeTone("mic.wav")
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        try writeTone("recording.wav", frequency: 880) // new audio, not yet uploaded
        await run(.evict, cloud)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
    }
    func testOriginalFormatUploadsTheWAVItself() async throws {
        try writeTone("recording.wav")
        let cloud = MemoryCloud()
        var options = CloudOptions()
        options.audioEncoding = nil
        await run(.sync, cloud, options: options)
        let stored = try XCTUnwrap(manifest(cloud).files["recording.wav"])
        XCTAssertNil(stored.encoding)
        let remote = await cloud.data[stored.id]
        XCTAssertEqual(remote, try Data(contentsOf: meeting.appendingPathComponent("recording.wav")))
    }
    func testUnreadableAudioFallsBackToTheOriginalFile() async throws {
        let cloud = MemoryCloud() // the fixture's "audio" is plain text: not decodable
        await run(.sync, cloud)
        XCTAssertNil(try manifest(cloud).files["recording.wav"]?.encoding)
        XCTAssertNil(try manifest(cloud).lastError)
    }
    func testInterruptedCompressedUploadResumesWithTheSameEncodedBytes() async throws {
        try writeTone("recording.wav", seconds: 3)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("mic.wav"))
        let cloud = MemoryCloud()
        await cloud.enable(sessions: true)
        await cloud.setDrop(1000)
        await run(.sync, cloud, options: CloudOptions(audio: true, text: false))
        await cloud.setDrop(nil)
        await run(.sync, cloud, engine: makeEngine(), options: CloudOptions(audio: true, text: false))
        let begins = await cloud.begins, resumed = await cloud.resumedFrom
        XCTAssertEqual(begins, 2)           // plus the map copy; the cached encoding matched the open session
        XCTAssertTrue(resumed.contains(1000))
        XCTAssertNil(try manifest(cloud).lastError)
        let cache = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("cache").path)) ?? []
        XCTAssertTrue(cache.isEmpty)        // removed once uploaded
    }
    func testMeetingInUseIsNotChargedARetryDelay() async throws {
        let cloud = MemoryCloud()
        actor Calls { var n = 0; func next() -> Int { n += 1; return n } }
        let calls = Calls()
        // Free when the pass starts, in use as soon as the first file is about to upload.
        _ = await makeEngine().perform(.sync, directories: [meeting], provider: cloud, options: CloudOptions(), force: true,
                                       isActive: { _ in await calls.next() > 1 })
        let stored = try? manifest(cloud)
        XCTAssertEqual(stored?.attempts ?? 0, 0)
        XCTAssertNil(stored?.nextAttempt)
    }
    func testAudioNotReadyToFreeDoesNotHoldBackItsUpload() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud, options: CloudOptions(audio: false, text: true)) // text uploaded, audio not
        await run(.reclaim, cloud)                                              // storage limit tries to free audio
        XCTAssertTrue(exists("recording.wav"))
        XCTAssertEqual(try manifest(cloud).attempts, 0)
        XCTAssertNil(try manifest(cloud).nextAttempt)
    }
    func testPartialDownloadsLeftByACrashAreRemoved() async throws {
        let cloud = MemoryCloud()
        let stale = meeting.appendingPathComponent(".cloud-crashed"), fresh = meeting.appendingPathComponent(".migration-running")
        try Data("partial".utf8).write(to: stale); try Data("partial".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        await run(.sync, cloud)
        XCTAssertFalse(CloudFiles.exists(stale))
        XCTAssertTrue(CloudFiles.exists(fresh)) // could still be in use
    }
    func testKeptFolderCopyForgetsTheOriginalsCloudRecords() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let copy = root.appendingPathComponent("2026-11-17_130000 (Mac's conflicted copy)")
        try FileManager.default.copyItem(at: meeting, to: copy)
        let records = copy.appendingPathComponent(".overheard-cloud-destinations")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: copy.appendingPathComponent(".overheard-cloud 2.json"))
        let kept = try SyncConflicts.keepBoth(SyncConflict(url: copy, original: meeting))
        XCTAssertFalse(CloudFiles.exists(kept.appendingPathComponent(".overheard-cloud-destinations")))
        XCTAssertTrue(SyncConflicts.scan(kept).isEmpty)
    }
    func testSyncedFolderKeepsACopyButFreesNothingWithoutUploadConfirmation() async throws {
        let base = root.appendingPathComponent("Aruba Drive")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var folder = LocalFolderProvider(kind: .folder, base: base)
        folder.trashOnRemove = false
        let engine = makeEngine()
        _ = await engine.perform(.sync, directories: [meeting], provider: folder, options: CloudOptions(), force: true)
        let copy = base.appendingPathComponent("Overheard/\(meeting.lastPathComponent)/transcript.md")
        XCTAssertEqual(try String(contentsOf: copy), "# Meeting\n\n**[00:01] Speaker:** Hello")
        XCTAssertNil(try CloudManifest.load(meeting, destination: folder.id).lastError)
        // A plain folder cannot confirm the upload: freeing space must refuse.
        _ = await engine.perform(.evict, directories: [meeting], provider: folder, options: CloudOptions(), force: true)
        XCTAssertTrue(exists("recording.wav")); XCTAssertTrue(exists("mic.wav"))
        // The folder disappearing (app quit, disk unplugged) stops the pass instead of re-uploading.
        try FileManager.default.removeItem(at: base)
        let report = await engine.perform(.sync, directories: [meeting], provider: folder, options: CloudOptions(), force: true)
        XCTAssertNotNil(report.stopped)
        do { _ = try await folder.reserve(meeting: CloudMeetingID(), folder: "..", file: "x"); XCTFail("traversal") } catch {}
    }
    func testTransferChoiceIsRememberedPerOldAndNewDestination() {
        let target = "dropbox:test-\(UUID().uuidString)", source = "drive:acct:folder"
        defer { CloudSync.setChoice(nil, target: target, source: source) }
        XCTAssertNil(CloudSync.choice(target: target, source: source))
        CloudSync.setChoice(.copy, target: target, source: source)
        XCTAssertEqual(CloudSync.choice(target: target, source: source), .copy)
        XCTAssertNil(CloudSync.choice(target: "onedrive:other", source: source)) // another new destination asks again
        CloudSync.setChoice(.keep, target: target, source: source)
        XCTAssertEqual(CloudSync.choice(target: target, source: source), .keep)
    }
    func testDestinationsAreNamedAsPeopleKnowThem() throws {
        XCTAssertEqual(CloudSync.displayName("drive:123:folderid"), "Google Drive")
        XCTAssertEqual(CloudSync.displayName("dropbox:dbid:x"), "Dropbox")
        XCTAssertEqual(CloudSync.displayName("onedrive:abc"), "OneDrive")
        XCTAssertEqual(CloudSync.displayName("icloud:/Users/x/Library/Mobile Documents/com~apple~CloudDocs"), "iCloud Drive")
        XCTAssertTrue(CloudSync.displayName("folder:/Users/x/Aruba Drive").contains("Aruba Drive"))
        XCTAssertEqual(CloudSync.displayName("webdav:https://ewebdav.pcloud.com/Overheard/:me@x.com"), "ewebdav.pcloud.com")
        // A meeting mid-transfer is still "from" its original destination.
        var original = CloudManifest(destination: "drive:123:f")
        original.files["a.md"] = CloudRemoteFile(id: "x", version: CloudFileVersion(byteCount: 1, sha256: String(repeating: "a", count: 64)))
        var moving = CloudManifest(meeting: original.meeting, destination: "dropbox:dbid:x")
        moving.migrationSource = try JSONEncoder().encode(original)
        XCTAssertEqual(CloudSync.source(of: moving).destination, "drive:123:f")
        XCTAssertTrue(CloudSync.source(of: moving).inProgress)
        XCTAssertFalse(CloudSync.source(of: original).inProgress)
    }
    func testMoveIsCutAndPasteFoldersAndRecordsIncluded() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
        let remaining = await source.data, folders = await source.removedFolders
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(folders, [meeting.lastPathComponent])               // the emptied meeting folder goes too
        XCTAssertFalse(CloudFiles.exists(CloudManifest.archiveURL(meeting, destination: source.id))) // no stale reference
        XCTAssertNil(try CloudManifest.load(meeting, destination: target.id).pendingRemoval)
    }
    func testMoveFinishesWhenTheOldServiceIsBackAndKeepsCopiesEditedThere() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let original = try manifest(source)
        try await makeEngine().migrate(meeting, from: nil, to: target, move: true, options: CloudOptions()) // old service unreachable
        XCTAssertNotNil(try CloudManifest.load(meeting, destination: target.id).pendingRemoval)
        let waiting = CloudSync.describe(try CloudManifest.load(meeting, destination: target.id))
        XCTAssertTrue(waiting.contains("ricollegalo") || waiting.contains("reconnect"))
        // Meanwhile someone edited the transcript on the old service: that copy must survive.
        let edited = try XCTUnwrap(original.files["transcript.md"]?.id)
        await source.replace(edited, with: Data("edited on the old service".utf8))
        try await makeEngine().finishMove(meeting, source: source, target: target)
        let left = await source.data
        XCTAssertEqual(Array(left.keys), [edited])
        XCTAssertNil(try CloudManifest.load(meeting, destination: target.id).pendingRemoval)
    }
    func testExportZipContainsEverythingIncludingCloudOnlyAudio() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud)
        XCTAssertFalse(exists("recording.wav"))
        let staging = root.appendingPathComponent("staging/Overheard")
        let skipped = try await CloudExport.stage(meeting, into: staging, manifest: try manifest(cloud), provider: cloud)
        XCTAssertEqual(skipped, 0)
        let zip = root.appendingPathComponent("export.zip")
        try CloudExport.zip(staging, to: zip)
        let unpacked = root.appendingPathComponent("unpacked")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run(); ditto.waitUntilExit()
        let folder = unpacked.appendingPathComponent("Overheard/\(meeting.lastPathComponent)")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("transcript.md")), "# Meeting\n\n**[00:01] Speaker:** Hello")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("recording.wav")), "system audio") // fetched from the cloud
        XCTAssertFalse(exists("recording.wav"))                                                             // ~/Meetings untouched
        // Without the service, the audio is skipped and counted, not fatal.
        let again = try await CloudExport.stage(meeting, into: root.appendingPathComponent("staging2"), manifest: try manifest(cloud), provider: nil)
        XCTAssertEqual(again, 2)
    }
    func testSyncedFolderRemovesOnlyAnEmptyMeetingFolder() async throws {
        let base = root.appendingPathComponent("Synced")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Overheard/m1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Overheard/m2"), withIntermediateDirectories: true)
        try Data("user file".utf8).write(to: base.appendingPathComponent("Overheard/m2/notes.txt"))
        let folder = LocalFolderProvider(kind: .folder, base: base)
        try await folder.removeMeetingFolder("m1", id: nil)
        try await folder.removeMeetingFolder("m2", id: nil)
        XCTAssertFalse(CloudFiles.exists(base.appendingPathComponent("Overheard/m1")))
        XCTAssertTrue(CloudFiles.exists(base.appendingPathComponent("Overheard/m2/notes.txt")))
    }
    /// Two Macs edited the same transcript: the cloud's version must survive next to ours.
    func conflictFixture(_ cloud: MemoryCloud) async throws -> (id: String, theirs: Data, ours: Data) {
        await run(.sync, cloud)
        let id = try XCTUnwrap(manifest(cloud).files["transcript.md"]).id
        let theirs = Data("edited on the other Mac".utf8)
        await cloud.replace(id, with: theirs)
        let ours = Data("# Meeting\n\nedited on this Mac".utf8)
        try write("transcript.md", String(decoding: ours, as: UTF8.self))
        return (id, theirs, ours)
    }
    func testBothVersionsSurviveWhenTwoMacsEditTheSameFile() async throws {
        let cloud = MemoryCloud()
        let (id, theirs, ours) = try await conflictFixture(cloud)
        let status = await run(.sync, cloud)
        XCTAssertNotNil(try manifest(cloud).lastError)
        XCTAssertNotNil(status[meeting.path])
        // The cloud's version is untouched, ours is untouched, and the cloud's version sits next to it.
        let remote = await cloud.data
        XCTAssertEqual(remote[id], theirs)
        XCTAssertEqual(try Data(contentsOf: meeting.appendingPathComponent("transcript.md")), ours)
        let conflicts = SyncConflicts.scan(meeting)
        let copy = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(copy.original?.lastPathComponent, "transcript.md")
        XCTAssertTrue(copy.url.lastPathComponent.hasSuffix(".md"))
        XCTAssertEqual(try Data(contentsOf: copy.url), theirs)
        // Further passes wait for the person's choice: nothing is overwritten and no second copy appears.
        await run(.sync, cloud)
        await run(.sync, cloud)
        let again = await cloud.data
        XCTAssertEqual(again[id], theirs)
        XCTAssertEqual(SyncConflicts.scan(meeting).count, 1)
    }
    func testChoosingTheCloudVersionSettlesTheConflict() async throws {
        let cloud = MemoryCloud()
        let (id, theirs, _) = try await conflictFixture(cloud)
        await run(.sync, cloud)
        let copy = try XCTUnwrap(SyncConflicts.scan(meeting).first)
        try SyncConflicts.useCopy(copy, trash: { try FileManager.default.removeItem(at: $0) })
        XCTAssertEqual(try Data(contentsOf: meeting.appendingPathComponent("transcript.md")), theirs)
        await run(.sync, cloud)
        let state = try manifest(cloud)
        XCTAssertNil(state.lastError)
        XCTAssertTrue(SyncConflicts.scan(meeting).isEmpty)
        let remote = await cloud.data
        XCTAssertEqual(remote[id], theirs)
        XCTAssertEqual(state.files["transcript.md"]?.version.byteCount, Int64(theirs.count))
    }
    func testKeepingBothLetsOurVersionReplaceTheCloudOneKnowingly() async throws {
        let cloud = MemoryCloud()
        let (id, theirs, ours) = try await conflictFixture(cloud)
        await run(.sync, cloud)
        let copy = try XCTUnwrap(SyncConflicts.scan(meeting).first)
        let kept = try SyncConflicts.keepBoth(copy)
        XCTAssertEqual(try Data(contentsOf: kept), theirs) // the other version lives on as its own item
        await run(.sync, cloud)
        let remote = await cloud.data
        XCTAssertEqual(remote[id], ours)
        XCTAssertNil(try manifest(cloud).lastError)
    }
    func testDeletedMeetingCloudCopiesAreQueuedAndMovedToTheTrash() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let state = try manifest(cloud)
        XCTAssertTrue(try CloudTrashQueue.shared.enqueue(manifest: state, folder: meeting.lastPathComponent))
        // The folder is gone, the queue still knows what to remove.
        try FileManager.default.removeItem(at: meeting)
        let entry = try XCTUnwrap(CloudTrashQueue.shared.entries.first)
        XCTAssertEqual(Set(entry.items.map(\.name)), Set(state.files.keys))
        try await makeEngine().removeQueued(entry, provider: cloud)
        let removed = await cloud.removals
        XCTAssertEqual(Set(removed), Set(state.files.values.map(\.id)))
        let marked = try XCTUnwrap(CloudLedger.current.entry(state.meeting))
        XCTAssertEqual(marked.placements[cloud.id]?.live.count, 0)
        CloudTrashQueue.shared.remove(entry)
        XCTAssertTrue(CloudTrashQueue.shared.entries.isEmpty)
    }
    func testQueuedTrashNeverRemovesAFileSomeoneElseEdited() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let state = try manifest(cloud)
        try CloudTrashQueue.shared.enqueue(manifest: state, folder: meeting.lastPathComponent)
        let edited = try XCTUnwrap(state.files["transcript.md"])
        await cloud.replace(edited.id, with: Data("edited by a colleague".utf8))
        let entry = try XCTUnwrap(CloudTrashQueue.shared.entries.first)
        try await makeEngine().removeQueued(entry, provider: cloud)
        let removed = await cloud.removals
        XCTAssertFalse(removed.contains(edited.id))
        XCTAssertEqual(removed.count, state.files.count - 1)
        let data = await cloud.data
        XCTAssertEqual(data[edited.id], Data("edited by a colleague".utf8))
    }
    func testQueuedTrashSurvivesAFailureAndANewReader() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let state = try manifest(cloud)
        try CloudTrashQueue.shared.enqueue(manifest: state, folder: meeting.lastPathComponent)
        XCTAssertEqual(CloudTrashQueue.shared.entries.count, 1) // read back from disk, not memory
        // Nothing to queue for a meeting that never reached the cloud.
        var empty = state; empty.files = [:]
        XCTAssertFalse(try CloudTrashQueue.shared.enqueue(manifest: empty, folder: "x"))
    }
    func testTheProgressCountsOnlyWhatStillHasToBeUploaded() async throws {
        let cloud = MemoryCloud()
        // Nothing synced yet: every file counts, by its real size.
        let everything = CloudSync.pendingBytes(meeting, options: CloudOptions())
        let sizes = try ["recording.wav", "mic.wav", "transcript.md"].reduce(Int64(0)) {
            $0 + Int64(try Data(contentsOf: meeting.appendingPathComponent($1)).count)
        }
        XCTAssertGreaterThanOrEqual(everything, sizes)
        await run(.sync, cloud)
        // Uploaded and unchanged: nothing is left, so a new pass has no bar to fill from zero.
        XCTAssertEqual(CloudSync.pendingBytes(meeting, options: CloudOptions()), 0)
        // One file edited: only that file is pending.
        try write("transcript.md", "# Meeting\n\nedited after the upload")
        let edited = Int64(try Data(contentsOf: meeting.appendingPathComponent("transcript.md")).count)
        XCTAssertEqual(CloudSync.pendingBytes(meeting, options: CloudOptions()), edited)
    }
    func testUploadStateIgnoresFoldersMacOSDoesNotTrack() throws {
        let base = root.appendingPathComponent("plain")
        let folder = base.appendingPathComponent("Overheard/2026-11-17_130000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: folder.appendingPathComponent("transcript.md"))
        let state = LocalFolderProvider(kind: .folder, base: base).uploadState()
        XCTAssertEqual(state, LocalFolderProvider.UploadState()) // nothing claimed about files macOS cannot report on
        XCTAssertEqual(state.fraction, 1)
        // The fraction is the share of bytes already uploaded.
        let partial = LocalFolderProvider.UploadState(files: 4, pendingFiles: 1, bytes: 1000, pendingBytes: 250)
        XCTAssertEqual(partial.fraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(partial.doneFiles, 3)
    }
    func testRetentionDeletingEverythingAlsoQueuesTheCloudCopiesForTheTrash() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let state = try manifest(cloud)
        var trashed: [URL] = []
        let cleaned = Retention.run(skipping: nil, root: root, days: 1, mode: "all", cloudEnabled: true, trash: { trashed.append($0) })
        XCTAssertEqual(cleaned, 1)
        XCTAssertEqual(trashed.map(\.lastPathComponent), [meeting.lastPathComponent])
        let entry = try XCTUnwrap(CloudTrashQueue.shared.entries.first)
        XCTAssertEqual(entry.meeting, state.meeting)
        XCTAssertEqual(Set(entry.items.map(\.name)), Set(state.files.keys))
        CloudTrashQueue.shared.remove(entry)
    }
    func testRetentionKeepsTheAudioOnlyModeOutOfTheCloudAndUndoesAFailedTrash() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        var trashed: [URL] = []
        XCTAssertEqual(Retention.run(skipping: nil, root: root, days: 1, mode: "audio", cloudEnabled: true, trash: { trashed.append($0) }), 0)
        XCTAssertTrue(trashed.isEmpty)
        XCTAssertTrue(CloudTrashQueue.shared.entries.isEmpty)
        // The local trash fails: nothing may stay queued for a meeting that was not deleted.
        struct Refused: Error {}
        XCTAssertEqual(Retention.run(skipping: nil, root: root, days: 1, mode: "all", cloudEnabled: true, trash: { _ in throw Refused() }), 0)
        XCTAssertTrue(CloudTrashQueue.shared.entries.isEmpty)
        XCTAssertTrue(CloudFiles.exists(meeting))
    }
    func testReplaceIsRefusedWhenTheCloudFileChangedAfterTheCheck() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let known = try XCTUnwrap(manifest(cloud).files["transcript.md"])
        try await cloud.expectUnchanged(known.id, known.version)
        await cloud.replace(known.id, with: Data("arrived a moment ago".utf8))
        do { try await cloud.expectUnchanged(known.id, known.version); XCTFail("must refuse") } catch is CloudError {}
        await cloud.replace(known.id, with: nil)
        do { try await cloud.expectUnchanged(known.id, known.version); XCTFail("must refuse") } catch is CloudError {}
    }
    func testAnotherMacsPartialUploadIsNotMistakenForStale() throws {
        let fresh = root.appendingPathComponent(".overheard-upload-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
        let old = root.appendingPathComponent(".overheard-upload-\(Int(Date().timeIntervalSince1970) - 7200)-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent(".overheard-upload-\(UUID().uuidString)")
        for url in [fresh, old, legacy] { try Data("x".utf8).write(to: url) }
        // A copy keeps its source's modification date: a recording from yesterday must not look abandoned.
        let yesterday = Date().addingTimeInterval(-86400)
        for url in [fresh, old] { try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: url.path) }
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: legacy.path)
        XCTAssertFalse(LocalFolderProvider.isStaleUpload(fresh))
        XCTAssertTrue(LocalFolderProvider.isStaleUpload(old))
        XCTAssertTrue(LocalFolderProvider.isStaleUpload(legacy)) // old naming: the modification date decides
        XCTAssertFalse(LocalFolderProvider.isStaleUpload(root.appendingPathComponent("notes.md")))
    }
    func testGoogleDriveStyleConflictCopyIsRecognisedButOnlyWithMatchingContent() throws {
        try write("notes.md", "same text")
        try write("notes (1).md", "same text")
        try write("other (1).md", "unrelated, no original next to it")
        let found = SyncConflicts.scan(meeting)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["notes (1).md"])
        XCTAssertEqual(found.first?.original?.lastPathComponent, "notes.md")
        // A different text with a numeric suffix is not accused without evidence.
        try write("notes (1).md", "different text")
        XCTAssertTrue(SyncConflicts.scan(meeting).isEmpty)
    }
    func testFolderWithOnlyDSStoreIsRemoved() async throws {
        let base = root.appendingPathComponent("Synced")
        let folder = base.appendingPathComponent("Overheard/m1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent(".DS_Store"))
        try await LocalFolderProvider(kind: .folder, base: base).removeMeetingFolder("m1", id: nil)
        XCTAssertFalse(CloudFiles.exists(folder))
    }
    func testEveryBookmarkKeepsTheMeetingVerifiedForSync() throws {
        Bookmarks.add(meeting, seconds: 1.5)
        Bookmarks.add(meeting, seconds: 20)
        Bookmarks.add(meeting, seconds: 33.3)
        XCTAssertEqual(Bookmarks.load(meeting), [1.5, 20, 33.3])
        XCTAssertNoThrow(try CloudProvenance.validate(meeting))
    }
    func testTheMapOutlivesTheMeetingFolder() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try manifest(cloud).meeting
        try FileManager.default.removeItem(at: meeting) // trashed, lost disk…
        let entry = try XCTUnwrap(CloudLedger.current.entry(id))
        XCTAssertEqual(entry.folder, "2026-11-17_130000")
        XCTAssertEqual(entry.placements[cloud.id]?.live.count, 3)
        XCTAssertTrue(entry.events.contains { $0.text.contains("recording.wav") })
    }
    func testACopyOfTheMapTravelsToTheCloudAndSettles() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        await run(.sync, cloud) // the map changed while the first pass uploaded: the second sends it
        let id = try manifest(cloud).meeting
        let remote = try XCTUnwrap(try manifest(cloud).files[CloudLedger.mirrorName])
        let local = try Data(contentsOf: meeting.appendingPathComponent(CloudLedger.mirrorName))
        let entry = try JSONDecoder.iso8601.decode(CloudLedger.Entry.self, from: local)
        XCTAssertEqual(entry.meeting, id)
        XCTAssertEqual(entry.placements[cloud.id]?.live.count, 3) // the map never lists itself
        await run(.sync, cloud)
        XCTAssertEqual(try manifest(cloud).files[CloudLedger.mirrorName], remote) // stable: no re-upload loop
    }
    func testPurgeRemovesEveryCloudCopyAndKeepsTheMeetingOnTheMac() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let record = try manifest(cloud)
        let before = try FileManager.default.contentsOfDirectory(atPath: meeting.path).filter { !$0.hasPrefix(".") }.sorted()
        let kept = try await makeEngine().purge(meeting, record: record, provider: cloud)
        XCTAssertTrue(kept.isEmpty)
        let remaining = await cloud.data
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: meeting.path).filter { !$0.hasPrefix(".") }.sorted(), before)
        let entry = try XCTUnwrap(CloudLedger.current.entry(record.meeting))
        XCTAssertTrue(entry.placements[cloud.id]?.live.isEmpty == true) // the map remembers they were removed
    }
    func testAnInterruptedPurgeKeepsAnExactMapAndFinishesOnTheNextRun() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let record = try manifest(cloud)
        await cloud.setRemoveLimit(1)
        do { _ = try await makeEngine().purge(meeting, record: record, provider: cloud); XCTFail("the connection dropped") } catch {}
        let half = try XCTUnwrap(CloudLedger.current.entry(record.meeting)?.placements[cloud.id])
        XCTAssertEqual(half.removed.count, 1)              // exactly the file that went
        XCTAssertEqual(half.live.count, half.files.count - 1)
        await cloud.setRemoveLimit(nil)
        let kept = try await makeEngine().purge(meeting, record: record, provider: cloud) // same record, run again
        XCTAssertTrue(kept.isEmpty)
        let remaining = await cloud.data
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(CloudLedger.current.entry(record.meeting)?.placements[cloud.id]?.live.isEmpty == true)
    }
    func testStaleTranscriptionMarkersAreClearedButRecentOnesStay() throws {
        let fm = FileManager.default
        let old = root.appendingPathComponent("2026-10-22_152727"), fresh = root.appendingPathComponent("2026-11-18_090000")
        for dir in [old, fresh] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent(".transcribing").path, contents: nil)
        }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)], ofItemAtPath: old.appendingPathComponent(".transcribing").path)
        Transcriber.clearStaleMarkers(root: root)
        XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent(".transcribing").path))
        XCTAssertTrue(fm.fileExists(atPath: fresh.appendingPathComponent(".transcribing").path)) // maybe transcribing right now
    }
    func testPurgeNeverDeletesATranscriptThatIsOnlyInTheCloud() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let record = try manifest(cloud)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("transcript.md")) // deleted on the Mac
        let kept = try await makeEngine().purge(meeting, record: record, provider: cloud)
        XCTAssertEqual(kept, ["transcript.md"])
        let remaining = await cloud.data
        XCTAssertEqual(remaining.count, 1) // its last copy stays in the cloud
    }
    func testPurgeRefusesWhileAudioIsOnlyInTheCloud() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        await run(.evict, cloud)
        let record = try manifest(cloud)
        do {
            _ = try await makeEngine().purge(meeting, record: record, provider: cloud)
            XCTFail("the only copy must not be deleted")
        } catch {}
        let remaining = await cloud.data
        XCTAssertFalse(remaining.isEmpty)
    }
    func testTheMapRemembersWhereFilesWereMovedFromAndTo() async throws {
        let source = MemoryCloud()
        let target = MemoryCloud(id: "second-provider")
        await run(.sync, source)
        let id = try manifest(source).meeting
        try await makeEngine().migrate(meeting, from: source, to: target, move: true, options: CloudOptions())
        let entry = try XCTUnwrap(CloudLedger.current.entry(id))
        XCTAssertEqual(entry.placements[source.id]?.files.count, 3)   // still known…
        XCTAssertTrue(entry.placements[source.id]?.live.isEmpty == true) // …and marked removed
        XCTAssertEqual(entry.placements[target.id]?.live.count, 3)
    }
    func testALostMeetingIsRebuiltFromTheMapWithIdenticalAudio() async throws {
        try writeTone("recording.wav", channels: 2)
        try writeTone("mic.wav", rate: 16000, frequency: 220)
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        for name in CloudFiles.audio + ["transcript.md"] {
            try FileManager.default.copyItem(at: meeting.appendingPathComponent(name), to: originals.appendingPathComponent(name))
        }
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try manifest(cloud).meeting
        try FileManager.default.removeItem(at: meeting) // the folder is gone
        let entry = try XCTUnwrap(CloudLedger.current.entry(id))
        let place = try XCTUnwrap(entry.placements[cloud.id])
        let rebuilt = try await makeEngine().rebuild(entry, from: place, provider: cloud, into: root)
        XCTAssertEqual(rebuilt.lastPathComponent, "2026-11-17_130000")
        for name in CloudFiles.audio {
            XCTAssertTrue(try CloudAudio.samplesEqual(originals.appendingPathComponent(name), rebuilt.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(try Data(contentsOf: rebuilt.appendingPathComponent("transcript.md")), try Data(contentsOf: originals.appendingPathComponent("transcript.md")))
        // Back in the chain: the next pass finds nothing to upload, and the map says what happened.
        let uploads = await cloud.uploads
        await run(.sync, cloud)
        let after = await cloud.uploads
        XCTAssertEqual(after, uploads + 1) // only the map copy, which gained the history
        XCTAssertNil(try manifest(cloud).lastError)
        XCTAssertTrue(CloudLedger.current.entry(id)?.events.contains { $0.text.contains("ricostruita") || $0.text.contains("rebuilt") } == true)
        do { _ = try await makeEngine().rebuild(entry, from: place, provider: cloud, into: root); XCTFail("already on the Mac") } catch {}
    }
    func testLocalAbsenceNeverDeletesRemoteContent() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let id = try XCTUnwrap(manifest(cloud).files["recording.wav"]?.id)
        try FileManager.default.removeItem(at: meeting.appendingPathComponent("recording.wav"))
        await run(.sync, cloud)
        let remote = try await cloud.inspect(id)
        XCTAssertNotNil(remote)
        XCTAssertTrue(try manifest(cloud).archived.contains("recording.wav"))
    }
    func testPersistedRetryBackoffCanBeOverriddenManually() async throws {
        let cloud = MemoryCloud()
        await cloud.setOffline(true)
        await run(.sync, cloud)
        let reserves = await cloud.reserves
        await cloud.setOffline(false)
        await run(.sync, cloud, force: false)
        let after = await cloud.reserves
        XCTAssertEqual(reserves, after)
        XCTAssertNotNil(try manifest(cloud).nextAttempt)
        await run(.sync, cloud, force: true)
        XCTAssertNil(try manifest(cloud).nextAttempt)
    }
    func testKeepBothRenamesConflictWithoutDeletingEitherVersion() throws {
        let original = meeting.appendingPathComponent("transcript.md")
        let copy = meeting.appendingPathComponent("transcript (Mac's conflicted copy).md")
        try Data("alternative transcript".utf8).write(to: copy)
        let kept = try SyncConflicts.keepBoth(SyncConflict(url: copy, original: original))
        XCTAssertTrue(CloudFiles.exists(original)); XCTAssertTrue(CloudFiles.exists(kept))
        XCTAssertEqual(try String(contentsOf: kept), "alternative transcript")
        XCTAssertTrue(SyncConflicts.scan(meeting).isEmpty)
    }
    func testUseCopyPreservesOriginalInTrashAndRestoresCanonicalName() throws {
        let original = meeting.appendingPathComponent("transcript.md")
        let old = try String(contentsOf: original)
        let copy = meeting.appendingPathComponent("transcript.sync-conflict-20261117-130000-ABCD.md")
        try Data("chosen version".utf8).write(to: copy)
        let trash = root.appendingPathComponent("original-in-trash.md")
        try SyncConflicts.useCopy(SyncConflict(url: copy, original: original)) { source in
            try FileManager.default.moveItem(at: source, to: trash)
        }
        XCTAssertEqual(try String(contentsOf: original), "chosen version")
        XCTAssertEqual(try String(contentsOf: trash), old)
        XCTAssertFalse(CloudFiles.exists(copy))
    }
    func testKeepingCloudFolderCreatesIndependentIdentity() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud)
        let copy = root.appendingPathComponent("2026-11-17_130000 (Mac's conflicted copy)")
        try FileManager.default.copyItem(at: meeting, to: copy)
        let original = try manifest(cloud)
        let kept = try SyncConflicts.keepBoth(SyncConflict(url: copy, original: meeting))
        let independent = try CloudManifest.load(kept, destination: cloud.id)
        XCTAssertNotEqual(original.meeting, independent.meeting)
        XCTAssertTrue(independent.files.isEmpty)
        XCTAssertTrue(CloudFiles.exists(kept.appendingPathComponent("recording.wav")))
    }
    func testKeepingArchivedFolderRequiresRestoringFirst() async throws {
        let cloud = MemoryCloud()
        await run(.sync, cloud); await run(.evict, cloud)
        let copy = root.appendingPathComponent("2026-11-17_130000 (Mac's conflicted copy)")
        try FileManager.default.copyItem(at: meeting, to: copy)
        XCTAssertThrowsError(try SyncConflicts.keepBoth(SyncConflict(url: copy, original: meeting)))
        XCTAssertTrue(CloudFiles.exists(copy))
    }
    func testVerificationRejectsMalformedAndMismatchedDigests() {
        let a = CloudFileVersion(byteCount: 1, sha256: String(repeating: "a", count: 64))
        XCTAssertTrue(CloudVerification.matches(local: a, remote: a))
        XCTAssertFalse(CloudVerification.matches(local: a, remote: CloudFileVersion(byteCount: 1, sha256: "wrong")))
        XCTAssertFalse(CloudVerification.matches(local: a, remote: CloudFileVersion(byteCount: -1, sha256: a.sha256)))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
