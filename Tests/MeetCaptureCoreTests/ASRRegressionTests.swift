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

    func testParakeetTokensBecomeTimedWords() {
        func t(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
            TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 1)
        }
        let words = ParakeetEngine.words(from: [
            t("▁Ho", 0.0, 0.2), t("la", 0.2, 0.4), t(",", 0.4, 0.45),
            t("▁", 0.5, 0.5), t("CE", 0.6, 0.7), t("DEAR", 0.7, 0.9),
            t(" mañana", 1.0, 1.4), t(".", 1.4, 1.5),
        ])
        XCTAssertEqual(words, [Segment(start: 0, end: 0.45, text: "Hola,"),
                               Segment(start: 0.6, end: 0.9, text: "CEDEAR"),
                               Segment(start: 1.0, end: 1.5, text: "mañana.")])
        XCTAssertEqual(ParakeetEngine.words(from: []), [])
    }
}
