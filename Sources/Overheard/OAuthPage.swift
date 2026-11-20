import Foundation

/// The page the browser shows when it comes back to Overheard after signing in.
/// Self-contained: inline style and logo, no scripts, nothing loaded from the network
/// (the address holds the authorization code, so nothing may receive it as a referrer).
enum OAuthPage {
    enum Outcome {
        /// Connected. `syncing`: the first upload starts now; otherwise the page says how to start it.
        case connected(service: String, account: String?, place: String, syncing: Bool)
        case failed(service: String, message: String)
        case cancelled
    }

    static func response(_ outcome: Outcome) -> Data {
        let body = Data(html(outcome).utf8)
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'",
            "Referrer-Policy: no-referrer",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((head + "\r\n\r\n").utf8) + body
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func html(_ outcome: Outcome) -> String {
        let badge: String, tone: String, title: String, lead: String
        var rows: [(icon: String, text: String)] = []
        switch outcome {
        case let .connected(service, account, place, syncing):
            badge = check; tone = "ok"
            title = String(localized: "\(service) è collegato")
            lead = account.map { String(localized: "Account: \($0)") } ?? String(localized: "Account collegato a Overheard.")
            rows.append((folder, String(localized: "Le riunioni vanno in \(place).")))
            rows.append((lock, String(localized: "Overheard vede solo la propria cartella, non il resto del tuo spazio.")))
            rows.append(syncing
                ? (upload, String(localized: "Il primo caricamento è partito, dalle riunioni più recenti. Puoi continuare a lavorare."))
                : (upload, String(localized: "Ultimo passo: in Overheard attiva “Sincronizza le riunioni”.")))
        case let .failed(service, message):
            badge = alert; tone = "warn"
            title = String(localized: "Collegamento a \(service) non riuscito")
            lead = message
            rows.append((retry, String(localized: "Torna in Overheard e riprova. Non è stato salvato nulla.")))
        case .cancelled:
            badge = alert; tone = "warn"
            title = String(localized: "Accesso annullato")
            lead = String(localized: "Nessun dato è stato condiviso.")
            rows.append((retry, String(localized: "Puoi riprovare quando vuoi dalle impostazioni di Overheard.")))
        }
        let list = rows.map { "<li><span class=\"i\">\($0.icon)</span><span>\(escape($0.text))</span></li>" }.joined()
        let language = Prefs.uiLanguage
        return """
        <!doctype html><html lang="\(language)"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Overheard</title><style>\(style)</style></head><body>
        <main class="card \(tone)">
          <div class="mark">\(logo)<span class="badge">\(badge)</span></div>
          <h1>\(escape(title))</h1>
          <p class="lead">\(escape(lead))</p>
          <ul>\(list)</ul>
          <a class="button" href="overheard://settings" rel="noreferrer">\(escape(String(localized: "Torna a Overheard")))</a>
          <p class="foot">\(escape(String(localized: "Puoi chiudere questa scheda.")))</p>
        </main></body></html>
        """
    }

    private static let style = """
    :root{--bg:#0B0B0C;--card:#151517;--line:rgba(255,255,255,.08);--fg:#F4F4F2;--dim:rgba(244,244,242,.66);--faint:rgba(244,244,242,.42);
    --coral:#FF6A5F;--teal:#5FD3C6;--grad:linear-gradient(135deg,#FF9A5B 0%,#FF4F6D 100%)}
    *{box-sizing:border-box}html,body{height:100%}
    body{margin:0;display:grid;place-items:center;padding:24px 16px;background:var(--bg);color:var(--fg);
    font:16px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;-webkit-font-smoothing:antialiased;
    background-image:radial-gradient(60% 50% at 50% 0%,rgba(255,106,95,.16),transparent 70%)}
    .card{width:100%;max-width:460px;background:var(--card);border:1px solid var(--line);border-radius:24px;padding:36px 32px 28px;
    box-shadow:0 30px 80px rgba(0,0,0,.45);animation:rise .6s cubic-bezier(.2,.7,.2,1) both}
    .mark{position:relative;width:76px;height:76px;margin-bottom:22px}
    .mark>svg{width:76px;height:76px;border-radius:19px;box-shadow:0 10px 30px rgba(255,79,109,.25);animation:float 5s ease-in-out 1s infinite}
    .badge{position:absolute;right:-8px;bottom:-8px;width:32px;height:32px;border-radius:50%;display:grid;place-items:center;
    border:3px solid var(--card);animation:pop .45s cubic-bezier(.2,1.4,.4,1) .35s both}
    .ok .badge{background:var(--teal)}.warn .badge{background:var(--coral)}
    .badge svg{width:16px;height:16px}.badge path{stroke-dasharray:30;stroke-dashoffset:30;animation:draw .5s ease-out .65s forwards}
    h1{margin:0 0 6px;font-size:26px;line-height:1.2;letter-spacing:-.02em;font-weight:700}
    .lead{margin:0 0 22px;color:var(--dim);word-break:break-word}
    ul{list-style:none;margin:0 0 26px;padding:0;border-top:1px solid var(--line)}
    li{display:flex;gap:12px;align-items:flex-start;padding:13px 0;border-bottom:1px solid var(--line);font-size:15px;color:var(--fg)}
    .i{flex:none;width:30px;height:30px;border-radius:9px;display:grid;place-items:center;background:rgba(255,255,255,.05);color:var(--coral)}
    .i svg{width:16px;height:16px}
    .button{display:block;text-align:center;padding:13px 18px;border-radius:12px;background:var(--grad);color:#fff;font-weight:600;
    text-decoration:none;transition:transform .15s,filter .15s}.button:hover{filter:brightness(1.08)}.button:active{transform:scale(.98)}
    .foot{margin:14px 0 0;text-align:center;font-size:13px;color:var(--faint)}
    @keyframes rise{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:none}}
    @keyframes pop{from{transform:scale(0)}to{transform:scale(1)}}
    @keyframes draw{to{stroke-dashoffset:0}}
    @keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}
    @media (prefers-reduced-motion:reduce){*{animation:none!important}.badge path{stroke-dashoffset:0}}
    @media (max-width:420px){.card{padding:28px 22px 22px}h1{font-size:23px}}
    """

    // The app icon (docs/assets/icon-tile.svg), inline.
    private static let logo = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="100 100 824 824" role="img" aria-label="Overheard"><defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0B0B0F"/><stop offset="1" stop-color="#1C1A22"/></linearGradient>
    <radialGradient id="glow" cx="512" cy="512" r="380" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#FF6A5F" stop-opacity=".22"/><stop offset="1" stop-color="#FF6A5F" stop-opacity="0"/></radialGradient>
    <linearGradient id="fg" gradientUnits="userSpaceOnUse" x1="214" y1="347" x2="806" y2="677"><stop offset="0" stop-color="#FF9A5B"/><stop offset="1" stop-color="#FF4F6D"/></linearGradient></defs>
    <rect x="100" y="100" width="824" height="824" rx="185" fill="url(#bg)"/><rect x="100" y="100" width="824" height="824" rx="185" fill="url(#glow)"/>
    <g transform="translate(512 512) scale(1.12) translate(-510 -512)"><g fill="url(#fg)"><rect x="214" y="437" width="48" height="150" rx="24"/><rect x="286" y="347" width="48" height="330" rx="24"/><rect x="358" y="397" width="48" height="230" rx="24"/><rect x="430" y="452" width="48" height="120" rx="24"/><rect x="526" y="353" width="280" height="48" rx="24"/><rect x="526" y="431" width="210" height="48" rx="24"/><rect x="526" y="509" width="250" height="48" rx="24"/><rect x="526" y="587" width="150" height="48" rx="24"/></g></g></svg>
    """
    private static func icon(_ path: String) -> String {
        "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">\(path)</svg>"
    }
    private static let check = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"#0B0B0C\" stroke-width=\"3.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M5 12.5l4.5 4.5L19 7.5\"/></svg>"
    private static let alert = "<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"#fff\" stroke-width=\"3.2\" stroke-linecap=\"round\" aria-hidden=\"true\"><path d=\"M12 6v8M12 18.5v.01\"/></svg>"
    private static let folder = icon("<path d=\"M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z\"/>")
    private static let lock = icon("<rect x=\"5\" y=\"11\" width=\"14\" height=\"9\" rx=\"2\"/><path d=\"M8 11V8a4 4 0 0 1 8 0v3\"/>")
    private static let upload = icon("<path d=\"M7 18a4.5 4.5 0 0 1-.6-9A6 6 0 0 1 18 8a4 4 0 0 1-1 10H7zM12 11v5M9.5 13.5 12 11l2.5 2.5\"/>")
    private static let retry = icon("<path d=\"M3 12a9 9 0 1 0 3-6.7L3 8M3 3v5h5\"/>")
}
