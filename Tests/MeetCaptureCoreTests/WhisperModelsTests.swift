import XCTest
@testable import MeetCaptureCore

final class WhisperModelsTests: XCTestCase {
    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = TestSupport.makeTempDir(self, "whisper")
    }

    private func touch(_ name: String) { TestSupport.write("", to: dir + "/" + name) }

    func testFilenamesPerQuant() {
        XCTAssertEqual(WhisperModelSize.medium.filename(quant: .f16), "ggml-medium.bin")
        XCTAssertEqual(WhisperModelSize.medium.filename(quant: .q5_0), "ggml-medium-q5_0.bin")
        XCTAssertEqual(WhisperModelSize.largeV3Turbo.filename(quant: .q5_1), "ggml-large-v3-turbo-q5_1.bin")
        XCTAssertEqual(WhisperModelSize.normalized(from: " medium-q5_0 "), .medium)
        XCTAssertEqual(WhisperModelSize.normalized(from: "large-v3-turbo"), .largeV3Turbo)
        XCTAssertNil(WhisperModelSize.normalized(from: "zipformer-es"))
    }

    func testBestPathPrefersQ5_1ThenQ5_0ThenF16() {
        let models = WhisperModels(directory: dir)
        XCTAssertNil(models.bestPath(for: .medium))
        touch("ggml-medium.bin")
        XCTAssertEqual(models.bestPath(for: .medium), dir + "/ggml-medium.bin")
        touch("ggml-medium-q5_0.bin")
        XCTAssertEqual(models.bestPath(for: .medium), dir + "/ggml-medium-q5_0.bin")
        touch("ggml-medium-q5_1.bin")
        XCTAssertEqual(models.bestPath(for: .medium), dir + "/ggml-medium-q5_1.bin")
    }

    func testSelectionHonoursSettingWhenItFitsElseFallsBack() {
        let models = WhisperModels(directory: dir)
        XCTAssertNil(models.select(setting: "medium", availableMB: 100_000))
        touch("ggml-tiny.bin"); touch("ggml-medium-q5_0.bin"); touch("ggml-large-v3-turbo.bin")
        XCTAssertEqual(models.select(setting: "medium-q5_0", availableMB: 8_000)?.size, .medium)
        XCTAssertEqual(models.select(setting: "large-v3-turbo", availableMB: 8_000)?.size, .largeV3Turbo)
        XCTAssertEqual(models.select(setting: "small", availableMB: 8_000)?.size, .largeV3Turbo, "missing size → largest downloaded that fits")
        XCTAssertEqual(models.select(setting: "medium", availableMB: 500)?.size, .tiny, "low memory → smaller model")
        XCTAssertEqual(models.select(setting: "medium", availableMB: 0)?.size, .tiny, "nothing fits → smallest available")
    }

    func testNewestVADModelIsPicked() {
        let models = WhisperModels(directory: dir)
        XCTAssertNil(models.vadModelPath)
        touch("ggml-silero-v5.1.1.bin"); touch("ggml-silero-v5.1.2.bin"); touch("ggml-medium.bin")
        XCTAssertEqual(models.vadModelPath, dir + "/ggml-silero-v5.1.2.bin")
    }
}
