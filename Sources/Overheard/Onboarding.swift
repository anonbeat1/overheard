// Benvenuto al primo avvio: unveil dell'icona, cosa fa l'app, poche scelte per partire.
// Riapribile da Impostazioni ("Rivedi l'introduzione").
import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI

private let coral = Color(red: 1, green: 0.42, blue: 0.4)
private let tileTop = Color(red: 0.067, green: 0.051, blue: 0.063) // #110D10
private let tileBottom = Color(red: 0.145, green: 0.11, blue: 0.129) // #251C21

struct OnboardingView: View {
    var done: () -> Void
    @State private var page = 0
    @State private var forward = true
    @State private var nav = 0 // identità nuova a ogni passaggio: una pagina che rientra mentre esce non sparisce
    private let pages = 5

    var body: some View {
        ZStack {
            Color.black
            // bagliore corallo che si sposta dietro le pagine
            Circle().fill(coral.opacity(page == 0 ? 0.28 : 0.14)).frame(width: 520).blur(radius: 140)
                .offset(x: CGFloat(page - 2) * 70, y: page == 0 ? -40 : -170)
                .animation(.easeInOut(duration: 1.1), value: page)

            Group {
                switch page {
                case 0: Unveil { go(1) }
                case 1: Features()
                case 2: SetupVoice()
                case 3: SetupPrefs()
                default: Ready()
                }
            }
            .id(nav)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            .padding(.horizontal, 48)
            .padding(.top, 40)
            .padding(.bottom, 84)

            if page > 0 {
                VStack {
                    Spacer()
                    HStack {
                        Button("Indietro") { go(page - 1) }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        HStack(spacing: 7) {
                            ForEach(1..<pages, id: \.self) { i in
                                Capsule().fill(i == page ? coral : Color.white.opacity(0.2))
                                    .frame(width: i == page ? 18 : 7, height: 7)
                            }
                        }
                        .animation(.spring(duration: 0.4), value: page)
                        Spacer()
                        PrimaryButton(title: page == pages - 1 ? "Inizia a usarlo" : "Avanti") {
                            page == pages - 1 ? done() : go(page + 1)
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                }
                .transition(.opacity)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .frame(width: 680, height: 560)
    }

    private func go(_ p: Int) {
        forward = p > page
        withAnimation(.spring(duration: 0.55, bounce: 0.15)) { page = p; nav += 1 }
    }
}

// MARK: - Pagine

/// L'icona sale dal buio, un riflesso fa il giro del bordo, poi il nome e la frase.
private struct Unveil: View {
    var next: () -> Void
    @State private var tile = false
    @State private var glint: CGFloat = 0
    @State private var glintOn = false
    @State private var flash = false
    @State private var words = false
    @State private var button = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            ZStack {
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(LinearGradient(colors: [tileTop, tileBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                LogoView(size: 150, paused: !tile)
                // riflesso che corre lungo il bordo
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .trim(from: max(0, glint - 0.18), to: glint)
                    .stroke(LinearGradient(colors: [.clear, .white, coral], startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .opacity(glintOn ? 1 : 0)
                    .blur(radius: 0.6)
                RoundedRectangle(cornerRadius: 46, style: .continuous)
                    .fill(Color.white.opacity(flash ? 0.18 : 0))
            }
            .frame(width: 200, height: 200)
            .shadow(color: coral.opacity(tile ? 0.45 : 0), radius: 40, y: 8)
            .scaleEffect(tile ? 1 : 0.72)
            .opacity(tile ? 1 : 0)
            .blur(radius: tile ? 0 : 18)
            .rotation3DEffect(.degrees(tile ? 0 : 24), axis: (x: 1, y: 0, z: 0), perspective: 0.6)

            VStack(spacing: 10) {
                Text(verbatim: "Overheard").font(.system(size: 46, weight: .bold, design: .rounded))
                    .tracking(words ? 0 : 8)
                Text("Le tue riunioni, diventate testo — e interrogabili da Claude.")
                    .font(.title3).foregroundStyle(.white.opacity(0.65))
            }
            .opacity(words ? 1 : 0)
            .offset(y: words ? 0 : 14)

            PrimaryButton(title: "Scopri come funziona", action: next)
                .opacity(button ? 1 : 0)
                .scaleEffect(button ? 1 : 0.9)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.spring(duration: 1.3, bounce: 0.25)) { tile = true }
            try? await Task.sleep(for: .seconds(0.9))
            glintOn = true
            withAnimation(.easeInOut(duration: 1.4)) { glint = 1.18 }
            try? await Task.sleep(for: .seconds(1.3))
            withAnimation(.easeOut(duration: 0.15)) { flash = true; glintOn = false }
            withAnimation(.easeOut(duration: 0.6).delay(0.15)) { flash = false }
            withAnimation(.spring(duration: 0.9, bounce: 0.2)) { words = true }
            try? await Task.sleep(for: .seconds(0.7))
            withAnimation(.spring(duration: 0.6)) { button = true }
        }
    }
}

private struct Features: View {
    @State private var shown = 0
    @State private var ai: [String]?
    private let items: [(String, LocalizedStringKey, LocalizedStringKey, [Permission])] = [
        ("record.circle", "Registra", "Parte da solo quando Meet, Teams o Slack usano il microfono. Nessun bot entra nella call.",
         [.microphone, .systemAudio, .notifications]),
        ("text.quote", "Trascrive", "Ogni parola, con chi parla e quando. Nel cloud o tutto sul tuo Mac.", []),
        ("checklist", "Riassume", "Decisioni e cose da fare da spuntare, appena finisce la call. Titoli e invitati dal calendario.", [.calendar]),
        ("sparkles", "Rispondi con Claude", "Chiedi a Claude Code o Codex cosa si è deciso: legge le tue riunioni.", []),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Heading(title: "Cosa fa Overheard", subtitle: "Concedi i permessi di cui ha bisogno, uno alla volta.")
            VStack(spacing: 10) {
                ForEach(items.indices, id: \.self) { i in
                    let (icon, title, text, perms) = items[i]
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(coral)
                            .frame(width: 40, height: 40)
                            .background(coral.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .symbolEffect(.bounce, value: shown > i)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            Text(text).font(.callout).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                            if !perms.isEmpty {
                                HStack(spacing: 8) { ForEach(perms, id: \.self) { PermissionChip(permission: $0) } }
                            }
                            if i == 3 { aiStatus }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .opacity(shown > i ? 1 : 0)
                    .offset(x: shown > i ? 0 : 30)
                }
            }
        }
        .task {
            for i in 1...items.count {
                try? await Task.sleep(for: .seconds(0.14))
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) { shown = i }
            }
        }
        .task { ai = await Task.detached { AIChat.installed() }.value }
    }

    @ViewBuilder private var aiStatus: some View {
        if let ai {
            if ai.isEmpty {
                HStack(spacing: 8) {
                    Label("Non trovato", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Link("Installa Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                    Button("Ricontrolla") { Task { self.ai = nil; self.ai = await Task.detached { AIChat.installed() }.value } }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                }
                .font(.caption)
            } else {
                Label(ai.map { $0 == "claude" ? "Claude Code" : "Codex" }.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// Un permesso: "Consenti" → richiesta di macOS → spunta verde (o "Apri Impostazioni" se negato)
private struct PermissionChip: View {
    let permission: Permission
    @State private var state: Permission.State?

    var body: some View {
        Button {
            Task {
                if state == .denied { permission.openSettings() } else { await permission.request() }
                state = await permission.state()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state == .granted ? "checkmark.circle.fill" : permission.icon)
                Text(permission.title)
                if state == .denied { Text("· Apri Impostazioni").foregroundStyle(.white.opacity(0.6)) }
                else if state != .granted { Text("· Consenti").foregroundStyle(coral) }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(state == .granted ? .green : .white)
            .background(state == .granted ? Color.green.opacity(0.14) : Color.white.opacity(0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state == .granted)
        .animation(.spring(duration: 0.3), value: state)
        .task { state = await permission.state() }
        // rientrando dalle Impostazioni di Sistema
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { state = await permission.state() }
        }
    }
}

private struct SetupVoice: View {
    @ObservedObject var rec = Recorder.shared
    @ObservedObject var models = LocalModels.shared
    @AppStorage("myName") private var myName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Heading(title: "Due cose su di te", subtitle: "Puoi cambiarle quando vuoi nelle Impostazioni.")
            Card {
                Text("Come ti chiami?").font(.headline)
                TextField("Il tuo nome, es. Mario", text: $myName).textFieldStyle(.roundedBorder)
                Text("Così la tua voce nei transcript ha il tuo nome.").font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Card {
                Text("Come trascrivere").font(.headline)
                HStack(spacing: 10) {
                    EngineChoice(icon: "cloud", title: "ElevenLabs", text: "La più precisa. Serve una chiave API.", on: rec.engine == "elevenlabs") { rec.engine = "elevenlabs" }
                    EngineChoice(icon: "lock.laptopcomputer", title: "Sul Mac", text: "Privata, l'audio non esce. ~2,5 GB.", on: rec.engine == "local") {
                        rec.engine = "local"
                        if !models.ready, LocalModels.supported { models.download() }
                    }
                }
                if rec.engine == "elevenlabs" {
                    ElevenLabsKeyField()
                } else if !LocalModels.supported {
                    Text("Richiede macOS 15 o successivo").font(.caption).foregroundStyle(.orange)
                } else if let p = models.progress {
                    ProgressView(value: p) { Text("Download modelli · \(Int(p * 100))%").font(.caption) }
                } else if models.ready {
                    Text("Modelli pronti").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }
}

private struct SetupPrefs: View {
    @ObservedObject var rec = Recorder.shared
    @AppStorage("calendar.enabled") private var calendarOn = false
    @AppStorage("summary.auto") private var summaryAuto = true
    @AppStorage("dock.visible") private var dockVisible = false
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var mcp: [String] = []
    @State private var mcpBusy = false
    @State private var hasAI = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Heading(title: "Come vuoi usarlo?", subtitle: "Scegli cosa fa da solo.")
            Card {
                toggle("record.circle", "Registra automaticamente", "Quando Meet, Teams o Slack usano il microfono", $rec.autoDetect)
                toggle("calendar", "Titoli dal calendario", "Il meeting prende titolo e invitati dall'evento", $calendarOn.onSet { on in
                    guard on, !MeetingCalendar.authorized else { return }
                    Task { @MainActor in calendarOn = await MeetingCalendar.requestAccess() }
                })
                toggle("checklist", "Riassunto automatico", "Con Claude Code o Codex dopo ogni trascrizione", $summaryAuto)
                toggle("power", "Apri al login", "Così non perdi nessuna call", $atLogin.onSet { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    atLogin = SMAppService.mainApp.status == .enabled
                })
                toggle("dock.rectangle", "Mostra nel Dock", "Oltre all'icona nella barra dei menu", $dockVisible.onSet { _ in AppDelegate.applyDock() })
            }
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(coral).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Collega a Claude")
                        Text(hasAI ? "Claude Code, Claude Desktop e Codex potranno leggere le tue riunioni"
                                   : "Installa Claude Code o Codex, poi collegali dalle Impostazioni")
                            .font(.caption).foregroundStyle(.white.opacity(0.5))
                        if !mcp.isEmpty { Text(mcp.joined(separator: "  ")).font(.caption).foregroundStyle(.green) }
                    }
                    Spacer()
                    Button(mcpBusy ? "Collego…" : "Collega") {
                        mcpBusy = true
                        Task.detached {
                            let r = MCPServer.install()
                            await MainActor.run { mcp = r; mcpBusy = false }
                        }
                    }
                    .disabled(mcpBusy || !hasAI)
                }
            }
        }
        .task {
            hasAI = await Task.detached { !AIChat.installed().isEmpty }.value
        }
    }

    private func toggle(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(coral).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text).font(.caption).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(coral)
        }
    }
}

private struct Ready: View {
    @State private var on = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(coral, in: Circle())
                .shadow(color: coral.opacity(0.5), radius: 16)
                .scaleEffect(on ? 1 : 0.5).opacity(on ? 1 : 0)
            Text("Tutto pronto").font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Overheard vive nella barra dei menu, in alto a destra. Cliccala per registrare, vedere le ultime riunioni o chiedere all'AI.")
                .font(.title3).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center).frame(maxWidth: 480)
            HStack(spacing: 8) {
                Text("Durante una call, segna un momento con").foregroundStyle(.white.opacity(0.6))
                Text("⌃⌥M").font(.callout.monospaced()).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.callout)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .task { withAnimation(.spring(duration: 0.7, bounce: 0.4)) { on = true } }
    }
}

// MARK: - Pezzi

private struct Heading: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle).foregroundStyle(.white.opacity(0.55))
        }
    }
}

private struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).padding(.horizontal, 22).padding(.vertical, 10)
                .background(LinearGradient(colors: [Color(red: 1, green: 0.6, blue: 0.36), Color(red: 1, green: 0.31, blue: 0.43)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                .foregroundStyle(.white)
                .shadow(color: coral.opacity(hover ? 0.6 : 0.3), radius: hover ? 16 : 8)
                .scaleEffect(hover ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hover = h } }
    }
}

private struct EngineChoice: View {
    let icon: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let on: Bool
    let pick: () -> Void
    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon).foregroundStyle(coral)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? coral : .white.opacity(0.3))
                }
                Text(text).font(.caption).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? coral.opacity(0.12) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(on ? coral.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.3), value: on)
    }
}

// MARK: - Finestra

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    /// Al primo avvio; `force` per rivederla dalle Impostazioni
    static func showIfNeeded(force: Bool = false) {
        guard force || !UserDefaults.standard.bool(forKey: "onboarding.done") else { return }
        UserDefaults.standard.set(true, forKey: "onboarding.done") // anche se la chiude a metà: non ricompare da sola
        let w = window ?? {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.title = "Overheard"
            window = w
            return w
        }()
        w.contentView = NSHostingView(rootView: OnboardingView {
            w.close()
            PanelController.shared.show() // mostra dove vive l'app
        })
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
