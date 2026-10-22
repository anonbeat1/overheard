// Menu bar app: registra le riunioni in ~/Meetings (vedi Capture.swift) e propone di registrare quando
// Meet/Teams iniziano a usare il microfono. Dopo lo stop trascrive (Transcription.swift). Da script: open -g overheard://toggle
import AppKit
import CoreAudio
import ServiceManagement
import Sparkle
import SwiftUI
import UserNotifications

let home = FileManager.default.homeDirectoryForCurrentUser.path

// MARK: - Rilevamento riunione (chi sta usando il microfono, macOS 14.2+)

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func micUsers() -> [String] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.compactMap { id in
        guard prop(id, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { return nil }
        return prop(id, kAudioProcessPropertyBundleID, "" as CFString) as String?
    }
}

/// ponytail: Teams nel browser risulta "meet".
func meetingSource() -> String? {
    let users = micUsers().filter { $0 != "com.apple.replayd" }.joined(separator: "\n").lowercased()
    if users.contains("teams") { return "teams" }
    if users.contains("slack") { return "slack" } // huddle (com.tinyspeck.slackmacgap)
    if ["chrome", "safari", "arc", "brave", "firefox", "edgemac", "vivaldi", "opera"].contains(where: users.contains) { return "meet" }
    return nil
}

// MARK: - Stato e azioni

