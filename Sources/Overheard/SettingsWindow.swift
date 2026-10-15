// Finestra Impostazioni (icona ingranaggio nel pannello), stesso stile nero del pannello.
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var rec = Recorder.shared
    @ObservedObject var models = LocalModels.shared
    @AppStorage("label.meet") private var labelMeet = ""
    @AppStorage("label.teams") private var labelTeams = ""
    @AppStorage("label.slack") private var labelSlack = ""
    @AppStorage("label.altro") private var labelAltro = ""
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("myName") private var myName = ""
    @AppStorage("micDevice") private var micDevice = ""
    @AppStorage("keyterms") private var keyterms = ""
    @AppStorage("retentionDays") private var retentionDays = 0
    @AppStorage("retentionMode") private var retentionMode = "audio"
    @AppStorage("echoReduction") private var echoReduction = true
    @AppStorage("language") private var language = ""
    @AppStorage("calendar.enabled") private var calendarOn = false
    @AppStorage("summary.auto") private var summaryAuto = true
    @AppStorage("speakers.autoName") private var autoNames = true
    @AppStorage("dock.visible") private var dockVisible = false
    @AppStorage("autoStop.seconds") private var autoStop = 30
    @State private var calendarDenied = false
    @AppStorage("mcp.write") private var mcpWrite = false
    @State private var mcpResult: [String] = []
    @State private var mcpBusy = false
    @State private var mcpConnected = MCPServer.connected()
    @AppStorage("notes.folder") private var notesFolder = ""
    @AppStorage("notes.auto") private var notesAuto = true
    @State private var apiKey = ""
    @State private var hasKey = Keychain.hasElevenLabsKey

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 22)
                .padding(.top, 38) // spazio per i pulsanti della finestra (barra del titolo trasparente)
                .padding(.bottom, 22)
        }
        .frame(minWidth: 440, idealWidth: 460, minHeight: 360, idealHeight: 640)
        .foregroundStyle(.white)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Impostazioni").font(.system(size: 20, weight: .bold))
                Spacer()
                // spostati qui dal pannello (anche nel clic destro sull'icona nella barra)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "\(home)/Meetings")) } label: { Label("Cartella", systemImage: "folder") }
                Button(role: .destructive) { NSApp.terminate(nil) } label: { Label("Esci", systemImage: "power") }
            }

            Card {
                row("Registra automaticamente", "Parte quando Meet o Teams usano il microfono", $rec.autoDetect)
                Divider().overlay(Color.white.opacity(0.1))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ferma dopo la fine della call")
                        Text("Attesa dopo che la call lascia il microfono").font(.caption).foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Picker("", selection: $autoStop) {
                        ForEach([10, 20, 30, 60, 120, 300], id: \.self) { s in
                            Text(s < 60 ? "\(s) s" : "\(s / 60) min").tag(s)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                Divider().overlay(Color.white.opacity(0.1))
                row("Apri al login", nil, $atLogin)
                    .onChange(of: atLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        atLogin = SMAppService.mainApp.status == .enabled
                    }
                Divider().overlay(Color.white.opacity(0.1))
                HStack {
                    Button("Rivedi l'introduzione") { Onboarding.showIfNeeded(force: true) }
                    Spacer()
                    Text(verbatim: "v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                        .font(.caption).foregroundStyle(.white.opacity(0.4))
                    Button("Controlla aggiornamenti…") { Updates.check() }
                }
            }

            Card {
                HStack {
                    Text("Elimina i meeting più vecchi di")
                    Spacer()
                    Picker("", selection: $retentionDays) {
                        Text("Mai").tag(0)
                        Text("7 giorni").tag(7)
                        Text("30 giorni").tag(30)
                        Text("90 giorni").tag(90)
                        Text("6 mesi").tag(180)
                        Text("1 anno").tag(365)
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: retentionDays) { _, _ in rec.cleanOld() }
                }
                if retentionDays > 0 {
                    Picker("", selection: $retentionMode) {
                        Text("Solo l'audio").tag("audio")
                        Text("Tutto").tag("all")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: retentionMode) { _, _ in rec.cleanOld() }
                    Text(retentionMode == "audio"
                         ? "Elimina le registrazioni audio (~700 MB/ora) e conserva transcript e riassunti."
                         : "Elimina l'intera cartella del meeting: audio, transcript e riassunto.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                    Text("I file vanno nel Cestino: si possono recuperare finché non lo svuoti. Controllo all'avvio e ogni ora.")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }

            Card {
                Text("Etichette")
                labelRow("Google Meet", $labelMeet, "es. Cliente A")
                labelRow("Microsoft Teams", $labelTeams, "es. Azienda B")
                labelRow("Slack", $labelSlack, "es. Team interno")
                labelRow("Altro", $labelAltro, "es. Riunioni in presenza")
                Text("Compaiono accanto al nome dell'app nel pannello, nelle notifiche e nella lista dei meeting. Lascia vuoto per non usarle.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Card {
                row("Titoli dal calendario", "Il meeting prende titolo e invitati dall'evento in corso", $calendarOn.onSet { on in
                    guard on, !MeetingCalendar.authorized else { return }
                    Task { @MainActor in
                        let ok = await MeetingCalendar.requestAccess()
                        calendarOn = ok
                        calendarDenied = !ok
                    }
                })
                if calendarDenied {
                    Text("Accesso negato: Impostazioni di Sistema → Privacy e sicurezza → Calendari → Overheard")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Divider().overlay(Color.white.opacity(0.1))
                row("Riassunto automatico", "Riassunto, decisioni e cose da fare con Claude Code o Codex dopo ogni trascrizione", $summaryAuto)
                Divider().overlay(Color.white.opacity(0.1))
                row("Nomi dei parlanti automatici", "Con il riassunto, l'AI sostituisce \"Parlante N\" col nome quando nel discorso è chiaro (si presenta o viene chiamato per nome)", $autoNames)
                    .disabled(!summaryAuto)
                Divider().overlay(Color.white.opacity(0.1))
                row("Mostra nel Dock", "Icona nel Dock e barra dei menu, oltre all'icona in alto", $dockVisible.onSet { _ in
                    MainActor.assumeIsolated { AppDelegate.applyDock() }
                })
                Divider().overlay(Color.white.opacity(0.1))
                HStack {
                    Text("Segna un momento importante").foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("⌃⌥M").font(.callout.monospaced()).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Card {
                Text("Claude e altre AI (MCP)")
                Text("Rende i tuoi meeting disponibili in Claude Desktop, Claude Code e Codex: \"prepara la mail di follow-up del meeting di ieri\". Tutto in locale, niente esce dal Mac se non quello che chiedi all'AI.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(mcpBusy ? "Collego…" : mcpConnected.isEmpty ? "Collega a Claude" : "Ricollega") {
                        mcpBusy = true
                        Task.detached {
                            let r = MCPServer.install()
                            await MainActor.run { mcpResult = r; mcpBusy = false; mcpConnected = MCPServer.connected() }
                        }
                    }
                    .disabled(mcpBusy)
                    Spacer()
                    if !mcpResult.isEmpty {
                        Text(mcpResult.joined(separator: "  ")).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    } else if !mcpConnected.isEmpty {
                        Label(String(localized: "Collegato: ") + mcpConnected.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green).lineLimit(2)
                    }
                }
                row("Permetti azioni", "Spuntare cose da fare, avviare/fermare la registrazione, segnare momenti", $mcpWrite)
            }

            Card {
                Text("Note (Obsidian, Logseq, Notion…)")
                HStack {
                    Image(systemName: "folder").foregroundStyle(.white.opacity(0.5))
                    Text(notesFolder.isEmpty ? String(localized: "Nessuna cartella") : (notesFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.white.opacity(notesFolder.isEmpty ? 0.5 : 0.85))
                    Spacer()
                    if !notesFolder.isEmpty { Button("Rimuovi") { notesFolder = "" } }
                    Button("Scegli…") { if let f = SettingsView.chooseNotesFolder() { notesFolder = f.path } }
                }
                if !notesFolder.isEmpty { row("Esporta automaticamente", "Dopo ogni trascrizione e modifica", $notesAuto) }
                Text("Ogni meeting diventa una nota markdown con data, partecipanti e transcript. Per Notion: Importa → Markdown.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }

            Card {
                Text("La tua voce")
                TextField("Il tuo nome, es. Mario", text: $myName)
                    .textFieldStyle(.roundedBorder)
                Text("Etichetta della tua voce (microfono) nei transcript").font(.caption).foregroundStyle(.white.opacity(0.5))
                Picker("Microfono", selection: $micDevice) {
                    Text("Integrato del Mac (consigliato)").tag("")
                    ForEach(MicCapture.deviceNames(), id: \.self) { Text($0).tag($0) }
                }
                Text("Le cuffie Bluetooth come microfono abbassano la qualità dell'audio durante le call.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
            }

            Card {
                Text("Trascrizione")
                Picker("", selection: $rec.engine.onSet { if $0 == "local", !models.ready, LocalModels.supported { models.download() } }) {
                    Text("ElevenLabs").tag("elevenlabs")
                    Text("Sul Mac (Cohere)").tag("local")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Picker("Lingua delle riunioni", selection: $language) {
                    Text("Automatica").tag("")
                    ForEach([("it", "Italiano"), ("en", "English"), ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("pt", "Português")], id: \.0) {
                        Text(verbatim: $0.1).tag($0.0)
                    }
                }
                row("Riduci l'eco", "Se usi le casse invece delle cuffie: toglie dal microfono la voce degli altri", $echoReduction)
                Text(rec.engine == "elevenlabs"
                     ? "Più precisa, riconosce bene nomi e dialetto. L'audio viene inviato a ElevenLabs (cloud); se non risponde si usa Cohere sul Mac."
                     : "Privata: l'audio non esce dal Mac. Meno precisa su nomi propri e parlato veloce.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if rec.engine == "local" {
                    Divider().overlay(Color.white.opacity(0.1))
                    if !LocalModels.supported {
                        Label("Richiede macOS 15 o successivo", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if let p = models.progress {
                        ProgressView(value: p) { Text("Download modelli · \(models.phase)").font(.caption) }
                            currentValueLabel: { Text("\(Int(p * 100))% di ~2,5 GB").font(.caption).foregroundStyle(.white.opacity(0.5)) }
                    } else if models.ready {
                        Label("Modelli scaricati, pronta all'uso", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        HStack {
                            Text("Servono i modelli di trascrizione (~2,5 GB, una volta sola)").font(.caption).foregroundStyle(.white.opacity(0.6))
                            Spacer()
                            Button("Scarica") { models.download() }
                        }
                        if let e = models.error { Text("Errore: \(e)").font(.caption).foregroundStyle(.red) }
                    }
                }

                if rec.engine == "elevenlabs" {
                    Divider().overlay(Color.white.opacity(0.1))
                    Text("Chiave API ElevenLabs")
                    HStack {
                        SecureField(hasKey ? "•••••••• (salvata nel Portachiavi)" : "sk_…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button("Salva") {
                            Keychain.setElevenLabsKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                            hasKey = Keychain.hasElevenLabsKey
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasKey {
                            Button("Rimuovi") { Keychain.setElevenLabsKey(nil); hasKey = false }
                        }
                    }
                    HStack(spacing: 4) {
                        Image(systemName: hasKey ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(hasKey ? .green : .orange)
                        Text(hasKey ? "Chiave configurata" : "Crea una chiave su elevenlabs.io → API Keys (permesso Speech to Text)")
                    }
                    .font(.caption).foregroundStyle(.white.opacity(0.6))

                    Divider().overlay(Color.white.opacity(0.1))
                    Text("Parole chiave")
                    TextEditor(text: $keyterms)
                        .font(.callout)
                        .frame(height: 110)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    Text("Nomi di persone, aziende e progetti da scrivere correttamente, uno per riga (+20% di costo)")
                        .font(.caption).foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    /// Cartella delle note (es. un vault Obsidian); usata anche dal pulsante Esporta del transcript
    @MainActor static func chooseNotesFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Usa questa cartella")
        panel.message = String(localized: "Dove salvare le note dei meeting (es. il tuo vault Obsidian)")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "notes.folder")
        return url
    }

    func labelRow(_ app: LocalizedStringKey, _ text: Binding<String>, _ placeholder: LocalizedStringKey) -> some View {
        HStack {
            Text(app).frame(width: 120, alignment: .leading).foregroundStyle(.white.opacity(0.7))
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }

    func row(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey?, _ isOn: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.5)) }
            }
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.title = "Impostazioni"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}

extension Binding {
    /// Esegue `action` dopo ogni scrittura (es. avviare il download quando si sceglie "Sul Mac")
    func onSet(_ action: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0; action($0) })
    }
}
