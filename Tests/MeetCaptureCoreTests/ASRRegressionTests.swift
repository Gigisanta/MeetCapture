import XCTest
@testable import MeetCaptureCore

final class ASRRegressionTests: XCTestCase {
    func testWhisperUsesTheVerifiedBundleBeforeMachineInstallations() {
        let dir = TestSupport.makeTempDir(self, "bundled-whisper")
        let cli = dir + "/whisper-cli"
        TestSupport.writeExecutable("exit 0", to: cli)
        XCTAssertEqual(WhisperCLI.locate(bundleResourcePath: dir)?.executable, cli)
    }

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

    func testInt16InputIsResampledAndMixedBeforeWritingWAV() throws {
        let dir = TestSupport.makeTempDir(self, "asr-resample")
        let input = dir + "/stereo.pcm"
        var frames: [Int16] = []
        for _ in 0..<3 { frames += [1000, 3000] }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: input))
        let output = URL(fileURLWithPath: dir + "/stereo.wav")

        try PCMToWAV.convert(inputPath: input,
                             format: .int16Interleaved(channels: 2, sampleRate: 48_000),
                             outputURL: output)

        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.count, PCMToWAV.headerSize + 2, "three 48 kHz frames become one 16 kHz frame")
        let bytes = [UInt8](data.dropFirst(PCMToWAV.headerSize))
        let sample = Int16(littleEndian: Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
        XCTAssertEqual(sample, 4000)
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
        XCTAssertThrowsError(try PCMToWAV.prepare(audioPath: sidecarAudio, captureSampleRate: 16_000)) { error in
            XCTAssertTrue(error.localizedDescription.contains("s24le"))
        }
    }

    func testWhisperCanonicalOutputDoesNotDuplicateLegacySegments() {
        let json = #"{"transcription":[{"offsets":{"from":0,"to":1000},"text":"uno"}],"segments":[{"start":0,"end":1,"text":"uno"}]}"#
        XCTAssertEqual(SegmentJSON.parseWhisper(Data(json.utf8)),
                       [Segment(start: 0, end: 1, text: "uno")])
    }

    func testWhisperCLIRetriesATransientFakeProcessFailure() async throws {
        let dir = TestSupport.makeTempDir(self, "asr-retry")
        let state = dir + "/attempt"
        let fake = dir + "/fake-whisper"
        TestSupport.writeExecutable("""
            if [ ! -f "\(state)" ]; then
              echo first > "\(state)"
              exit 7
            fi
            out=""
            previous=""
            for arg in "$@"; do
              if [ "$previous" = "-of" ]; then out="$arg.json"; fi
              previous="$arg"
            done
            printf '%s' '{"transcription":[{"offsets":{"from":0,"to":1000},"text":"ok"}]}' > "$out"
            """, to: fake)
        let wav = URL(fileURLWithPath: dir + "/input.wav")
        var data = PCMToWAV.header(dataSize: 2)
        data.append(contentsOf: [0, 0])
        try data.write(to: wav)

        let segments = try await WhisperCLI(executable: fake).transcribe(
            wav: wav, modelPath: "fake-model", language: "es", prompt: "", vadModelPath: nil, threads: 1)

        XCTAssertEqual(segments, [Segment(start: 0, end: 1, text: "ok")])
        XCTAssertEqual(try String(contentsOfFile: state, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "first")
    }
}
