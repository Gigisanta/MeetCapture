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
        let keys = [Settings.Key.maxRecordingDuration, .asrLanguage, .retention]
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
        store.set("", forKey: Settings.Key.asrLanguage.rawValue)
        XCTAssertEqual(Settings.asrLanguage, Settings.Default.asrLanguage, "empty language falls back to the default")
        store.set("en", forKey: Settings.Key.asrLanguage.rawValue)
        XCTAssertEqual(Settings.asrLanguage, "en")
        store.set("bogus", forKey: Settings.Key.retention.rawValue)
        XCTAssertEqual(Settings.retention, .keep24h, "the default keeps a day to retranscribe")
        store.set("deleteAfterHandoff", forKey: Settings.Key.retention.rawValue)
        XCTAssertEqual(Settings.retention, .deleteAfterHandoff)
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
    }

    func testLocalConfigParsingIsTolerant() {
        XCTAssertEqual(LocalConfig.parse(Data("[]".utf8)), .empty)
        XCTAssertEqual(LocalConfig.parse(Data("{".utf8)), .empty)
        let json = #"{"whitelistedEmails":[" A@B.com ","", "c@d.e"],"aliases":{"AppSheet":["app sheet"," "],"CEDEAR":"sedear"," ":["x"],"FCI":7},"domainPrompt":"obra","extra":1}"#
        let c = LocalConfig.parse(Data(json.utf8))
        XCTAssertEqual(c.whitelistedEmails, ["a@b.com", "c@d.e"])
        XCTAssertEqual(c.aliases, ["AppSheet": ["app sheet"], "CEDEAR": ["sedear"], "FCI": []],
                       "a string is one variant; blanks and non-strings are dropped")
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
