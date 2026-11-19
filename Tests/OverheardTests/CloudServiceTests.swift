import CryptoKit
import XCTest
@testable import Overheard

/// Dropbox and S3 protocols against simulated HTTP. No real account is contacted.
final class CloudServiceTests: XCTestCase {
    private var previous: URLSession!
    private var file: URL!
    override func setUp() {
        previous = CloudHTTP.shared.session
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProtocolStub.self]
        CloudHTTP.shared.session = URLSession(configuration: config)
        file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() {
        CloudHTTP.shared.session.invalidateAndCancel()
        CloudHTTP.shared.session = previous
        CloudProtocolStub.handler = nil
        try? FileManager.default.removeItem(at: file)
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
    static func argument(_ request: URLRequest) -> [String: Any] {
        let text = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: S3

    /// Example "GET Object" from the AWS Signature Version 4 documentation.
    func testSigV4MatchesAWSReferenceExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.httpMethod = "GET"
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        let signer = S3Signer(accessKey: "AKIAIOSFODNN7EXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
        signer.sign(&request, payloadHash: S3Signer.emptyHash, date: Date(timeIntervalSince1970: 1369353600)) // 2013-05-24T00:00:00Z
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }
    func s3() -> S3Provider {
        S3Provider(endpoint: URL(string: "https://s3.example.com")!, region: "eu-central-003", bucket: "meetings",
                   prefix: "/Overheard/", accessKey: "key", secret: "secret")
    }
    func testS3UploadSignsBodyHashAndStoresDigest() async throws {
        try Data("audio bytes".utf8).write(to: file)
        let hash = try CloudFiles.version(file).sha256
        let provider = s3()
        let id = try await provider.reserve(meeting: CloudMeetingID(), folder: "2026-11-17_1300 2", file: "recording.wav")
        XCTAssertEqual(id, "Overheard/2026-11-17_1300 2/recording.wav")
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.absoluteString, "https://s3.example.com/meetings/Overheard/2026-11-17_1300%202/recording.wav")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), hash)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-meta-sha256"), hash)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-meta-sha256") == true)
            return (200, ["ETag": "\"e\""], Data())
        }
        try await provider.upload(file: file, id: id, name: "recording.wav", replacing: false)
    }
    func testS3InspectReadsStoredDigestAndMissingObjects() async throws {
        let hash = String(repeating: "b", count: 64)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            return (200, ["Content-Length": "42", "x-amz-meta-sha256": hash], Data())
        }
        let version = try await s3().inspect("Overheard/m/recording.wav")
        XCTAssertEqual(version, CloudFileVersion(byteCount: 42, sha256: hash))
        CloudProtocolStub.handler = { _ in (404, [:], Data()) }
        let missing = try await s3().inspect("Overheard/m/recording.wav")
        XCTAssertNil(missing)
    }
    func testS3CredentialAndRegionErrorsStopTheWholePass() async throws {
        for code in ["InvalidAccessKeyId", "SignatureDoesNotMatch", "NoSuchBucket", "RequestTimeTooSkewed"] {
            CloudProtocolStub.handler = { _ in (403, [:], Data("<Error><Code>\(code)</Code></Error>".utf8)) }
            do { try await s3().remove("Overheard/m/x"); XCTFail(code) }
            catch let error as CloudError { XCTAssertTrue(error.affectsDestination, code) }
        }
    }
    func testS3RejectsUnsafeKeysAndBuckets() async throws {
        do { _ = try await s3().reserve(meeting: CloudMeetingID(), folder: "..", file: "x"); XCTFail("traversal") } catch {}
        XCTAssertFalse(S3Provider.validBucket("My_Bucket"))
        XCTAssertTrue(S3Provider.validBucket("my-bucket.eu"))
        XCTAssertFalse(S3Provider.validEndpoint(URL(string: "http://s3.example.com")!))
    }
    func testS3MultipartResumesUploadingOnlyMissingParts() async throws {
        let previous = S3Provider.partSize
        S3Provider.partSize = 5
        defer { S3Provider.partSize = previous }
        try Data("0123456789AB".utf8).write(to: file) // parts: 01234 | 56789 | AB
        var uploaded: [String] = [], completed = ""
        let p1 = Insecure.MD5.hash(data: Data("01234".utf8)).map { String(format: "%02x", $0) }.joined()
        CloudProtocolStub.handler = { request in
            let query = request.url?.query ?? ""
            switch request.httpMethod {
            case "GET": // part 1 survived the interruption, and its ETag proves its bytes
                XCTAssertTrue(query.contains("uploadId=u1"))
                return (200, [:], Data("<ListPartsResult><IsTruncated>false</IsTruncated><Part><PartNumber>1</PartNumber><ETag>&quot;\(p1)&quot;</ETag><Size>5</Size></Part></ListPartsResult>".utf8))
            case "PUT":
                let body = Self.body(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.hex(body))
                uploaded.append(String(decoding: body, as: UTF8.self))
                return (200, ["ETag": "\"p\(uploaded.count + 1)\""], Data())
            default:
                completed = String(decoding: Self.body(request), as: UTF8.self)
                return (200, [:], Data("<CompleteMultipartUploadResult/>".utf8))
            }
        }
        try await s3().resumeUpload(file: file, session: "u1\nOverheard/m/recording.wav")
        XCTAssertEqual(uploaded, ["56789", "AB"])
        XCTAssertTrue(completed.contains("<PartNumber>1</PartNumber><ETag>\"\(p1)\"</ETag>"))
        XCTAssertTrue(completed.contains("<PartNumber>3</PartNumber>"))
    }
    func testS3StoredPartWithDifferentBytesIsUploadedAgain() async throws {
        let previous = S3Provider.partSize
        S3Provider.partSize = 5
        defer { S3Provider.partSize = previous }
        try Data("01234".utf8).write(to: file)
        var puts = 0
        CloudProtocolStub.handler = { request in
            switch request.httpMethod {
            case "GET": return (200, [:], Data("<ListPartsResult><Part><PartNumber>1</PartNumber><ETag>\"0000\"</ETag><Size>5</Size></Part></ListPartsResult>".utf8))
            case "PUT": puts += 1; return (200, ["ETag": "\"new\""], Data())
            default: return (200, [:], Data("<CompleteMultipartUploadResult/>".utf8))
            }
        }
        try await s3().resumeUpload(file: file, session: "u\nk/x")
        XCTAssertEqual(puts, 1) // same size is not enough to reuse a part
    }
    func testS3NewObjectsAreCreateOnlyWithFallbackForServicesWithout() async throws {
        try Data("audio".utf8).write(to: file)
        var conditional: [String?] = []
        CloudProtocolStub.handler = { request in
            conditional.append(request.value(forHTTPHeaderField: "If-None-Match"))
            return conditional.count == 1 ? (501, [:], Data("<Error><Code>NotImplemented</Code></Error>".utf8)) : (200, [:], Data())
        }
        try await s3().upload(file: file, id: "Overheard/m/a.md", name: "a.md", replacing: false)
        XCTAssertEqual(conditional, ["*", nil])
        conditional = []
        CloudProtocolStub.handler = { request in conditional.append(request.value(forHTTPHeaderField: "If-None-Match")); return (200, [:], Data()) }
        try await s3().upload(file: file, id: "Overheard/m/a.md", name: "a.md", replacing: true)
        XCTAssertEqual(conditional, [nil])
    }
    func testS3OnlyAnUnknownUploadMeansTheSessionExpired() async throws {
        try Data("01234".utf8).write(to: file)
        CloudProtocolStub.handler = { _ in (404, [:], Data("<Error><Code>NoSuchBucket</Code></Error>".utf8)) }
        do { try await s3().resumeUpload(file: file, session: "u\nk/x"); XCTFail("must fail") }
        catch is CloudUploadExpired { XCTFail("a missing bucket is not an expired session") }
        catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
        CloudProtocolStub.handler = { _ in (404, [:], Data("<Error><Code>NoSuchUpload</Code></Error>".utf8)) }
        do { try await s3().resumeUpload(file: file, session: "u\nk/x"); XCTFail("must fail") } catch is CloudUploadExpired {}
    }
    func testS3RemovalCopiesToTheTrashBeforeDeleting() async throws {
        var seen: [(String, String, String?)] = []
        CloudProtocolStub.handler = { request in
            seen.append((request.httpMethod ?? "", request.url?.path ?? "", request.value(forHTTPHeaderField: "x-amz-copy-source")))
            return request.httpMethod == "PUT" ? (200, [:], Data("<CopyObjectResult><ETag>\"a\"</ETag></CopyObjectResult>".utf8)) : (204, [:], Data())
        }
        try await s3().remove("Overheard/2026-11-17_130000/transcript.md")
        XCTAssertEqual(seen.map(\.0), ["PUT", "DELETE"])
        XCTAssertEqual(seen[0].2, "/meetings/Overheard/2026-11-17_130000/transcript.md")
        XCTAssertTrue(seen[0].1.hasPrefix("/meetings/Overheard/.trash/"))
        XCTAssertTrue(seen[0].1.hasSuffix("/2026-11-17_130000/transcript.md"))
        XCTAssertEqual(seen[1].1, "/meetings/Overheard/2026-11-17_130000/transcript.md")
    }
    func testS3RemovalDoesNotDeleteWhenTheTrashCopyFails() async throws {
        var methods: [String] = []
        CloudProtocolStub.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (400, [:], Data("<Error><Code>InvalidRequest</Code><Message>too large</Message></Error>".utf8))
        }
        do { try await s3().remove("Overheard/m/recording.wav"); XCTFail("must fail") } catch {}
        XCTAssertEqual(methods, ["PUT"])
    }
    func testS3RemovalOfAMissingObjectOnlyCountsAsDoneForNoSuchKey() async throws {
        CloudProtocolStub.handler = { _ in (404, [:], Data("<Error><Code>NoSuchKey</Code></Error>".utf8)) }
        try await s3().remove("Overheard/m/a.md")
        CloudProtocolStub.handler = { _ in (404, [:], Data("<Error><Code>NoSuchBucket</Code></Error>".utf8)) }
        do { try await s3().remove("Overheard/m/a.md"); XCTFail("a missing bucket must surface") }
        catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
    }
    func testS3HeadForbiddenStopsTheWholePassInsteadOfEveryMeeting() async throws {
        // A HEAD answer has no body, hence no error code.
        CloudProtocolStub.handler = { _ in (403, [:], Data()) }
        do { _ = try await s3().size("Overheard/m/a.md"); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
    }
    func testDriveReducedPermissionsStopThePassButOtherForbiddenStaysPerFile() throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/x")!
        let forbidden = HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!
        do { try CloudHTTP.check(forbidden, data: Data(#"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#.utf8)); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
        do { try CloudHTTP.check(forbidden, data: Data(#"{"error":{"errors":[{"reason":"forbidden"}]}}"#.utf8)); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertFalse(error.affectsDestination) }
    }
    func testS3AbandonedUploadIsAborted() async throws {
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertTrue(request.url?.query?.contains("uploadId=u9") == true)
            return (204, [:], Data())
        }
        try await s3().abandonUpload(session: "u9\nOverheard/m/recording.m4a\ncreate")
    }
    func testS3ErrorInsideSuccessfulCompletionIsAFailure() async throws {
        let previous = S3Provider.partSize
        S3Provider.partSize = 5
        defer { S3Provider.partSize = previous }
        try Data("01234".utf8).write(to: file)
        CloudProtocolStub.handler = { request in
            if request.httpMethod == "GET" {
                return (200, [:], Data("<ListPartsResult><Part><PartNumber>1</PartNumber><ETag>\"a\"</ETag><Size>5</Size></Part></ListPartsResult>".utf8))
            }
            return (200, [:], Data("<Error><Code>InternalError</Code></Error>".utf8))
        }
        do { try await s3().resumeUpload(file: file, session: "u\nk/x"); XCTFail("must fail") } catch {}
    }

    // MARK: Sign-in page

    func testSignInPageIsSelfContainedAndEscapesWhatItShows() {
        let data = OAuthPage.response(.failed(service: "Dropbox", message: "<script>alert(1)</script> & \"quotes\""))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertTrue(text.contains("Referrer-Policy: no-referrer"))
        XCTAssertFalse(text.contains("<script>"))
        XCTAssertTrue(text.contains("&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;quotes&quot;"))
        XCTAssertFalse(text.contains("http://") && text.range(of: #"(src|href)="https?://"#, options: .regularExpression) != nil)
        let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        XCTAssertTrue(text.contains("Content-Length: \(body.utf8.count)\r\n"))
    }
    func testSignInPageSaysWhatHappensNext() {
        let syncing = OAuthPage.html(.connected(service: "Google Drive", account: "me@example.com", place: "Drive", syncing: true))
        let waiting = OAuthPage.html(.connected(service: "Google Drive", account: nil, place: "Drive", syncing: false))
        XCTAssertTrue(syncing.contains("me@example.com"))
        XCTAssertNotEqual(syncing, waiting)
        XCTAssertTrue(syncing.contains("overheard://settings"))
    }

    // MARK: OneDrive

    func testQuickXorHashMatchesHandComputedReferenceValues() {
        func digest(_ bytes: [UInt8]) -> [UInt8] { var h = QuickXorHash(); h.update(bytes); return h.finalize() }
        XCTAssertEqual(digest([]), [UInt8](repeating: 0, count: 20))
        var one = [UInt8](repeating: 0, count: 20); one[0] = 0x01; one[12] = 0x01  // byte at bit 0, length 1
        XCTAssertEqual(digest([0x01]), one)
        var two = [UInt8](repeating: 0, count: 20); two[0] = 0x01; two[1] = 0x10; two[12] = 0x02 // 2nd byte shifted by 11 bits
        XCTAssertEqual(digest([0x01, 0x02]), two)
        XCTAssertEqual(QuickXorHash.hex(fromBase64: "AAAAAAAAAAAAAAAAAAAAAAAAAAA="), String(repeating: "0", count: 40))
    }
    func testQuickXorHashDoesNotDependOnChunkBoundaries() {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<5000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var whole = QuickXorHash(); whole.update(bytes)
        for cut in [1, 7, 159, 160, 161, 333, 2048] {
            var split = QuickXorHash()
            var start = 0
            while start < bytes.count { let end = min(bytes.count, start + cut); split.update(Array(bytes[start..<end])); start = end }
            XCTAssertEqual(split.finalize(), whole.finalize(), "chunk size \(cut)")
        }
    }
    func oneDrive() -> OneDriveProvider { OneDriveProvider(accountID: "me", accessToken: { "token" }) }
    func testOneDriveInspectReadsTheServerHashInsideTheAppFolder() async throws {
        let digest = Data((0..<20).map { UInt8($0) })
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertTrue(request.url!.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/me/drive/special/approot:/2026-11-17_1300/recording.m4a:"))
            if request.url!.absoluteString.contains("gone") { return (404, [:], Data()) }
            return (200, [:], Data(#"{"size":7,"file":{"hashes":{"quickXorHash":"\#(digest.base64EncodedString())"}}}"#.utf8))
        }
        let version = try await oneDrive().inspect("/2026-11-17_1300/recording.m4a")
        XCTAssertEqual(version, CloudFileVersion(byteCount: 7, sha256: digest.map { String(format: "%02x", $0) }.joined()))
        XCTAssertTrue(CloudVerification.matches(local: version!, remote: version!))
    }
    func testOneDriveNewFilesNeverOverwriteAndPathsAreSafe() async throws {
        try Data("hi".utf8).write(to: file)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix(":/content?@microsoft.graph.conflictBehavior=fail"))
            return (201, [:], Data("{}".utf8))
        }
        try await oneDrive().upload(file: file, id: "/m/a.md", name: "a.md", replacing: false)
        do { _ = try await oneDrive().reserve(meeting: CloudMeetingID(), folder: "..", file: "x"); XCTFail("traversal") } catch {}
    }
    func testOneDriveResumesWhereTheSessionStoppedWithoutSendingTheToken() async throws {
        let previous = OneDriveProvider.chunkSize
        OneDriveProvider.chunkSize = 4
        defer { OneDriveProvider.chunkSize = previous }
        try Data("abcdefghij".utf8).write(to: file)
        var ranges: [String] = []
        CloudProtocolStub.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) // upload URLs are pre-authenticated
            if request.httpMethod == "GET" { return (200, [:], Data(#"{"nextExpectedRanges":["4-"]}"#.utf8)) }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            ranges.append(range)
            return range.hasPrefix("bytes 8-") ? (201, [:], Data("{}".utf8)) : (202, [:], Data(#"{"nextExpectedRanges":["8-"]}"#.utf8))
        }
        try await oneDrive().resumeUpload(file: file, session: "https://api.onedrive.com/rup/abc")
        XCTAssertEqual(ranges, ["bytes 4-7/10", "bytes 8-9/10"])
        do { try await oneDrive().resumeUpload(file: file, session: "https://evil.example/rup"); XCTFail("untrusted") } catch is CloudUploadExpired {}
    }
    func testOneDriveDownloadFollowsOnlyMicrosoftRedirects() async throws {
        let target = file.appendingPathExtension("out")
        defer { try? FileManager.default.removeItem(at: target) }
        CloudProtocolStub.handler = { request in
            if request.url!.host == "graph.microsoft.com" { return (302, ["Location": "https://public.dm.files.1drv.com/x"], Data()) }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, [:], Data("audio".utf8))
        }
        try await oneDrive().download("/m/a.m4a", to: target)
        XCTAssertEqual(try String(contentsOf: target), "audio")
        CloudProtocolStub.handler = { _ in (302, ["Location": "https://evil.example/x"], Data()) }
        do { try await oneDrive().download("/m/a.m4a", to: file.appendingPathExtension("bad")); XCTFail("untrusted redirect") } catch {}
    }

    // MARK: WebDAV setup

    func testWebDAVSetupCreatesTheFolderAndChecksCredentials() async throws {
        let provider = WebDAVProvider(endpoint: URL(string: "https://webdav.example.com/Overheard/")!, username: "me", password: "pw")
        var methods: [String] = []
        CloudProtocolStub.handler = { request in
            methods.append(request.httpMethod!)
            return request.httpMethod == "MKCOL" ? (405, [:], Data()) : (207, [:], Data("<multistatus/>".utf8))
        }
        try await provider.prepare()
        XCTAssertEqual(methods, ["MKCOL", "PROPFIND"])
        CloudProtocolStub.handler = { _ in (401, [:], Data()) }
        do { try await provider.prepare(); XCTFail("wrong password") } catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
    }

    // MARK: Dropbox

    func testDropboxContentHashUsesFourMegabyteBlocks() throws {
        let block = DropboxContentHash.block
        var data = Data(repeating: 1, count: block)
        data.append(contentsOf: [2, 3])
        try data.write(to: file)
        var expected = SHA256()
        expected.update(data: Data(SHA256.hash(data: data.prefix(block))))
        expected.update(data: Data(SHA256.hash(data: data.suffix(2))))
        XCTAssertEqual(try DropboxContentHash.version(file),
                       CloudFileVersion(byteCount: Int64(block + 2), sha256: expected.finalize().map { String(format: "%02x", $0) }.joined()))
        try Data().write(to: file)
        XCTAssertEqual(try DropboxContentHash.version(file).sha256, S3Signer.emptyHash)
    }
    func testDropboxArgumentHeaderIsASCII() throws {
        let header = try DropboxProvider.argument(["path": "/Riunione è 🎙/a.md"])
        XCTAssertTrue(header.allSatisfy(\.isASCII))
        let decoded = try JSONSerialization.jsonObject(with: Data(header.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["path"], "/Riunione è 🎙/a.md")
    }
    func dropbox() -> DropboxProvider { DropboxProvider(accountID: "dbid:1", accessToken: { "token" }) }
    func testDropboxPathsAreReadableAndSafe() async throws {
        let id = try await dropbox().reserve(meeting: CloudMeetingID(), folder: "2026-11-17_1300", file: "recording.wav")
        XCTAssertEqual(id, "/2026-11-17_1300/recording.wav")
        do { _ = try await dropbox().reserve(meeting: CloudMeetingID(), folder: "..", file: "x"); XCTFail("traversal") } catch {}
    }
    func testDropboxInspectReportsMissingAndContentHash() async throws {
        let hash = String(repeating: "c", count: 64)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            let body = (try? JSONSerialization.jsonObject(with: Self.body(request))) as? [String: String]
            if body?["path"] == "/gone" { return (409, [:], Data(#"{"error_summary":"path/not_found/.","error":{".tag":"path"}}"#.utf8)) }
            return (200, [:], Data(#"{".tag":"file","size":7,"content_hash":"\#(hash)"}"#.utf8))
        }
        let missing = try await dropbox().inspect("/gone")
        XCTAssertNil(missing)
        let found = try await dropbox().inspect("/m/recording.wav")
        XCTAssertEqual(found, CloudFileVersion(byteCount: 7, sha256: hash))
    }
    func testDropboxReplaceCommitsAgainstTheRevisionTheEngineVerified() async throws {
        let hash = String(repeating: "d", count: 64)
        try Data("hello".utf8).write(to: file)
        var modes: [Any?] = []
        CloudProtocolStub.handler = { request in
            if request.url?.absoluteString.hasSuffix("files/get_metadata") == true {
                return (200, [:], Data(#"{".tag":"file","size":7,"content_hash":"\#(hash)","rev":"0123abcd"}"#.utf8))
            }
            modes.append(Self.argument(request)["mode"])
            return (200, [:], Data("{}".utf8))
        }
        let provider = dropbox()
        try await provider.expectUnchanged("/m/a.md", CloudFileVersion(byteCount: 7, sha256: hash))
        try await provider.upload(file: file, id: "/m/a.md", name: "a.md", replacing: true)
        let mode = try XCTUnwrap(modes.first as? [String: String])
        XCTAssertEqual(mode[".tag"], "update")
        XCTAssertEqual(mode["update"], "0123abcd")
        // The revision is used once: a second replace without a new check falls back to the plain overwrite.
        try await provider.upload(file: file, id: "/m/a.md", name: "a.md", replacing: true)
        XCTAssertEqual(modes.last as? String, "overwrite")
    }
    func testDropboxRefusesToReplaceAFileThatChanged() async throws {
        let hash = String(repeating: "d", count: 64)
        CloudProtocolStub.handler = { _ in (200, [:], Data(#"{".tag":"file","size":9,"content_hash":"\#(String(repeating: "e", count: 64))","rev":"ffff0000"}"#.utf8)) }
        do { try await dropbox().expectUnchanged("/m/a.md", CloudFileVersion(byteCount: 7, sha256: hash)); XCTFail("must refuse") }
        catch is CloudError {}
        CloudProtocolStub.handler = { _ in (409, [:], Data(#"{"error_summary":"path/not_found/.","error":{".tag":"path"}}"#.utf8)) }
        do { try await dropbox().expectUnchanged("/m/a.md", CloudFileVersion(byteCount: 7, sha256: hash)); XCTFail("must refuse") }
        catch is CloudError {}
    }
    func testDropboxFullAccountStopsThePass() async throws {
        try Data("x".utf8).write(to: file)
        CloudProtocolStub.handler = { _ in (409, [:], Data(#"{"error_summary":"path/insufficient_space/..","error":{".tag":"path"}}"#.utf8)) }
        do { try await dropbox().upload(file: file, id: "/m/a.md", name: "a.md", replacing: false); XCTFail("must fail") }
        catch let error as CloudError { XCTAssertTrue(error.affectsDestination) }
    }
    func testDropboxSmallUploadIsOneRequestThatNeverOverwritesByAccident() async throws {
        try Data("hello".utf8).write(to: file)
        CloudProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://content.dropboxapi.com/2/files/upload")
            XCTAssertEqual(Self.argument(request)["mode"] as? String, "add")
            XCTAssertEqual(Self.argument(request)["autorename"] as? Bool, false)
            return (200, [:], Data("{}".utf8))
        }
        try await dropbox().upload(file: file, id: "/m/a.md", name: "a.md", replacing: false)
        let session = try await dropbox().beginUpload(id: "/m/a.md", name: "a.md", parent: nil, replacing: false,
                                                      version: CloudFileVersion(byteCount: 5, sha256: S3Signer.emptyHash))
        XCTAssertNil(session)
    }
    func testDropboxSessionResumesAtTheOffsetDropboxReports() async throws {
        let previous = DropboxProvider.chunkSize
        DropboxProvider.chunkSize = 4
        defer { DropboxProvider.chunkSize = previous }
        try Data("abcdefghij".utf8).write(to: file)
        var appended: [String] = [], finished: [String: Any] = [:]
        CloudProtocolStub.handler = { request in
            let argument = Self.argument(request)
            let offset = ((argument["cursor"] as? [String: Any])?["offset"] as? NSNumber)?.intValue ?? -1
            switch request.url?.lastPathComponent {
            case "append_v2":
                if offset == 0 { // 4 bytes were stored before the interruption
                    return (409, [:], Data(#"{"error_summary":"incorrect_offset/..","error":{".tag":"incorrect_offset","correct_offset":4}}"#.utf8))
                }
                appended.append("\(offset):" + String(decoding: Self.body(request), as: UTF8.self))
                return (200, [:], Data("null".utf8))
            case "finish":
                finished = argument
                return (200, [:], Data("{}".utf8))
            default: XCTFail("unexpected \(request.url!)"); return (500, [:], Data())
            }
        }
        let session = #"{"path":"/m/recording.wav","replacing":false,"session":"s1"}"#
        try await dropbox().resumeUpload(file: file, session: session)
        XCTAssertEqual(appended, ["4:efgh", "8:ij"])
        XCTAssertEqual(((finished["cursor"] as? [String: Any])?["offset"] as? NSNumber)?.intValue, 10)
        XCTAssertEqual((finished["commit"] as? [String: Any])?["path"] as? String, "/m/recording.wav")
    }
    func testDropboxUnknownSessionIsReportedAsExpired() async throws {
        try Data("abc".utf8).write(to: file)
        CloudProtocolStub.handler = { _ in (409, [:], Data(#"{"error_summary":"not_found/..","error":{".tag":"not_found"}}"#.utf8)) }
        do {
            try await dropbox().resumeUpload(file: file, session: #"{"path":"/m/x","replacing":false,"session":"old"}"#)
            XCTFail("must expire")
        } catch is CloudUploadExpired {}
    }
}
