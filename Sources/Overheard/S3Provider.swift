import CryptoKit
import Foundation

/// AWS Signature Version 4, as accepted by S3 and S3-compatible services (R2, B2, Wasabi, MinIO).
struct S3Signer: Sendable {
    let accessKey: String
    let secret: String
    let region: String

    static func hex(_ data: some DataProtocol) -> String { SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined() }
    static let emptyHash = hex(Data())
    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    static func encode(_ text: String) -> String {
        text.utf8.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: return String(UnicodeScalar(byte))
            default: return String(format: "%%%02X", byte)
            }
        }.joined()
    }

    /// Signs `host`, `range` and every `x-amz-*` header. `payloadHash` is the hex SHA-256 of the body:
    /// the server rejects a body that does not match it, so a signed upload is also a verified upload.
    func sign(_ request: inout URLRequest, payloadHash: String, date: Date = Date()) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: date), day = String(stamp.prefix(8))
        request.setValue(stamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        guard let url = request.url, let host = url.host else { return }
        var headers: [String: String] = ["host": url.port.map { "\(host):\($0)" } ?? host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            if key == "range" || key.hasPrefix("x-amz-") { headers[key] = value.trimmingCharacters(in: .whitespaces) }
        }
        let names = headers.keys.sorted()
        let items: [URLQueryItem] = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let pairs: [(String, String)] = items.map { (Self.encode($0.name), Self.encode($0.value ?? "")) }
        let sorted = pairs.sorted { (a: (String, String), b: (String, String)) -> Bool in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        let query: String = sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let path: String = url.path(percentEncoded: true)
        let headerBlock: String = names.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let lines: [String] = [request.httpMethod ?? "GET", path.isEmpty ? "/" : path, query, headerBlock, names.joined(separator: ";"), payloadHash]
        let canonical = lines.joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope, Self.hex(Data(canonical.utf8))].joined(separator: "\n")
        func hmac(_ key: SymmetricKey, _ text: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)))
        }
        let signing = hmac(hmac(hmac(hmac(SymmetricKey(data: Data("AWS4\(secret)".utf8)), day), region), "s3"), "aws4_request")
        let signature = HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: signing).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(names.joined(separator: ";")), Signature=\(signature)",
                         forHTTPHeaderField: "Authorization")
    }
}

/// S3-compatible bucket. Objects are `<prefix><meeting folder>/<file>`. Every upload is signed with the
/// SHA-256 of its body and carries it as `x-amz-meta-sha256`, so later checks read the verified digest
/// with a HEAD instead of downloading the audio again.
struct S3Provider: CloudStorageProvider {
    let endpoint: URL
    let bucket: String
    let prefix: String
    let signer: S3Signer
    /// Multipart part size. S3 requires at least 5 MiB for every part but the last.
    nonisolated(unsafe) static var partSize = 16 * 1024 * 1024

    init(endpoint: URL, region: String, bucket: String, prefix: String, accessKey: String, secret: String) {
        self.endpoint = endpoint
        self.bucket = bucket
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        self.prefix = trimmed.isEmpty ? "" : trimmed + "/"
        signer = S3Signer(accessKey: accessKey, secret: secret, region: region.isEmpty ? "us-east-1" : region)
    }
    var id: String { "s3:\(endpoint.absoluteString)/\(bucket)/\(prefix)" }

