import XCTest
@testable import Overheard

/// Parole chiave dal vivo: il conteggio sul testo riconosciuto (il riconoscimento vocale non viene avviato).
final class KeywordAlertsTests: XCTestCase {
    func testWholeWordsIgnoringCaseAndAccents() {
        let c = KeywordAlerts.counts(in: "Vito, la scadenza è venerdì. Scadenza confermata, scadenzario a parte. VENERDI ok",
                                     words: ["vito", "scadenza", "venerdì", "budget"])
        XCTAssertEqual(c["vito"], 1)
        XCTAssertEqual(c["scadenza"], 2, "scadenzario is a different word")
        XCTAssertEqual(c["venerdì"], 2, "accents and case do not matter")
        XCTAssertEqual(c["budget"], 0)
    }

    func testMultiWordAndSymbols() {
        let c = KeywordAlerts.counts(in: "We moved the go-live to Q3, the go live date is fixed", words: ["go-live", "Q3", "c++"])
        XCTAssertEqual(c["go-live"], 1)
        XCTAssertEqual(c["Q3"], 1)
        XCTAssertEqual(c["c++"], 0)
    }
}
