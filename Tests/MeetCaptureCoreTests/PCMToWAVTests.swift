import XCTest
import CryptoKit
@testable import MeetCaptureCore

final class PCMToWAVTests: XCTestCase {
    func testDurationReadsActualAfconvertWAVWithExtraChunks() async throws {
        let dir = TestSupport.makeTempDir(self, "wav-real-afconvert")
        let source = dir + "/source.wav"
        var data = PCMToWAV.header(dataSize: 32_000)
        data.append(Data(repeating: 0, count: 32_000))
        try data.write(to: URL(fileURLWithPath: source))
        let output = dir + "/afconvert.wav"
        try await ProcessRunner.runChecked(ProcessSpec(executable: "/usr/bin/afconvert",
            arguments: [source, output, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"], timeout: 10))
        XCTAssertTrue(PCMToWAV.is16kMonoWAV(output))
        XCTAssertEqual(PCMToWAV.wavDurationSeconds(output), 1, accuracy: 0.0001)
        TestSupport.write("not a WAV", to: dir + "/invalid.wav")
        XCTAssertFalse(PCMToWAV.is16kMonoWAV(dir + "/invalid.wav"))
        XCTAssertEqual(PCMToWAV.wavDurationSeconds(dir + "/invalid.wav"), 0)
}
    func testTempURLsAreUniqueAndInterpolated() {
        let a = PCMToWAV.makeTempURL(), b = PCMToWAV.makeTempURL()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.lastPathComponent.contains("\\("), "UUID must be interpolated, not escaped")
        XCTAssertTrue(a.lastPathComponent.hasPrefix("meetcapture-whole-"))
        XCTAssertEqual(a.pathExtension, "wav")
    }

    func testFloat32MonoIsResampledTo16kInt16WithValidHeader() throws {
        let dir = TestSupport.makeTempDir(self, "wav")
        let input = dir + "/in.pcm"
        // 1 s of 48 kHz float32 sine at 440 Hz.
        var samples = [Float](repeating: 0, count: 48_000)
        for i in samples.indices { samples[i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: input))

        let out = URL(fileURLWithPath: dir + "/out.wav")
        try PCMToWAV.convert(inputPath: input, format: .float32Mono(sampleRate: 48_000), outputURL: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(data.count, PCMToWAV.headerSize + 16_000 * 2)
        XCTAssertTrue(PCMToWAV.is16kMonoWAV(out.path))
        XCTAssertEqual(PCMToWAV.wavDurationSeconds(out.path), 1.0, accuracy: 0.001)
        let b = [UInt8](data.prefix(44))
        XCTAssertEqual(String(decoding: b[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: b[8..<12], as: UTF8.self), "WAVE")
        let dataSize = UInt32(b[40]) | UInt32(b[41]) << 8 | UInt32(b[42]) << 16 | UInt32(b[43]) << 24
        XCTAssertEqual(dataSize, 32_000, "data chunk size must be patched after streaming")
    }

    func testInt16StereoIsSummedToMono() throws {
        let dir = TestSupport.makeTempDir(self, "wav2")
        let input = dir + "/in.pcm"
        // 10 frames at 16 kHz: L = 1000, R = 3000 → mono 4000 (sum, not average).
        var frames = [Int16]()
        for _ in 0..<10 { frames += [1000, 3000] }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: URL(fileURLWithPath: input))
        let out = URL(fileURLWithPath: dir + "/out.wav")
        try PCMToWAV.convert(inputPath: input, format: .int16Interleaved(channels: 2, sampleRate: 16_000), outputURL: out)
        let data = try Data(contentsOf: out)
        let mono = data.dropFirst(PCMToWAV.headerSize).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(mono.count, 10)
        XCTAssertEqual(Set(mono), [4000])
    }

    func testSidecarSelectsInputFormat() throws {
        let dir = TestSupport.makeTempDir(self, "sidecar")
        let audio = dir + "/recording-1.pcm"
        TestSupport.write("", to: audio)
        XCTAssertEqual(PCMToWAV.inputFormat(forAudio: audio, captureSampleRate: 44_100), .float32Mono(sampleRate: 44_100))
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "x").write(forAudio: audio)
        XCTAssertEqual(PCMToWAV.inputFormat(forAudio: audio, captureSampleRate: 44_100),
                       .int16Interleaved(channels: 2, sampleRate: 16_000))
        let sidecar = try XCTUnwrap(AudioFormatSidecar.read(forAudio: audio))
        XCTAssertEqual(sidecar.schema, AudioFormatSidecar.currentSchema)
        XCTAssertEqual(AudioFormatSidecar.path(forAudio: audio), audio + ".format.json")
    }

    func testPrepareReturnsOriginalFor16kWAVAndCleanupKeepsIt() throws {
        let dir = TestSupport.makeTempDir(self, "prep")
        let wav = dir + "/a.wav"
        var data = PCMToWAV.header(dataSize: 4)
        data.append(contentsOf: [0, 0, 0, 0])
        try data.write(to: URL(fileURLWithPath: wav))
        let url = try PCMToWAV.prepare(audioPath: wav, captureSampleRate: 48_000)
        XCTAssertEqual(url.path, wav)
        PCMToWAV.cleanup(url, original: wav)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav), "passthrough input must not be deleted")
    }

