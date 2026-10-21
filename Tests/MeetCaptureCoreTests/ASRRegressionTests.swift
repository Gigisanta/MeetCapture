import FluidAudio
import XCTest
@testable import MeetCaptureCore

final class ASRRegressionTests: XCTestCase {
    func testFloat32AtTargetRateKeepsTheFinalSample() throws {
        let dir = TestSupport.makeTempDir(self, "asr-last-sample")
        let input = dir + "/one.pcm"
        let samples: [Float] = [0.75]
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: input))
        let output = URL(fileURLWithPath: dir + "/one.wav")

        try PCMToWAV.convert(inputPath: input, format: .float32Mono(sampleRate: 16_000), outputURL: output)

        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, PCMToWAV.headerSize + 2)
        XCTAssertEqual(PCMToWAV.wavDurationSeconds(output.path), 1.0 / 16_000, accuracy: 0.000_001)
    }

    func testInt16ChannelsAreResampledSeparately() throws {
        let dir = TestSupport.makeTempDir(self, "asr-resample")
        let input = dir + "/stereo.pcm"
        var frames: [Int16] = []
        for _ in 0..<3 { frames += [1000, 3000] }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: input))
        let outputs = [URL(fileURLWithPath: dir + "/l.wav"), URL(fileURLWithPath: dir + "/r.wav")]

        try PCMToWAV.convert(inputPath: input,
                             format: .int16Interleaved(channels: 2, sampleRate: 48_000),
                             outputURLs: outputs)

        for (output, expected) in zip(outputs, [Int16(1000), 3000]) {
            let data = try Data(contentsOf: output)
            XCTAssertEqual(data.count, PCMToWAV.headerSize + 2, "three 48 kHz frames become one 16 kHz frame")
            let bytes = [UInt8](data.dropFirst(PCMToWAV.headerSize))
            XCTAssertEqual(Int16(littleEndian: Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)), expected)
        }
    }

    func testTruncatedAndUnknownPCMFormatsFailActionably() throws {
        let dir = TestSupport.makeTempDir(self, "asr-format")
        let truncated = dir + "/truncated.pcm"
        try Data([0x00]).write(to: URL(fileURLWithPath: truncated))
        XCTAssertThrowsError(try PCMToWAV.convert(inputPath: truncated,
                                                   format: .float32Mono(sampleRate: 16_000),
                                                   outputURL: URL(fileURLWithPath: dir + "/bad.wav"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("truncados"))
        }

        let sidecarAudio = dir + "/unknown.pcm"
        TestSupport.write("", to: sidecarAudio)
        let sidecar = AudioFormatSidecar(sampleRate: 16_000, sampleFormat: "s24le", channels: 1,
                                         layout: "mono", tapStrategy: "fixture", tapInfo: "")
        try sidecar.write(forAudio: sidecarAudio)
        XCTAssertEqual(PCMToWAV.inputFormat(forAudio: sidecarAudio, captureSampleRate: 16_000),
                       .unsupported(sampleFormat: "s24le"))
        XCTAssertThrowsError(try ChannelReader.prepare(audioPath: sidecarAudio, captureSampleRate: 16_000,
                                                       workDirectory: dir)) { error in
            XCTAssertTrue(error.localizedDescription.contains("s24le"))
        }
    }

    func testParakeetTokensBecomeTimedWords() throws {
        func t(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
            TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
        }
        let result = ASRResult(text: "Hola, CEDEAR mañana.", confidence: 1, duration: 2, processingTime: 0, tokenTimings: [
            t("▁Ho", 0.0, 0.2), t("la", 0.2, 0.4), t(",", 0.4, 0.45),
            t("▁", 0.5, 0.5), t("CE", 0.6, 0.7), t("DEAR", 0.7, 0.9),
            t(" mañana", 1.0, 1.4), t(".", 1.4, 1.5),
        ])
        let words = try ParakeetEngine.timedWords(from: result)
        XCTAssertEqual(words, [Segment(start: 0, end: 0.45, text: "Hola,"),
                               Segment(start: 0.6, end: 0.9, text: "CEDEAR"),
                               Segment(start: 1.0, end: 1.5, text: "mañana.")])
    }

    func testSDKTextRequiresRealValidTimingsButEmptyOutputIsAllowed() throws {
        let whitespace = TokenTiming(token: "▁", tokenId: 0, startTime: 0, endTime: 0, confidence: 1)
        let missingTimings: [[TokenTiming]?] = [nil, [], [whitespace]]
        for timings in missingTimings {
            let speech = ASRResult(text: "No", confidence: 1, duration: 2, processingTime: 0, tokenTimings: timings)
            XCTAssertThrowsError(try ParakeetEngine.timedWords(from: speech)) { error in
                guard case ParakeetEngine.AdapterError.missingTimedWords = error else {
                    return XCTFail("nonempty SDK text must not become successful silence: \(error)")
                }
            }
            let empty = ASRResult(text: " \n", confidence: 1, duration: 2, processingTime: 0, tokenTimings: timings)
            XCTAssertEqual(try ParakeetEngine.timedWords(from: empty), [])
        }
        for (start, end) in [(Double.nan, 0.2), (-0.1, 0.2), (1.0, 0.5), (0.0, Double.infinity)] {
            // A valid final punctuation token must not hide an invalid interior piece.
            let result = ASRResult(text: "No.", confidence: 1, duration: 2, processingTime: 0, tokenTimings: [
                TokenTiming(token: "▁N", tokenId: 1, startTime: 0, endTime: 0.1, confidence: 1),
                TokenTiming(token: "o", tokenId: 2, startTime: start, endTime: end, confidence: 1),
                TokenTiming(token: ".", tokenId: 3, startTime: 0.3, endTime: 0.4, confidence: 1),
            ])
            XCTAssertThrowsError(try ParakeetEngine.timedWords(from: result)) { error in
                guard case ParakeetEngine.AdapterError.invalidTimedWords = error else {
                    return XCTFail("invalid token timings must fail before word aggregation: \(error)")
                }
            }
        }
    }

    func testModelRevisionTracksActualWeightsAndVocabularyAndFailsClosed() throws {
        let dir = URL(fileURLWithPath: TestSupport.makeTempDir(self, "asr-artifacts"))
        for bundle in ModelNames.ASR.requiredModelsV3() {
            let weights = dir.appendingPathComponent(bundle + "/weights")
            try AppPaths.ensurePrivateDirectory(weights.path)
            try Data([0x11]).write(to: weights.appendingPathComponent("weight.bin"))
        }
        let vocabulary = dir.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        try Data("{}".utf8).write(to: vocabulary)
        let original = try ParakeetEngine.artifactRevision(in: dir)

        let encoder = dir.appendingPathComponent(ModelNames.ASR.encoderFile + "/weights/weight.bin")
        try Data([0x12]).write(to: encoder) // Same byte count, different loaded weights.
        let changedWeights = try ParakeetEngine.artifactRevision(in: dir)
        XCTAssertNotEqual(changedWeights, original)
        try Data("[]".utf8).write(to: vocabulary)
        XCTAssertNotEqual(try ParakeetEngine.artifactRevision(in: dir), changedWeights)

        try FileManager.default.removeItem(at: vocabulary)
        XCTAssertThrowsError(try ParakeetEngine.artifactRevision(in: dir),
                             "an unreadable identity must not become an 'unknown' reusable cache key")
    }
}
