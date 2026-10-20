import XCTest
@testable import MeetCaptureCore

final class AliasesTests: XCTestCase {
    private func apply(_ aliases: [String: [String]], _ text: String) -> String {
        Aliases.apply(aliases, to: [Segment(start: 0, end: 1, text: text, speaker: "Gio")])[0].text
    }

    func testVariantsBecomeTheCanonicalSpellingAsWholeWords() {
        let aliases = ["AppSheet": ["app sheet", "apshit"], "CEDEAR": ["sedear"], "MEP": []]
        XCTAssertEqual(apply(aliases, "Lo armé en App  Sheet y en apshit."), "Lo armé en AppSheet y en AppSheet.")
        XCTAssertEqual(apply(aliases, "Compré sedears y un sedear, dólar mep."), "Compré sedears y un CEDEAR, dólar MEP.",
                       "only whole words; the canonical form also fixes case")
        XCTAssertEqual(apply([:], "sin cambios"), "sin cambios")
    }

    func testLongerVariantsWinAndSpeakersAndTimesAreKept() {
        let aliases = ["Cactus Wealth": ["cactus welt"], "Cactus": ["kaktus"]]
        let out = Aliases.apply(aliases, to: [Segment(start: 2, end: 3, text: "cactus welt y kaktus", speaker: "Participante 1")])
        XCTAssertEqual(out, [Segment(start: 2, end: 3, text: "Cactus Wealth y Cactus", speaker: "Participante 1")])
    }

    func testTemplateCharactersInTheCanonicalFormAreLiteral() {
        XCTAssertEqual(apply(["$1 \\ x": ["uno"]], "uno"), "$1 \\ x")
    }
}
