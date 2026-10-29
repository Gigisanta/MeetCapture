import AVFoundation
import FluidAudio
import XCTest
@testable import MeetCaptureCore

/// Scripted recognizer: `script(call, samples)` answers each call in order.
actor FakeRecognizer: SpeechRecognizer {
    typealias Script = @Sendable (Int, [Float]) throws -> [Segment]
    static let testIdentity = RecognitionIdentity(
        engine: .parakeet, model: "fixture", modelRepository: "fixture",
        modelRevision: "fixture-v1", sdk: "fixture", sdkRevision: "1", configuration: [:])
    private let identity: RecognitionIdentity
    private let script: Script
    private(set) var calls = 0
    private(set) var releases = 0

    init(identity: RecognitionIdentity = FakeRecognizer.testIdentity, _ script: @escaping Script) {
        self.identity = identity
        self.script = script
    }

    func prepare() async throws -> RecognitionIdentity { identity }
    func release() async { releases += 1 }

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

    private func run(_ wav: URL, _ dir: String, bytes: UInt64 = 1_000, language: String = "es",
                     gateReference: URL? = nil, _ recognizer: FakeRecognizer) async throws -> ChunkedResult {
        let identity = try await recognizer.prepare()
        let work = dir + "/work/" + (gateReference == nil ? "remote" : "mic")
        do {
            let result = try await ChunkedTranscription.run(
                wav: wav, workDirectory: work, audioBytes: bytes, gateReference: gateReference,
                language: language, recognizer: recognizer, recognizerIdentity: identity) { _ in }
            await recognizer.release()
            return result
        } catch {
            await recognizer.release()
            throw error
        }
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
        XCTAssertEqual(first.quality.audioDurationSec, 700)
        XCTAssertEqual(try XCTUnwrap(first.quality.decodingCoverage), 300.0 / 700.0, accuracy: 1e-12)
        XCTAssertEqual(first.quality.decodedDurationSec, 300, "coverage is the processed audio, not the one second of words")
        XCTAssertEqual(first.quality.silenceSkippedDurationSec, 0)
        XCTAssertEqual(first.quality.failedChunks, [.init(start: 300, end: 700)])
        XCTAssertEqual(first.quality.unmeasuredIntervals, [])
        XCTAssertNil(first.quality.bleedGate)
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
        XCTAssertEqual(second.quality.decodingCoverage, 1)
        XCTAssertEqual(second.quality.decodedDurationSec, 700, "cached measurements and newly decoded samples both count")
        XCTAssertEqual(second.quality.failedChunks, [])

        // A pre-metadata word-array checkpoint remains valid, but its missing
        // measured sample counts cannot turn into full/zero coverage.
        let legacy = URL(fileURLWithPath: dir + "/work/remote/chunk-000.json")
        try JSONEncoder().encode([Segment(start: 1, end: 2, text: "hola")]).write(to: legacy)
        let unused = FakeRecognizer { _, _ in throw FakeEngineError() }
        let fromLegacy = try await run(wav, dir, unused)
        XCTAssertEqual(fromLegacy.words, second.words)
        XCTAssertNil(fromLegacy.quality.decodingCoverage)
        XCTAssertNil(fromLegacy.quality.decodedDurationSec)
        XCTAssertNil(fromLegacy.quality.silenceSkippedDurationSec)
        XCTAssertEqual(fromLegacy.quality.unmeasuredIntervals, [.init(start: 0, end: 300)])
        XCTAssertEqual(fromLegacy.quality.failedChunks, [])
        let legacyCalls = await unused.calls
        XCTAssertEqual(legacyCalls, 0, "missing metrics never invalidate valid words")
    }

    func testLanguageChangeInvalidatesCheckpoints() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-language")
        let wav = try makeWAV(dir, seconds: 30)
        _ = try await run(wav, dir, language: "es", FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "hola")] })
        let retainedAudio = URL(fileURLWithPath: dir + "/work/remote/retained.wav")
        let original = try Data(contentsOf: wav)
        try original.write(to: retainedAudio)

        let english = FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "hello")] }
        let again = try await run(wav, dir, language: "en", english)
        XCTAssertEqual(again.words.map(\.text), ["hello"], "chunks in another language are redone")
        let calls = await english.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try Data(contentsOf: wav), original)
        XCTAssertEqual(try Data(contentsOf: retainedAudio), original, "invalidation removes only generated JSON")
    }

    func testMissingSDKTimingsNeverCheckpointEmptySuccessAndRemainRecoverable() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-allfail")
        let wav = try makeWAV(dir, seconds: 1)
        let original = try Data(contentsOf: wav)
        let broken = FakeRecognizer { _, _ in
            try ParakeetEngine.timedWords(from: ASRResult(text: "No", confidence: 1, duration: 1, processingTime: 0))
        }
        do {
            _ = try await run(wav, dir, broken)
            XCTFail("expected a failure")
        } catch TranscriptionError.emptyOutput {}
        let failedCalls = await broken.calls
        XCTAssertEqual(failedCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/work/remote/chunk-000.json"))
        XCTAssertEqual(try Data(contentsOf: wav), original)

        let healthy = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "No")] }
        let recovered = try await run(wav, dir, healthy)
        XCTAssertEqual(recovered.words.map(\.text), ["No"])
        let recoveryCalls = await healthy.calls
        XCTAssertEqual(recoveryCalls, 1, "the invalid SDK result must not leave an empty success checkpoint")
    }

    func testCancellationIsNotRetriedOrTurnedIntoAGapEvenWhenTheSDKIgnoresIt() async throws {
        let scripts: [FakeRecognizer.Script] = [
            { _, _ in throw CancellationError() },
            { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return [Segment(start: 0, end: 0.5, text: "not completed")]
            },
            { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw FakeEngineError()
            },
        ]
        for (index, script) in scripts.enumerated() {
            let dir = TestSupport.makeTempDir(self, "chunk-cancel-\(index)")
            let wav = try makeWAV(dir, seconds: 1)
            let original = try Data(contentsOf: wav)
            let recognizer = FakeRecognizer(script)
            let job = TranscriptionJob(audioPath: wav.path, captureSampleRate: 16_000, language: "es",
                                       diarize: false, recognizer: recognizer)
            // Cancel a separate task, never XCTest's own task.
            let task = Task { try await job.run { _ in } }
            do {
                _ = try await task.value
                XCTFail("expected cancellation")
            } catch is CancellationError {}
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            let work = ChunkedTranscription.workDirectory(forAudio: wav.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/remote/chunk-000.json"))
            let releases = await recognizer.releases
            XCTAssertEqual(releases, 1)
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }

    func testEveryChunkReachesTheEngineWhole() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-whole")
        let wav = try makeWAV(dir, seconds: 700, silences: [300])
        let recognizer = FakeRecognizer { _, samples in [Segment(start: 0, end: 1, text: "\(samples.count)")] }
        let result = try await run(wav, dir, recognizer)
        XCTAssertEqual(result.words.compactMap { Int($0.text) }.reduce(0, +), 700 * rate,
                       "a short AVAudioFile read must not drop the end of a chunk")
    }

    func testEmptyResultsDistinguishDecodedAudioFromSkippedSilenceAcrossResume() async throws {
        for silent in [true, false] {
            let dir = TestSupport.makeTempDir(self, "chunk-empty-\(silent)")
            let wav = URL(fileURLWithPath: dir + "/empty.wav")
            try WAVFixture.write(silent ? [Int16](repeating: 0, count: 10 * rate) : WAVFixture.tone(seconds: 10), to: wav)
            let recognizer = FakeRecognizer { _, _ in [] }
            let result = try await run(wav, dir, recognizer)
            XCTAssertEqual(result.words, [])
            XCTAssertEqual(result.quality.decodingCoverage, 1)
            XCTAssertEqual(result.quality.decodedDurationSec, silent ? 0 : 10)
            XCTAssertEqual(result.quality.silenceSkippedDurationSec, silent ? 10 : 0)
            let calls = await recognizer.calls
            XCTAssertEqual(calls, silent ? 0 : 1)

            let unused = FakeRecognizer { _, _ in throw FakeEngineError() }
            let resumed = try await run(wav, dir, unused)
            XCTAssertEqual(resumed.quality, result.quality, "an empty word list does not erase its decoding/silence evidence")
            let resumedCalls = await unused.calls
            XCTAssertEqual(resumedCalls, 0)
        }
    }

    func testChangedAudioInvalidatesCheckpointsIncludingSameSizeEdits() async throws {
        for sameSize in [false, true] {
            let dir = TestSupport.makeTempDir(self, "chunk-stale-\(sameSize)")
            let wav = try makeWAV(dir, seconds: 1)
            _ = try await run(wav, dir, bytes: 1_000, FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "viejo")] })
            if sameSize {
                var samples = WAVFixture.tone(seconds: 1)
                samples[samples.count - 1] += 1
                try WAVFixture.write(samples, to: wav)
            }
            let original = try Data(contentsOf: wav)
            let result = try await run(wav, dir, bytes: sameSize ? 1_000 : 2_000,
                                       FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "nuevo")] })
            XCTAssertEqual(result.words.map(\.text), ["nuevo"])
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }

    func testGateReferenceChangeInvalidatesWordsAndMutesBleedBeforeTheEngine() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-gate")
        // The mic is the system channel 20 ms late and 6 dB quieter: pure bleed.
        let system = WAVFixture.tone(seconds: 4)
        let lag = rate / 50
        let mic = [Int16](repeating: 0, count: lag) + system.prefix(system.count - lag).map { $0 / 2 }
        let systemURL = URL(fileURLWithPath: dir + "/system.wav"), micURL = URL(fileURLWithPath: dir + "/mic.wav")
        try WAVFixture.write([Int16](repeating: 0, count: system.count), to: systemURL)
        try WAVFixture.write(mic, to: micURL)
        let firstRecognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "before gate")] }
        let before = try await run(micURL, dir, bytes: 1, gateReference: systemURL, firstRecognizer)
        XCTAssertEqual(before.words.map(\.text), ["before gate"])
        XCTAssertEqual(before.quality.bleedGate?.gatedSamples, 0)
        XCTAssertEqual(before.quality.bleedGate?.complete, true)
        // Same byte count, but now the reference proves this mic signal is bleed.
        try WAVFixture.write(system, to: systemURL)
        let recognizer = FakeRecognizer { _, samples in
            [Segment(start: 0, end: 1, text: "peak \(samples.map(abs).max() ?? 0)")]
        }
        let result = try await run(micURL, dir, bytes: 1, gateReference: systemURL, recognizer)
        XCTAssertEqual(result.words, [], "a fully gated chunk is silent and never reaches the engine")
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.quality.decodingCoverage, 1)
        XCTAssertEqual(result.quality.decodedDurationSec, 0)
        XCTAssertEqual(result.quality.silenceSkippedDurationSec, 4)
        XCTAssertEqual(result.quality.bleedGate,
                       .init(measuredSamples: 4 * rate, gatedSamples: 4 * rate, gatedDurationSec: 4, complete: true))
        let unused = FakeRecognizer { _, _ in throw FakeEngineError() }
        let resumed = try await run(micURL, dir, bytes: 1, gateReference: systemURL, unused)
        XCTAssertEqual(resumed.quality, result.quality, "gate counts survive a cached empty/silent chunk")
        let resumedCalls = await unused.calls
        XCTAssertEqual(resumedCalls, 0)
    }

    func testUnavailableGateCountsKeepValidWordsWithoutInventingCompleteness() async throws {
        let dir = TestSupport.makeTempDir(self, "chunk-legacy-metrics")
        // Two chunks, but a silent reference keeps this migration test out of
        // NCC. Only the first checkpoint will lose its measurement metadata.
        let mic = try makeWAV(dir, seconds: 451, silences: [300])
        let system = URL(fileURLWithPath: dir + "/system.wav")
        try WAVFixture.write([Int16](repeating: 0, count: 451 * rate), to: system)
        let original = try await run(mic, dir, gateReference: system,
                                     FakeRecognizer { _, _ in [Segment(start: 1, end: 2, text: "conservado")] })
        let checkpoint = URL(fileURLWithPath: dir + "/work/mic/chunk-000.json")
        let measured = try Data(contentsOf: checkpoint)
        for legacy in [true, false] {
            if legacy {
                try JSONEncoder().encode([original.words[0]]).write(to: checkpoint)
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: measured) as? [String: Any])
                var quality = try XCTUnwrap(object["quality"] as? [String: Any])
                quality["gatedSamples"] = -1
                object["quality"] = quality
                try JSONSerialization.data(withJSONObject: object).write(to: checkpoint)
            }
            let unused = FakeRecognizer { _, _ in throw FakeEngineError() }
            let resumed = try await run(mic, dir, gateReference: system, unused)
            XCTAssertEqual(resumed.words, original.words)
            XCTAssertEqual(resumed.quality.audioDurationSec, 451)
            XCTAssertNil(resumed.quality.decodingCoverage)
            XCTAssertNil(resumed.quality.decodedDurationSec)
            XCTAssertNil(resumed.quality.silenceSkippedDurationSec)
            XCTAssertEqual(resumed.quality.bleedGate,
                           .init(measuredSamples: 151 * rate, gatedSamples: 0, gatedDurationSec: 0, complete: false),
                           "a measured zero for the known tail is not a complete meeting total or a re-run of NCC")
            XCTAssertEqual(resumed.quality.unmeasuredIntervals, [.init(start: 0, end: 300)])
            let calls = await unused.calls
            XCTAssertEqual(calls, 0)
        }
        // When every checkpoint lacks metrics, even a zero gate count is unknown.
        try JSONEncoder().encode([original.words[0]]).write(to: checkpoint)
        try JSONEncoder().encode([original.words[1]])
            .write(to: URL(fileURLWithPath: dir + "/work/mic/chunk-001.json"))
        let unused = FakeRecognizer { _, _ in throw FakeEngineError() }
        let unmeasured = try await run(mic, dir, gateReference: system, unused)
        XCTAssertEqual(unmeasured.words, original.words)
        XCTAssertNil(unmeasured.quality.bleedGate)
        XCTAssertEqual(unmeasured.quality.unmeasuredIntervals,
                       [.init(start: 0, end: 300), .init(start: 300, end: 451)])
        let calls = await unused.calls
        XCTAssertEqual(calls, 0)
    }

    func testRecognizerChangesInvalidateDerivedWordsWithoutChangingAudio() async throws {
        let changes: [(String, (inout RecognitionIdentity) -> Void)] = [
            ("model", { $0.model = "another-model" }),
            ("weights", { $0.modelRevision = "different-local-content" }),
            ("sdk", { $0.sdkRevision = "another-revision" }),
            ("decoder", { $0.configuration["seamGapRepairMinGapSeconds"] = "0.5" }),
            ("compute", { $0.configuration["compute.encoderDecoder"] = "cpuOnly" }),
        ]
        for (name, change) in changes {
            let dir = TestSupport.makeTempDir(self, "chunk-recognizer-\(name)")
            let wav = try makeWAV(dir, seconds: 1)
            let original = try Data(contentsOf: wav)
            _ = try await run(wav, dir, FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "old")] })
            var identity = FakeRecognizer.testIdentity
            change(&identity)
            let recognizer = FakeRecognizer(identity: identity) { _, _ in [Segment(start: 0, end: 0.5, text: name)] }
            let result = try await run(wav, dir, recognizer)
            XCTAssertEqual(result.words.map(\.text), [name], "\(name) must not reuse another recognizer's words")
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }

    func testLegacyAndCorruptCheckpointsAreRedoneInsteadOfReused() async throws {
        for corruption in ["legacy-v3", "chunking", "boundaries", "word-times"] {
            let dir = TestSupport.makeTempDir(self, "chunk-checkpoint-\(corruption)")
            let wav = try makeWAV(dir, seconds: 1)
            let original = try Data(contentsOf: wav)
            _ = try await run(wav, dir, FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "old")] })
            let manifestURL = URL(fileURLWithPath: dir + "/work/remote/manifest.json")
            if corruption == "legacy-v3" {
                let legacy: [String: Any] = ["version": 3, "audioBytes": 1_000, "language": "es", "boundaries": [0, rate]]
                try JSONSerialization.data(withJSONObject: legacy).write(to: manifestURL)
            } else if corruption == "word-times" {
                try JSONEncoder().encode([Segment(start: -1, end: 0.5, text: "invalid")])
                    .write(to: URL(fileURLWithPath: dir + "/work/remote/chunk-000.json"))
            } else {
                var manifest = try JSONDecoder().decode(ChunkManifest.self, from: Data(contentsOf: manifestURL))
                if corruption == "chunking" {
                    manifest.chunking.targetSamples += 1
                } else {
                    manifest.boundaries = [0, rate / 2, rate]
                }
                try JSONEncoder().encode(manifest).write(to: manifestURL)
            }
            let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "new")] }
            let result = try await run(wav, dir, recognizer)
            XCTAssertEqual(result.words.map(\.text), ["new"], corruption)
            let calls = await recognizer.calls
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(try Data(contentsOf: wav), original)
        }
    }
}
