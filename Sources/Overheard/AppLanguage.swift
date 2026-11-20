import AppKit
import Foundation

enum AppLanguage {
    static let choices = [
        ("en", "English"), ("it", "Italiano"), ("es", "Español"),
        ("fr", "Français"), ("de", "Deutsch"), ("pt", "Português (Brasil)"),
        ("zh-Hans", "简体中文"), ("hi", "हिन्दी"), ("ar", "العربية"),
        ("ja", "日本語"), ("ru", "Русский"), ("bn", "বাংলা"),
    ]

    // Read only this app's override, rather than the inherited system languages.
    static var selected: String {
        guard let identifier = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: identifier)?["AppleLanguages"] as? [String],
              let first = languages.first else { return "" }
        return choices.contains { $0.0 == first } ? first : ""
    }

    /// The language this run started with (first read happens before any change made in Settings).
    static let launched = selected

    static func save(_ language: String, defaults: UserDefaults = .standard) {
        guard language.isEmpty || choices.contains(where: { $0.0 == language }) else { return }
        if language.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
    }
}

/// Restarts the app (the language is read at launch). Quitting goes through applicationShouldTerminate, which closes
/// a recording cleanly; a transcription restarts at the next launch. So when work is in progress the person chooses.
@MainActor
enum AppRestart {
    static var busy: Bool {
        Recorder.shared.recording || ((try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Meetings")) ?? [])
            .contains { FileManager.default.fileExists(atPath: "\(home)/Meetings/\($0)/.transcribing") }
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the same bundle again.
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done; /usr/bin/open \"$2\"", "sh", String(getpid()), Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private static var waiter: Task<Void, Never>?
    static var waiting: Bool { waiter != nil }

    static func cancelWaiting() { waiter?.cancel(); waiter = nil }

    private static func relaunchWhenIdle() {
        waiter?.cancel()
        waiter = Task { @MainActor in
            while busy {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
            }
            relaunch()
        }
    }

    /// Restarts now, or asks first when a recording or transcription is in progress.
    static func requestRelaunch(onWaiting: @escaping () -> Void) {
        guard busy else { return relaunch() }
        let alert = NSAlert()
        alert.messageText = String(localized: "Riavviare Overheard per cambiare lingua?")
        alert.informativeText = String(localized: "Sta registrando o trascrivendo. Riavviando ora la registrazione si chiude e la trascrizione riprende al prossimo avvio.")
        alert.addButton(withTitle: String(localized: "Riavvia a fine lavoro"))
        alert.addButton(withTitle: String(localized: "Riavvia ora"))
        alert.addButton(withTitle: String(localized: "Annulla"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: relaunchWhenIdle(); onWaiting()
        case .alertSecondButtonReturn: relaunch()
        default: break
        }
    }
}
