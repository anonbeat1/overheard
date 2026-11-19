import Foundation
import Security

/// Deliberately no plaintext fallback for cloud credentials.
enum CloudKeychain {
    static func read(_ account: String) throws -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudError.message(String(localized: "Accesso al Portachiavi negato (\(status))")) }
        return result as? Data
    }
    static func save(_ data: Data?, account: String) throws {
        let query = base(account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudError.message(String(localized: "Errore Portachiavi (\(status))")) }
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw CloudError.message(String(localized: "Errore Portachiavi (\(added))")) }
        } else if status != errSecSuccess { throw CloudError.message(String(localized: "Errore Portachiavi (\(status))")) }
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.anonbeat.overheard") + ".cloud",
         kSecAttrAccount as String: account]
    }
}

/// One download with a per-chunk callback. Same rule as `CloudHTTP.shared`: redirects are refused.
final class ProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64) async -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var file: URL?
    private var cancelled = false

    init(report: @escaping @Sendable (Int64, Int64) async -> Void) { self.report = report }

    func run(_ session: URLSession, _ request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, URLResponse), Error>) in
            let task = session.downloadTask(with: request)
            lock.lock()
            self.continuation = continuation
            self.task = task
            let stop = cancelled
            lock.unlock()
            if stop { task.cancel() } else { task.resume() }
        }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = self.task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let report = self.report
        Task { await report(totalBytesWritten, max(totalBytesExpectedToWrite, 0)) }
    }
    /// The system deletes `location` when this returns: move it somewhere that outlives the callback.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        if (try? FileManager.default.moveItem(at: location, to: kept)) != nil { lock.lock(); file = kept; lock.unlock() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; let file = self.file; lock.unlock()
        guard let continuation else { return }
        if let error { if let file { try? FileManager.default.removeItem(at: file) }; continuation.resume(throwing: error) }
        else if let file, let response = task.response { continuation.resume(returning: (file, response)) }
        else { continuation.resume(throwing: URLError(.badServerResponse)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Refuses redirects: credentials and uploads must never follow an untrusted destination.
final class CloudHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = CloudHTTP()
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // A stalled connection fails after 60 s of silence; a slow but moving one is never cut off
        // (a single WebDAV PUT of a long meeting can take hours on a slow uplink).
        configuration.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    /// Like `session.download(for:)`, and reporting bytes received when someone is listening (a restore binds
    /// `SyncProgress.downloadBytes`). Without a listener it is exactly the plain download. Cancelling the task
    /// cancels the transfer.
    static func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        guard let report = CloudSyncEngine.SyncProgress.downloadBytes else { return try await shared.session.download(for: request) }
        let delegate = ProgressDownload(report: report)
        let session = URLSession(configuration: shared.session.configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await withTaskCancellationHandler { try await delegate.run(session, request) } onCancel: { delegate.cancel() }
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError() // stopping a transfer is not a failure of the meeting
        }
    }
    static func check(_ response: URLResponse, data: Data? = nil, allowing: Set<Int> = []) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        guard (200...299).contains(http.statusCode) || allowing.contains(http.statusCode) else {
            // Drive reports quota and rate limits as 403 with a reason in the body.
            let reason = data.map { String(decoding: $0.prefix(4096), as: UTF8.self) } ?? ""
            switch http.statusCode {
            // Redirects are refused, so a 3xx is a Wi-Fi login page (hotel, train, airport) or a moved server:
            // a problem with the network, not with any meeting.
            case 300...399: throw CloudError.destination(String(localized: "La rete chiede un accesso (Wi-Fi di hotel, treno, aeroporto…) o il servizio ha cambiato indirizzo. La sincronizzazione riprenderà da sola."))
            case 408: throw CloudError.offline
            case 401:
                // Often only the access token: the next pass gets a fresh one before asking to reconnect.
                Task { await DriveAccount.shared.expire(); await DropboxAccount.shared.expire(); await OneDriveAccount.shared.expire() }
                throw CloudError.destination(String(localized: "Accesso scaduto. Ricollega l'account cloud."))
            case 507: throw CloudError.destination(String(localized: "Spazio cloud esaurito. Libera spazio nell'account: la sincronizzazione riprenderà da sola."))
            case 403 where reason.contains("storageQuotaExceeded") || reason.contains("quotaExceeded"):
                throw CloudError.destination(String(localized: "Spazio cloud esaurito. Libera spazio nell'account: la sincronizzazione riprenderà da sola."))
            case let status where status == 429 || (status == 403 && reason.localizedCaseInsensitiveContains("rateLimitExceeded")):
                throw CloudError.destination(String(localized: "Limite del servizio raggiunto. La sincronizzazione verrà riprovata."))
            case 403 where reason.contains("insufficientPermissions") || reason.contains("appNotAuthorizedToFile"):
                // Reduced scope or revoked sharing hits every meeting alike: stop the pass instead of failing each one.
                throw CloudError.destination(String(localized: "Permesso negato dal servizio cloud. Controlla la cartella di destinazione."))
            case 403: throw CloudError.message(String(localized: "Permesso negato dal servizio cloud. Controlla la cartella di destinazione."))
            case 404: throw CloudError.message(String(localized: "File cloud non trovato. Copie locali conservate."))
            case 409, 412: throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
            case 500...599: throw CloudError.destination(String(localized: "Servizio cloud non disponibile (HTTP \(http.statusCode)). Riprova."))
            default: throw CloudError.message(String(localized: "Servizio cloud non disponibile (HTTP \(http.statusCode)). Riprova."))
            }
        }
    }
}

