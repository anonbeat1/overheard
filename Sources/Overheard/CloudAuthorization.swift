import AppKit
import CryptoKit
import Network
import Security

/// OAuth credentials shipped with a release build (Info.plist, filled by build.sh from the environment).
/// With them, connecting is one click. Without them, the settings ask for the user's own credentials.
enum CloudAppKeys {
    private static func value(_ key: String) -> String? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !text.isEmpty, !text.hasPrefix("$(") else { return nil }
        return text
    }
    static var dropbox: String? { value("OverheardDropboxAppKey") }
    static var oneDrive: String? { value("OverheardOneDriveClientID") }
    static var google: (id: String, secret: String)? {
        guard let id = value("OverheardGoogleClientID"), let secret = value("OverheardGoogleClientSecret") else { return nil }
        return (id, secret)
    }
}

/// Authorization-code flow in the user's browser with PKCE, state validation and a loopback-only callback.
@MainActor
final class OAuthLoopback {
    /// The sign-in waiting for the browser, so Settings can cancel it.
    private static var current: OAuthLoopback?
    /// Stops the sign-in in progress, for example after an error page in the browser.
    static func cancelCurrent() {
        current?.finish(.failure(CloudError.message(String(localized: "Accesso annullato"))))
    }
    /// Opens the sign-in page again: the loopback listener keeps waiting, so a closed tab costs nothing.
    static func reopenCurrent() {
        if let page = current?.page { NSWorkspace.shared.open(page) }
    }
    private var page: URL?
    /// The browser's callback request, answered once the sign-in has really finished.
    private var reply: NWConnection?
    private var fallback: Task<Void, Never>?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var timeout: Task<Void, Never>?
    private var state = ""
    private var redirect = ""
    private var connections: [NWConnection] = []
    private var path = "/oauth2callback"
    let verifier: String
    let challenge: String

    init() throws {
        verifier = try Self.random()
        challenge = Self.base64(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// - Parameters:
    ///   - port: a fixed port for providers that only accept registered redirect URIs (Dropbox). nil picks a free one.
    ///   - path: the redirect path. Google's desktop clients expect the loopback root (`/`);
    ///     Dropbox needs exactly the path registered in its console.
    ///   - authorizeURL: builds the provider URL from the redirect URI and the state.
    /// - Returns: the authorization code and the redirect URI used.
    ///   - localhost: name the redirect `localhost` instead of `127.0.0.1` (Microsoft ignores the port only
    ///     for `localhost`). The browser may then use IPv6, so the callback is also accepted on `[::1]`.
    func authorize(port: UInt16? = nil, path: String = "/oauth2callback", localhost: Bool = false,
                   authorizeURL: @escaping (String, String) -> URL?) async throws -> (code: String, redirect: String) {
        state = try Self.random()
        self.path = path
        Self.current?.finish(.failure(CloudError.message(String(localized: "Accesso annullato"))))
        Self.current = self
        let pair = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, String), Error>) in
            self.continuation = continuation
            do {
                let parameters = NWParameters.tcp
                let local = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: local)
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        switch update {
                        case .ready:
                            guard let bound = listener.port else { self.finish(.failure(CloudError.message(String(localized: "Porta OAuth non disponibile")))); return }
                            self.redirect = "http://\(localhost ? "localhost" : "127.0.0.1"):\(bound.rawValue)\(self.path)"
                            if localhost { self.listenOnIPv6(bound) }
                            self.page = authorizeURL(self.redirect, self.state)
                            guard let target = self.page, NSWorkspace.shared.open(target) else {
                                self.finish(.failure(CloudError.message(String(localized: "Impossibile aprire il browser")))); return
                            }
                        case .failed:
                            let text = port.map { String(localized: "La porta \(Int($0)) è occupata da un'altra app. Chiudila e riprova.") }
                                ?? String(localized: "Porta OAuth non disponibile")
                            self.finish(.failure(CloudError.message(text)))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self else { connection.cancel(); return }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.receive(connection, buffer: Data())
                    }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    // Nothing waits on this in the UI, so leave time for two-factor sign-in.
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                    if !Task.isCancelled { self?.finish(.failure(CloudError.message(String(localized: "Accesso annullato o scaduto. Riprova.")))) }
                }
            } catch { finish(.failure(error)) }
        }
        return (pair.0, pair.1)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 8192, error == nil else { connection.cancel(); return }
                let text = String(decoding: buffer, as: UTF8.self)
                guard text.contains("\r\n\r\n") else {
                    if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                    return
                }
                let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", let url = URLComponents(string: "http://localhost" + parts[1]),
                      url.path == self.path,
                      url.queryItems?.first(where: { $0.name == "state" })?.value == self.state else { connection.cancel(); return }
                let code = url.queryItems?.first(where: { $0.name == "code" })?.value
                self.connections.removeAll { $0 === connection }
                self.reply = connection
                if let code, !code.isEmpty {
                    // The page waits for the token exchange, so it shows the real outcome.
                    self.fallback = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 30_000_000_000)
                        if !Task.isCancelled {
                            self?.respond(.failed(service: "Overheard", message: String(localized: "Overheard non ha confermato il collegamento. Controlla nelle impostazioni.")))
                        }
                    }
                    self.finish(.success((code, self.redirect)))
                } else {
                    self.respond(.cancelled)
                    self.finish(.failure(CloudError.message(String(localized: "Accesso annullato"))))
                }
            }
        }
    }
    /// Answers the browser with the final page. Only the first answer counts.
    func respond(_ outcome: OAuthPage.Outcome) {
        fallback?.cancel(); fallback = nil
        guard let connection = reply else { return }
        reply = nil
        connection.send(content: OAuthPage.response(outcome), completion: .contentProcessed { _ in connection.cancel() })
    }

    private var ipv6: NWListener?
    /// Same port on the IPv6 loopback, best effort: "localhost" may resolve to [::1] first.
    private func listenOnIPv6(_ port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: port)
        guard let listener = try? NWListener(using: parameters) else { return }
        ipv6 = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: .main)
                self.receive(connection, buffer: Data())
            }
        }
        listener.start(queue: .main)
    }

    private func finish(_ result: Result<(String, String), Error>) {
        let pending = continuation
        continuation = nil
        if Self.current === self { Self.current = nil }
        ipv6?.cancel(); ipv6 = nil
        listener?.cancel(); listener = nil
        timeout?.cancel(); timeout = nil
        for connection in connections { connection.cancel() }
        connections = []
        pending?.resume(with: result)
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CloudError.message(String(localized: "Generazione credenziali non riuscita")) }
        return base64(Data(bytes))
    }
    static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func url(_ base: String, _ items: [String: String]) -> URL? {
        var url = URLComponents(string: base)
        url?.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url?.url
    }
}

