import AVFoundation
import XCTest
@testable import MeetCaptureCore

/// Explicit test identity; neither method loads a model or uses the network.
actor FakeRecognizer: SpeechRecognizer {
    typealias Script = @Sendable (Int, [Float]) throws -> [Segment]
    typealias FileScript = @Sendable (Int, URL) throws -> [Segment]
    static let testIdentity = QATrace.RecognizerIdentity(
        adapterType: "FakeRecognizer", engine: "parakeet", model: "fake-asr-model",
        sdk: "unit-test", sdkRevision: "fake-sdk-revision",
        modelRepository: "unit-test-fixture", modelRevisionStatus: "fake-model-revision-a",
        configuration: ["decoder": "fake-decoder-a", "compute": "no-model"])
    nonisolated let engine: ASREngine = .parakeet
    nonisolated let identity: QATrace.RecognizerIdentity
    nonisolated var modelName: String { identity.model! }
    private let script: Script
    private let fileScript: FileScript?
    private(set) var calls = 0
    private(set) var fileCalls = 0

    init(identity: QATrace.RecognizerIdentity = FakeRecognizer.testIdentity, fileScript: FileScript? = nil,
         _ script: @escaping Script = { _, _ in throw FakeEngineError() }) {
        self.identity = identity
        self.fileScript = fileScript
        self.script = script
    }

    func prepare() async throws {}
    func unload() async {}

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        calls += 1
        return try script(calls - 1, samples)
    }

    func words(inFile file: URL, language: String) async throws -> [Segment] {
        calls += 1
        fileCalls += 1
        guard let fileScript else { throw FakeEngineError() }
        return try fileScript(calls - 1, file)
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

    private func run(_ wav: URL, _ dir: String, bytes: UInt64 = 1_000, language: String = "es",
                     options: ChunkedTranscription.Options = .current,
                     _ recognizer: FakeRecognizer) async throws -> ChunkedResult {
        try await ChunkedTranscription.run(wav: wav, workDirectory: dir + "/work/remote", audioBytes: bytes,
                                           language: language, recognizer: recognizer, options: options) { _ in }
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
        XCTAssertEqual(first.gaps.map(\.start), [300])
        XCTAssertEqual(first.gaps.map(\.end), [700])
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

    func testLanguageChangeInvalidatesCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-language")
        let wav = try makeWAV(dir, seconds: 30)
        _ = try await run(wav, dir, language: "es", FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "hola")] })

        let english = FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "hello")] }
        let again = try await run(wav, dir, language: "en", english)
        XCTAssertEqual(again.words.map(\.text), ["hello"], "chunks in another language are redone")
        let calls = await english.calls
        XCTAssertEqual(calls, 1)
    }

    func testEveryGeometryRetriesTwiceAndKeepsFailedAudioRecoverable() async throws {
        for seconds in [300, 600, 0] {
            let dir = TestSupport.makeTempDir(self, "chunk-allfail-\(seconds)")
            let wav = try makeWAV(dir, seconds: 3)
            let original = try Data(contentsOf: wav)
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let failing = FakeRecognizer(fileScript: { _, _ in throw FakeEngineError() }) { _, _ in
                throw FakeEngineError()
            }
            do {
                _ = try await run(wav, dir, options: options, failing)
                XCTFail("expected a failure")
            } catch TranscriptionError.emptyOutput {}
            let calls = await failing.calls
            XCTAssertEqual(calls, 2)
            XCTAssertEqual(try Data(contentsOf: wav), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/work/remote/chunk-000.json"))

            let words = [Segment(start: 1.125, end: 1.625, text: "recuperado")]
            let healthy = FakeRecognizer(fileScript: { _, _ in words }) { _, _ in words }
            let recovered = try await run(wav, dir, options: options, healthy)
            XCTAssertEqual(recovered.words, words, "file timestamps are not invented or interpolated")
            XCTAssertTrue(recovered.gaps.isEmpty)
        }
    }

    func testCancellationIsNotRetriedOrCheckpointedInAnyGeometry() async throws {
        for seconds in [300, 600, 0] {
            let dir = TestSupport.makeTempDir(self, "chunk-cancel-\(seconds)")
            let wav = try makeWAV(dir, seconds: 3)
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer(fileScript: { _, _ in throw CancellationError() }) { _, _ in
                throw CancellationError()
            }
            do {
                _ = try await run(wav, dir, options: options, recognizer)
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/work/remote/chunk-000.json"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        }
    }

    func testCancellationAfterACompletedChunkResumesOnlyTheUnfinishedAudio() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-cancel-resume")
        let wav = try makeWAV(dir, seconds: 700, silences: [300])
        let cancelled = FakeRecognizer { call, _ in
            if call == 0 { return [Segment(start: 1, end: 2, text: "guardado")] }
            throw CancellationError()
        }
        do {
            _ = try await run(wav, dir, cancelled)
            XCTFail("expected cancellation after the first checkpoint")
        } catch is CancellationError {}
        let cancelledCalls = await cancelled.calls
        XCTAssertEqual(cancelledCalls, 2)
        let resumed = FakeRecognizer { _, _ in [Segment(start: 3, end: 4, text: "reanudado")] }
        let result = try await run(wav, dir, resumed)
        XCTAssertEqual(result.words, [Segment(start: 1, end: 2, text: "guardado"),
                                      Segment(start: 303, end: 304, text: "reanudado")])
        XCTAssertTrue(result.gaps.isEmpty)
        let resumedCalls = await resumed.calls
        XCTAssertEqual(resumedCalls, 1)
    }

    func testRecognitionGeometryDeliversEverySampleAndUsesTheRequestedBoundaries() async throws {
        for seconds in [300, 600] {
            let dir = TestSupport.makeTempDir(self, "chunk-whole-\(seconds)")
            let wav = try makeWAV(dir, seconds: 700, silences: [300, 604])
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer { _, samples in
                [Segment(start: 0, end: 1, text: "\(samples.count)")]
            }
            let result = try await run(wav, dir, options: options, recognizer)
            XCTAssertEqual(result.words.compactMap { Int($0.text) },
                           seconds == 300 ? [300 * rate, 400 * rate] : [700 * rate])
            XCTAssertEqual(result.words.map(\.start), seconds == 300 ? [0, 300] : [0])
        }
    }

    func testSilenceSkipsBothRecognizerAPIsInEveryGeometry() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-silent")
        let wav = URL(fileURLWithPath: dir + "/silence.wav")
        try WAVFixture.write([Int16](repeating: 0, count: 10 * rate), to: wav)
        for seconds in [300, 600, 0] {
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer(fileScript: { _, _ in
                [Segment(start: 0, end: 1, text: "inventado")]
            }) { _, _ in [Segment(start: 0, end: 1, text: "inventado")] }
            let result = try await run(wav, dir, options: options, recognizer)
            XCTAssertEqual(result.words, [])
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testSameSizeAudioContentChangeInvalidatesCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-stale")
        let wav = try makeWAV(dir, seconds: 3)
        _ = try await run(wav, dir, FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "viejo")] })
        var replacement = WAVFixture.tone(seconds: 3)
        replacement[replacement.count - 1] += 1
        try WAVFixture.write(replacement, to: wav)
        let original = try Data(contentsOf: wav)
        let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "nuevo")] }
        let result = try await run(wav, dir, recognizer)
        XCTAssertEqual(result.words.map(\.text), ["nuevo"])
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: wav), original)
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
        for seconds in [300, 600, 0] {
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer(fileScript: { _, _ in
                [Segment(start: 0, end: 1, text: "inventado")]
            }) { _, _ in [Segment(start: 0, end: 1, text: "inventado")] }
            let result = try await ChunkedTranscription.run(
                wav: micURL, workDirectory: dir + "/work/mic", audioBytes: 1, gateReference: systemURL,
                language: "es", recognizer: recognizer, options: options) { _ in }
            XCTAssertEqual(result.words, [], "fully gated input never reaches either engine API")
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testSixHundredSecondCutsAndWholeFileControlHaveDifferentActualBoundaries() throws {
        let total = 1_520 * rate
        let cuts = ChunkedTranscription.boundaries(totalSamples: total, chunkSeconds: 600) { start, end in
            var window = [Int16](repeating: 100, count: end - start)
            for quiet in [604 * rate, 1_197 * rate] where quiet >= start && quiet + rate / 5 <= end {
                window.replaceSubrange((quiet - start)..<(quiet - start + rate / 5),
                                       with: repeatElement(0, count: rate / 5))
            }
            return window
        }
        XCTAssertEqual(cuts, [0, 604 * rate, 1_197 * rate, total])
        let whole = ChunkedTranscription.boundaries(totalSamples: total, chunkSeconds: 0) { _, _ in
            XCTFail("whole-file geometry must not request a whole-channel array")
            return []
        }
        XCTAssertEqual(whole, [0, total])
    }

    func testWholeChannelCheckpointAvoidsRedecodingCompletedAudio() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-file")
        let wav = URL(fileURLWithPath: dir + "/meeting.wav")
        let total = 9 * rate + rate / 4
        try WAVFixture.write(Array(WAVFixture.tone(seconds: 10).prefix(total)), to: wav)
        let expected = [Segment(start: 0.125, end: 0.26, text: "primero"),
                        Segment(start: 8.93, end: 9.11, text: "último")]
        let recognizer = FakeRecognizer(fileScript: { _, _ in expected })
        var options = ChunkedTranscription.Options.current
        options.chunkSeconds = 0
        _ = try await run(wav, dir, options: options, recognizer)

        let resumed = FakeRecognizer()
        let again = try await run(wav, dir, options: options, resumed)
        XCTAssertEqual(again.words, expected)
        let resumedCalls = await resumed.calls
        XCTAssertEqual(resumedCalls, 0)
    }

    func testRecognizerAndEveryExperimentOptionInvalidateDerivedWords() async throws {
        typealias Options = ChunkedTranscription.Options
        let baseline = Options.current
        var cases: [(String, Options, QATrace.RecognizerIdentity)] = []
        func changedOption(_ name: String, _ change: (inout Options) -> Void) {
            var options = baseline
            change(&options)
            cases.append((name, options, FakeRecognizer.testIdentity))
        }
        changedOption("600s") { $0.chunkSeconds = 600 }
        changedOption("file") { $0.chunkSeconds = 0 }
        changedOption("seam-repair") { $0.seamGapSeconds = 0.5 }
        changedOption("mic-dedupe") { $0.lexicalMicDedupe = false }
        changedOption("capture-repair") { $0.repairCapture = true }
        changedOption("whisper-context") { $0.whisperPrompt = true }
        var revision = FakeRecognizer.testIdentity
        revision.modelRevisionStatus = "fake-model-revision-b"
        cases.append(("model-revision", baseline, revision))
        for field in ["decoder", "compute"] {
            var identity = FakeRecognizer.testIdentity
            identity.configuration?[field] = "changed"
            cases.append((field, baseline, identity))
        }

        for (name, options, identity) in cases {
            let dir = TestSupport.makeTempDir(self, "chunk-identity-\(name)")
            let wav = try makeWAV(dir, seconds: 1)
            let original = try Data(contentsOf: wav)
            let old = [Segment(start: 0, end: 0.5, text: "anterior")]
            _ = try await run(wav, dir, options: baseline, FakeRecognizer({ _, _ in old }))
            let cached = FakeRecognizer()
            let unchanged = try await run(wav, dir, options: baseline, cached)
            XCTAssertEqual(unchanged.words, old)
            let reusedCalls = await cached.calls
            XCTAssertEqual(reusedCalls, 0, "unchanged identity must actually reuse its checkpoint")

            let words = [Segment(start: 0.125, end: 0.5, text: name)]
            let changed = FakeRecognizer(identity: identity, fileScript: { _, _ in words }) { _, _ in words }
            let result = try await run(wav, dir, options: options, changed)
            XCTAssertEqual(result.words, words, "\(name) must not reuse old recognition")
            let calls = await changed.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }

    func testLegacyV3AndMissingRecognizerIdentityCannotReuseCheckpointWords() async throws {
        for legacy in [true, false] {
            let dir = TestSupport.makeTempDir(self, "chunk-manifest-migration")
            let wav = try makeWAV(dir, seconds: 1)
            _ = try await run(wav, dir, FakeRecognizer { _, _ in
                [Segment(start: 0, end: 0.5, text: "anterior")]
            })
            let url = URL(fileURLWithPath: dir + "/work/remote/manifest.json")
            var manifest: [String: Any]
            if legacy {
                // Exact old v3 shape: no recognizer or source-content identity.
                manifest = ["version": 3, "audioBytes": 1_000, "language": "es", "boundaries": [0, rate]]
            } else {
                manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                manifest.removeValue(forKey: "recognizer")
            }
            try JSONSerialization.data(withJSONObject: manifest).write(to: url)
            let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "actual")] }
            let result = try await run(wav, dir, recognizer)
            XCTAssertEqual(result.words.map(\.text), ["actual"])
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        }
    }

    func testSameSizeGateReferenceChangeInvalidatesMicCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-reference-identity")
        let wav = try makeWAV(dir, seconds: 1)
        let reference = URL(fileURLWithPath: dir + "/system.wav")
        var system = [Int16](repeating: 0, count: rate)
        try WAVFixture.write(system, to: reference)
        _ = try await ChunkedTranscription.run(
            wav: wav, workDirectory: dir + "/work/mic", audioBytes: 1, gateReference: reference,
            language: "es", recognizer: FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "anterior")] }
        ) { _ in }
        system[system.count - 1] = 1 // Still below gate activity; only content identity changes.
        try WAVFixture.write(system, to: reference)
        let original = try Data(contentsOf: reference)
        let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "actual")] }
        let result = try await ChunkedTranscription.run(
            wav: wav, workDirectory: dir + "/work/mic", audioBytes: 1, gateReference: reference,
            language: "es", recognizer: recognizer) { _ in }
        XCTAssertEqual(result.words.map(\.text), ["actual"])
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: reference), original)
    }

    func testGateHistoryFilterResetsAndFractionalTailsAreIdenticalAcrossGeometries() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-gate-partitions")
        let sampleRate = rate
        let total = 451 * rate + rate / 4
        let cut = 300 * rate + rate / 10
        let lag = rate / 50
        var system = [Int16](repeating: 0, count: total)
        for range in [(290 * rate)..<(311 * rate), (450 * rate)..<total] {
            for index in range { system[index] = index % 32 < 16 ? 8_000 : -8_000 }
        }
        var mic = [Int16](repeating: 0, count: lag) + system.prefix(total - lag).map { $0 / 2 }
        mic.replaceSubrange(cut..<(cut + rate / 5), with: repeatElement(0, count: rate / 5))
        let micURL = URL(fileURLWithPath: dir + "/mic.wav")
        let systemURL = URL(fileURLWithPath: dir + "/system.wav")
        try WAVFixture.write(mic, to: micURL)
        try WAVFixture.write(system, to: systemURL)
        let cuts = [0, cut, total]
        var expected: [Float] = []
        for part in 0..<2 {
            let start = cuts[part], end = cuts[part + 1]
            let from = max(0, start - BleedGate.maxLagSamples)
            let history = [Float](repeating: 0, count: BleedGate.maxLagSamples - (start - from))
                + system[from..<end].map { Float($0) / 32_768 }
            expected += BleedGate.apply(mic: mic[start..<end].map { Float($0) / 32_768 }, system: history)
        }
        // Both retained tails contain real nonzero echo, so resetting at an
        // arbitrary streaming boundary or gating a fractional window is visible.
        XCTAssertNotEqual(expected[cut - 1], 0)
        XCTAssertNotEqual(expected[total - 1], 0)
        let expectedSamples = expected
        let originalMic = try Data(contentsOf: micURL)
        let originalSystem = try Data(contentsOf: systemURL)
        for seconds in [300, 600, 0] {
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer(fileScript: { _, url in
                XCTAssertNotEqual(url, micURL)
                let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
                XCTAssertEqual(Int(file.length), total)
                for start in stride(from: 0, to: total, by: 30 * sampleRate) {
                    let end = min(total, start + 30 * sampleRate)
                    let actual = try ChunkedTranscription.readSamples(file, from: start, to: end)
                        .map { Float($0) / 32_768 }
                    XCTAssertEqual(actual, Array(expectedSamples[start..<end]))
                }
                return [Segment(start: 0.125, end: 0.5, text: "archivo")]
            }) { call, samples in
                let start = seconds == 300 ? cuts[call] : 0
                let end = seconds == 300 ? cuts[call + 1] : total
                XCTAssertEqual(samples, Array(expectedSamples[start..<end]))
                return [Segment(start: 0.125, end: 0.5, text: "bloque")]
            }
            _ = try await ChunkedTranscription.run(
                wav: micURL, workDirectory: dir + "/work/mic", audioBytes: 1, gateReference: systemURL,
                language: "es", recognizer: recognizer, options: options) { _ in }
            let calls = await recognizer.calls
            let fileCalls = await recognizer.fileCalls
            XCTAssertEqual(calls, seconds == 300 ? 2 : 1)
            XCTAssertEqual(fileCalls, seconds == 0 ? 1 : 0)
        }
        XCTAssertEqual(try Data(contentsOf: micURL), originalMic)
        XCTAssertEqual(try Data(contentsOf: systemURL), originalSystem)
    }

    func testRequiredEvidenceFailureIsNotRetriedOrConvertedIntoAGap() async throws {
        for seconds in [300, 0] {
            let dir = TestSupport.makeTempDir(self, "chunk-evidence-failure")
            let wav = try makeWAV(dir, seconds: 1)
            var options = ChunkedTranscription.Options.current
            options.chunkSeconds = seconds
            let recognizer = FakeRecognizer(fileScript: { _, _ in
                throw QATrace.Failure.evidence("fixture")
            }) { _, _ in throw QATrace.Failure.evidence("fixture") }
            do {
                _ = try await run(wav, dir, options: options, recognizer)
                XCTFail("required evidence failure must propagate")
            } catch is QATrace.Failure {}
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/work/remote/chunk-000.json"))
        }
    }
}
