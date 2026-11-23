import XCTest
@testable import Overheard

/// Cose da fare → Promemoria: quali righe si mandano e quale scadenza si legge dal testo. Promemoria non viene toccato.
final class RemindersTests: XCTestCase {
    func testPendingSkipsDoneAndAlreadyAdded() {
        let summary = SummaryLine.parse("""
        ## Cose da fare
        - [ ] **Marco**: send the offer
        - [x] Anna: book the room
        - [ ] Vito: update the deck
        - a bullet, not a task
        """)
        XCTAssertEqual(MeetingReminders.pending(summary, added: []), ["Marco: send the offer", "Vito: update the deck"])
        XCTAssertEqual(MeetingReminders.pending(summary, added: ["Vito: update the deck"]), ["Marco: send the offer"])
    }

    func testDueDateFromText() {
        let now = DateComponents(calendar: .current, year: 2026, month: 3, day: 2).date!
        let due = MeetingReminders.dueDate(in: "Marco: send the offer by March 12, 2026", now: now)
        XCTAssertEqual(due?.month, 3)
        XCTAssertEqual(due?.day, 12)
        XCTAssertNil(MeetingReminders.dueDate(in: "Marco: send the offer", now: now))
        XCTAssertNil(MeetingReminders.dueDate(in: "Marco: send it by January 5, 2026", now: now), "a date already past is not a deadline")
    }
}
