import XCTest
@testable import Overheard

final class CloudProtocolStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class CloudProviderTests: XCTestCase {
    private var previous: URLSession!
    override func setUp() {
        previous = CloudHTTP.shared.session
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProtocolStub.self]
        CloudHTTP.shared.session = URLSession(configuration: config)
    }
    override func tearDown() {
        CloudHTTP.shared.session.invalidateAndCancel()
        CloudHTTP.shared.session = previous
        CloudProtocolStub.handler = nil
    }
    func testDriveFindsMarkedLibraryAcrossPages() async throws {
        CloudProtocolStub.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let filter = query.first { $0.name == "q" }?.value ?? ""
            let data: String
            if filter.contains("name = 'Overheard'") {
                if query.contains(where: { $0.name == "pageToken" && $0.value == "next" }) {
                    data = #"{"files":[{"id":"marked"}]}"#
                } else {
                    data = #"{"files":[{"id":"older"}],"nextPageToken":"next"}"#
                }
            } else if filter.contains("'marked' in parents") {
                XCTAssertTrue(filter.contains(".overheard-library.json"))
                data = #"{"files":[{"id":"marker-id"}]}"#
            } else {
                XCTAssertTrue(filter.contains("'older' in parents"))
                data = #"{"files":[]}"#
            }
            return (200, [:], Data(data.utf8))
        }
        let drive = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        let folder = try await drive.existingLibraryFolder()
        XCTAssertEqual(folder, "marked")
    }

    func testDriveReadsServerChecksumAndAuthenticates() async throws {
        let hash = String(repeating: "a", count: 64)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.url?.path, "/drive/v3/files/file123")
            return (200, [:], Data("{\"size\":\"12\",\"sha256Checksum\":\"\(hash)\",\"trashed\":false}".utf8))
        }
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        let version = try await provider.inspect("file123")
        XCTAssertEqual(version, CloudFileVersion(byteCount: 12, sha256: hash))
    }
    func testDriveMissingAndTrashedFilesAreNotVerified() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        CloudProtocolStub.handler = { _ in (404, [:], Data()) }
        let missing = try await provider.inspect("missing")
        XCTAssertNil(missing)
        CloudProtocolStub.handler = { _ in (200, [:], Data(#"{"trashed":true}"#.utf8)) }
        let trashed = try await provider.inspect("trashed")
        XCTAssertNil(trashed)
    }
    func testDriveRefusesTrashedLibraryBeforeReadingItsMarker() async throws {
        let drive = GoogleDriveProvider(folder: "library", accountID: "account", accessToken: { "test-token" })
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files/library")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], Data(#"{"mimeType":"application/vnd.google-apps.folder","trashed":true}"#.utf8))
        }
        let engine = CloudSyncEngine()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try await engine.confirmLibrary(drive, in: root)
            XCTFail("A library in the Drive trash must stop synchronization")
        } catch let error as CloudError {
            XCTAssertTrue(error.affectsDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testDriveReservesIDsAndCreatesChosenFolder() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        CloudProtocolStub.handler = { request in
            if request.url!.path.hasSuffix("generateIds") { return (200, [:], Data(#"{"ids":["stable-id"]}"#.utf8)) }
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, [:], Data(#"{"id":"new-folder"}"#.utf8))
        }
        let id = try await provider.reserve(meeting: CloudMeetingID(), name: "recording.wav")
        XCTAssertEqual(id, "stable-id")
        let folder = try await provider.createFolder(name: "My meetings")
        XCTAssertEqual(folder, "new-folder")
    }
    func testProviderErrorsExplainAuthenticationAndQuotaFailures() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        for status in [401, 403, 429, 507] {
            CloudProtocolStub.handler = { _ in (status, [:], Data()) }
            do { _ = try await provider.inspect("file"); XCTFail("HTTP \(status) must fail") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
    }
    func testDriveStartsUploadWithReservedIDThenStreamsFile() async throws {
        let provider = GoogleDriveProvider(folder: "folder", accountID: "account", accessToken: { "test-token" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("audio".utf8).write(to: file)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/upload/drive/v3/files")
                return (200, ["Location": "https://www.googleapis.com/upload/session"], Data())
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/upload/session")
            return (200, [:], Data())
        }
        try await provider.upload(file: file, id: "reserved-id", name: "meeting-recording.wav", replacing: false)
    }
    func testDriveResumesFromTheLastStoredByte() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        let previous = GoogleDriveProvider.chunkSize
        GoogleDriveProvider.chunkSize = 256 * 1024
        defer { GoogleDriveProvider.chunkSize = previous }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 7, count: 600 * 1024).write(to: file)
        var ranges: [String] = []
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            ranges.append(range)
            switch range {
            case "bytes */614400": return (308, ["Range": "bytes=0-262143"], Data())   // half stored before the interruption
            case "bytes 262144-524287/614400": return (308, ["Range": "bytes=0-524287"], Data())
            default: return (200, [:], Data())
            }
        }
        actor Progress {
            var offsets: [Int64] = []
            func record(_ sent: Int64) { offsets.append(sent) }
        }
        let progress = Progress()
        try await CloudSyncEngine.SyncProgress.$uploadBytes.withValue({ sent, total in
            XCTAssertEqual(total, 614400)
            await progress.record(sent)
        }) {
            try await provider.resumeUpload(file: file, session: "https://www.googleapis.com/upload/drive/v3/files?upload_id=abc")
        }
        let offsets = await progress.offsets
        XCTAssertEqual(offsets, [262144, 524288, 614400])
        XCTAssertEqual(ranges, ["bytes */614400", "bytes 262144-524287/614400", "bytes 524288-614399/614400"])
    }
    func testDriveExpiredSessionIsReported() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("audio".utf8).write(to: file)
        CloudProtocolStub.handler = { _ in (404, [:], Data()) }
        do {
            try await provider.resumeUpload(file: file, session: "https://www.googleapis.com/upload/drive/v3/files?upload_id=old")
            XCTFail("An unknown session must be reported as expired")
        } catch is CloudUploadExpired {}
    }
    func testDriveFolderCreationAcceptsAnExistingFolderAfterARetry() async throws {
        let provider = GoogleDriveProvider(folder: "parent", accountID: "account", accessToken: { "test-token" })
        CloudProtocolStub.handler = { request in
            if request.httpMethod == "POST" { return (409, [:], Data()) }
            XCTAssertEqual(request.url?.path, "/drive/v3/files/folder-id")
            return (200, [:], Data(#"{"mimeType":"application/vnd.google-apps.folder","trashed":false}"#.utf8))
        }
        try await provider.createFolder(id: "folder-id", name: "2026-11-17_1300 – Weekly")
    }
    func testDriveTakesATrashedFileBackInsteadOfLoopingOnConflict() async throws {
        let provider = GoogleDriveProvider(folder: "folder", accountID: "account", accessToken: { "test-token" })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("audio".utf8).write(to: file)
        var calls: [String] = []
        CloudProtocolStub.handler = { request in
            calls.append("\(request.httpMethod!) \(request.url!.path)")
            switch (request.httpMethod!, request.url!.path) {
            case ("POST", "/upload/drive/v3/files"): return (409, [:], Data())        // the reserved ID exists (in the trash)
            case ("PATCH", "/drive/v3/files/reserved-id"): return (200, [:], Data("{}".utf8)) // untrash
            case ("PATCH", "/upload/drive/v3/files/reserved-id"): return (200, ["Location": "https://www.googleapis.com/upload/s"], Data())
            default: return (200, [:], Data())
            }
        }
        try await provider.upload(file: file, id: "reserved-id", name: "a.wav", replacing: false)
        XCTAssertEqual(Array(calls.prefix(3)), ["POST /upload/drive/v3/files", "PATCH /drive/v3/files/reserved-id", "PATCH /upload/drive/v3/files/reserved-id"])
    }
    func testDriveRefusesUntrustedUploadSessionURL() async throws {
        let provider = GoogleDriveProvider(folder: "root", accountID: "account", accessToken: { "test-token" })
        CloudProtocolStub.handler = { _ in (200, ["Location": "https://untrusted.example/upload"], Data()) }
        do {
            try await provider.upload(file: URL(fileURLWithPath: "/unused"), id: "reserved-id", name: "audio", replacing: false)
            XCTFail("Must reject a session outside Google")
        } catch {}
    }
    func testWebDAVCreateUsesConditionalPUT() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("audio".utf8).write(to: file)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
            return (201, [:], Data())
        }
        try await provider.upload(file: file, id: "meeting-recording.wav", name: "audio", replacing: false)
    }
    func testWebDAVUsesDeterministicSafeObjectNames() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        let meeting = CloudMeetingID()
        let first = try await provider.reserve(meeting: meeting, name: "recording.wav")
        let second = try await provider.reserve(meeting: meeting, name: "recording.wav")
        XCTAssertEqual(first, second)
        do { _ = try await provider.inspect("../outside"); XCTFail("Path traversal must fail") } catch {}
    }
    func testWebDAVPresenceCheckIsAHeadNotADownload() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            return request.url!.lastPathComponent == "missing" ? (404, [:], Data()) : (200, ["Content-Length": "1234"], Data())
        }
        let present = try await provider.size("object")
        XCTAssertEqual(present, 1234)
        let missing = try await provider.size("missing")
        XCTAssertNil(missing)
    }
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int64, Int64)] = []
        func add(_ done: Int64, _ total: Int64) { lock.withLock { values.append((done, total)) } }
        var all: [(Int64, Int64)] { lock.withLock { values } }
    }
    func testDownloadReportsTheBytesReceivedAndReturnsTheFile() async throws {
        let body = Data((0..<1000).map { UInt8($0 % 251) })
        CloudProtocolStub.handler = { _ in (200, ["Content-Length": "1000"], body) }
        let reports = Reports()
        let (file, response) = try await CloudSyncEngine.SyncProgress.$downloadBytes.withValue({ done, total in reports.add(done, total) }) {
            try await CloudHTTP.download(for: URLRequest(url: URL(string: "https://example.com/audio")!))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try Data(contentsOf: file), body)
        // The callbacks are delivered asynchronously: wait for the last one instead of guessing how long it takes.
        for _ in 0..<100 where reports.all.last?.0 != 1000 { try await Task.sleep(nanoseconds: 50_000_000) }
        let last = try XCTUnwrap(reports.all.last)
        XCTAssertEqual(last.0, 1000)
        XCTAssertEqual(last.1, 1000)
    }
    func testDownloadWithoutAListenerIsThePlainDownload() async throws {
        CloudProtocolStub.handler = { _ in (200, [:], Data("plain".utf8)) }
        let (file, _) = try await CloudHTTP.download(for: URLRequest(url: URL(string: "https://example.com/a")!))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "plain")
    }
    func testCancellingTheTaskStopsADownloadAndReportsCancellation() async throws {
        CloudProtocolStub.handler = { _ in Thread.sleep(forTimeInterval: 1.5); return (200, [:], Data("late".utf8)) }
        let work = Task { () -> Error? in
            do {
                _ = try await CloudSyncEngine.SyncProgress.$downloadBytes.withValue({ _, _ in }) {
                    try await CloudHTTP.download(for: URLRequest(url: URL(string: "https://example.com/slow")!))
                }
                return nil
            } catch { return error }
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        work.cancel()
        let error = await work.value
        // If cancelling were ignored the download would finish and return normally, so no error would come back.
        XCTAssertTrue(error is CancellationError, "a stopped transfer is a cancellation, not a failure of the meeting: \(String(describing: error))")
    }
    func testTransferSummaryShowsShareSpeedAndTimeLeft() {
        let full = CloudPhaseView.summary(done: 250_000_000, total: 1_000_000_000, rate: 5_000_000)
        XCTAssertTrue(full.hasPrefix("25%"), full)
        XCTAssertTrue(full.contains("/s"), full)
        XCTAssertTrue(full.contains("~"), full)
        // No speed yet (first second of a transfer): only the share is claimed.
        XCTAssertEqual(CloudPhaseView.summary(done: 500, total: 1000, rate: nil), "50%")
        XCTAssertEqual(CloudPhaseView.summary(done: 2000, total: 1000, rate: nil), "100%") // never beyond 100%
    }
    func testOnlyARejectedGrantMeansReconnect() async throws {
        let url = URL(string: "https://oauth.example.com/token")!
        CloudProtocolStub.handler = { _ in (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
        do { _ = try await OAuthTokens.exchange(url, [:], expired: "expired"); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertTrue(error.needsReconnect); XCTAssertTrue(error.affectsDestination) }
        // A wrong app key is a setup problem: reconnecting cannot fix it, so it must not ask for that.
        CloudProtocolStub.handler = { _ in (400, [:], Data(#"{"error":"invalid_client"}"#.utf8)) }
        do { _ = try await OAuthTokens.exchange(url, [:], expired: "expired"); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertFalse(error.needsReconnect); XCTAssertTrue(error.affectsDestination) }
        // A 400 with no readable reason keeps the old, cautious meaning.
        CloudProtocolStub.handler = { _ in (400, [:], Data()) }
        do { _ = try await OAuthTokens.exchange(url, [:], expired: "expired"); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertTrue(error.needsReconnect) }
    }
    func testWebDAVRemovalMovesTheFileToTheTrashAndNeverDeletes() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        var seen: [(String, String, String?)] = []
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("user:password".utf8).base64EncodedString())
            seen.append((request.httpMethod ?? "", request.url?.path ?? "", request.value(forHTTPHeaderField: "Destination")))
            return (201, [:], Data())
        }
        try await provider.remove("object")
        XCTAssertFalse(seen.contains { $0.0 == "DELETE" })
        XCTAssertEqual(seen.map(\.0), ["MKCOL", "MKCOL", "MOVE"])
        XCTAssertEqual(seen[0].1, "/dav/meetings/.overheard-trash")
        XCTAssertTrue(seen[1].1.hasPrefix("/dav/meetings/.overheard-trash/"))
        XCTAssertEqual(seen[2].1, "/dav/meetings/object")
        let destination = try XCTUnwrap(seen[2].2)
        XCTAssertTrue(destination.hasPrefix("https://example.com/dav/meetings/.overheard-trash/"))
        XCTAssertTrue(destination.hasSuffix("-object"))
    }
    func testWebDAVWithoutMoveSupportKeepsTheFile() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        var methods: [String] = []
        CloudProtocolStub.handler = { request in
            methods.append(request.httpMethod ?? "")
            return request.httpMethod == "MOVE" ? (501, [:], Data()) : (405, [:], Data()) // folders exist, MOVE unsupported
        }
        do { try await provider.remove("object"); XCTFail("must not report success") } catch {}
        XCTAssertFalse(methods.contains("DELETE"))
    }
    func testWebDAVRemovingAMissingFileIsNotAnError() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://example.com/dav/meetings/")!, username: "user", password: "password")
        CloudProtocolStub.handler = { request in request.httpMethod == "MOVE" ? (404, [:], Data()) : (405, [:], Data()) }
        try await provider.remove("object")
    }
}