struct WebDAVProvider: CloudLibraryProvider {
    let endpoint: URL
    let username: String
    let password: String
    var id: String { "webdav:\(endpoint.absoluteString):\(username)" }
    private func request(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    private func url(_ id: String) throws -> URL {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), id != ".", id != ".." else { throw CloudError.message(String(localized: "Percorso remoto non valido")) }
        return endpoint.appendingPathComponent(id)
    }
    func libraryMarkerID() async throws -> String? { Self.libraryMarkerName }
    func createLibraryMarker(file: URL) async throws {
        try await upload(file: file, id: Self.libraryMarkerName, name: Self.libraryMarkerName, replacing: false)
    }

    /// WebDAV exposes the per-meeting maps as direct children of the configured destination.
    func remoteMaps() async throws -> [String] {
        var query = request(endpoint, method: "PROPFIND")
        query.setValue("1", forHTTPHeaderField: "Depth")
        let (data, response) = try await CloudHTTP.shared.session.data(for: query)
        try CloudHTTP.check(response)
        guard (response as? HTTPURLResponse)?.statusCode == 207 else {
            throw CloudError.message(String(localized: "Risposta cloud non valida"))
        }
        let paths = WebDAVPaths()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = paths
        guard parser.parse() else { throw CloudError.message(String(localized: "Risposta cloud non valida")) }
        let parent = endpoint.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Set(paths.hrefs.compactMap { href -> String? in
            guard let resource = URL(string: href, relativeTo: endpoint)?.absoluteURL,
                  resource.scheme == endpoint.scheme, resource.host == endpoint.host, resource.port == endpoint.port,
                  resource.query == nil, resource.fragment == nil else { return nil }
            let name = resource.lastPathComponent
            let directory = resource.deletingLastPathComponent().path(percentEncoded: false)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard directory == parent, name.hasSuffix("-" + CloudLedger.mirrorName) else { return nil }
            return name
        }).sorted()
    }