    func testStreamingResamplerPreservesBaselinePCMBytes() throws {
        let dir = TestSupport.makeTempDir(self, "wav-golden")
        let floatInput = dir + "/float.pcm"
        let floatSamples = (0..<200_004).map { i in
            Float((i * 7_919 % 60_001) - 30_000) / 32_767
        }
        try floatSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: floatInput))
        let floatOutput = URL(fileURLWithPath: dir + "/float.wav")
        try PCMToWAV.convert(inputPath: floatInput,
                             format: .float32Mono(sampleRate: 48_000), outputURL: floatOutput)

        let int16Input = dir + "/stereo.pcm"
        var frames: [Int16] = []
        frames.reserveCapacity(200_004 * 2)
        for i in 0..<200_004 {
            frames.append(Int16((i * 97 % 60_001) - 30_000))
            frames.append(Int16((i * 193 % 60_001) - 30_000))
        }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: int16Input))
        let int16Output = URL(fileURLWithPath: dir + "/stereo.wav")
        try PCMToWAV.convert(inputPath: int16Input,
                             format: .int16Interleaved(channels: 2, sampleRate: 48_000),
                             outputURL: int16Output)

        let cases: [(URL, String)] = [
            (floatOutput, "93ae88b5c07ab708e40b9329242e216b0cb95b60973d780bdb0beedcaa6467af"),
            (int16Output, "ef9a7b7425199d9e149a422bb39902f37f4ee614002262f9f7484ccb3e9387ba"),
        ]
        for (output, expectedSHA256) in cases {
            let data = try Data(contentsOf: output)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hash, expectedSHA256)
            XCTAssertTrue(PCMToWAV.is16kMonoWAV(output.path))
            XCTAssertEqual(data.count, PCMToWAV.headerSize + 66_668 * 2)
            XCTAssertEqual(PCMToWAV.wavDurationSeconds(output.path), 66_668.0 / 16_000, accuracy: 0.000_001)
        }
    }

    func testStreamingOutputLengthIsFlooredForBothPCMFormats() throws {
        let dir = TestSupport.makeTempDir(self, "wav-output-floor")
        let floatInput = dir + "/float.pcm"
        let floatSamples: [Float] = [0.25, 0.5, -0.25, -0.5, 0.75]
        try floatSamples.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: floatInput))
        let floatOutput = URL(fileURLWithPath: dir + "/float.wav")
        try PCMToWAV.convert(inputPath: floatInput,
                             format: .float32Mono(sampleRate: 48_000), outputURL: floatOutput)

        let int16Input = dir + "/stereo.pcm"
        var frames: [Int16] = []
        for _ in 0..<5 { frames += [1_000, 3_000] }
        try frames.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: int16Input))
        let int16Output = URL(fileURLWithPath: dir + "/stereo.wav")
        try PCMToWAV.convert(inputPath: int16Input,
                             format: .int16Interleaved(channels: 2, sampleRate: 48_000),
                             outputURL: int16Output)

        for output in [floatOutput, int16Output] {
            let data = try Data(contentsOf: output)
            XCTAssertEqual(data.count, PCMToWAV.headerSize + 2)
            XCTAssertTrue(PCMToWAV.is16kMonoWAV(output.path))
            XCTAssertEqual(PCMToWAV.wavDurationSeconds(output.path), 1.0 / 16_000, accuracy: 0.000_000_1)
        }
        let stereoBytes = try Data(contentsOf: int16Output).dropFirst(PCMToWAV.headerSize)
        XCTAssertEqual(stereoBytes.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }.littleEndian, 4_000)
    }

    func testInvalidFloatStreamsAreRejectedAndPreparedOutputRollsBack() throws {
        let dir = TestSupport.makeTempDir(self, "wav-invalid-float")
        let tempDir = FileManager.default.temporaryDirectory
        func preparedWAVs() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(at: tempDir,
                                                              includingPropertiesForKeys: nil)
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix("meetcapture-whole-") && $0.hasSuffix(".wav") })
        }

        let before = try preparedWAVs()
        let truncated = dir + "/truncated.pcm"
        try Data([0x00, 0x01, 0x02]).write(to: URL(fileURLWithPath: truncated))
        XCTAssertThrowsError(try PCMToWAV.prepare(audioPath: truncated, captureSampleRate: 48_000)) { error in
            guard let conversionError = error as? PCMToWAV.ConversionError,
                  case .invalidData = conversionError else {
                return XCTFail("expected invalidData for a truncated float sample, got \(error)")
            }
        }
        XCTAssertEqual(try preparedWAVs(), before, "failed preparation must remove its partial WAV")

        let nonFinite = dir + "/nan.pcm"
        var samples = [Float](repeating: 0.25, count: 40_000)
        samples[20_000] = .nan
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }
            .write(to: URL(fileURLWithPath: nonFinite))
        XCTAssertThrowsError(try PCMToWAV.prepare(audioPath: nonFinite, captureSampleRate: 48_000)) { error in
            guard let conversionError = error as? PCMToWAV.ConversionError,
                  case .invalidData = conversionError else {
                return XCTFail("expected invalidData for NaN PCM, got \(error)")
            }
        }
        XCTAssertEqual(try preparedWAVs(), before, "failed preparation must roll back its partial WAV")
    }

}
