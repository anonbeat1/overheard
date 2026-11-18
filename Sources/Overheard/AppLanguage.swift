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

    static func save(_ language: String, defaults: UserDefaults = .standard) {
        guard language.isEmpty || choices.contains(where: { $0.0 == language }) else { return }
        if language.isEmpty {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language], forKey: "AppleLanguages")
        }
    }
}
