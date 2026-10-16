// Chat sui meeting con l'AI già installata (Claude Code o Codex, col login dell'utente: niente chiavi in più).
// Gira nella cartella ~/Meetings in sola lettura e cerca da sola nei transcript: un meeting o tutti.
import AppKit
import SwiftUI

@MainActor
final class AIChat: ObservableObject {
    struct Message: Identifiable {
        let id = UUID()
        let mine: Bool
        let text: String
    }

    @Published var messages: [Message] = []
    @Published var busy = false
    @Published var started: Date?
    @Published var tools: [String] = [] // "claude", "codex": quelli trovati nel PATH della shell di login
    @AppStorage("ai.engine") var engine = "claude"
    private var process: Process?
    private var appleTask: Task<Void, Never>?

    @Published var checking = true

    init() { detect() }

    func detect() {
        checking = true
        Task.detached {
            let found = AIChat.installed()
            await MainActor.run {
                self.tools = found
                self.checking = false
                if !found.contains(self.engine), let first = found.first { self.engine = first }
            }
        }
    }

    /// CLI che rispondono davvero (`--version`), non solo presenti nel PATH: un link rotto o un'installazione
    /// a metà farebbe accettare domande che poi non ricevono risposta
    nonisolated static func installed() -> [String] {
        ["claude", "codex"].filter { shell("\($0) --version").status == 0 } + (AppleAI.available ? ["apple"] : [])
    }

    nonisolated static func name(_ engine: String) -> String {
        switch engine {
        case "codex": "Codex"
        case "apple": "Apple Intelligence"
        default: "Claude"
        }
    }

    private static let instructions = """
    You are the Overheard assistant. The current folder holds the recorded meetings: each subfolder \
    yyyy-MM-dd_HHmmss has transcript.md (lines "**[mm:ss] Speaker:** text"), an optional summary.md and a source file \
    (meet/teams/slack/altro/import). Search the transcripts by reading the files (grep/glob/read); never modify anything. \
    Answer concisely in the language of the question, citing the meeting date and time and the minute [mm:ss] when possible.
    """

    /// `meeting` = cartella su cui restringere la domanda; nil = tutti i meeting
    func ask(_ question: String, meeting: Meeting?) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        // domande di seguito: si passa la conversazione recente (le sessioni non vengono salvate)
        let history = messages.suffix(6).map { ($0.mine ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        messages.append(Message(mine: true, text: q))
        var prompt = ""
        if let m = meeting { prompt += "Answer only about the meeting in folder \(m.id) (\(m.app), \(m.when)).\n\n" }
        if !history.isEmpty { prompt += "Conversation so far:\n\(history)\n\nNew question: " }
        prompt += q
        if engine == "apple" { return askApple(q, prompt: prompt, meeting: meeting) }

        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Meetings")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("overheard-ai.txt")
        let args: [String] = engine == "codex"
            ? ["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "--color", "never", "--output-last-message", out.path, Self.instructions + "\n\n" + prompt]
            : ["claude", "-p", "--no-session-persistence", "--allowedTools", "Read,Grep,Glob", "--append-system-prompt", Self.instructions, prompt]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$0\" \"$@\""] + args // shell di login: stesso PATH del Terminale
        p.environment = Self.environment
        p.currentDirectoryURL = dir
        let pipe = Pipe(), err = Pipe()
        p.standardOutput = pipe
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let codex = engine == "codex"
        p.terminationHandler = { proc in
            let stdout = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let last = codex ? (try? String(contentsOf: out, encoding: .utf8)) : nil
            Task { @MainActor in
                var text = (last ?? stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationReason == .uncaughtSignal { text = String(localized: "Interrotto.") }
                else if proc.terminationStatus != 0 || text.isEmpty {
                    let detail = (stderr + "\n" + stdout).split(separator: "\n").suffix(3).joined(separator: "\n")
                    text = String(localized: "Errore: ") + (detail.isEmpty ? String(localized: "nessuna risposta") : detail)
                    if proc.terminationStatus == 127 { text = String(localized: "Claude Code o Codex non trovato: installalo e fai il login nel Terminale.") }
                }
                self.messages.append(Message(mine: false, text: text))
                self.busy = false
                self.process = nil
            }
        }
        do {
            try p.run()
            process = p
            busy = true
            started = Date()
        } catch {
            messages.append(Message(mine: false, text: String(localized: "Errore: \(error.localizedDescription)")))
        }
    }

    /// Apple Intelligence non legge i file da sola: le si passano riassunti e righe pertinenti
    private func askApple(_ question: String, prompt: String, meeting: Meeting?) {
        busy = true
        started = Date()
        let meetings = meeting.map { [$0] } ?? Meeting.recent(60)
        appleTask = Task {
            let context = AppleAI.context(for: question, meetings: meetings, limit: AppleAI.budget - prompt.count)
            var text: String
            do {
                text = try await AppleAI.complete(prompt, instructions: """
                You answer questions about the user's recorded meetings, using only the meeting notes below. \
                Answer concisely in the language of the question, citing the meeting and the minute [mm:ss] when possible. \
                If the notes do not contain the answer, say so.

                \(context)
                """)
            } catch is CancellationError {
                text = String(localized: "Interrotto.")
            } catch {
                text = String(localized: "Errore: ") + error.localizedDescription
            }
            if Task.isCancelled { text = String(localized: "Interrotto.") }
            messages.append(Message(mine: false, text: text))
            busy = false
            appleTask = nil
        }
    }

    func stop() {
        process?.terminate()
        appleTask?.cancel()
    }

    func clear() {
        stop()
        messages = []
    }

    /// Domanda secca all'AI (senza strumenti), es. il riassunto: ritorna il testo della risposta
    nonisolated static func complete(_ prompt: String, engine: String) -> String? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mr-ai-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = engine == "codex"
            ? ["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "--color", "never", "--output-last-message", out.path, prompt]
            : ["claude", "-p", "--no-session-persistence", prompt]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$0\" \"$@\""] + args
        p.environment = environment
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = engine == "codex" ? (try? String(contentsOf: out, encoding: .utf8)) : String(data: data, encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// La shell di login legge ~/.zprofile ma non ~/.zshrc, dove spesso finisce il PATH di Claude Code o Codex
    /// (nvm, npm globale, installer nativo): unisce il PATH della shell interattiva e le cartelle d'installazione comuni.
    nonisolated static let environment: [String: String] = {
        let home = NSHomeDirectory(), fm = FileManager.default
        var dirs = interactivePath().split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin",
                 "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.cargo/bin", "\(home)/.deno/bin"]
        for base in ["\(home)/.nvm/versions/node", "\(home)/Library/Application Support/fnm/node-versions"] {
            for v in ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted().reversed() {
                dirs += ["\(base)/\(v)/bin", "\(base)/\(v)/installation/bin"]
            }
        }
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = dirs.filter { fm.fileExists(atPath: $0) && seen.insert($0).inserted }.joined(separator: ":")
        return env
    }()

    /// PATH di `zsh -i` (legge ~/.zshrc); al massimo 4s, perché certe configurazioni restano in attesa
    nonisolated private static func interactivePath() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf '\\n__PATH__%s\\n' \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) { if p.isRunning { p.terminate() } }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out.components(separatedBy: "\n").first { $0.hasPrefix("__PATH__") }.map { String($0.dropFirst(8)) } ?? ""
    }