@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()

    @Published var recording = false
    @Published var since: Date?
    @Published var source = ""
    @Published var meeting: String?
    @Published var busy = false
    @Published var panelVisible = false // l'animazione del logo gira solo a pannello aperto
    @Published var autoDetect = UserDefaults.standard.object(forKey: "autoDetect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoDetect, forKey: "autoDetect") }
    }
    /// Motore di trascrizione: "elevenlabs" o "local"
    @Published var engine = Recorder.defaultEngine {
        didSet { UserDefaults.standard.set(engine, forKey: "engine") }
    }

    /// Nuove installazioni su macOS 15+: sul Mac, senza chiavi. Chi aveva già l'app resta su ElevenLabs.
    /// Si salva subito, così dopo l'onboarding non cambia.
    private static var defaultEngine: String {
        let d = UserDefaults.standard
        if let e = d.string(forKey: "engine") { return e }
        let e = !d.bool(forKey: "onboarding.done") && LocalModels.supported ? "local" : "elevenlabs"
        d.set(e, forKey: "engine")
        return e
    }

    func cleanOld() {
        let n = Retention.run(skipping: capture?.dir)
        if n > 0 { notify(String(localized: "Pulizia meeting"), String(localized: "\(n) meeting più vecchi di \(Retention.days) giorni spostati nel Cestino")) }
    }

    /// Registrazioni interrotte da una chiusura improvvisa: le chiude e le trascrive
    func recoverInterrupted() {
        let dirs = Recovery.orphans(skipping: capture?.dir), pending = Recovery.untranscribed(skipping: capture?.dir)
        guard !dirs.isEmpty || !pending.isEmpty else { return }
        let engine = engine
        Task.detached {
            var todo = pending
            for dir in dirs where Recovery.finalize(dir) { todo.append(dir) }
            guard !todo.isEmpty else { return }
            notify(String(localized: "Registrazione recuperata"), String(localized: "L'app si era chiusa durante la call: la trascrivo ora"))
            await MainActor.run { NotificationCenter.default.post(name: .meetingsChanged, object: nil) }
            for dir in todo { _ = await Transcriber.run(dir: dir, engine: engine) }
        }
    }

    func sourceOf(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("source"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "altro"
    }

    private var capture: MeetingCapture?
    var currentDir: URL? { capture?.dir }
    /// Cartella in registrazione? Per nome: lo stesso percorso può arrivare con o senza "/" finale
    func isRecording(_ dir: URL) -> Bool { capture?.dir.lastPathComponent == dir.lastPathComponent }
    var captureForQuit: MeetingCapture? { capture }
    private var handled = false // call già gestita (registrata o scartata): non ripartire finché non lascia il mic
    private var sawMeeting = false // la call è stata vista durante la registrazione
    private var goneSince: Date?

    init() {
        // pulizia dei meeting vecchi all'avvio e poi ogni ora
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Recorder.shared.cleanOld() }
        }
        DispatchQueue.main.async { Recorder.shared.cleanOld() }
        DispatchQueue.main.async { Recorder.shared.recoverInterrupted() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in Recorder.shared.tick() }
        }
    }

    func tick() {
        meeting = meetingSource()
        if let capture {
            // Se allo start la call non era ancora partita, aggiorna la sorgente appena la vede
            if let m = meeting, capture.source == "altro" { try? capture.setSource(m); source = m }
            // Stop automatico quando la call rilascia il microfono (attesa nelle Impostazioni, 30s di default)
            if meeting != nil {
                sawMeeting = true
                goneSince = nil
            } else if sawMeeting {
                if goneSince == nil { goneSince = .now }
                let wait = UserDefaults.standard.object(forKey: "autoStop.seconds") as? Double ?? 30
                if let g = goneSince, Date().timeIntervalSince(g) >= wait, !busy { toggle(reason: "Riunione terminata") }
            }
        } else if let m = meeting {
            if !handled && autoDetect {
                handled = true
                toggle(auto: m)
            }
        } else {
            handled = false
        }
    }

    /// `auto`: sorgente della call che ha fatto partire la registrazione automatica.
    @Published var bookmarks = 0

    /// Segna il momento attuale della registrazione (⌃⌥M, pulsante nel pannello, overheard://bookmark)
    func bookmark() {
        guard let capture, let since else { return notify(String(localized: "Nessuna registrazione in corso"), String(localized: "⌃⌥M segna i momenti importanti mentre registri")) }
        let t = Date().timeIntervalSince(since)
        Bookmarks.add(capture.dir, seconds: t)
        bookmarks += 1
        notify(String(localized: "⭐ Momento segnato"), String(localized: "al minuto \(Summarizer.stamp(t)) · lo trovi nel transcript e nel riassunto"))
    }

    func toggle(reason: String? = nil, auto: String? = nil, discard: Bool = false) {
        guard !busy else { return }
        if let capture {
            busy = true
            capture.stop { [self] in
                self.capture = nil
                busy = false
                recording = false
                since = nil
                if discard {
                    try? FileManager.default.removeItem(at: capture.dir)
                    notify(String(localized: "Registrazione scartata"), String(localized: "Non verrà trascritta"))
                } else {
                    notify(reason ?? String(localized: "Registrazione salvata"), String(localized: "⏹ \(sourceLabel(source).0) · trascrizione in corso"))
                    let dir = capture.dir, engine = engine, started = capture.started
                    let label = sourceLabel(sourceOf(dir)).0
                    Task.detached { // fuori dal main thread: legge il Portachiavi e lavora sull'audio
                        MeetingCalendar.annotate(dir, at: started) // se all'avvio non c'era ancora l'evento
                        switch await Transcriber.run(dir: dir, engine: engine) {
                        case .success: notify(String(localized: "Transcript pronto"), String(localized: "\(label) · apri da Ultime riunioni"))
                        case let .failure(e): notify(String(localized: "Trascrizione non riuscita"), e.localizedDescription)
                        }
                    }
                }
                source = ""
            }
        } else {
            let src = meetingSource() ?? "altro"
            do {
                let c = try MeetingCapture(source: src)
                capture = c
                recording = true
                since = c.started
                bookmarks = 0
                let dir = c.dir, started = c.started
                Task.detached { MeetingCalendar.annotate(dir, at: started) }
                source = src
                sawMeeting = meeting != nil
                goneSince = nil
                if let auto { notifyAutoStart(auto) }
                if !c.micOK { notify(String(localized: "Registrazione avviata senza microfono"), String(localized: "Controlla il permesso Microfono per Overheard")) }
            } catch {
                notify(String(localized: "❌ Registrazione non avviata"), error.localizedDescription)
            }
        }
    }

    func notifyAutoStart(_ source: String) {
        let c = UNMutableNotificationContent()
        c.title = "⏺ Sto registrando · \(sourceLabel(source).0)"
        c.body = "Riunione rilevata. Non vuoi registrarla? Clicca \"Non registrare\"."
        c.categoryIdentifier = "AUTOREC"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "meeting", content: c, trigger: nil))
    }
}

func notify(_ title: String, _ body: String) {
    let c = UNMutableNotificationContent()
    c.title = title
    c.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
}

