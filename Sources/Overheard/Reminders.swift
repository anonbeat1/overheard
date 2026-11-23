// Cose da fare del riassunto → app Promemoria, in un elenco "Overheard" (creato la prima volta).
import EventKit
import Foundation

enum MeetingReminders {
    static let listName = "Overheard"

    /// Cose da fare già mandate a Promemoria da questa riunione, una per riga: non si creano doppioni
    static func added(_ dir: URL) -> Set<String> {
        Set(((try? String(contentsOf: dir.appendingPathComponent("reminders.txt"), encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { !$0.isEmpty })
    }

    /// Testi delle cose da fare non spuntate e non ancora mandate
    static func pending(_ summary: [SummaryLine], added: Set<String>) -> [String] {
        summary.compactMap { l in
            guard case .todo(done: false) = l.kind else { return nil }
            let text = l.text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            return text.isEmpty || added.contains(text) ? nil : text
        }
    }

    /// Prima data nel testo ("entro venerdì", "by 12 March"), se non è già passata
    static func dueDate(in text: String, now: Date = Date()) -> DateComponents? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date, date >= Calendar.current.startOfDay(for: now) else { return nil }
        return Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    /// Crea i promemoria e ritorna quanti ne ha aggiunti
    static func add(_ items: [String], meeting: Meeting) async throws -> Int {
        let store = MeetingCalendar.store
        guard (try? await store.requestFullAccessToReminders()) == true else {
            throw TranscriptionError.message(String(localized: "Accesso negato: Impostazioni di Sistema → Privacy e sicurezza → Promemoria → Overheard"))
        }
        let list = try list(in: store)
        let notes = "\(meeting.app) · \(meeting.date?.formatted(date: .long, time: .shortened) ?? meeting.id)"
        for text in items {
            let r = EKReminder(eventStore: store)
            r.calendar = list
            r.title = text
            r.notes = notes
            r.dueDateComponents = dueDate(in: text)
            try store.save(r, commit: false)
        }
        try store.commit()
        let url = meeting.url.appendingPathComponent("reminders.txt")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + items.map { $0 + "\n" }.joined()).write(to: url, atomically: true, encoding: .utf8)
        return items.count
    }

    private static func list(in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listName }) { return existing }
        guard let source = store.defaultCalendarForNewReminders()?.source else {
            throw TranscriptionError.message(String(localized: "Nessun account Promemoria su questo Mac"))
        }
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = listName
        list.source = source
        try store.saveCalendar(list, commit: true)
        return list
    }
}
