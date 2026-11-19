import CryptoKit
import Foundation

struct DropboxCredentials: Codable {
    let appKey: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var accountID: String
    var email: String?
}

actor DropboxAccount {
    static let shared = DropboxAccount()
    private var cached: DropboxCredentials?
    /// The service refused the access token before its expiry (revoked, or the Mac's clock was behind):
    /// the next request reloads the Keychain, where another app copy may have stored a newer one, and refreshes.
    private var rejected = false
    func expire() { cached = nil; rejected = true }
    func store(_ credentials: DropboxCredentials) throws {
        try CloudKeychain.save(JSONEncoder().encode(credentials), account: "dropbox")
        cached = credentials
    }
    func disconnect() throws { try CloudKeychain.save(nil, account: "dropbox"); cached = nil }
    func credentials() throws -> DropboxCredentials {
        if let cached { return cached }
        guard let data = try CloudKeychain.read("dropbox") else { throw CloudError.message(String(localized: "Collega Dropbox nelle impostazioni")) }
        let credentials = try JSONDecoder().decode(DropboxCredentials.self, from: data)
        cached = credentials
        return credentials
    }
    func token() async throws -> String {
        var credentials = try credentials()
        if !rejected, credentials.expiresAt > Date().addingTimeInterval(90) { return credentials.accessToken }
        let refreshedFrom = credentials.refreshToken
        let token = try await Self.exchange(["client_id": credentials.appKey, "refresh_token": credentials.refreshToken, "grant_type": "refresh_token"])
        credentials.accessToken = token.access_token
        rejected = false
        credentials.expiresAt = Date().addingTimeInterval(token.expires_in)
        if let refresh = token.refresh_token { credentials.refreshToken = refresh }
        // The refresh awaited the network: a disconnect or another account may have happened meanwhile.
        // Store only if the stored account is still the one this refresh started from.
        guard let latest = try? self.credentials(), latest.accountID == credentials.accountID,
              latest.refreshToken == refreshedFrom else { return credentials.accessToken }
        try store(credentials)
        return credentials.accessToken
    }
    static func exchange(_ parameters: [String: String]) async throws -> OAuthTokens.Token {
        try await OAuthTokens.exchange(URL(string: "https://api.dropboxapi.com/oauth2/token")!, parameters,
                                       expired: String(localized: "Autorizzazione Dropbox scaduta o revocata. Ricollega l'account."))
    }
    static func email(_ token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        try CloudHTTP.check(response, data: data)
        struct Account: Decodable { let email: String? }
        return try JSONDecoder().decode(Account.self, from: data).email
    }
}