// MARK: - Notifiche

/// Aggiornamenti automatici (Sparkle): feed e chiave pubblica in Info.plist, pubblicazione con release.sh.
/// "Gentili": durante una call o una trascrizione non apre finestre, mette un pallino sull'icona e una riga nel pannello.
@MainActor
enum Updates {
    static let state = UpdateState()
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: state)
    static func check() { NSApp.activate(ignoringOtherApps: true); controller.checkForUpdates(nil) }
}

final class UpdateState: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @MainActor @Published var available: String? // versione trovata e non ancora mostrata

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated {
            let busy = Recorder.shared.recording || ((try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Meetings")) ?? [])
                .contains { FileManager.default.fileExists(atPath: "\(home)/Meetings/\($0)/.transcribing") }
            return immediateFocus && !busy
        }
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { available = handleShowingUpdate ? nil : update.displayVersionString }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { available = nil }
    }
}

/// Voce di menu che esegue una closure
final class MenuAction: NSObject {
    private static var all: [MenuAction] = []
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @MainActor @objc func fire() { run() }

    static func item(_ title: String, _ key: String, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let a = MenuAction(run)
        all.append(a) // NSMenuItem.target è weak
        let i = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: key)
        i.target = a
        return i
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { TranscriptWindow.show(nil) }
        return false
    }

    /// Esci / aggiornamento Sparkle durante una call: chiude bene i file (poi trascrive al prossimo avvio)
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let capture = Recorder.shared.captureForQuit else { return .terminateNow }
            capture.stop { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
    }

    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // kill / pkill: passa da applicationShouldTerminate invece di troncare la registrazione
        signal(SIGTERM, SIG_IGN)
        // terminate dal run loop, non da un blocco della coda principale: lo stop della registrazione
        // risponde con DispatchQueue.main.async, che resterebbe bloccato dietro al blocco in corso
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigterm?.setEventHandler { RunLoop.main.perform { NSApp.terminate(nil) } }
        sigterm?.resume()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let discard = UNNotificationAction(identifier: "DISCARD", title: String(localized: "Non registrare"), options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: "AUTOREC", actions: [discard], intentIdentifiers: [])])
        // i nuovi utenti la concedono nell'introduzione, non al primo avvio insieme a tutto il resto
        if UserDefaults.standard.bool(forKey: "onboarding.done") { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        Self.applyDock()
        HotKey.register()
        _ = Recorder.shared
        MainActor.assumeIsolated {
            PanelController.shared.setup()
            _ = Updates.controller
            Onboarding.showIfNeeded()
        }
    }

    /// Icona nel Dock (Impostazioni): app normale con il suo menu; altrimenti solo barra dei menu
    static func applyDock() {
        let dock = UserDefaults.standard.bool(forKey: "dock.visible")
        NSApp.setActivationPolicy(dock ? .regular : .accessory)
        NSApp.mainMenu = editMenu(appMenu: dock)
        if dock { NSApp.activate(ignoringOtherApps: true) }
    }

    /// App solo-barra: senza un menu Modifica, ⌘A/⌘C/⌘V/⌘Z non arrivano ai campi di testo.
    /// Il menu non si vede (niente barra dei menu per le app accessorie) ma le scorciatoie funzionano.
    static func editMenu(appMenu: Bool = false) -> NSMenu {
        let main = NSMenu()
        if appMenu { // con il Dock la barra dei menu si vede: il primo menu è quello dell'app
            let app = NSMenu(title: "Overheard")
            app.addItem(MenuAction.item(String(localized: "Riunioni"), "l") { TranscriptWindow.show(nil) })
            app.addItem(MenuAction.item(String(localized: "Impostazioni…"), ",") { SettingsWindow.show() })
            app.addItem(MenuAction.item(String(localized: "Controlla aggiornamenti…"), "") { Updates.check() })
            app.addItem(.separator())
            app.addItem(withTitle: String(localized: "Esci da Overheard"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            let item = NSMenuItem()
            item.submenu = app
            main.addItem(item)
        }
        let edit = NSMenu(title: String(localized: "Modifica"))
        for (title, action, key) in [("Annulla", "undo:", "z"), ("Ripeti", "redo:", "Z"), ("Taglia", "cut:", "x"), ("Copia", "copy:", "c"),
                                     ("Incolla", "paste:", "v"), ("Seleziona tutto", "selectAll:", "a"), ("Chiudi finestra", "performClose:", "w")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let item = NSMenuItem()
        item.submenu = edit
        main.addItem(item)
        return main
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "DISCARD" else { return }
        await MainActor.run {
            if Recorder.shared.recording { Recorder.shared.toggle(discard: true) }
        }
    }

    /// overheard://toggle (usato da Raycast)
    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(where: { $0.host == "toggle" }) { MainActor.assumeIsolated { Recorder.shared.toggle() } }
        if urls.contains(where: { $0.host == "bookmark" }) { MainActor.assumeIsolated { Recorder.shared.bookmark() } }
        if urls.contains(where: { $0.host == "meetings" }) { MainActor.assumeIsolated { TranscriptWindow.show(nil) } }
        // overheard://import?url=<file o link> (es. da Raycast)
        for u in urls where u.host == "import" {
            guard let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { continue }
            MainActor.assumeIsolated {
                if v.hasPrefix("http") { Importer.shared.importLink(v) } else { Task { await Importer.shared.importFile(URL(fileURLWithPath: v)) } }
            }
        }
    }
}

// MARK: - UI

struct Meeting: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    let source: String
    var title: String? // file "title": per i file e link importati

    /// Meeting da una cartella di ~/Meetings (file source e title opzionali)
    static func at(_ d: URL) -> Meeting {
        func read(_ name: String) -> String? {
            (try? String(contentsOf: d.appendingPathComponent(name), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Meeting(url: d, source: read("source") ?? "altro", title: read("title"))
    }

    static func recent(_ n: Int = 4) -> [Meeting] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "\(home)/Meetings"), includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.lastPathComponent.hasPrefix("20") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(n)
            .map(Meeting.at)
    }

    var date: Date? {
        let f = DateFormatter()
        f.dateFormat = id.count > 15 ? "yyyy-MM-dd_HHmmss" : "yyyy-MM-dd_HHmm"
        return f.date(from: id)
    }

    /// "12:20" oggi, "ieri 20:20", altrimenti "10 ott 20:20"
    var when: String {
        guard let d = date else { return id }
        let time = d.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time }
        if cal.isDateInYesterday(d) { return String(localized: "ieri \(time)") }
        return "\(d.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    var app: String {
        if let title, !title.isEmpty { return title }
        let name = switch source {
        case "meet": "Google Meet"
        case "teams": "Microsoft Teams"
        case "slack": "Slack"
        default: String(localized: "Altro")
        }
        let label = Prefs.label(source)
        return label.isEmpty ? name : (source == "altro" ? label : "\(name) · \(label)")
    }
}

