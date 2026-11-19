import Foundation

/// Microsoft's QuickXorHash, the content hash OneDrive computes server side for every file.
/// A faithful port of the reference implementation:
/// https://learn.microsoft.com/onedrive/developer/code-snippets/quickxorhash
struct QuickXorHash {
    private static let bitsInLastCell = 32
    private static let shift = 11
    private static let widthInBits = 160
    private var data = [UInt64](repeating: 0, count: (160 - 1) / 64 + 1)
    private var lengthSoFar: Int64 = 0
    private var shiftSoFar = 0

    mutating func update(_ array: [UInt8]) {
        let cbSize = array.count
        var vectorArrayIndex = shiftSoFar / 64
        var vectorOffset = shiftSoFar % 64
        let iterations = min(cbSize, Self.widthInBits)
        for i in 0..<iterations {
            let isLastCell = vectorArrayIndex == data.count - 1
            let bitsInVectorCell = isLastCell ? Self.bitsInLastCell : 64
            if vectorOffset <= bitsInVectorCell - 8 {
                var j = i
                while j < cbSize { data[vectorArrayIndex] ^= UInt64(array[j]) << UInt64(vectorOffset); j += Self.widthInBits }
            } else {
                let index1 = vectorArrayIndex
                let index2 = isLastCell ? 0 : vectorArrayIndex + 1
                let low = bitsInVectorCell - vectorOffset
                var xoredByte: UInt8 = 0
                var j = i
                while j < cbSize { xoredByte ^= array[j]; j += Self.widthInBits }
                data[index1] ^= UInt64(xoredByte) << UInt64(vectorOffset)
                data[index2] ^= UInt64(xoredByte) >> UInt64(low)
            }
            vectorOffset += Self.shift
            while vectorOffset >= bitsInVectorCell {
                vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1
                vectorOffset -= bitsInVectorCell
            }
        }
        shiftSoFar = (shiftSoFar + Self.shift * (cbSize % Self.widthInBits)) % Self.widthInBits
        lengthSoFar += Int64(cbSize)
    }

    /// The 20-byte digest: the cells in little-endian order, with the length XORed into the last 8 bytes.
    func finalize() -> [UInt8] {
        var rgb = [UInt8](repeating: 0, count: (Self.widthInBits - 1) / 8 + 1)
        for i in 0..<(data.count - 1) {
            withUnsafeBytes(of: data[i].littleEndian) { for k in 0..<8 { rgb[i * 8 + k] = $0[k] } }
        }
        let tail = rgb.count - (data.count - 1) * 8
        withUnsafeBytes(of: data[data.count - 1].littleEndian) { for k in 0..<tail { rgb[(data.count - 1) * 8 + k] = $0[k] } }
        withUnsafeBytes(of: lengthSoFar.littleEndian) { bytes in
            for i in 0..<8 { rgb[Self.widthInBits / 8 - 8 + i] ^= bytes[i] }
        }
        return rgb
    }

