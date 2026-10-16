import XCTest
@testable import MeetCaptureCore

final class SegmentJSONTests: XCTestCase {
    func testWhisperOffsetsAreMilliseconds() {
        let json = #"{"transcription":[{"offsets":{"from":1500,"to":3250},"text":" Hola "},{"offsets":{"from":0,"to":10},"text":"  "}]}"#
        let segs = SegmentJSON.parseWhisper(Data(json.utf8))
        XCTAssertEqual(segs, [Segment(start: 1.5, end: 3.25, text: "Hola")])
    }

    func testWhisperLegacySegmentsShape() {
        let json = #"{"segments":[{"start":2,"end":4,"text":"chau"}]}"#
        XCTAssertEqual(SegmentJSON.parseWhisper(Data(json.utf8)), [Segment(start: 2, end: 4, text: "chau")])
        XCTAssertEqual(SegmentJSON.parseWhisper(Data("not json".utf8)), [])
    }

    func testSherpaNilOnEmptyOrGarbage() {
        XCTAssertNil(SegmentJSON.parseSherpa(Data("[]".utf8)))
        XCTAssertNil(SegmentJSON.parseSherpa(Data(#"{"segments":[]}"#.utf8)))
        let segs = SegmentJSON.parseSherpa(Data(#"{"engine":"sherpa","segments":[{"start":0.5,"end":1,"text":"ok"}]}"#.utf8))
        XCTAssertEqual(segs, [Segment(start: 0.5, end: 1, text: "ok")])
    }

    /// The bug that kept speakerCount at 0: speaker_diarize.py reads asr["segments"], so the
    /// file passed via --segments must be an object, never a bare array.
    func testDiarizerInputIsWrappedInSegmentsObject() throws {
        let data = try SegmentJSON.encodeForDiarizer([Segment(start: 0, end: 1, text: "a", speaker: "Z")])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try XCTUnwrap(root["segments"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].keys.sorted(), ["end", "start", "text"], "diarizer input carries no speaker")
    }

    /// Fixture shaped like a real speaker_diarize.py run: "?" means unassigned.
    func testDiarizedQuestionMarkBecomesNil() throws {
        let json = #"{"speakers":2,"segments":[{"start":0,"end":1,"text":"a","speaker":"A"},{"start":1,"end":2,"text":"b","speaker":"?"},{"start":2,"end":3,"text":"c","speaker":""},{"start":3,"end":4,"text":"d","speaker":"B"}]}"#
        let segs = try XCTUnwrap(SegmentJSON.parseDiarized(Data(json.utf8)))
        XCTAssertEqual(segs.map(\.speaker), ["A", nil, nil, "B"])
        XCTAssertEqual(TranscriptFormatter.speakerCount(segs), 2)
        XCTAssertEqual(TranscriptFormatter.text(for: segs), "[A]: a\nb\nc\n[B]: d")
    }

    func testMergeByIndexWhenCountsMatchElseByMidpoint() {
        let base = [Segment(start: 0, end: 2, text: "x"), Segment(start: 2, end: 4, text: "y")]
        let same = [Segment(start: 0, end: 2, text: "x", speaker: "A"), Segment(start: 2, end: 4, text: "y", speaker: "B")]
        XCTAssertEqual(DiarizationMerge.apply(labels: same, to: base).map(\.speaker), ["A", "B"])
        let coarse = [Segment(start: 0, end: 4, text: "xy", speaker: "C")]
        XCTAssertEqual(DiarizationMerge.apply(labels: coarse, to: base).map(\.speaker), ["C", "C"])
        XCTAssertEqual(DiarizationMerge.apply(labels: [], to: base), base)
    }

    func testCleanedDropsBlankSegments() {
        let segs = [Segment(start: 0, end: 1, text: "  "), Segment(start: 1, end: 2, text: " ok ")]
        XCTAssertEqual(TranscriptFormatter.cleaned(segs), [Segment(start: 1, end: 2, text: "ok")])
    }
}
