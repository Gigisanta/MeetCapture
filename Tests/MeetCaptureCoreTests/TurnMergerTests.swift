import XCTest
@testable import MeetCaptureCore

final class TurnMergerTests: XCTestCase {
    private func w(_ start: Double, _ text: String, _ speaker: String? = nil) -> Segment {
        Segment(start: start, end: start + 0.3, text: text, speaker: speaker)
    }

    func testRemoteWordsTakeTheSpeakerOfTheMostOverlappingSpanNumberedByAppearance() {
        let spans = [SpeakerSpan(start: 0, end: 2, speaker: "S7"),
                     SpeakerSpan(start: 2, end: 4, speaker: "S2"),
                     SpeakerSpan(start: 6, end: 8, speaker: "S7")]
        let labeled = TurnMerger.labelRemote([w(0.5, "a"), w(1.9, "b"), w(3, "c"), w(4.2, "d"), w(7, "e")],
                                             spans: spans)
        XCTAssertEqual(labeled.map(\.speaker), ["Participante 1", "Participante 2", "Participante 2",
                                                "Participante 2", "Participante 1"],
                       "1.9–2.2 overlaps S2 most; 4.2 is nearest to S2's end")
        XCTAssertEqual(TurnMerger.labelRemote([w(0, "a")], spans: nil).map(\.speaker), ["Participante"])
        XCTAssertEqual(TurnMerger.labelRemote([w(0, "a")], spans: []).map(\.speaker), ["Participante"])
    }

    func testTurnsSplitOnSpeakerChangeAndLongGaps() {
        let turns = TurnMerger.merge([
            w(0, "Hola", "Participante 1"), w(0.4, "Gio", "Participante 1"),
            w(1, "Buenas", "Gio"),
            w(1.5, "¿cómo", "Participante 1"), w(4, "seguimos?", "Participante 1"),
        ])
        XCTAssertEqual(turns.map(\.text), ["Hola Gio", "Buenas", "¿cómo", "seguimos?"])
        XCTAssertEqual(turns.map(\.speaker), ["Participante 1", "Gio", "Participante 1", "Participante 1"])
        XCTAssertEqual(turns[0].end, 0.7, accuracy: 1e-9)
    }

    func testMicEchoOfARemoteWordIsDroppedButRealRepliesStay() {
        let turns = TurnMerger.merge([
            w(0, "Dale.", "Participante"), w(0.2, "dale", "Gio"), w(3, "Dale", "Gio"),
        ])
        XCTAssertEqual(turns.map(\.text), ["Dale.", "Dale"])
        XCTAssertEqual(turns.map(\.speaker), ["Participante", "Gio"])
    }

    func testWithoutLexicalDedupeBothSpeakersKeepTheirNegationsAndRepetitions() {
        let turns = TurnMerger.merge([
            w(0, "No.", "Participante"),
            w(0.1, "No,", "Gio"), w(0.4, "no.", "Gio"),
        ], deduplicateMic: false)
        XCTAssertEqual(turns.map(\.text), ["No.", "No, no."])
        XCTAssertEqual(turns.map(\.speaker), ["Participante", "Gio"])
        XCTAssertEqual(turns[1].start, 0.1)
        XCTAssertEqual(turns[1].end, 0.7, accuracy: 1e-9)
    }

    func testWordsFromBothChannelsAreSortedStably() {
        let turns = TurnMerger.merge([w(2, "b", "Participante"), w(1, "a", "Gio"), w(2, "c", "Gio")])
        XCTAssertEqual(turns.map(\.text), ["a", "b", "c"], "equal starts keep their input order")
    }

    func testLongTurnsBreakAtTheNextSentenceEnd() {
        var words: [Segment] = []
        var t = 0.0
        while t < 50 { words.append(w(t, "palabra", "Gio")); t += 1 }
        words[46].text = "fin."
        words.append(w(50, "sigue", "Gio"))
        let turns = TurnMerger.merge(words)
        XCTAssertEqual(turns.count, 2)
        XCTAssertTrue(turns[0].text.hasSuffix("fin."))
        XCTAssertTrue(turns[1].text.hasPrefix("palabra"))
    }
}
