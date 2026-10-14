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

    init() {
        Task.detached {
            let found = ["claude", "codex"].filter { AIChat.shell("command -v \($0)").status == 0 }
            await MainActor.run {
                self.tools = found
                if !found.contains(self.engine), let first = found.first { self.engine = first }
            }
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

        let dir = URL(fileURLWithPath: NSHomeDirectory() + "/Meetings")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("overheard-ai.txt")
        let args: [String] = engine == "codex"
            ? ["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "--color", "never", "--output-last-message", out.path, Self.instructions + "\n\n" + prompt]
            : ["claude", "-p", "--no-session-persistence", "--allowedTools", "Read,Grep,Glob", "--append-system-prompt", Self.instructions, prompt]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "exec \"$0\" \"$@\""] + args // shell di login: stesso PATH del Terminale
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
                    text = String(localized: "Errore: ") + (stderr.split(separator: "\n").suffix(3).joined(separator: "\n").isEmpty ? String(localized: "nessuna risposta") : stderr.split(separator: "\n").suffix(3).joined(separator: "\n"))
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

    func stop() { process?.terminate() }

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

    nonisolated static func shell(_ cmd: String) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
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
                        ForEach(chat.tools, id: \.self) { Text($0 == "claude" ? "Claude" : "Codex").tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 130)
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

            if chat.tools.isEmpty {
                Spacer()
                Text("Serve Claude Code o Codex installato e con il login fatto nel Terminale.")
                    .font(.callout).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth: .infinity)
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
        .onAppear { focused = true }
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