/// Icona di Teams o Slack (dall'app installata), altrimenti un simbolo.
struct SourceIcon: View {
    let source: String
    var body: some View {
        if let img = Self.appIcon(source) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 20, height: 20)
        } else {
            Image(systemName: source == "altro" ? "mic.fill" : source == "import" ? "square.and.arrow.down.fill" : "video.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(sourceLabel(source).1, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    static func appIcon(_ source: String) -> NSImage? {
        let ws = NSWorkspace.shared
        switch source {
        case "teams":
            let url = ["com.microsoft.teams2", "com.microsoft.teams"].lazy.compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
            return url.map { ws.icon(forFile: $0.path) }
        case "slack":
            return ws.urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap").map { ws.icon(forFile: $0.path) }
        default:
            return nil
        }
    }
}

/// Nome dell'app della call + etichetta personale dalle Impostazioni (es. "Teams · Acme").
func sourceLabel(_ s: String) -> (String, Color) {
    let (app, color): (String, Color) = switch s {
    case "teams": ("Teams", .indigo)
    case "meet": ("Meet", .teal)
    case "slack": ("Slack", .purple)
    case "import": (String(localized: "Importato"), .blue)
    default: (String(localized: "Altro"), .gray)
    }
    let label = Prefs.label(s)
    return (label.isEmpty ? app : (s == "altro" ? label : "\(app) · \(label)"), color)
}
// Stile "Now Playing": pannello nero molto stondato, testo bianco, card scure, glow rosso quando registra.
let panelRadius: CGFloat = 30
let arrowHeight: CGFloat = 11