    func readMap(_ id: String) async throws -> (CloudLedger.Entry, CloudFileVersion) {
        let (temporary, response) = try await CloudHTTP.shared.session.download(for: request(try url(id), method: "GET"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try CloudHTTP.check(response)
        let version = try CloudFiles.version(temporary)
        guard version.byteCount <= 4_194_304 else { throw CloudError.message(String(localized: "File non valido")) }
        return (try CloudLedger.decodeEntry(Data(contentsOf: temporary)), version)
    }

    /// Compare the exact bytes and use the ETag from that same response as the write precondition.
    func replace(file: URL, id: String, expected: CloudFileVersion) async throws {
        let target = try url(id)
        let (temporary, response) = try await CloudHTTP.shared.session.download(for: request(target, method: "GET"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try CloudHTTP.check(response)
        guard let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"),
              tag.hasPrefix("\""), try CloudFiles.version(temporary) == expected else {
            throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        var update = request(target, method: "PUT")
        update.setValue(tag, forHTTPHeaderField: "If-Match")
        update.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, written) = try await CloudHTTP.shared.session.upload(for: update, fromFile: file)
        try CloudHTTP.check(written, data: data)
    }

    func reserve(meeting: CloudMeetingID, name: String) async throws -> String { "\(meeting.rawValue.uuidString)-\(name)" }
    func inspect(_ id: String) async throws -> CloudFileVersion? {
        // WebDAV has no portable content digest. Verify the bytes, not ETag or Content-Length.
        let (temporary, response) = try await CloudHTTP.shared.session.download(for: request(try url(id), method: "GET"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try CloudHTTP.check(response)
        return try CloudFiles.version(temporary)
    }
    /// Creates the destination folder when missing and checks the credentials, so a wrong address or
    /// password shows up while setting up, not at the first upload.
    func prepare() async throws {
        let (created, made) = try await CloudHTTP.shared.session.data(for: request(endpoint, method: "MKCOL"))
        let status = (made as? HTTPURLResponse)?.statusCode
        if status != 405 { // 405: the folder already exists
            if status == 409 { throw CloudError.message(String(localized: "La cartella che contiene quella di Overheard non esiste sul server. Controlla l'indirizzo.")) }
            try CloudHTTP.check(made, data: created)
        }
        var propfind = request(endpoint, method: "PROPFIND")
        propfind.setValue("0", forHTTPHeaderField: "Depth")
        let (data, response) = try await CloudHTTP.shared.session.data(for: propfind)
        guard (response as? HTTPURLResponse)?.statusCode == 207 else {
            try CloudHTTP.check(response, data: data)
            throw CloudError.message(String(localized: "L'indirizzo non è una cartella WebDAV. Controlla l'indirizzo."))
        }
    }
    /// Presence and size with a HEAD: inspect() downloads the whole file to hash it.
    func size(_ id: String) async throws -> Int64? {
        let (_, response) = try await CloudHTTP.shared.session.data(for: request(try url(id), method: "HEAD"))
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try CloudHTTP.check(response)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init)
    }
    /// A HEAD, not `inspect` (which downloads the whole file): it catches a replaced or removed file, and an edit
    /// that changes the size. The ETag-guarded `replace(file:id:expected:)` covers the rest where it is used.
    func expectUnchanged(_ id: String, _ expected: CloudFileVersion) async throws {
        guard let current = try await size(id), current == expected.byteCount else {
            throw CloudError.message(String(localized: "Il file cloud è cambiato o manca. La copia locale è stata conservata."))
        }
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        var req = request(try url(id), method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if !replacing { req.setValue("*", forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await CloudHTTP.shared.session.upload(for: req, fromFile: file)
        if [404, 409].contains((response as? HTTPURLResponse)?.statusCode) {
            // The folder holding every meeting is gone (renamed or deleted on the server): no meeting can go.
            throw CloudError.destination(String(localized: "La cartella WebDAV non esiste più sul server. Ricreala o scegli di nuovo la destinazione nelle impostazioni."))
        }
        try CloudHTTP.check(response, data: data)
    }
    func download(_ id: String, to destination: URL) async throws {
        let (file, response) = try await CloudHTTP.download(for: request(try url(id), method: "GET"))
        defer { try? FileManager.default.removeItem(at: file) }
        try CloudHTTP.check(response)
        try FileManager.default.moveItem(at: file, to: destination)
    }
    /// Moved into `.overheard-trash/<date>/` on the server, never deleted outright: a removal that cannot
    /// be undone from the server's own file browser is not done at all.
    func remove(_ id: String) async throws {
        let source = try url(id)
        let now = CloudTrash.stamp()
        let trash = endpoint.appendingPathComponent(CloudTrash.folder)
        let day = trash.appendingPathComponent(String(now.prefix(8)))
        for folder in [trash, day] {
            let (data, response) = try await CloudHTTP.shared.session.data(for: request(folder, method: "MKCOL"))
            // 405: it already exists. Anything else that fails means the server cannot keep a trash for us.
            if (response as? HTTPURLResponse)?.statusCode != 405 { try CloudHTTP.check(response, data: data) }
        }
        var move = request(source, method: "MOVE")
        move.setValue(day.appendingPathComponent(String(now.suffix(6)) + "-" + id).absoluteString, forHTTPHeaderField: "Destination")
        move.setValue("F", forHTTPHeaderField: "Overwrite")
        let (data, response) = try await CloudHTTP.shared.session.data(for: move)
        if [405, 501].contains((response as? HTTPURLResponse)?.statusCode) {
            throw CloudError.message(String(localized: "Il server non permette di spostare i file nel cestino: la copia cloud non è stata rimossa."))
        }
        try CloudHTTP.check(response, data: data, allowing: [404])
    }
}

/// Where removed cloud copies wait on providers that have no trash of their own (WebDAV, S3).
enum CloudTrash {
    static let folder = ".overheard-trash"
    static let s3Folder = ".trash"
    /// UTC `yyyyMMddHHmmss`: the first 8 characters are the day, the last 6 the time.
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}

private final class WebDAVPaths: NSObject, XMLParserDelegate {
    private var href: String?
    private(set) var hrefs: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if namespaceURI == "DAV:", elementName == "href" { href = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { href?.append(string) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if namespaceURI == "DAV:", elementName == "href", let href {
            hrefs.append(href.trimmingCharacters(in: .whitespacesAndNewlines))
            self.href = nil
        }
    }
}

struct DriveCredentials: Codable {
    let clientID: String
    let clientSecret: String
    var refreshToken: String
    var accessToken: String
    var expiresAt: Date
    var accountID: String
    var email: String?
}

/// OAuth token endpoint shared by Google and Dropbox. A 400 means the grant is gone: the user must reconnect.
enum OAuthTokens {
    struct Token: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let account_id: String?
    }
    static func exchange(_ url: URL, _ parameters: [String: String], expired: String) async throws -> Token {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var form = URLComponents()
        form.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 400 {
            // Only a rejected grant means "reconnect". A wrong app key or redirect is a setup problem that
            // reconnecting cannot fix, and saying otherwise sends the person in circles.
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            if code == nil || code == "invalid_grant" { throw CloudError.authExpired(expired) }
            throw CloudError.destination(String(localized: "Il servizio ha rifiutato la richiesta di accesso: la configurazione dell'app non è valida. Ricollegare l'account non risolve il problema."))
        }
        try CloudHTTP.check(response, data: data)
        return try JSONDecoder().decode(Token.self, from: data)
    }
}

actor DriveAccount {
    static let shared = DriveAccount()
    private var cached: DriveCredentials?
    /// The service refused the access token before its expiry (revoked, or the Mac's clock was behind):
    /// the next request reloads the Keychain, where another app copy may have stored a newer one, and refreshes.
    private var rejected = false
    func expire() { cached = nil; rejected = true }
    func store(_ credentials: DriveCredentials) throws {
        try CloudKeychain.save(JSONEncoder().encode(credentials), account: "google-drive")
        cached = credentials
    }
    func disconnect() throws {
        try CloudKeychain.save(nil, account: "google-drive"); cached = nil
    }
    func credentials() throws -> DriveCredentials {
        if let cached { return cached }
        guard let data = try CloudKeychain.read("google-drive") else { throw CloudError.message(String(localized: "Collega un account Google Drive nelle impostazioni")) }
        let credentials = try JSONDecoder().decode(DriveCredentials.self, from: data)
        cached = credentials
        return credentials
    }
    func token() async throws -> String {
        var credentials = try credentials()
        if !rejected, credentials.expiresAt > Date().addingTimeInterval(90) { return credentials.accessToken }
        let refreshedFrom = credentials.refreshToken
        let token = try await Self.exchange(["client_id": credentials.clientID, "client_secret": credentials.clientSecret,
                                             "refresh_token": credentials.refreshToken, "grant_type": "refresh_token"])
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
        try await OAuthTokens.exchange(URL(string: "https://oauth2.googleapis.com/token")!, parameters,
                                       expired: String(localized: "Autorizzazione Google scaduta o non valida. Ricollega l'account."))
    }
}

struct GoogleDriveProvider: CloudLibraryProvider {
    let folder: String
    let accountID: String
    let accessToken: @Sendable () async throws -> String
    init(folder: String, accountID: String, accessToken: @escaping @Sendable () async throws -> String = { try await DriveAccount.shared.token() }) {
        self.folder = folder; self.accountID = accountID; self.accessToken = accessToken
    }
    var id: String { "drive:\(accountID):\(folder)" }
    private func request(_ url: String, method: String = "GET") async throws -> URLRequest {
        guard let url = URL(string: url) else { throw CloudError.message(String(localized: "URL Google Drive non valido")) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer " + (try await accessToken()), forHTTPHeaderField: "Authorization")
        return req
    }
    private func valid(_ id: String) throws -> String {
        guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw CloudError.message(String(localized: "ID Google Drive non valido")) }
        return id
    }
    private func files(matching query: String) async throws -> [String] {
        struct Page: Decodable {
            struct Item: Decodable { let id: String }
            let files: [Item]
            let nextPageToken: String?
        }
        var token: String?
        var ids: [String] = []
        repeat {
            var endpoint = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            endpoint.queryItems = [URLQueryItem(name: "q", value: query + " and trashed = false"),
                                   URLQueryItem(name: "fields", value: "nextPageToken,files(id)"),
                                   URLQueryItem(name: "pageSize", value: "100")]
            if let token { endpoint.queryItems?.append(URLQueryItem(name: "pageToken", value: token)) }
            let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(endpoint.url!.absoluteString))
            try CloudHTTP.check(response, data: data)
            let page = try JSONDecoder().decode(Page.self, from: data)
            ids.append(contentsOf: try page.files.map { try valid($0.id) })
            token = page.nextPageToken
        } while token != nil
        return ids
    }

    func existingLibraryFolder() async throws -> String? {
        let candidates = try await files(matching: "'root' in parents and mimeType = 'application/vnd.google-apps.folder' and name = 'Overheard'")
        if candidates.count <= 1 { return candidates.first }
        var marked: [String] = []
        for folder in candidates {
            let candidate = GoogleDriveProvider(folder: folder, accountID: accountID, accessToken: accessToken)
            if try await candidate.libraryMarkerID() != nil { marked.append(folder) }
        }
        guard marked.count == 1 else {
            throw CloudError.destination(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        return marked.first
    }

    func libraryMarkerID() async throws -> String? {
        let candidates = try await files(matching: "'\(try valid(folder))' in parents and name = '\(Self.libraryMarkerName)'")
        guard candidates.count <= 1 else {
            throw CloudError.destination(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        return candidates.first
    }

    func createLibraryMarker(file: URL) async throws {
        if try await libraryMarkerID() != nil { return }
        let id = try await reserve(meeting: CloudMeetingID(), name: Self.libraryMarkerName)
        try await upload(file: file, id: id, name: Self.libraryMarkerName, parent: folder, replacing: false)
    }

    func validateLibraryFolder() async throws {
        if folder == "root" { return }
        guard try await folderExists(folder) else {
            throw CloudError.destination(String(localized: "Cartella Google Drive nel Cestino o non accessibile. Ripristinala o scegli un'altra cartella."))
        }
    }

    func createFolder(name: String) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudError.message(String(localized: "Inserisci un nome per la cartella")) }
        var req = try await request("https://www.googleapis.com/drive/v3/files?fields=id", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": ["root"]])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await CloudHTTP.shared.session.data(for: req)
        try CloudHTTP.check(response, data: data)
        struct Folder: Decodable { let id: String }
        return try JSONDecoder().decode(Folder.self, from: data).id
    }
    func reserve(meeting: CloudMeetingID, name: String) async throws -> String {
        let req = try await request("https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive&type=files")
        let (data, response) = try await CloudHTTP.shared.session.data(for: req)
        try CloudHTTP.check(response, data: data)
        struct IDs: Decodable { let ids: [String] }
        guard let id = try JSONDecoder().decode(IDs.self, from: data).ids.first else { throw CloudError.message(String(localized: "Impossibile creare un ID remoto")) }
        return id
    }
    func inspect(_ id: String) async throws -> CloudFileVersion? {
        let req = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))?fields=size,sha256Checksum,trashed")
        let (data, response) = try await CloudHTTP.shared.session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try CloudHTTP.check(response, data: data)
        struct Metadata: Decodable { let size: String?; let sha256Checksum: String?; let trashed: Bool? }
        let metadata = try JSONDecoder().decode(Metadata.self, from: data)
        if metadata.trashed == true { return nil }
        if let size = metadata.size.flatMap(Int64.init), let hash = metadata.sha256Checksum {
            return CloudFileVersion(byteCount: size, sha256: hash)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await download(id, to: temporary)
        return try CloudFiles.version(temporary)
    }
    func reserveFolder() async throws -> String? { try await reserve(meeting: CloudMeetingID(), name: "") }
    /// Trashes the meeting's folder only when Drive lists nothing in it (recoverable from the Drive trash).
    func removeMeetingFolder(_ folder: String, id: String?) async throws {
        guard let id else { return }
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [URLQueryItem(name: "q", value: "'\(try valid(id))' in parents and trashed=false"),
                                 URLQueryItem(name: "pageSize", value: "1"), URLQueryItem(name: "fields", value: "files(id)")]
        let (data, response) = try await CloudHTTP.shared.session.data(for: try await request(components.url!.absoluteString))
        try CloudHTTP.check(response, data: data)
        struct Listing: Decodable { struct Item: Decodable { let id: String }; let files: [Item] }
        guard try JSONDecoder().decode(Listing.self, from: data).files.isEmpty else { return }
        try await remove(id)
    }
    func folderExists(_ id: String) async throws -> Bool {
        let req = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))?fields=mimeType,trashed")
        let (data, response) = try await CloudHTTP.shared.session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return false }
        try CloudHTTP.check(response, data: data)
        struct Folder: Decodable { let mimeType: String; let trashed: Bool? }
        let folder = try JSONDecoder().decode(Folder.self, from: data)
        guard folder.mimeType == "application/vnd.google-apps.folder" else {
            throw CloudError.message(String(localized: "Conflitto remoto. Copie locali conservate."))
        }
        return folder.trashed != true
    }
    func createFolder(id: String, name: String) async throws {
        var req = try await request("https://www.googleapis.com/drive/v3/files?fields=id", method: "POST")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": try valid(id), "name": name,
                                                                   "mimeType": "application/vnd.google-apps.folder", "parents": [try valid(folder)]])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await CloudHTTP.shared.session.data(for: req)
        do { try CloudHTTP.check(response, data: data) } catch let error as CloudError where !error.affectsDestination {
            // A retry after a lost response finds the folder already there: that is success.
            let probe = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))?fields=mimeType,trashed")
            let (body, status) = try await CloudHTTP.shared.session.data(for: probe)
            struct Folder: Decodable { let mimeType: String; let trashed: Bool? }
            guard (status as? HTTPURLResponse)?.statusCode == 200, let existing = try? JSONDecoder().decode(Folder.self, from: body),
                  existing.mimeType == "application/vnd.google-apps.folder", existing.trashed != true else { throw error }
        }
    }
    func upload(file: URL, id: String, name: String, replacing: Bool) async throws {
        try await upload(file: file, id: id, name: name, parent: nil, replacing: replacing)
    }
    func upload(file: URL, id: String, name: String, parent: String?, replacing: Bool) async throws {
        let bytes = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        try await resumeUpload(file: file, session: try await begin(id: id, name: name, parent: parent, replacing: replacing, bytes: bytes))
    }
    func beginUpload(id: String, name: String, parent: String?, replacing: Bool, version: CloudFileVersion) async throws -> String? {
        try await begin(id: id, name: name, parent: parent, replacing: replacing, bytes: version.byteCount)
    }
    private func begin(id: String, name: String, parent: String?, replacing: Bool, bytes: Int64) async throws -> String {
        let suffix = replacing ? "/\(try valid(id))" : ""
        var req = try await request("https://www.googleapis.com/upload/drive/v3/files\(suffix)?uploadType=resumable", method: replacing ? "PATCH" : "POST")
        var metadata: [String: Any] = ["name": name]
        if !replacing { metadata["id"] = try valid(id); metadata["parents"] = [try valid(parent ?? folder)] }
        req.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue(String(bytes), forHTTPHeaderField: "X-Upload-Content-Length")
        let (body, response) = try await CloudHTTP.shared.session.data(for: req)
        if !replacing, (response as? HTTPURLResponse)?.statusCode == 409 {
            // The reserved ID already exists: our own file, typically moved to the Drive trash by the user
            // (inspect reports trashed files as missing). Take it out of the trash and replace its content.
            var restore = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))", method: "PATCH")
            restore.httpBody = Data(#"{"trashed":false}"#.utf8)
            restore.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, restored) = try await CloudHTTP.shared.session.data(for: restore)
            try CloudHTTP.check(restored, data: data)
            return try await begin(id: id, name: name, parent: parent, replacing: true, bytes: bytes)
        }
        try CloudHTTP.check(response, data: body)
        guard let location = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"), Self.trusted(location) != nil else {
            throw CloudError.message(String(localized: "Sessione di caricamento Google non valida"))
        }
        return location
    }
    /// Chunk size for resumable uploads. Drive requires multiples of 256 KiB except for the last chunk.
    nonisolated(unsafe) static var chunkSize = 32 * 1024 * 1024
    /// Asks Drive how much it already stored, then sends the rest in bounded-memory chunks.
    func resumeUpload(file: URL, session: String) async throws {
        guard let url = Self.trusted(session) else { throw CloudError.message(String(localized: "Sessione di caricamento Google non valida")) }
        let total = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard var offset = try await send(url, range: "bytes */\(total)", body: Data()) else {
            await CloudSyncEngine.SyncProgress.uploadBytes?(total, total)
            return
        }
        await CloudSyncEngine.SyncProgress.uploadBytes?(offset, total)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        while true {
            try Task.checkCancellation()
            guard offset < total else { throw CloudError.message(String(localized: "Caricamento Google incompleto. Verrà riprovato.")) }
            try handle.seek(toOffset: UInt64(offset))
            let chunk = try handle.read(upToCount: Self.chunkSize) ?? Data()
            guard !chunk.isEmpty else { throw CloudError.message(String(localized: "File locale modificato durante il caricamento. Verrà riprovato.")) }
            guard let next = try await send(url, range: "bytes \(offset)-\(offset + Int64(chunk.count) - 1)/\(total)", body: chunk) else {
                await CloudSyncEngine.SyncProgress.uploadBytes?(total, total)
                return
            }
            guard next > offset else { throw CloudError.message(String(localized: "Caricamento Google incompleto. Verrà riprovato.")) }
            offset = next
            await CloudSyncEngine.SyncProgress.uploadBytes?(offset, total)
        }
    }
    /// One PUT to the session. Returns nil once Drive has the whole file, otherwise the next byte it expects.
    private func send(_ url: URL, range: String, body: Data) async throws -> Int64? {
        var req = try await request(url.absoluteString, method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(range, forHTTPHeaderField: "Content-Range")
        let (data, response) = try await CloudHTTP.shared.session.upload(for: req, from: body)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200, 201: return nil
        case 308: return Self.nextOffset(response)
        case 404, 410: throw CloudUploadExpired()
        default:
            try CloudHTTP.check(response, data: data)
            throw CloudError.message(String(localized: "Risposta cloud non valida"))
        }
    }
    static func nextOffset(_ response: URLResponse) -> Int64 {
        // "Range: bytes=0-1048575" lists what Drive stored. No header means nothing yet.
        guard let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range"),
              let last = range.split(separator: "-").last, let end = Int64(last) else { return 0 }
        return end + 1
    }
    private static func trusted(_ location: String) -> URL? {
        guard let url = URL(string: location), url.scheme == "https", url.host == "www.googleapis.com" else { return nil }
        return url
    }
    func download(_ id: String, to destination: URL) async throws {
        let req = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))?alt=media")
        let (file, response) = try await CloudHTTP.download(for: req)
        defer { try? FileManager.default.removeItem(at: file) }
        try CloudHTTP.check(response)
        try FileManager.default.moveItem(at: file, to: destination)
    }
    func remove(_ id: String) async throws {
        var req = try await request("https://www.googleapis.com/drive/v3/files/\(try valid(id))", method: "PATCH")
        req.httpBody = Data(#"{"trashed":true}"#.utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await CloudHTTP.shared.session.data(for: req)
        try CloudHTTP.check(response, allowing: [404])
    }
}
