import AVFoundation
import XCTest
@testable import MeetCaptureCore

/// Scripted recognizer: `script(call, samples)` answers each call in order.
actor FakeRecognizer: SpeechRecognizer {
    typealias Script = @Sendable (Int, [Float]) throws -> [Segment]
    private let script: Script
    private(set) var calls = 0
    private(set) var prepared = 0

    init(_ script: @escaping Script) { self.script = script }

    func prepare() async throws { prepared += 1 }

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        calls += 1
        return try script(calls - 1, samples)
    }
}

struct FakeEngineError: Error {}

enum WAVFixture {
    /// 16 kHz mono int16 WAV of `samples`.
    static func write(_ samples: [Int16], to url: URL) throws {
        var data = PCMToWAV.header(dataSize: UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    /// Square-wave tone everywhere except 200 ms of silence at each `silences` second.
    static func tone(seconds: Int, silences: [Double] = []) -> [Int16] {
        let rate = ChunkedTranscription.sampleRate
        var samples = [Int16](repeating: 0, count: seconds * rate)
        for i in samples.indices { samples[i] = i % 32 < 16 ? 8_000 : -8_000 }
        for s in silences {
            let start = Int(s * Double(rate))
            for i in start..<min(samples.count, start + rate / 5) { samples[i] = 0 }
        }
        return samples
    }
}

final class ChunkedTranscriptionTests: XCTestCase {
    private let rate = ChunkedTranscription.sampleRate

    private func makeWAV(_ dir: String, seconds: Int, silences: [Double] = []) throws -> URL {
        let url = URL(fileURLWithPath: dir + "/meeting.wav")
        try WAVFixture.write(WAVFixture.tone(seconds: seconds, silences: silences), to: url)
        return url
    }

    private func run(_ wav: URL, _ dir: String, bytes: UInt64 = 1_000,
                     _ recognizer: FakeRecognizer) async throws -> ChunkedResult {
        try await ChunkedTranscription.run(wav: wav, workDirectory: dir + "/work/remote", audioBytes: bytes,
                                           language: "es", recognizer: recognizer) { _ in }
    }

    func testCutsMoveToTheQuietestFrameNearEachBoundary() throws {
        let dir = TestSupport.makeTempDir(self, "chunk-cuts")
        let wav = try makeWAV(dir, seconds: 760, silences: [304, 597])
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: false)
        let cuts = try ChunkedTranscription.boundaries(totalSamples: Int(file.length)) { start, end in
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(end - start))!
            file.framePosition = AVAudioFramePosition(start)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(end - start))
            return Array(UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: Int(buffer.frameLength)))
        }
        XCTAssertEqual(cuts.count, 4, "760 s → 3 chunks; the 156 s tail stays a chunk of its own")
        XCTAssertEqual(Double(cuts[1]) / Double(rate), 304, accuracy: 0.1)
        XCTAssertEqual(Double(cuts[2]) / Double(rate), 597, accuracy: 0.1, "the next cut is measured from the previous one")
        XCTAssertEqual(cuts.last, 760 * rate)
    }

    func testShortTailJoinsThePreviousChunk() throws {
        let cuts = ChunkedTranscription.boundaries(totalSamples: 400 * rate) { start, end in
            [Int16](repeating: 100, count: end - start)
        }
        XCTAssertEqual(cuts, [0, 400 * rate])
    }

    func testWordsAreShiftedAndAFailedRunResumesFromTheCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-resume")
        let wav = try makeWAV(dir, seconds: 700, silences: [300])

        // First pass: chunk 0 succeeds, chunk 1 fails on both attempts.
        let failing = FakeRecognizer { call, _ in
            if call == 0 { return [Segment(start: 1, end: 2, text: "hola")] }
            throw FakeEngineError()
        }
        let first = try await run(wav, dir, failing)
        XCTAssertEqual(first.failedChunks, 1)
        XCTAssertEqual(first.words.map(\.text), ["hola"])
        XCTAssertEqual(first.gaps.map(\.text), ["[fragmento sin transcribir 00:05:00–00:11:40]"])
        let firstCalls = await failing.calls
        XCTAssertEqual(firstCalls, 3, "a failed chunk is tried twice")

        // Second pass: only the missing chunk runs again, with its offset applied.
        let healthy = FakeRecognizer { _, _ in [Segment(start: 3, end: 4, text: "chau")] }
        let second = try await run(wav, dir, healthy)
        XCTAssertEqual(second.failedChunks, 0)
        XCTAssertEqual(second.words, [Segment(start: 1, end: 2, text: "hola"),
                                      Segment(start: 303, end: 304, text: "chau")])
        let secondCalls = await healthy.calls
        XCTAssertEqual(secondCalls, 1, "chunk 0 came from its checkpoint")
    }

    func testEveryChunkFailingKeepsTheCaptureRecoverable() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-allfail")
        let wav = try makeWAV(dir, seconds: 30)
        do {
            _ = try await run(wav, dir, FakeRecognizer { _, _ in throw FakeEngineError() })
            XCTFail("expected a failure")
        } catch TranscriptionError.emptyOutput {}
    }

    func testCancellationIsNotRetriedOrTurnedIntoAGap() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-cancel")
        let wav = try makeWAV(dir, seconds: 30)
        let recognizer = FakeRecognizer { _, _ in throw CancellationError() }
        do {
            _ = try await run(wav, dir, recognizer)
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1)
    }

    func testEveryChunkReachesTheEngineWhole() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-whole")
        let wav = try makeWAV(dir, seconds: 700, silences: [300])
        let recognizer = FakeRecognizer { _, samples in [Segment(start: 0, end: 1, text: "\(samples.count)")] }
        let result = try await run(wav, dir, recognizer)
        XCTAssertEqual(result.words.compactMap { Int($0.text) }.reduce(0, +), 700 * rate,
                       "a short AVAudioFile read must not drop the end of a chunk")
    }

    func testSilentChunksSkipTheEngine() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-silent")
        let wav = URL(fileURLWithPath: dir + "/silence.wav")
        try WAVFixture.write([Int16](repeating: 0, count: 10 * rate), to: wav)
        let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "inventado")] }
        let result = try await run(wav, dir, recognizer)
        XCTAssertEqual(result.words, [])
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0)
    }

    func testChangedAudioInvalidatesCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-stale")
        let wav = try makeWAV(dir, seconds: 30)
        _ = try await run(wav, dir, bytes: 1_000, FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "viejo")] })
        let result = try await run(wav, dir, bytes: 2_000,
                                   FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "nuevo")] })
        XCTAssertEqual(result.words.map(\.text), ["nuevo"])
    }

    func testGateReferenceMutesBleedBeforeTheEngine() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-gate")
        // The mic is the system channel 20 ms late and 6 dB quieter: pure bleed.
        let system = WAVFixture.tone(seconds: 4)
        let lag = rate / 50
        let mic = [Int16](repeating: 0, count: lag) + system.prefix(system.count - lag).map { $0 / 2 }
        let systemURL = URL(fileURLWithPath: dir + "/system.wav"), micURL = URL(fileURLWithPath: dir + "/mic.wav")
        try WAVFixture.write(system, to: systemURL)
        try WAVFixture.write(mic, to: micURL)
        let recognizer = FakeRecognizer { _, samples in
            [Segment(start: 0, end: 1, text: "peak \(samples.map(abs).max() ?? 0)")]
        }
        let result = try await ChunkedTranscription.run(
            wav: micURL, workDirectory: dir + "/work/mic", audioBytes: 1, gateReference: systemURL,
            language: "es", recognizer: recognizer) { _ in }
        XCTAssertEqual(result.words, [], "a fully gated chunk is silent and never reaches the engine")
    }
}