/// Sfondo del pannello: rettangolo stondato con una "goccia" in alto che punta all'icona nella barra dei menu.
struct PanelShape: Shape {
    var arrowX: CGFloat? // x della punta, relativa al pannello; nil = senza goccia

    func path(in rect: CGRect) -> Path {
        let body = Path(roundedRect: CGRect(x: 0, y: arrowHeight, width: rect.width, height: rect.height - arrowHeight),
                        cornerRadius: panelRadius, style: .continuous)
        guard let ax = arrowX.map({ min(max($0, panelRadius + 16), rect.width - panelRadius - 16) }) else { return body }
        var drop = Path()
        drop.move(to: CGPoint(x: ax - 16, y: arrowHeight + 1))
        drop.addCurve(to: CGPoint(x: ax, y: 0), control1: CGPoint(x: ax - 8, y: arrowHeight + 1), control2: CGPoint(x: ax - 5, y: 0))
        drop.addCurve(to: CGPoint(x: ax + 16, y: arrowHeight + 1), control1: CGPoint(x: ax + 5, y: 0), control2: CGPoint(x: ax + 8, y: arrowHeight + 1))
        drop.closeSubpath()
        return body.union(drop)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Pillola azione del pannello (icona + testo)
struct QuickAction: View {
    let icon: String
    let title: LocalizedStringKey
    var tint: Color = .white
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) { Self.label(icon: icon, title: title, tint: tint, hover: hover) }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
    }

    static func label(icon: String, title: LocalizedStringKey, tint: Color = .white, hover: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .background(Color.white.opacity(hover ? 0.13 : 0.07), in: Capsule())
        .contentShape(Capsule())
    }
}

