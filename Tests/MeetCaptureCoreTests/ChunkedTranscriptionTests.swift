import AVFoundation
import XCTest
@testable import MeetCaptureCore

final class ChunkedTranscriptionTests: XCTestCase {
    private let rate = ChunkedTranscription.sampleRate

    /// Tone everywhere except 200 ms of silence at each `silences` second.
    private func makeWAV(_ dir: String, seconds: Int, silences: [Double] = []) throws -> URL {
        var samples = [Int16](repeating: 0, count: seconds * rate)
        for i in samples.indices { samples[i] = i % 32 < 16 ? 8_000 : -8_000 }
        for s in silences {
            let start = Int(s * Double(rate))
            for i in start..<min(samples.count, start + rate / 5) { samples[i] = 0 }
        }
        var data = PCMToWAV.header(dataSize: UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = URL(fileURLWithPath: dir + "/meeting.wav")
        try data.write(to: url)
        return url
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

    func testSegmentsAreShiftedAndAFailedRunResumesFromTheCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-resume")
        let wav = try makeWAV(dir, seconds: 700, silences: [300])
        let source = dir + "/recording-1.pcm"
        try Data(count: 1_000).write(to: URL(fileURLWithPath: source))

        let calls = CallLog()
        // First pass: chunk 1 hangs on GPU and CPU, chunk 0 succeeds on GPU.
        let failing: ChunkedTranscription.Engine = { _, useGPU in
            let n = await calls.next(useGPU)
            if n == 0 { return [Segment(start: 1, end: 2, text: "hola")] }
            throw ProcessRunnerError.timedOut("whisper-cli", seconds: 660)
        }
        let first = try await ChunkedTranscription.run(wav: wav, sourceAudio: source, engine: failing) { _ in }
        XCTAssertEqual(first.failedChunks, 1)
        XCTAssertEqual(first.segments.map(\.text), ["hola", "[fragmento sin transcribir 00:05:00–00:11:40]"])
        let firstRun = await calls.log
        XCTAssertEqual(firstRun, [true, true, false], "a failed chunk retries once on CPU")

        // Second pass: only the missing chunk runs again, with its offset applied.
        let healthy: ChunkedTranscription.Engine = { _, useGPU in
            _ = await calls.next(useGPU)
            return [Segment(start: 3, end: 4, text: "chau")]
        }
        let second = try await ChunkedTranscription.run(wav: wav, sourceAudio: source, engine: healthy) { _ in }
        XCTAssertEqual(second.failedChunks, 0)
        XCTAssertEqual(second.segments, [Segment(start: 1, end: 2, text: "hola"),
                                         Segment(start: 303, end: 304, text: "chau")])
        let total = await calls.log
        XCTAssertEqual(total.count, 4, "chunk 0 came from its checkpoint")
    }

    func testEveryChunkFailingKeepsTheCaptureRecoverable() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-allfail")
        let wav = try makeWAV(dir, seconds: 30)
        let source = dir + "/recording-1.pcm"
        try Data(count: 1_000).write(to: URL(fileURLWithPath: source))
        do {
            _ = try await ChunkedTranscription.run(wav: wav, sourceAudio: source,
                                                   engine: { _, _ in throw WhisperError.outputMissing }) { _ in }
            XCTFail("expected a failure")
        } catch TranscriptionError.emptyOutput {}
    }

    func testChangedAudioInvalidatesCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-stale")
        let wav = try makeWAV(dir, seconds: 30)
        let source = dir + "/recording-1.pcm"
        try Data(count: 1_000).write(to: URL(fileURLWithPath: source))
        let a: ChunkedTranscription.Engine = { _, _ in [Segment(start: 0, end: 1, text: "viejo")] }
        _ = try await ChunkedTranscription.run(wav: wav, sourceAudio: source, engine: a) { _ in }
        try Data(count: 2_000).write(to: URL(fileURLWithPath: source))
        let b: ChunkedTranscription.Engine = { _, _ in [Segment(start: 0, end: 1, text: "nuevo")] }
        let result = try await ChunkedTranscription.run(wav: wav, sourceAudio: source, engine: b) { _ in }
        XCTAssertEqual(result.segments.map(\.text), ["nuevo"])
    }

    func testWhisperTimeoutScalesPerChunkWithoutACap() {
        XCTAssertEqual(WhisperCLI.timeout(forAudioSeconds: 300), 660)
        XCTAssertEqual(WhisperCLI.timeout(forAudioSeconds: 0), 60)
    }
}

private actor CallLog {
    private(set) var log: [Bool] = []
    func next(_ useGPU: Bool) -> Int { log.append(useGPU); return log.count - 1 }
}
