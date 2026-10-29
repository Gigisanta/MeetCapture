import AVFoundation
import XCTest
@testable import MeetCaptureCore

/// Fixed diarization, or a failure; counts calls to prove the cache.
actor FakeDiarizer: SpeakerDiarizing {
    private let result: [SpeakerSpan]?
    private let throwsCancellation: Bool
    private(set) var calls = 0
    init(_ result: [SpeakerSpan]?, throwsCancellation: Bool = false) {
        self.result = result
        self.throwsCancellation = throwsCancellation
    }
    func spans(in wav: URL) async throws -> [SpeakerSpan] {
        calls += 1
        if throwsCancellation { throw CancellationError() }
        guard let result else { throw DiarizationError.unsupportedOS }
        return result
    }
}

final class TranscriptionJobTests: XCTestCase {
    private let rate = ChunkedTranscription.sampleRate

    /// A capture as the recorder writes it: interleaved int16 L/R at 16 kHz plus its sidecar.
    private func capture(_ dir: String, left: [Int16], right: [Int16], strategy: String = "global") throws -> String {
        let path = dir + "/recording-1.pcm"
        var frames: [Int16] = []
        for (l, r) in zip(left, right) { frames += [l, r] }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: path))
        try AudioFormatSidecar.capture(tapStrategy: strategy, tapInfo: "test").write(forAudio: path)
        return path
    }

    /// Independent noise for Gio: not correlated with the remote tone, so the gate keeps it.
    private func gio(_ seconds: Int) -> [Int16] {
        var state: UInt32 = 7
        return (0..<(seconds * rate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int16(truncatingIfNeeded: Int32(state >> 16) - 32_768) / 4
        }
    }

    func testDualChannelCaptureSeparatesMicAndNumberedParticipants() async throws {
        let dir = TestSupport.makeTempDir(self, "job-dual")
        let audio = try capture(dir, left: WAVFixture.tone(seconds: 4), right: gio(4))
        // Call 0 is the remote channel, call 1 the mic.
        let recognizer = FakeRecognizer { call, _ in
            call == 0
                ? [Segment(start: 0.0, end: 0.4, text: "Hola"), Segment(start: 0.5, end: 0.9, text: "app sheet"),
                   Segment(start: 3.0, end: 3.3, text: "listo")]
                : [Segment(start: 1.5, end: 1.9, text: "Buenas"), Segment(start: 3.1, end: 3.3, text: "listo")]
        }
        let diarizer = FakeDiarizer([SpeakerSpan(start: 0, end: 1, speaker: "B"),
                                     SpeakerSpan(start: 1.0, end: 1.4, speaker: "C"),
                                     SpeakerSpan(start: 2.8, end: 4, speaker: "A")])
        let job = TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es", diarize: true,
                                   aliases: ["AppSheet": ["app sheet"]], recognizer: recognizer, diarizer: diarizer)
        let outcome = try await job.run { _ in }

        XCTAssertEqual(TranscriptFormatter.text(for: outcome.segments),
                       "[Participante 1]: Hola AppSheet\n[Yo]: Buenas\n[Participante 2]: listo\n[Yo]: listo",
                       "independent mic speech that survived the acoustic gate must not be deleted by text")
        XCTAssertEqual(outcome.engineUsed, .parakeet)
        XCTAssertEqual(outcome.modelUsed, FakeRecognizer.testIdentity.model)
        XCTAssertEqual(outcome.failedChunks, 0)
        XCTAssertEqual(outcome.audioDurationSec ?? 0, 4, accuracy: 0.01)
        // Exercise the same Codable boundary as the worker, with a real run's
        // measurements rather than a hand-authored quality payload.
        let transferred = try JSONDecoder().decode(TranscriptionJob.Outcome.self, from: JSONEncoder().encode(outcome))
        let quality = try XCTUnwrap(transferred.quality)
        XCTAssertEqual(quality.audioDurationSec, 4)
        XCTAssertEqual(quality.remoteSpeakerCount, 3,
                       "diarized speakers without recognized words must not disappear into a guessed 1:1")
        XCTAssertNil(quality.channels.single)
        XCTAssertEqual(quality.channels.remote?.decodingCoverage, 1)
        XCTAssertEqual(quality.channels.remote?.decodedDurationSec, 4)
        XCTAssertEqual(quality.channels.remote?.failedChunks, [])
        XCTAssertNil(quality.channels.remote?.bleedGate)
        XCTAssertEqual(quality.channels.microphone?.decodedDurationSec, 4)
        XCTAssertEqual(quality.channels.microphone?.bleedGate,
                       .init(measuredSamples: 4 * rate, gatedSamples: 0, gatedDurationSec: 0, complete: true))
        let work = ChunkedTranscription.workDirectory(forAudio: audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/system.wav"), "channel WAVs are derived data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/mic.wav"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio), "the capture itself is kept")

        // A rerun resumes from the checkpoints and the cached diarization.
        let again = try await TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es",
                                               diarize: true, recognizer: FakeRecognizer { _, _ in [] },
                                               diarizer: diarizer).run { _ in }
        XCTAssertEqual(again.segments.map(\.speaker), ["Participante 1", "Yo", "Participante 2", "Yo"])
        XCTAssertEqual(again.quality, quality, "resuming must preserve measured counters and the remote-speaker evidence")
        let diarizations = await diarizer.calls
        XCTAssertEqual(diarizations, 1)
    }

    func testOnlyProvenSystemMicLayoutCanSupplyRemoteSpeakerCount() async throws {
        var unsupportedSchema = AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "test")
        unsupportedSchema.schema = "meetcapture.audio.v999"
        let cases: [(AudioFormatSidecar, Bool)] = [
            (.capture(tapStrategy: "global", tapInfo: "test"), true),
            (.imported(), false),
            (.capture(tapStrategy: "mic-only", tapInfo: "test"), false),
            (unsupportedSchema, false),
        ]
        for (index, entry) in cases.enumerated() {
            let (format, proven) = entry
            let dir = TestSupport.makeTempDir(self, "job-layout-evidence-\(index)")
            let audio = try capture(dir, left: WAVFixture.tone(seconds: 2), right: gio(2))
            try format.write(forAudio: audio)
            let outcome = try await TranscriptionJob(
                audioPath: audio, captureSampleRate: 16_000, language: "es", diarize: true,
                recognizer: FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "voz")] },
                diarizer: FakeDiarizer([SpeakerSpan(start: 0, end: 2, speaker: "A")])).run { _ in }
            let quality = try XCTUnwrap(outcome.quality)
            if proven {
                XCTAssertEqual(quality.remoteSpeakerCount, 1)
                XCTAssertNotNil(quality.channels.remote)
                XCTAssertNotNil(quality.channels.microphone)
                XCTAssertNil(quality.channels.left)
                XCTAssertNil(quality.channels.right)
            } else {
                XCTAssertNil(quality.remoteSpeakerCount, "stereo positions or a mic-only sidecar cannot prove a remote identity")
                XCTAssertNil(quality.channels.remote)
                XCTAssertNil(quality.channels.microphone)
                XCTAssertNotNil(quality.channels.left)
                XCTAssertNotNil(quality.channels.right)
            }
            XCTAssertNil(quality.channels.single)
        }
    }

    func testUnavailableOrEmptyDiarizationFallsBackWithoutRemoteSpeakerEvidence() async throws {
        let cases: [[SpeakerSpan]?] = [nil, []]
        for (index, spans) in cases.enumerated() {
            let dir = TestSupport.makeTempDir(self, "job-nodiar-\(index)")
            let audio = try capture(dir, left: WAVFixture.tone(seconds: 2), right: gio(2))
            let recognizer = FakeRecognizer { call, _ in
                [Segment(start: call == 0 ? 0 : 1, end: call == 0 ? 0.5 : 1.5, text: call == 0 ? "remoto" : "local")]
            }
            let outcome = try await TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es",
                                                     diarize: true, recognizer: recognizer,
                                                     diarizer: FakeDiarizer(spans)).run { _ in }
            XCTAssertEqual(TranscriptFormatter.text(for: outcome.segments), "[Participante]: remoto\n[Yo]: local")
            XCTAssertNotNil(outcome.quality?.channels.remote)
            XCTAssertNil(outcome.quality?.remoteSpeakerCount, "a generic fallback label is not a measured single remote")
        }
    }

    func testSilentSystemChannelTranscribesTheMicAloneWithoutLabels() async throws {
        let dir = TestSupport.makeTempDir(self, "job-silent-tap")
        let audio = try capture(dir, left: [Int16](repeating: 3, count: 2 * rate), right: gio(2))
        let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "solo")] }
        let diarizer = FakeDiarizer([SpeakerSpan(start: 0, end: 2, speaker: "A")])
        let outcome = try await TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es",
                                                 diarize: false, recognizer: recognizer,
                                                 diarizer: diarizer).run { _ in }
        XCTAssertEqual(TranscriptFormatter.text(for: outcome.segments), "solo")
        XCTAssertNotNil(outcome.quality?.channels.single)
        XCTAssertNil(outcome.quality?.channels.remote)
        XCTAssertNil(outcome.quality?.channels.microphone)
        XCTAssertNil(outcome.quality?.remoteSpeakerCount)
        let diarized = try await TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es",
                                                  diarize: true, recognizer: recognizer,
                                                  diarizer: diarizer).run { _ in }
        XCTAssertEqual(TranscriptFormatter.text(for: diarized.segments), "[Participante 1]: solo")
        XCTAssertNil(diarized.quality?.remoteSpeakerCount, "a successful diarization of mic-only audio cannot name the calendar peer")
        XCTAssertNotNil(diarized.quality?.channels.single)
        let calls = await recognizer.calls
        XCTAssertEqual(calls, 1, "one channel, one chunk")
    }

    /// Every chunk decoded with no words is silence: terminal, not the
    /// retryable `emptyOutput` reserved for chunks that all failed.
    func testNoWordsInAnyChunkIsNoSpeech() async throws {
        let dir = TestSupport.makeTempDir(self, "job-no-speech")
        let audio = try capture(dir, left: WAVFixture.tone(seconds: 2), right: gio(2))
        let job = TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es", diarize: false,
                                   recognizer: FakeRecognizer { _, _ in [] }, diarizer: FakeDiarizer([]))
        do {
            _ = try await job.run { _ in }
            XCTFail("expected noSpeech")
        } catch TranscriptionError.noSpeech {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
    }

    /// The capture writes the mic to R and silence to L (AudioCaptureService).
    func testMicOnlyCaptureTranscribesTheMicChannel() throws {
        let dir = TestSupport.makeTempDir(self, "job-miconly")
        let audio = try capture(dir, left: [Int16](repeating: 0, count: 16_000), right: gio(1), strategy: "mic-only")
        let work = dir + "/work"
        try AppPaths.ensurePrivateDirectory(work)
        let layout = try ChannelReader.prepare(audioPath: audio, captureSampleRate: 16_000, workDirectory: work)
        XCTAssertEqual(layout, .single(URL(fileURLWithPath: work + "/mic.wav")))
        XCTAssertNil(layout.mic)
        let file = try AVAudioFile(forReading: layout.remote, commonFormat: .pcmFormatInt16, interleaved: false)
        XCTAssertEqual(try ChunkedTranscription.readSamples(file, from: 0, to: 16_000), gio(1))
        ChannelReader.cleanup(layout, original: audio)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work), [])
    }

    func testImported16kWAVIsReadInPlaceAndKept() throws {
        let dir = TestSupport.makeTempDir(self, "job-import")
        let wav = URL(fileURLWithPath: dir + "/import.wav")
        try WAVFixture.write(gio(1), to: wav)
        let layout = try ChannelReader.prepare(audioPath: wav.path, captureSampleRate: 48_000, workDirectory: dir)
        XCTAssertEqual(layout, .single(wav))
        ChannelReader.cleanup(layout, original: wav.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
    }

    func testLegacyWhisperCheckpointsAreDiscarded() async throws {
        let dir = TestSupport.makeTempDir(self, "job-legacy")
        let audio = try capture(dir, left: WAVFixture.tone(seconds: 2), right: gio(2))
        let work = ChunkedTranscription.workDirectory(forAudio: audio)
        try AppPaths.ensurePrivateDirectory(work)
        TestSupport.write(#"{"version":1,"audioBytes":1,"boundaries":[0,1]}"#, to: work + "/manifest.json")
        TestSupport.write(#"[{"start":0,"end":1,"text":"whisper viejo"}]"#, to: work + "/chunk-000.json")
        let outcome = try await TranscriptionJob(audioPath: audio, captureSampleRate: 16_000, language: "es",
                                                 diarize: false,
                                                 recognizer: FakeRecognizer { _, _ in [Segment(start: 0, end: 1, text: "nuevo")] },
                                                 diarizer: FakeDiarizer([])).run { _ in }
        XCTAssertFalse(outcome.segments.map(\.text).contains("whisper viejo"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/chunk-000.json"))
    }

    func testDiarizationCancellationDoesNotPublishFallbackOrCacheAndCanResume() async throws {
        let dir = TestSupport.makeTempDir(self, "job-cancel-diarization")
        let wav = URL(fileURLWithPath: dir + "/import.wav")
        try WAVFixture.write(WAVFixture.tone(seconds: 1), to: wav)
        let original = try Data(contentsOf: wav)
        let recognizer = FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "No")] }
        let work = ChunkedTranscription.workDirectory(forAudio: wav.path)
        do {
            _ = try await TranscriptionJob(audioPath: wav.path, captureSampleRate: 16_000, language: "es",
                                           diarize: true, recognizer: recognizer,
                                           diarizer: FakeDiarizer([], throwsCancellation: true)).run { _ in }
            XCTFail("cancellation must not become a successful undiarized transcript")
        } catch is CancellationError {}
        let cancelledReleases = await recognizer.releases
        XCTAssertEqual(cancelledReleases, 1, "a cancellation after ASR must release its model hold exactly once")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work + "/diarization.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work + "/remote/chunk-000.json"),
                      "completed ASR stays recoverable when the later diarization is cancelled")
        let resumed = FakeRecognizer { _, _ in throw FakeEngineError() }
        let outcome = try await TranscriptionJob(
            audioPath: wav.path, captureSampleRate: 16_000, language: "es", diarize: true,
            recognizer: resumed, diarizer: FakeDiarizer([SpeakerSpan(start: 0, end: 1, speaker: "A")])).run { _ in }
        XCTAssertEqual(TranscriptFormatter.text(for: outcome.segments), "[Participante 1]: No")
        XCTAssertNotNil(outcome.quality?.channels.single)
        XCTAssertNil(outcome.quality?.remoteSpeakerCount, "a mono import is not proven remote audio")
        let calls = await resumed.calls
        XCTAssertEqual(calls, 0, "resume uses the completed ASR, not a silently cancelled diarization cache")
        let resumedReleases = await resumed.releases
        XCTAssertEqual(resumedReleases, 1, "successful checkpoint recovery also releases its model hold")
        XCTAssertEqual(try Data(contentsOf: wav), original)
    }

    func testSameSizeAudioChangeInvalidatesDiarizationAsWellAsWords() async throws {
        let dir = TestSupport.makeTempDir(self, "job-stale-diarization")
        let wav = URL(fileURLWithPath: dir + "/import.wav")
        var samples = WAVFixture.tone(seconds: 1)
        try WAVFixture.write(samples, to: wav)
        let diarizer = FakeDiarizer([SpeakerSpan(start: 0, end: 1, speaker: "A")])
        let job = TranscriptionJob(
            audioPath: wav.path, captureSampleRate: 16_000, language: "es", diarize: true,
            recognizer: FakeRecognizer { _, _ in [Segment(start: 0, end: 0.5, text: "word")] }, diarizer: diarizer)
        _ = try await job.run { _ in }
        samples[samples.count - 1] += 1
        try WAVFixture.write(samples, to: wav)
        let changed = try Data(contentsOf: wav)
        _ = try await job.run { _ in }
        let calls = await diarizer.calls
        XCTAssertEqual(calls, 2, "the same byte count does not prove this is the diarized audio")
        XCTAssertEqual(try Data(contentsOf: wav), changed)
    }
}