    nonisolated static func shell(_ cmd: String) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

struct AIChatView: View {
    @ObservedObject var chat: AIChat
    let meeting: Meeting?
    @State private var input = ""
    @State private var allMeetings = true
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.orange)
                Text("Chiedi").font(.system(size: 18, weight: .bold))
                Spacer()
                if chat.tools.count > 1 {
                    Picker("", selection: $chat.engine) {
                        ForEach(chat.tools, id: \.self) { Text($0 == "apple" ? "Apple" : AIChat.name($0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: chat.tools.count > 2 ? 190 : 130)
                }
                if !chat.messages.isEmpty {
                    Button { chat.clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).help("Nuova conversazione")
                }
            }
            Picker("", selection: $allMeetings) {
                Text("Tutti i meeting").tag(true)
                Text("Questo meeting").tag(false)
            }
            .labelsHidden().pickerStyle(.segmented)
            .disabled(meeting == nil)

            if chat.checking && chat.tools.isEmpty {
                Spacer()
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer()
            } else if chat.tools.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(.orange)
                    Text("Per chiedere ai tuoi meeting serve Claude Code, Codex o Apple Intelligence").font(.headline).multilineTextAlignment(.center)
                    Text("Installa Claude Code o Codex e fai il login una volta nel Terminale, oppure attiva Apple Intelligence (macOS 26) in Impostazioni di Sistema. Lo usano anche i riassunti automatici.")
                        .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                    HStack {
                        Link("Installa Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                        Text(verbatim: "·").foregroundStyle(.white.opacity(0.4))
                        Link("Codex", destination: URL(string: "https://github.com/openai/codex")!)
                    }
                    .font(.callout)
                    Button("Ricontrolla") { chat.detect() }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if chat.messages.isEmpty {
                                Text("Esempi:\n• Cosa abbiamo deciso questa settimana?\n• In quali meeting si è parlato di budget?\n• Che cosa mi è stato chiesto di fare?")
                                    .font(.callout).foregroundStyle(.white.opacity(0.45))
                            }
                            ForEach(chat.messages) { m in bubble(m) }
                            if chat.busy {
                                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Cerco nei meeting… \(Int(ctx.date.timeIntervalSince(chat.started ?? ctx.date)))s")
                                            .font(.callout).foregroundStyle(.white.opacity(0.6))
                                        Spacer()
                                        Button("Stop") { chat.stop() }.buttonStyle(.plain).font(.callout).foregroundStyle(.orange)
                                    }
                                }
                                .id("busy")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) } }
                }

                HStack(spacing: 8) {
                    TextField(allMeetings || meeting == nil ? "Chiedi su tutti i meeting…" : "Chiedi su questo meeting…", text: $input, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...5).focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(input.isEmpty || chat.busy ? Color.white.opacity(0.15) : .orange, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(input.isEmpty || chat.busy)
                }
                .padding(10)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 38)
        .padding(.bottom, 16)
        .frame(width: 340)
        .background(Color.white.opacity(0.04))
        .onAppear { focused = true; chat.detect() }
    }

    private func send() {
        chat.ask(input, meeting: allMeetings ? nil : meeting)
        input = ""
    }

    private func bubble(_ m: AIChat.Message) -> some View {
        HStack {
            if m.mine { Spacer(minLength: 40) }
            Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                .font(.callout).lineSpacing(2).textSelection(.enabled)
                .padding(10)
                .background(m.mine ? Color.orange.opacity(0.25) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !m.mine { Spacer(minLength: 0) }
        }
    }
}
