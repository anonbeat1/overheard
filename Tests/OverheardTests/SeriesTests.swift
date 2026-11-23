import XCTest
@testable import Overheard

/// Riunioni ricorrenti: chi fa parte della serie e quali cose da fare restano aperte. Cartelle temporanee, niente calendario.
final class SeriesTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func meeting(_ id: String, title: String?, series: String? = nil, attendees: Bool = true, summary: String? = nil) throws -> Meeting {
        let dir = root.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let series { try series.write(to: dir.appendingPathComponent("series"), atomically: true, encoding: .utf8) }
        if attendees { try "Anna\nMarco\n".write(to: dir.appendingPathComponent("attendees"), atomically: true, encoding: .utf8) }
        if let summary { try summary.write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8) }
        return Meeting(url: dir, source: "meet", title: title)
    }

    func testMembersByRecurringEventThenTitleAndAttendees() throws {
        let a = try meeting("2026-03-02_0930", title: "Standup", series: "evt1")
        let b = try meeting("2026-03-09_0930", title: "standup", series: "evt1")
        let otherEvent = try meeting("2026-03-10_0930", title: "Standup", series: "evt2")
        let old = try meeting("2026-02-23_0930", title: "Standup")                 // prima del file series: titolo + invitati
        let aiTitled = try meeting("2026-02-16_0930", title: "Standup", attendees: false)
        let other = try meeting("2026-03-03_1500", title: "Budget review")
        let all = [a, b, otherEvent, old, aiTitled, other]
        XCTAssertEqual(MeetingSeries.members(of: b, in: all).map(\.id), [b.id, a.id, old.id])
        XCTAssertEqual(MeetingSeries.members(of: other, in: all).map(\.id), [], "a single meeting is not a series")
        XCTAssertEqual(MeetingSeries.members(of: aiTitled, in: all).map(\.id), [])
    }

    func testOpenTasksAcrossSeries() throws {
        let a = try meeting("2026-03-02_0930", title: "Standup", summary: "## Cose da fare\n- [ ] Anna: send notes\n- [x] Marco: fix login\n")
        let b = try meeting("2026-03-09_0930", title: "Standup", summary: "## Cose da fare\n- [ ] Marco: deploy\n")
        let tasks = MeetingSeries.openTasks([b, a])
        XCTAssertEqual(tasks.map(\.text), ["Marco: deploy", "Anna: send notes"])
        XCTAssertEqual(tasks.map(\.meeting.id), [b.id, a.id])
    }
}