struct RoundButton: View {
    let icon: String
    var tint: Color = .white
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct MenuView: View {
    var arrowX: CGFloat?
    @ObservedObject var rec = Recorder.shared
    @ObservedObject var updates = Updates.state
    @State private var meetings = Meeting.recent()
    @State private var query = ""
    @State private var notified = false

    /// Il messaggio per la chat della call: chi registra lo dice, e chi non vuole può chiedere di fermarsi
    private func notifyParticipants() {
        let msg = rec.engine == "local"
            ? String(localized: "Sto registrando questa call con Overheard per avere trascrizione e appunti. L'audio resta sul mio Mac. Se preferisci di no, dimmelo e mi fermo.")
            : String(localized: "Sto registrando questa call con Overheard per avere trascrizione e appunti. Se preferisci di no, dimmelo e mi fermo.")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(msg, forType: .string)
        notified = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { notified = false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LogoView(recording: rec.recording, size: 40, paused: !rec.panelVisible)
                Text(rec.recording ? "In registrazione" : "Meeting").font(.system(size: 20, weight: .bold))
                Spacer()
                RoundButton(icon: "gearshape") { PanelController.shared.hide(); SettingsWindow.show() }.help("Impostazioni")
            }
            if let v = updates.available, !rec.recording {
                Button { PanelController.shared.hide(); Updates.check() } label: {
                    Label("Aggiornamento disponibile: \(v) · Novità", systemImage: "arrow.down.circle.fill")
                        .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            // Registrazione
            HStack(spacing: 18) {
                Button { rec.toggle() } label: {
                    ZStack {
                        Circle().fill(rec.recording ? Color.red : Color.white)
                        Image(systemName: rec.recording ? "stop.fill" : "record.circle")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(rec.recording ? .white : .black)
                    }
                    .frame(width: 84, height: 84)
                    .shadow(color: rec.recording ? .red.opacity(0.7) : .white.opacity(0.15), radius: 22)
                    .symbolEffect(.pulse, isActive: rec.recording)
                }
                .buttonStyle(.plain)
                .disabled(rec.busy)

                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        if rec.busy {
                            Text(rec.recording ? "Salvataggio…" : "Avvio…")
                        } else if rec.recording, let since = rec.since {
                            Text(since, style: .timer).monospacedDigit()
                        } else {
                            Text("Pronto")
                        }
                    }
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    if rec.recording {
                        HStack(spacing: 8) {
                            chip(rec.source)
                            Button { rec.bookmark() } label: {
                                Label(rec.bookmarks > 0 ? "\(rec.bookmarks)" : "Segna", systemImage: "star.fill")
                            }
                            .buttonStyle(.plain)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.yellow)
                            .help("Segna questo momento (⌃⌥M da qualsiasi app)")
                            Button("Scarta") { rec.toggle(discard: true) }
                                .buttonStyle(.plain)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .disabled(rec.busy)
                        }
                        Button { notifyParticipants() } label: {
                            Label(notified ? "Copiato: incollalo nella chat della call" : "Avvisa i partecipanti",
                                  systemImage: notified ? "checkmark" : "bubble.left")
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(notified ? 0.9 : 0.6))
                        .help("Copia un messaggio da incollare nella chat della call per dire che stai registrando")
                    } else if let m = rec.meeting {
                        Text("Riunione rilevata · \(sourceLabel(m).0)").font(.callout).foregroundStyle(.orange)
                    } else if let next = MeetingCalendar.next() {
                        Text("\(next.title ?? "Riunione") · \(next.startDate, style: .relative)")
                            .font(.callout).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    } else {
                        Text("Clicca per registrare").font(.callout).foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer(minLength: 0)
            }

            QuickSearch(query: $query)
                .id(rec.panelVisible) // ricreata a ogni apertura: rilegge i transcript

            // azioni in vista: archivio, import, AI (prima erano raggiungibili solo da "Vedi tutte")
            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                HStack(spacing: 8) {
                    QuickAction(icon: "rectangle.stack", title: "Riunioni") { PanelController.shared.hide(); TranscriptWindow.show(nil) }
                    Menu {
                        Button("File audio o video…") { PanelController.shared.hide(); Importer.shared.pickFiles() }
                        Button("Da link (YouTube, podcast…)…") { PanelController.shared.hide(); TranscriptWindow.show(nil, importLink: true) }
                    } label: {
                        QuickAction.label(icon: "square.and.arrow.down", title: "Importa", hover: false)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    QuickAction(icon: "sparkles", title: "Chiedi", tint: .orange) { PanelController.shared.hide(); TranscriptWindow.show(nil, chat: true) }
                }
            }

            if query.trimmingCharacters(in: .whitespaces).count < 2, !meetings.isEmpty {
                Card {
                    HStack {
                        Text("Ultime riunioni").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Button("Vedi tutte") { PanelController.shared.hide(); TranscriptWindow.show(nil) }
                            .buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                    ForEach(meetings) { m in
                        Button { open(m) } label: {
                            HStack {
                                SourceIcon(source: m.source)
                                Text(m.app)
                                Text("· \(m.when)").foregroundStyle(.white.opacity(0.5))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(22)
        .padding(.top, arrowHeight)
        .frame(width: 380)
        .foregroundStyle(.white)
        .background(Color.black, in: PanelShape(arrowX: arrowX))
        .environment(\.colorScheme, .dark)
        .onAppear { meetings = Meeting.recent() }
        // l'NSHostingView del pannello resta lo stesso (stato e onAppear non si rinnovano):
        // a ogni apertura si rileggono le ultime riunioni
        .onChange(of: rec.panelVisible) { _, visible in
            guard visible else { return }
            meetings = Meeting.recent()
            query = ""
            DispatchQueue.main.async { PanelController.shared.fit() }
        }
        .onChange(of: query) { _, _ in DispatchQueue.main.async { PanelController.shared.fit() } }
    }

    func chip(_ source: String) -> some View {
        let (label, color) = sourceLabel(source)
        return Text(label).font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(color.opacity(0.25), in: Capsule())
            .foregroundStyle(color)
    }

    func open(_ m: Meeting) {
        PanelController.shared.hide()
        TranscriptWindow.show(m)
    }
}

// MARK: - Status item + pannello senza bordi (MenuBarExtra non permette angoli/sfondo custom)

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    // il pannello non attiva l'app, quindi le scorciatoie del menu Modifica vanno inoltrate a mano
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || (NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false)
    }
}

@MainActor
final class PanelController {
    static let shared = PanelController()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: Panel!
    private var host: NSHostingView<MenuView>!
    private var clickMonitor: Any?
    private var sub: Any?

    func setup() {
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]) // clic destro: menu con cartella ed Esci
        sub = Recorder.shared.$recording.combineLatest(Updates.state.$available)
            .sink { [weak self] on, update in self?.setIcon(on, update: update != nil) }

        host = NSHostingView(rootView: MenuView())
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
    }

    private func setIcon(_ recording: Bool, update: Bool) {
        // Glifo onda→testo (Resources/MenuIcon.png): template normalmente, rossa mentre registra, pallino se c'è un aggiornamento
        guard let base = Bundle.main.image(forResource: "MenuIcon") else { return }
        base.size = NSSize(width: 22, height: 22)
        if update && !recording {
            base.isTemplate = true
            let dot = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.maxX - 7, y: r.maxY - 7, width: 7, height: 7)).fill()
                return true
            }
            item.button?.image = dot
            return
        }
        guard recording else { base.isTemplate = true; item.button?.image = base; return }
        item.button?.image = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSColor.systemRed.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }

    @objc private func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp { return showMenu() }
        panel.isVisible ? hide() : show()
    }