    /// Hashes a file in bounded memory. Chunk boundaries do not change the result.
    static func version(_ url: URL) throws -> CloudFileVersion {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudError.message(String(localized: "File non valido")) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = QuickXorHash(), size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update([UInt8](chunk)); size += Int64(chunk.count)
        }
        return CloudFileVersion(byteCount: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    /// Graph reports the digest in base64; versions store lowercase hex.
    static func hex(fromBase64 text: String) -> String? {
        guard let data = Data(base64Encoded: text), data.count == 20 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

struct OneDriveCredentials: Codable {
    let clientID: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var accountID: String
    var email: String?
}

actor OneDriveAccount {
    static let shared = OneDriveAccount()
    static let scope = "Files.ReadWrite.AppFolder offline_access User.Read"
    private var cached: OneDriveCredentials?
    /// The service refused the access token before its expiry (revoked, or the Mac's clock was behind):
    /// the next request reloads the Keychain, where another app copy may have stored a newer one, and refreshes.
    private var rejected = false
    func expire() { cached = nil; rejected = true }
    func store(_ credentials: OneDriveCredentials) throws {
        try CloudKeychain.save(JSONEncoder().encode(credentials), account: "onedrive")
        cached = credentials
    }
    func disconnect() throws { try CloudKeychain.save(nil, account: "onedrive"); cached = nil }
    func credentials() throws -> OneDriveCredentials {
        if let cached { return cached }
        guard let data = try CloudKeychain.read("onedrive") else { throw CloudError.message(String(localized: "Collega OneDrive nelle impostazioni")) }
        let credentials = try JSONDecoder().decode(OneDriveCredentials.self, from: data)
        cached = credentials
        return credentials
    }
    func token() async throws -> String {
        var credentials = try credentials()
        if !rejected, credentials.expiresAt > Date().addingTimeInterval(90) { return credentials.accessToken }
        let refreshedFrom = credentials.refreshToken
        let token = try await Self.exchange(["client_id": credentials.clientID, "refresh_token": credentials.refreshToken,
                                             "grant_type": "refresh_token", "scope": Self.scope])
        credentials.accessToken = token.access_token
        rejected = false
        credentials.expiresAt = Date().addingTimeInterval(token.expires_in)
        if let refresh = token.refresh_token { credentials.refreshToken = refresh } // Microsoft rotates refresh tokens
        // A disconnect or another account during the refresh wins over this late result.
        guard let latest = try? self.credentials(), latest.accountID == credentials.accountID,
              latest.refreshToken == refreshedFrom else { return credentials.accessToken }
        try store(credentials)
        return credentials.accessToken
    }
    static func exchange(_ parameters: [String: String]) async throws -> OAuthTokens.Token {
        try await OAuthTokens.exchange(URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!, parameters,
                                       expired: String(localized: "Autorizzazione OneDrive scaduta o revocata. Ricollega l'account."))
    }
    /// Graph user id (stable per account) and the address to show in Settings.
    static func identity(_ token: String) async throws -> (id: String, email: String?) {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=id,mail,userPrincipalName")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        try CloudHTTP.check(response, data: data)
        struct Me: Decodable { let id: String; let mail: String?; let userPrincipalName: String? }
        let me = try JSONDecoder().decode(Me.self, from: data)
        return (me.id, me.mail ?? me.userPrincipalName)
    }
}

/// OneDrive through Microsoft Graph, confined to the app folder (OneDrive › Apps › Overheard) by the
/// Files.ReadWrite.AppFolder permission. The ID of a file is its path inside that folder.
struct OneDriveProvider: CloudLibraryProvider {
    let accountID: String
    let accessToken: @Sendable () async throws -> String
    init(accountID: String, accessToken: @escaping @Sendable () async throws -> String = { try await OneDriveAccount.shared.token() }) {
        self.accountID = accountID; self.accessToken = accessToken
    }
    var id: String { "onedrive:\(accountID)" }
    /// Upload-session chunk: Graph requires multiples of 320 KiB. Files up to one chunk go in a single PUT.
    nonisolated(unsafe) static var chunkSize = 32 * 320 * 1024

    func fingerprint(_ file: URL) throws -> CloudFileVersion { try QuickXorHash.version(file) }

    func libraryMarkerID() async throws -> String? { "/" + Self.libraryMarkerName }
    func createLibraryMarker(file: URL) async throws {
        try await upload(file: file, id: "/" + Self.libraryMarkerName, name: Self.libraryMarkerName, replacing: false)
    }

    func reserve(meeting: CloudMeetingID, name: String) async throws -> String { try path("/\(meeting.rawValue.uuidString)-\(name)") }
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String { try path("/\(folder)/\(file)") }
    private func path(_ value: String) throws -> String {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard value.hasPrefix("/"), !parts.isEmpty, value.utf8.count < 400,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains(where: { "\\:*?\"<>|#%".contains($0) }) }) else {
            throw CloudError.message(String(localized: "Percorso remoto non valido"))
        }
        return value
    }
    /// Path-based address inside the app folder, each segment percent-encoded.
    private func item(_ id: String, _ suffix: String = "") throws -> URL {
        let encoded = try path(id).split(separator: "/").map { S3Signer.encode(String($0)) }.joined(separator: "/")
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(encoded):\(suffix)") else {
            throw CloudError.message(String(localized: "Percorso remoto non valido"))
        }
        return url
    }
    private func request(_ url: URL, method: String = "GET") async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        return request
    }

    /// Graph errors carry a code: quota and throttling concern the whole destination.
    static func check(_ response: URLResponse, data: Data, allowing: Set<Int> = []) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        if (200...299).contains(http.statusCode) || allowing.contains(http.statusCode) { return }
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        if http.statusCode == 507 || text.contains("quotaLimitReached") || text.contains("insufficientStorage") {
            throw CloudError.destination(String(localized: "Spazio cloud esaurito. Libera spazio nell'account: la sincronizzazione riprenderà da sola."))
        }
        if http.statusCode == 409 || text.contains("nameAlreadyExists") {
            throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        try CloudHTTP.check(response, data: data, allowing: allowing)
    }

    func inspect(_ id: String) async throws -> CloudFileVersion? {
        var components = URLComponents(url: try item(id), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "$select=size,file,deleted"
        guard let url = components?.url else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(url))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.check(response, data: data)
        struct Item: Decodable {
            struct File: Decodable { struct Hashes: Decodable { let quickXorHash: String? }; let hashes: Hashes? }
            let size: Int64?; let file: File?
        }
        let item = try JSONDecoder().decode(Item.self, from: data)
        guard let size = item.size, item.file != nil else { throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate.")) }
        if let encoded = item.file?.hashes?.quickXorHash, let hex = QuickXorHash.hex(fromBase64: encoded) {
            return CloudFileVersion(byteCount: size, sha256: hex)
        }
        // No server hash reported: verify the bytes themselves.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await download(id, to: temporary)
        return try QuickXorHash.version(temporary)
    }
    func size(_ id: String) async throws -> Int64? {
        var components = URLComponents(url: try item(id), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "$select=size"
        guard let url = components?.url else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(url))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.check(response, data: data)
        struct Item: Decodable { let size: Int64? }
        return try JSONDecoder().decode(Item.self, from: data).size
    }
    /// New files are created with conflictBehavior=fail, so another file at the same path is never overwritten.
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        var components = URLComponents(url: try item(id, "/content"), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "@microsoft.graph.conflictBehavior=" + (replacing ? "replace" : "fail")
        guard let url = components?.url else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        var request = try await request(url, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await CloudHTTP.shared.session.upload(for: request, fromFile: file)
        try Self.check(response, data: data)
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? {
        guard version.byteCount > Int64(Self.chunkSize) else { return nil }
        var request = try await request(try item(id, "/createUploadSession"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": replacing ? "replace" : "fail"]])
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        try Self.check(response, data: data)
        struct Session: Decodable { let uploadUrl: String }
        let session = try JSONDecoder().decode(Session.self, from: data).uploadUrl
        guard Self.trusted(session) != nil else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        return session
    }
    /// Upload URLs are pre-authenticated Microsoft hosts. The bearer token is never sent to them.
    static func trusted(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host?.lowercased(),
              [".onedrive.com", ".sharepoint.com", ".1drv.com", ".live.com", ".microsoft.com", ".svc.ms"].contains(where: { host.hasSuffix($0) }) else { return nil }
        return url
    }
    /// Asks the session which bytes it still expects, then sends the rest in 320 KiB-aligned chunks.
    func resumeUpload(file: URL, session: String) async throws {
        guard let url = Self.trusted(session) else { throw CloudUploadExpired() }
        let total = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let (status, statusResponse) = try await CloudHTTP.shared.session.data(for: URLRequest(url: url))
        if (statusResponse as? HTTPURLResponse)?.statusCode == 404 { throw CloudUploadExpired() }
        try Self.check(statusResponse, data: status)
        var offset = Self.nextExpected(status) ?? 0
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while offset < total {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            guard !chunk.isEmpty else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.setValue("bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let (data, response) = try await CloudHTTP.shared.session.upload(for: put, from: chunk)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200, 201: return // the last chunk created the file
            case 202:
                guard let next = Self.nextExpected(data), next > offset else {
                    throw CloudError.message(String(localized: "Caricamento incompleto. Verrà riprovato."))
                }
                offset = next
            case 404: throw CloudUploadExpired()
            default:
                try Self.check(response, data: data)
                throw CloudError.message(String(localized: "Risposta cloud non valida"))
            }
        }
        throw CloudError.message(String(localized: "Caricamento incompleto. Verrà riprovato."))
    }
    /// First byte of `nextExpectedRanges` ("26214400-" or "0-1023").
    static func nextExpected(_ data: Data) -> Int64? {
        struct Status: Decodable { let nextExpectedRanges: [String]? }
        guard let first = (try? JSONDecoder().decode(Status.self, from: data))?.nextExpectedRanges?.first,
              let start = first.split(separator: "-").first else { return nil }
        return Int64(start)
    }
    func abandonUpload(session: String) async throws {
        guard let url = Self.trusted(session) else { return }
        var delete = URLRequest(url: url)
        delete.httpMethod = "DELETE"
        let (data, response) = try await CloudHTTP.shared.session.data(for: delete)
        try Self.check(response, data: data, allowing: [404])
    }
    /// Graph answers with a redirect to a pre-authenticated download host: followed by hand, only to Microsoft.
    func download(_ id: String, to destination: URL) async throws {
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(try item(id, "/content")))
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        guard (300...399).contains(http.statusCode) else { try Self.check(response, data: data); throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        guard let location = http.value(forHTTPHeaderField: "Location"), let url = Self.trusted(location) else {
            throw CloudError.message(String(localized: "Risposta cloud non valida"))
        }
        let (file, fileResponse) = try await CloudHTTP.download(for: URLRequest(url: url))
        defer { try? FileManager.default.removeItem(at: file) }
        try CloudHTTP.check(fileResponse)
        try FileManager.default.moveItem(at: file, to: destination)
    }
    /// Deletes the meeting's folder only when it is empty (to the OneDrive recycle bin).
    func removeMeetingFolder(_ folder: String, id: String?) async throws {
        let target = try path("/\(folder)")
        var components = URLComponents(url: try item(target, "/children"), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "$top=1&$select=id"
        guard let url = components?.url else { return }
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(url))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try Self.check(response, data: data)
        struct Children: Decodable { struct Item: Decodable { let id: String }; let value: [Item] }
        guard try JSONDecoder().decode(Children.self, from: data).value.isEmpty else { return }
        try await remove(target)
    }
    /// Deleted items go to the OneDrive recycle bin.
    func remove(_ id: String) async throws {
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(try item(id), method: "DELETE"))
        try Self.check(response, data: data, allowing: [404])
    }
}
