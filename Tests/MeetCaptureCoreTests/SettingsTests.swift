import XCTest
@testable import MeetCaptureCore

final class SettingsTests: XCTestCase {
    func testEveryKeyHasARegisteredDefault() {
        let defaults = Settings.defaults
        for key in Settings.Key.allCases {
            XCTAssertNotNil(defaults[key.rawValue], "missing default for \(key)")
        }
        XCTAssertEqual(defaults.count, Settings.Key.allCases.count)
    }

    func testClampsAndFallbacks() {
        let store = UserDefaults.standard
        let keys = [Settings.Key.maxRecordingDuration, .liveIdleUnloadMinutes, .asrModel, .engine, .retention]
        let saved: [String: Any] = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            store.object(forKey: key.rawValue).map { (key.rawValue, $0) }
        })
        defer {
            for key in keys {
                if let value = saved[key.rawValue] { store.set(value, forKey: key.rawValue) }
                else { store.removeObject(forKey: key.rawValue) }
            }
        }
        store.set(60.0, forKey: Settings.Key.maxRecordingDuration.rawValue)
        XCTAssertEqual(Settings.maxRecordingDuration, 1_800)
        store.set(999_999.0, forKey: Settings.Key.maxRecordingDuration.rawValue)
        XCTAssertEqual(Settings.maxRecordingDuration, 28_800)
        store.set(-5, forKey: Settings.Key.liveIdleUnloadMinutes.rawValue)
        XCTAssertEqual(Settings.liveIdleUnloadMinutes, 0)
        store.set("garbage", forKey: Settings.Key.engine.rawValue)
        XCTAssertEqual(Settings.engine, .whisper)
        store.set("sherpa", forKey: Settings.Key.engine.rawValue)
        store.set("  ", forKey: Settings.Key.asrModel.rawValue)
        XCTAssertEqual(Settings.asrModel, "zipformer-es", "empty model falls back per engine")
        store.set(Settings.Default.asrModel, forKey: Settings.Key.asrModel.rawValue)
        XCTAssertEqual(Settings.asrModel, "zipformer-es", "a persisted Whisper default cannot disable Sherpa")
        store.set("/tmp/custom-sherpa-model", forKey: Settings.Key.asrModel.rawValue)
        XCTAssertEqual(Settings.asrModel, "/tmp/custom-sherpa-model", "custom selections must survive")
        store.set("whisper", forKey: Settings.Key.engine.rawValue)
        store.set("zipformer-en", forKey: Settings.Key.asrModel.rawValue)
        XCTAssertEqual(Settings.asrModel, Settings.Default.asrModel, "switching back also resolves the engine default")
        store.set("bogus", forKey: Settings.Key.retention.rawValue)
        XCTAssertEqual(Settings.retention, .deleteAfterHandoff)
        store.set("24h", forKey: Settings.Key.retention.rawValue)
        XCTAssertEqual(Settings.retention, .keep24h)
    }

    func testAppPathsHonourTestOutputDir() {
        let p = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": "/tmp/mc"], home: "/Users/x")
        XCTAssertEqual(p.meetingsDir, "/tmp/mc")
        XCTAssertEqual(p.transcriptsDir, "/tmp/mc")
        XCTAssertEqual(p.importsDir, "/tmp/mc/imports")
        XCTAssertEqual(p.databasePath, "/tmp/mc/meetcapture.db")
        XCTAssertEqual(p.configFile, "/Users/x/.meetcapture/config.json")
        let d = AppPaths(environment: [:], home: "/Users/x")
        XCTAssertEqual(d.meetingsDir, "/Users/x/meetings")
        XCTAssertEqual(d.transcriptsDir, "/Users/x/meetings/transcripts")
        XCTAssertEqual(d.venvPython, "/Users/x/.meetcapture/venv/bin/python3")
        XCTAssertEqual(d.sherpaModelsDir, "/Users/x/.whisper/models/sherpa")
    }

    func testSwitchingToSherpaNormalizesEveryKnownWhisperModel() {
        for size in [WhisperModelSize.tiny, .base, .small, .medium, .large, .largeV3Turbo] {
            for suffix in ["", "-q5_0", "-q5_1", "-q8_0", "-f16"] {
                let model = size.rawValue + suffix
                XCTAssertEqual(Settings.model(for: .sherpa, configured: model), "zipformer-es", model)
            }
        }
        XCTAssertEqual(Settings.model(for: .sherpa, configured: "custom-model"), "custom-model")
        XCTAssertEqual(Settings.model(for: .sherpa, configured: "/models/medium"), "/models/medium")
    }

    func testLocalConfigParsingIsTolerant() {
        XCTAssertEqual(LocalConfig.parse(Data("[]".utf8)), .empty)
        XCTAssertEqual(LocalConfig.parse(Data("{".utf8)), .empty)
        let json = #"{"whitelistedEmails":[" A@B.com ","", "c@d.e"],"domainPrompt":" ","python":"~/venv/bin/python3","extra":1}"#
        let c = LocalConfig.parse(Data(json.utf8))
        XCTAssertEqual(c.whitelistedEmails, ["a@b.com", "c@d.e"])
        XCTAssertNil(c.domainPrompt)
        XCTAssertEqual(c.python, NSHomeDirectory() + "/venv/bin/python3")
        XCTAssertNil(c.scriptsDir)
    }

    func testSummaryConfigMergesIntoExistingFile() throws {
        let dir = TestSupport.makeTempDir(self, "summary")
        let path = dir + "/cfg/summary.json"
        try FileManager.default.createDirectory(atPath: dir + "/cfg", withIntermediateDirectories: true)
        TestSupport.write(#"{"model":"other","custom_key":"keep me","max_tokens":0}"#, to: path)
        var c = SummaryDispatcherConfig.load(path: path)
        XCTAssertEqual(c.model, "other")
        XCTAssertEqual(c.maxTokens, 2000, "non-positive max_tokens falls back to default")
        XCTAssertEqual(c.endpoint, "http://127.0.0.1:8080/v1")
        c.dryRun = true
        c.tagVocabularyDir = "/tmp/notes"
        try c.save(path: path)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(root["custom_key"] as? String, "keep me")
        XCTAssertEqual(root["dry_run"] as? Bool, true)
        XCTAssertEqual(root["model"] as? String, "other")
        XCTAssertEqual(root["tag_vocabulary_dir"] as? String, "/tmp/notes")
        let perms = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms & 0o777, 0o600)
        XCTAssertEqual(SummaryDispatcherConfig.load(path: dir + "/missing.json"), .default)
    }
}