@MainActor
enum DriveAuthorization {
    /// Uses the build's own Google client when there is one, otherwise the credentials typed in Settings.
    static func connect(clientID: String? = nil, secret: String? = nil) async throws {
        guard let clientID = clientID?.nilIfEmpty ?? CloudAppKeys.google?.id, let secret = secret?.nilIfEmpty ?? CloudAppKeys.google?.secret,
              clientID.hasSuffix(".apps.googleusercontent.com") else {
            throw CloudError.message(String(localized: "Inserisci le credenziali OAuth per app desktop di Google"))
        }
        let flow = try OAuthLoopback()
        let (code, redirect) = try await flow.authorize(path: "/") { redirect, state in
            OAuthLoopback.url("https://accounts.google.com/o/oauth2/v2/auth", [
                "client_id": clientID, "redirect_uri": redirect, "response_type": "code",
                "scope": "https://www.googleapis.com/auth/drive.file", "access_type": "offline", "prompt": "consent select_account",
                "code_challenge": flow.challenge, "code_challenge_method": "S256", "state": state])
        }
        do {
            let email = try await finishGoogle(code: code, redirect: redirect, clientID: clientID, secret: secret, verifier: flow.verifier)
            flow.respond(.connected(service: "Google Drive", account: email,
                                    place: String(localized: "una cartella “Overheard” del tuo Google Drive"), syncing: CloudSync.shared.enabled))
        } catch {
            flow.respond(.failed(service: "Google Drive", message: error.localizedDescription))
            throw error
        }
    }