    static func validBucket(_ name: String) -> Bool {
        (3...63).contains(name.count) && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }
    static func validEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.query == nil && url.fragment == nil && (url.path.isEmpty || url.path == "/")
    }

    func reserve(meeting: CloudMeetingID, name: String) async throws -> String { try key("\(prefix)\(meeting.rawValue.uuidString)-\(name)") }
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String { try key("\(prefix)\(folder)/\(file)") }
    private func key(_ value: String) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, !value.hasPrefix("/"), value.utf8.count <= 1024,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        return value
    }
    private func url(_ key: String, _ query: [(String, String)] = []) throws -> URL {
        let path = ([bucket] + (try self.key(key)).split(separator: "/").map(String.init)).map(S3Signer.encode).joined(separator: "/")
        var text = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path
        if !query.isEmpty { text += "?" + query.map { $0.1.isEmpty ? S3Signer.encode($0.0) : "\(S3Signer.encode($0.0))=\(S3Signer.encode($0.1))" }.joined(separator: "&") }
        guard let url = URL(string: text) else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        return url
    }
    private func request(_ method: String, _ key: String, query: [(String, String)] = [], payloadHash: String = S3Signer.emptyHash,
                         headers: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try url(key, query))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        signer.sign(&request, payloadHash: payloadHash)
        return request
    }

    /// Errors come as XML `<Code>`: credentials, clock and bucket problems concern the whole destination.
    static func check(_ response: URLResponse, data: Data, allowing: Set<Int> = []) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        // CompleteMultipartUpload can answer 200 with an <Error> body.
        guard !(200...299).contains(http.statusCode) || text.contains("<Error>") else { return }
        if allowing.contains(http.statusCode) { return }
        let code = field("Code", in: text) ?? ""
        switch code {
        case "InvalidAccessKeyId", "SignatureDoesNotMatch", "AccessDenied", "InvalidToken", "ExpiredToken":
            if text.localizedCaseInsensitiveContains("cap exceeded") || text.localizedCaseInsensitiveContains("quota") { fallthrough }
            throw CloudError.destination(String(localized: "Credenziali S3 non valide o permessi insufficienti sul bucket."))
        case "QuotaExceeded", "StorageQuotaExceeded", "ServiceQuotaExceeded":
            throw CloudError.destination(String(localized: "Spazio cloud esaurito. Libera spazio nell'account: la sincronizzazione riprenderà da sola."))
        case "RequestTimeTooSkewed":
            throw CloudError.destination(String(localized: "L'orologio del Mac non è sincronizzato: S3 rifiuta la richiesta."))
        case "NoSuchBucket", "PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException":
            throw CloudError.destination(String(localized: "Bucket, regione o endpoint S3 non corretti. Controlla le impostazioni."))
        case "" where http.statusCode == 403:
            // A HEAD has no body, so no Code: still credentials or permissions (or the clock), for the whole bucket.
            throw CloudError.destination(String(localized: "Credenziali S3 non valide o permessi insufficienti sul bucket."))
        case "XAmzContentSHA256Mismatch", "BadDigest", "IncompleteBody":
            throw CloudError.message(String(localized: "Il servizio ha ricevuto dati diversi da quelli inviati. Verrà riprovato."))
        case "SlowDown":
            throw CloudError.destination(String(localized: "Limite del servizio raggiunto. La sincronizzazione verrà riprovata."))
        default:
            try CloudHTTP.check(response, data: data, allowing: allowing)
            throw CloudError.message(String(localized: "Risposta cloud non valida"))
        }
    }
    static func field(_ name: String, in xml: String) -> String? { fields(name, in: xml).first }
    static func fields(_ name: String, in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<\(name)>(.*?)</\(name)>", options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { Range($0.range(at: 1), in: xml).map { String(xml[$0]) } }
            .map { $0.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#34;", with: "\"").replacingOccurrences(of: "&amp;", with: "&") }
    }

    func inspect(_ id: String) async throws -> CloudFileVersion? {
        let (data, response) = try await CloudHTTP.shared.session.data(for: try request("HEAD", id))
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        if http.statusCode == 404 { return nil }
        try Self.check(response, data: data)
        if let size = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
           let hash = http.value(forHTTPHeaderField: "x-amz-meta-sha256"),
           CloudVerification.matches(local: CloudFileVersion(byteCount: size, sha256: hash), remote: CloudFileVersion(byteCount: size, sha256: hash)) {
            return CloudFileVersion(byteCount: size, sha256: hash.lowercased())
        }
        // An object written by another tool has no digest: verify the bytes themselves.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await download(id, to: temporary)
        return try CloudFiles.version(temporary)
    }
    /// Presence and size with a HEAD only, even for objects without a stored digest.
    func size(_ id: String) async throws -> Int64? {
        let (data, response) = try await CloudHTTP.shared.session.data(for: try request("HEAD", id))
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        if http.statusCode == 404 { return nil }
        try Self.check(response, data: data)
        return http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        let hash = try CloudFiles.version(file).sha256
        var headers = ["x-amz-meta-sha256": hash, "Content-Type": "application/octet-stream"]
        // Create-only for a new object: another Mac's file under the same key is never overwritten.
        if !replacing { headers["If-None-Match"] = "*" }
        var (data, response) = try await CloudHTTP.shared.session.upload(for: try request("PUT", id, payloadHash: hash, headers: headers), fromFile: file)
        if !replacing, Self.unsupported(response, data) { // services without conditional writes
            headers["If-None-Match"] = nil
            (data, response) = try await CloudHTTP.shared.session.upload(for: try request("PUT", id, payloadHash: hash, headers: headers), fromFile: file)
        }
        try Self.check(response, data: data)
    }
    static func unsupported(_ response: URLResponse, _ data: Data) -> Bool {
        let status = (response as? HTTPURLResponse)?.statusCode
        return status == 501 || field("Code", in: String(decoding: data.prefix(4096), as: UTF8.self)) == "NotImplemented"
    }
    /// Only an unknown upload ID means the session is gone; a missing bucket must surface as a destination error.
    static func noSuchUpload(_ response: URLResponse, _ data: Data) -> Bool {
        (response as? HTTPURLResponse)?.statusCode == 404 && field("Code", in: String(decoding: data.prefix(4096), as: UTF8.self)) == "NoSuchUpload"
    }
    /// Aborts a multipart upload: until then S3 keeps (and bills) its parts, invisible in listings.
    func abandonUpload(session: String) async throws {
        let parts = session.split(separator: "\n", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return }
        let (data, response) = try await CloudHTTP.shared.session.data(for: try request("DELETE", parts[1], query: [("uploadId", parts[0])]))
        try Self.check(response, data: data, allowing: [404])
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? {
        guard version.byteCount > Int64(Self.partSize) else { return nil }
        let request = try request("POST", id, query: [("uploads", "")],
                                  headers: ["x-amz-meta-sha256": version.sha256, "Content-Type": "application/octet-stream"])
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        try Self.check(response, data: data)
        guard let upload = Self.field("UploadId", in: String(decoding: data, as: UTF8.self)), !upload.isEmpty else {
            throw CloudError.message(String(localized: "Risposta cloud non valida"))
        }
        return "\(upload)\n\(id)\n\(replacing ? "replace" : "create")"
    }
    /// Lists the parts S3 already has, uploads the missing ones (each signed with its own hash), then completes.
    func resumeUpload(file: URL, session: String) async throws {
        let parts = session.split(separator: "\n", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { throw CloudUploadExpired() }
        let (upload, id) = (parts[0], parts[1])
        let create = parts.count == 3 && parts[2] == "create"
        let total = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let size = Int64(Self.partSize)
        let count = max(1, Int((total + size - 1) / size))
        var stored = try await listParts(id, upload: upload)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        for number in 1...count {
            let offset = Int64(number - 1) * size
            let length = min(size, total - offset)
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Int(length)) ?? Data()
            guard chunk.count == length else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            // A stored part is reused only when its ETag is the MD5 of these exact bytes.
            if let part = stored[number], part.size == length,
               part.tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).lowercased() == Insecure.MD5.hash(data: chunk).map({ String(format: "%02x", $0) }).joined() {
                continue
            }
            let request = try request("PUT", id, query: [("partNumber", String(number)), ("uploadId", upload)], payloadHash: S3Signer.hex(chunk))
            let (data, response) = try await CloudHTTP.shared.session.upload(for: request, from: chunk)
            if Self.noSuchUpload(response, data) { throw CloudUploadExpired() }
            try Self.check(response, data: data)
            guard let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag") else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
            stored[number] = (tag, length)
        }
        let body = "<CompleteMultipartUpload>" + (1...count).map { number in
            "<Part><PartNumber>\(number)</PartNumber><ETag>\(stored[number]!.tag.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</ETag></Part>"
        }.joined() + "</CompleteMultipartUpload>"
        let payload = Data(body.utf8)
        func completion(createOnly: Bool) throws -> URLRequest {
            var complete = try request("POST", id, query: [("uploadId", upload)], payloadHash: S3Signer.hex(payload),
                                       headers: createOnly ? ["If-None-Match": "*"] : [:])
            complete.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            return complete
        }
        var (data, response) = try await CloudHTTP.shared.session.upload(for: try completion(createOnly: create), from: payload)
        if create, Self.unsupported(response, data) {
            (data, response) = try await CloudHTTP.shared.session.upload(for: try completion(createOnly: false), from: payload)
        }
        if Self.noSuchUpload(response, data) { throw CloudUploadExpired() }
        try Self.check(response, data: data)
    }
    private func listParts(_ id: String, upload: String) async throws -> [Int: (tag: String, size: Int64)] {
        var result: [Int: (tag: String, size: Int64)] = [:], marker = "0"
        while true {
            let request = try request("GET", id, query: [("part-number-marker", marker), ("uploadId", upload)])
            let (data, response) = try await CloudHTTP.shared.session.data(for: request)
            if Self.noSuchUpload(response, data) { throw CloudUploadExpired() }
            try Self.check(response, data: data)
            let xml = String(decoding: data, as: UTF8.self)
            for part in Self.fields("Part", in: xml) {
                guard let number = Self.field("PartNumber", in: part).flatMap(Int.init), let tag = Self.field("ETag", in: part),
                      let size = Self.field("Size", in: part).flatMap(Int64.init) else { continue }
                result[number] = (tag, size)
            }
            guard Self.field("IsTruncated", in: xml) == "true", let next = Self.field("NextPartNumberMarker", in: xml), next != marker else { return result }
            marker = next
        }
    }
    func download(_ id: String, to destination: URL) async throws {
        let (file, response) = try await CloudHTTP.shared.session.download(for: try request("GET", id))
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try Self.check(response, data: (try? Data(contentsOf: file)) ?? Data())
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
    /// Copied under `<prefix>.trash/<time>/` on the server before the original goes, so a removal can be
    /// undone from the bucket. If the copy fails (an object over 5 GB, no permission) nothing is deleted.
    func remove(_ id: String) async throws {
        let relative = id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
        let now = CloudTrash.stamp()
        let trashKey = try key("\(prefix)\(CloudTrash.s3Folder)/\(now.prefix(8))-\(now.suffix(6))/\(relative)")
        let source = "/" + ([bucket] + id.split(separator: "/").map(String.init)).map(S3Signer.encode).joined(separator: "/")
        let copy = try request("PUT", trashKey, headers: ["x-amz-copy-source": source])
        let (copied, copyResponse) = try await CloudHTTP.shared.session.data(for: copy)
        // Only a missing key means "already gone"; a missing bucket is a destination error for check() to raise.
        if (copyResponse as? HTTPURLResponse)?.statusCode == 404,
           Self.field("Code", in: String(decoding: copied.prefix(4096), as: UTF8.self)) == "NoSuchKey" { return }
        try Self.check(copyResponse, data: copied)
        let (data, response) = try await CloudHTTP.shared.session.data(for: try request("DELETE", id))
        try Self.check(response, data: data, allowing: [404])
    }
}
