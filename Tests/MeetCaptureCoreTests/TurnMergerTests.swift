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

    func testIdenticalRepliesAndLegitimateRepetitionsSurviveBothChannels() {
        let turns = TurnMerger.merge([
            w(0, "Sí.", "Participante"), w(0.1, "sí", "Gio"),
            w(1, "No.", "Participante"), w(1.1, "no", "Gio"), w(1.4, "no", "Gio"),
            w(2, "Dale.", "Participante"), w(2.2, "dale", "Gio"),
        ])
        XCTAssertEqual(turns.map(\.text), ["Sí.", "sí", "No.", "no no", "Dale.", "dale"])
        XCTAssertEqual(turns.map(\.speaker), ["Participante", "Gio", "Participante", "Gio", "Participante", "Gio"])
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

    func testOnlyWordsUnderTheThresholdAreMarkedBeforeTheirPunctuation() {
        func c(_ start: Double, _ text: String, _ confidence: Float?) -> Segment {
            Segment(start: start, end: start + 0.3, text: text, speaker: "Gio", confidence: confidence)
        }
        let below = TurnMerger.doubtfulBelow.nextDown
        let turns = TurnMerger.merge([
            c(0, "hola,", below), c(0.4, "¿no?", below), c(0.8, "seguro", TurnMerger.doubtfulBelow),
            c(1.2, "viejo", nil), c(1.6, "...", 0.01),
        ])
        XCTAssertEqual(turns.map(\.text), ["hola[?], ¿no[?]? seguro viejo ..."],
                       "at the threshold and without confidence (old checkpoints) nothing is marked")
        XCTAssertNil(turns[0].confidence, "a turn carries no word confidence")
    }

    func testCheckpointWithoutConfidenceDecodes() throws {
        let old = Data(#"[{"start":0,"end":0.5,"text":"hola"}]"#.utf8)
        let words = try JSONDecoder().decode([Segment].self, from: old)
        XCTAssertEqual(words, [Segment(start: 0, end: 0.5, text: "hola")])
    }

    func testAliasesPreserveDoubtAndMatchPunctuatedVariants() {
        let aliases = ["AppSheet": ["app sheet"], "EEUU": ["EE.UU."]]
        for (input, expected) in [
            ("abrí app[?] sheet[?], y listo[?]", "abrí AppSheet[?], y listo[?]"),
            ("en EE.UU[?]. hoy", "en EEUU[?] hoy"),
            ("en EE.UU. hoy", "en EEUU hoy"),
        ] {
            let turns = [Segment(start: 0, end: 1, text: input)]
            XCTAssertEqual(Aliases.apply(aliases, to: turns).map(\.text), [expected])
            let plain = [Segment(start: 0, end: 1, text: input.replacingOccurrences(of: "[?]", with: ""))]
            XCTAssertEqual(Aliases.apply(aliases, to: turns)[0].text.replacingOccurrences(of: "[?]", with: ""),
                           Aliases.apply(aliases, to: plain)[0].text)
        }
    }
}