/// Dropbox's content hash: SHA-256 over the concatenated SHA-256 digests of 4 MiB blocks.
/// Dropbox computes it server side, so a matching value proves Dropbox stored exactly these bytes.
enum DropboxContentHash {
    static let block = 4 * 1024 * 1024
    static func version(_ url: URL) throws -> CloudFileVersion {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CloudError.message(String(localized: "File non valido")) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var overall = SHA256(), size: Int64 = 0
        while let data = try handle.read(upToCount: block), !data.isEmpty {
            overall.update(data: Data(SHA256.hash(data: data)))
            size += Int64(data.count)
        }
        return CloudFileVersion(byteCount: size, sha256: overall.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

/// Files live in the app folder (Dropbox › Apps › Overheard). The ID of a file is its path there.
struct DropboxProvider: CloudLibraryProvider {
    let accountID: String
    let accessToken: @Sendable () async throws -> String
    init(accountID: String, accessToken: @escaping @Sendable () async throws -> String = { try await DropboxAccount.shared.token() }) {
        self.accountID = accountID; self.accessToken = accessToken
    }
    var id: String { "dropbox:\(accountID)" }
    /// Upload-session chunk. Files up to one chunk go in a single request.
    nonisolated(unsafe) static var chunkSize = 8 * 1024 * 1024

    func fingerprint(_ file: URL) throws -> CloudFileVersion { try DropboxContentHash.version(file) }

    func libraryMarkerID() async throws -> String? { "/" + Self.libraryMarkerName }
    func createLibraryMarker(file: URL) async throws {
        try await upload(file: file, id: "/" + Self.libraryMarkerName, name: Self.libraryMarkerName, replacing: false)
    }

    func reserve(meeting: CloudMeetingID, name: String) async throws -> String {
        try path("/\(meeting.rawValue.uuidString)-\(name)")
    }
    func reserve(meeting: CloudMeetingID, folder: String, file: String) async throws -> String {
        try path("/\(folder)/\(file)")
    }
    private func path(_ value: String) throws -> String {
        guard value.hasPrefix("/"), !value.contains("\\"), !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              value.count > 1, value.utf8.count < 1024 else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        return value
    }

    /// Dropbox-API-Arg must be ASCII: non-ASCII characters (only possible inside JSON strings) become \uXXXX.
    static func argument(_ object: [String: Any]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return json.utf16.map { $0 < 0x80 ? String(UnicodeScalar(UInt8($0))) : String(format: "\\u%04x", $0) }.joined()
    }
    private func content(_ endpoint: String, _ argument: [String: Any]) async throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        request.setValue(try Self.argument(argument), forHTTPHeaderField: "Dropbox-API-Arg")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func rpc(_ endpoint: String, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(endpoint)")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        return (data, http)
    }

    struct Failure: Decodable {
        let error_summary: String?
        struct Detail: Decodable {
            let tag: String?
            let correct_offset: Int64?
            enum CodingKeys: String, CodingKey { case tag = ".tag", correct_offset }
        }
        let error: Detail?
    }
    /// Maps Dropbox's 409 error summaries ("path/not_found/..", "path/insufficient_space/..") to app errors.
    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 409 else { return try CloudHTTP.check(response, data: data) }
        let summary = (try? JSONDecoder().decode(Failure.self, from: data))?.error_summary ?? ""
        if summary.contains("insufficient_space") {
            throw CloudError.destination(String(localized: "Spazio cloud esaurito. Libera spazio nell'account: la sincronizzazione riprenderà da sola."))
        }
        if summary.contains("not_found") { throw CloudError.message(String(localized: "File cloud non trovato. Copie locali conservate.")) }
        throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
    }
    private static func notFound(_ http: HTTPURLResponse, _ data: Data) -> Bool {
        http.statusCode == 409 && ((try? JSONDecoder().decode(Failure.self, from: data))?.error_summary ?? "").contains("not_found")
    }

    func inspect(_ id: String) async throws -> CloudFileVersion? {
        let (data, http) = try await rpc("files/get_metadata", ["path": try path(id)])
        if Self.notFound(http, data) { return nil }
        try Self.check(http, data: data)
        struct Metadata: Decodable {
            let tag: String; let size: Int64?; let content_hash: String?
            enum CodingKeys: String, CodingKey { case tag = ".tag", size, content_hash }
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard metadata.tag == "file", let size = metadata.size, let hash = metadata.content_hash else {
            throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        return CloudFileVersion(byteCount: size, sha256: hash)
    }
    /// Revisions seen by `expectUnchanged`, by path, until the commit that uses them.
    private final class Revisions: @unchecked Sendable {
        static let shared = Revisions()
        private let lock = NSLock()
        private var byPath: [String: String] = [:]
        func set(_ rev: String, for path: String) { lock.withLock { byPath[path] = rev } }
        func take(_ path: String) -> String? { lock.withLock { byPath.removeValue(forKey: path) } }
    }
    /// Replacing commits with the revision the engine just verified: Dropbox refuses (a 409 conflict) when
    /// another Mac changed the file since, instead of silently overwriting it.
    func expectUnchanged(_ id: String, _ expected: CloudFileVersion) async throws {
        let path = try path(id)
        let (data, http) = try await rpc("files/get_metadata", ["path": path])
        if Self.notFound(http, data) { throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata.")) }
        try Self.check(http, data: data)
        struct Metadata: Decodable {
            let size: Int64?; let content_hash: String?; let rev: String?
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        guard let size = metadata.size, let hash = metadata.content_hash, let rev = metadata.rev,
              CloudFileVersion(byteCount: size, sha256: hash) == expected else {
            throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
        }
        Revisions.shared.set(rev, for: path)
    }
    private func commit(_ id: String, replacing: Bool, rev: String? = nil) throws -> [String: Any] {
        let path = try path(id)
        let mode: Any
        if replacing, let rev = rev ?? Revisions.shared.take(path) { mode = [".tag": "update", "update": rev] }
        else { mode = replacing ? "overwrite" : "add" }
        return ["path": path, "mode": mode, "autorename": false, "mute": true]
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        let request = try await content("files/upload", try commit(id, replacing: replacing))
        let (data, response) = try await CloudHTTP.shared.session.upload(for: request, fromFile: file)
        try Self.check(response, data: data)
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? {
        guard version.byteCount > Int64(Self.chunkSize) else { return nil }
        let request = try await content("files/upload_session/start", ["close": false])
        let (data, response) = try await CloudHTTP.shared.session.upload(for: request, from: Data())
        try Self.check(response, data: data)
        struct Started: Decodable { let session_id: String }
        let session = try JSONDecoder().decode(Started.self, from: data).session_id
        var fields: [String: Any] = ["session": session, "path": try path(id), "replacing": replacing]
        if replacing, let rev = Revisions.shared.take(try path(id)) { fields["rev"] = rev }
        let state = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: state, as: UTF8.self)
    }
    /// Dropbox has no status call: an empty append at offset 0 either succeeds (nothing stored yet)
    /// or fails with incorrect_offset and the offset it expects.
    func resumeUpload(file: URL, session: String) async throws {
        struct State: Decodable { let session: String; let path: String; let replacing: Bool; let rev: String? }
        guard let state = try? JSONDecoder().decode(State.self, from: Data(session.utf8)) else { throw CloudUploadExpired() }
        let total = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        var offset = try await append(state.session, offset: 0, Data())
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while offset < total {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            guard !chunk.isEmpty else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            let next = try await append(state.session, offset: offset, chunk)
            guard next > offset else { throw CloudError.message(String(localized: "Caricamento incompleto. Verrà riprovato.")) }
            offset = next
        }
        guard offset == total else { throw CloudError.message(String(localized: "Caricamento incompleto. Verrà riprovato.")) }
        let request = try await content("files/upload_session/finish", ["cursor": ["session_id": state.session, "offset": total],
                                                                         "commit": try commit(state.path, replacing: state.replacing, rev: state.rev)])
        let (data, response) = try await CloudHTTP.shared.session.upload(for: request, from: Data())
        // A stale revision (the file changed since this session began) discards the session: the engine starts
        // a new one against the current file, and the conflict is then handled as a conflict, not overwritten.
        if (response as? HTTPURLResponse)?.statusCode == 409, Self.sessionGone(data) || Self.isConflict(data) { throw CloudUploadExpired() }
        try Self.check(response, data: data)
    }
    /// Returns the offset after this append, or the one Dropbox expects when ours was wrong.
    private func append(_ session: String, offset: Int64, _ chunk: Data) async throws -> Int64 {
        let request = try await content("files/upload_session/append_v2", ["cursor": ["session_id": session, "offset": offset], "close": false])
        let (data, response) = try await CloudHTTP.shared.session.upload(for: request, from: chunk)
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            if let correct = failure?.error?.correct_offset { return correct }
            if Self.sessionGone(data) { throw CloudUploadExpired() }
        }
        try Self.check(response, data: data)
        return offset + Int64(chunk.count)
    }
    private static func isConflict(_ data: Data) -> Bool {
        ((try? JSONDecoder().decode(Failure.self, from: data))?.error_summary ?? "").contains("conflict")
    }
    private static func sessionGone(_ data: Data) -> Bool {
        let summary = (try? JSONDecoder().decode(Failure.self, from: data))?.error_summary ?? ""
        return summary.hasPrefix("not_found") || summary.contains("lookup_failed/not_found") || summary.contains("closed")
    }
    func download(_ id: String, to destination: URL) async throws {
        var request = try await content("files/download", ["path": try path(id)])
        request.setValue(nil, forHTTPHeaderField: "Content-Type")
        let (file, response) = try await CloudHTTP.shared.session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            try Self.check(response, data: (try? Data(contentsOf: file)) ?? Data())
        }
        try CloudHTTP.check(response)
        try FileManager.default.moveItem(at: file, to: destination)
    }
    /// Deletes the meeting's folder only when it is empty (recoverable from Dropbox's deleted files).
    func removeMeetingFolder(_ folder: String, id: String?) async throws {
        let target = try path("/\(folder)")
        let (data, http) = try await rpc("files/list_folder", ["path": target, "limit": 1])
        if Self.notFound(http, data) { return }
        try Self.check(http, data: data)
        struct Listing: Decodable { let entries: [[String: AnyDecodable]] }
        struct AnyDecodable: Decodable { init(from decoder: Decoder) throws {} }
        guard try JSONDecoder().decode(Listing.self, from: data).entries.isEmpty else { return }
        try await remove(target)
    }
    /// Deleted files stay recoverable from Dropbox's deleted-files view for at least 30 days.
    func remove(_ id: String) async throws {
        let (data, http) = try await rpc("files/delete_v2", ["path": try path(id)])
        if Self.notFound(http, data) { return }
        try Self.check(http, data: data)
    }
}