    private static func finishGoogle(code: String, redirect: String, clientID: String, secret: String, verifier: String) async throws -> String? {
        let token = try await DriveAccount.exchange(["client_id": clientID, "client_secret": secret, "code": code, "redirect_uri": redirect,
                                                     "code_verifier": verifier, "grant_type": "authorization_code"])
        guard let refresh = token.refresh_token else { throw CloudError.message(String(localized: "Google non ha fornito accesso offline. Riprova il collegamento.")) }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(permissionId,emailAddress)")!)
        request.setValue("Bearer " + token.access_token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await CloudHTTP.shared.session.data(for: request)
        try CloudHTTP.check(response, data: data)
        struct About: Decodable { struct User: Decodable { let permissionId: String; let emailAddress: String? }; let user: User }
        let user = try JSONDecoder().decode(About.self, from: data).user
        try await DriveAccount.shared.store(DriveCredentials(clientID: clientID, clientSecret: secret, refreshToken: refresh, accessToken: token.access_token,
                                                             expiresAt: Date().addingTimeInterval(token.expires_in), accountID: user.permissionId,
                                                             email: user.emailAddress))
        return user.emailAddress
    }
}

@MainActor
enum DropboxAuthorization {
    /// Dropbox accepts only registered redirect URIs, so the callback uses a fixed loopback port.
    /// Register exactly this URI in the Dropbox app console.
    static let port: UInt16 = 53139
    static var redirectURI: String { "http://127.0.0.1:\(port)/oauth2callback" }

    static func connect(appKey: String? = nil) async throws {
        guard let key = appKey?.nilIfEmpty ?? CloudAppKeys.dropbox else {
            throw CloudError.message(String(localized: "Inserisci la App key della tua app Dropbox"))
        }
        let flow = try OAuthLoopback()
        let (code, redirect) = try await flow.authorize(port: port) { redirect, state in
            OAuthLoopback.url("https://www.dropbox.com/oauth2/authorize", [
                "client_id": key, "redirect_uri": redirect, "response_type": "code", "token_access_type": "offline",
                "code_challenge": flow.challenge, "code_challenge_method": "S256", "state": state])
        }
        do {
            let token = try await DropboxAccount.exchange(["client_id": key, "code": code, "redirect_uri": redirect,
                                                           "code_verifier": flow.verifier, "grant_type": "authorization_code"])
            guard let refresh = token.refresh_token, let account = token.account_id else {
                throw CloudError.message(String(localized: "Dropbox non ha fornito accesso offline. Riprova il collegamento."))
            }
            let email = try? await DropboxAccount.email(token.access_token)
            try await DropboxAccount.shared.store(DropboxCredentials(appKey: key, refreshToken: refresh, accessToken: token.access_token,
                                                                     expiresAt: Date().addingTimeInterval(token.expires_in), accountID: account,
                                                                     email: email))
            flow.respond(.connected(service: "Dropbox", account: email,
                                    place: String(localized: "Dropbox › Applicazioni › Overheard"), syncing: CloudSync.shared.enabled))
        } catch {
            flow.respond(.failed(service: "Dropbox", message: error.localizedDescription))
            throw error
        }
    }
}

@MainActor
enum OneDriveAuthorization {
    /// Register `http://localhost` (platform "Mobile and desktop applications") in Microsoft Entra:
    /// the port is ignored for localhost redirects. Public client with PKCE, no secret.
    static func connect(clientID: String? = nil) async throws {
        guard let client = clientID?.nilIfEmpty ?? CloudAppKeys.oneDrive else {
            throw CloudError.message(String(localized: "Inserisci l'ID applicazione Microsoft della tua app"))
        }
        let flow = try OAuthLoopback()
        let (code, redirect) = try await flow.authorize(path: "/", localhost: true) { redirect, state in
            OAuthLoopback.url("https://login.microsoftonline.com/common/oauth2/v2.0/authorize", [
                "client_id": client, "redirect_uri": redirect, "response_type": "code", "response_mode": "query",
                "scope": OneDriveAccount.scope, "prompt": "select_account",
                "code_challenge": flow.challenge, "code_challenge_method": "S256", "state": state])
        }
        do {
            let token = try await OneDriveAccount.exchange(["client_id": client, "code": code, "redirect_uri": redirect,
                                                            "code_verifier": flow.verifier, "grant_type": "authorization_code",
                                                            "scope": OneDriveAccount.scope])
            guard let refresh = token.refresh_token else {
                throw CloudError.message(String(localized: "OneDrive non ha fornito accesso offline. Riprova il collegamento."))
            }
            let me = try await OneDriveAccount.identity(token.access_token)
            try await OneDriveAccount.shared.store(OneDriveCredentials(clientID: client, refreshToken: refresh, accessToken: token.access_token,
                                                                       expiresAt: Date().addingTimeInterval(token.expires_in),
                                                                       accountID: me.id, email: me.email))
            flow.respond(.connected(service: "OneDrive", account: me.email,
                                    place: String(localized: "OneDrive › App › Overheard"), syncing: CloudSync.shared.enabled))
        } catch {
            flow.respond(.failed(service: "OneDrive", message: error.localizedDescription))
            throw error
        }
    }
}