    private func showMenu() {
        hide()
        let menu = NSMenu()
        for (title, key, action) in [(String(localized: "Riunioni"), "", #selector(openLibrary)), (String(localized: "Apri cartella Meetings"), "", #selector(openFolder)),
                                     (String(localized: "Impostazioni…"), ",", #selector(openSettings)),
                                     (String(localized: "Controlla aggiornamenti…"), "", #selector(checkUpdates))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: key).target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Esci da Overheard"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openLibrary() { MainActor.assumeIsolated { TranscriptWindow.show(nil) } }
    @objc private func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/Meetings")) }
    @objc private func openSettings() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc private func checkUpdates() { MainActor.assumeIsolated { Updates.check() } }

    func show() {
        guard let button = item.button, let win = button.window else { return }
        host.rootView = MenuView() // ricarica ultime riunioni
        let size = host.fittingSize
        let anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = win.screen?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        host.rootView = MenuView(arrowX: anchor.midX - x) // la goccia punta all'icona anche se il pannello è spostato
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 1, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        Recorder.shared.panelVisible = true
        // il clic sull'icona arriva anche qui (la barra è di un altro processo): lo ignora, ci pensa togglePanel a chiudere
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in
                if anchor.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) { return }
                PanelController.shared.hide()
            }
        }
    }

    /// Ridimensiona il pannello al contenuto tenendo fisso il bordo in alto (la goccia resta attaccata alla barra)
    func fit() {
        guard panel.isVisible else { return }
        let h = host.fittingSize.height, f = panel.frame
        guard abs(h - f.height) > 0.5 else { return }
        panel.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true, animate: false)
    }

    func hide() {
        panel.orderOut(nil)
        Recorder.shared.panelVisible = false
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

// Avvio AppKit puro: una App SwiftUI richiede una scena (es. Settings) che macOS apre da sola all'avvio.
@main
enum OverheardMain {
    static let delegate = AppDelegate()

    static func main() {
        migrateFromMeetingRecorder()
        if CommandLine.arguments.contains("--mcp") { MCPServer.run() } // server MCP per Claude & co., niente interfaccia
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory) // solo barra dei menu, niente Dock
        app.delegate = delegate
        app.run()
    }

    /// Una tantum: impostazioni e chiave ElevenLabs dal vecchio nome dell'app (MeetingRecorder).
    // ponytail: togliere quando non ci sono più installazioni di MeetingRecorder
    static func migrateFromMeetingRecorder() {
        let d = UserDefaults.standard, old = "com.gabriele.meetingrecorder"
        guard !d.bool(forKey: "migrated.meetingrecorder") else { return }
        d.set(true, forKey: "migrated.meetingrecorder")
        for (k, v) in d.persistentDomain(forName: old) ?? [:] where d.object(forKey: k) == nil { d.set(v, forKey: k) }
        if Keychain.elevenLabsKey == nil, let key = Keychain.read(service: old) { Keychain.setElevenLabsKey(key) }
        d.set(Keychain.elevenLabsKey != nil, forKey: "hasElevenLabsKey") // se macOS non ha dato il permesso, la chiede nelle Impostazioni
    }
}
