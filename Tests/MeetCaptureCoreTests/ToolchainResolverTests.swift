import XCTest
@testable import MeetCaptureCore

final class ToolchainResolverTests: XCTestCase {
    private var dir = ""

    override func setUp() {
        super.setUp()
        dir = TestSupport.makeTempDir(self, "toolchain")
    }

    private func python(_ name: String) -> String {
        let path = dir + "/" + name
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        TestSupport.writeExecutable("exit 0", to: path)
        return path
    }

    private func scripts(_ name: String) -> String {
        let d = dir + "/" + name
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        TestSupport.write("", to: d + "/" + ToolchainResolver.sentinelScript)
        return d
    }

    private func resolve(settingsPython: String? = nil, settingsScripts: String? = nil, config: LocalConfig = .empty,
                         env: [String: String] = [:], bundle: String? = nil, home: String = "/nonexistent") -> Toolchain {
        ToolchainResolver.resolve(settingsPython: settingsPython, settingsScriptsDir: settingsScripts, config: config,
                                  environment: env, bundleResourcePath: bundle,
                                  paths: AppPaths(environment: [:], home: home))
    }

    func testNothingFound() {
        let t = resolve(env: ["PATH": dir + "/empty"])
        XCTAssertEqual(t, .unavailable)
        XCTAssertFalse(t.isUsable)
        XCTAssertEqual(t.pythonDescription, "python: no encontrado")
    }

    func testPrecedenceSettingsConfigEnvironmentVenvPath() {
        let s = python("settings/python3"), c = python("config/python3"), e = python("env/python3")
        let v = python(".meetcapture/venv/bin/python3"), p = python("bin/python3")
        let config = LocalConfig(whitelistedEmails: [], domainPrompt: nil, python: c, scriptsDir: nil)
        let env = ["MEETCAPTURE_PYTHON": e, "PATH": dir + "/bin"]
        XCTAssertEqual(resolve(settingsPython: s, config: config, env: env, home: dir).python, s)
        XCTAssertEqual(resolve(settingsPython: s, config: config, env: env, home: dir).pythonSource, .settings)
        XCTAssertEqual(resolve(config: config, env: env, home: dir).pythonSource, .config)
        XCTAssertEqual(resolve(env: env, home: dir).pythonSource, .environment)
        XCTAssertEqual(resolve(env: ["PATH": dir + "/bin"], home: dir).python, v)
        XCTAssertEqual(resolve(env: ["PATH": dir + "/bin"], home: dir).pythonSource, .venv)
        XCTAssertEqual(resolve(env: ["PATH": dir + "/bin"]).python, p)
        XCTAssertEqual(resolve(env: ["PATH": dir + "/bin"]).pythonSource, .path)
        // A configured path that does not exist is skipped, not trusted.
        XCTAssertEqual(resolve(settingsPython: dir + "/missing", env: ["PATH": dir + "/bin"]).pythonSource, .path)
    }

    func testScriptsPrecedenceAndSentinel() {
        let s = scripts("s1"), c = scripts("s2"), e = scripts("s3"), b = dir + "/bundle"
        try? FileManager.default.createDirectory(atPath: b + "/scripts", withIntermediateDirectories: true)
        let config = LocalConfig(whitelistedEmails: [], domainPrompt: nil, python: nil, scriptsDir: c)
        XCTAssertEqual(resolve(settingsScripts: s, config: config, env: ["MEETCAPTURE_SCRIPTS_DIR": e], bundle: b).scriptsSource, .settings)
        XCTAssertEqual(resolve(config: config, env: ["MEETCAPTURE_SCRIPTS_DIR": e], bundle: b).scriptsSource, .config)
        XCTAssertEqual(resolve(env: ["MEETCAPTURE_SCRIPTS_DIR": e], bundle: b).scriptsDir, e)
        XCTAssertEqual(resolve(bundle: b).scriptsSource, .none, "bundle dir without the sentinel script is ignored")
        TestSupport.write("", to: b + "/scripts/" + ToolchainResolver.sentinelScript)
        let t = resolve(bundle: b)
        XCTAssertEqual(t.scriptsSource, .bundle)
        XCTAssertEqual(t.script(ToolchainResolver.sentinelScript), b + "/scripts/" + ToolchainResolver.sentinelScript)
        XCTAssertNil(t.script("nope.py"))
    }

    func testValidationCachesAndMarksMissingSherpa() async {
        let bad = python("bad/python3")
        TestSupport.writeExecutable("exit 1", to: bad)
        var t = resolve(settingsPython: bad, settingsScripts: scripts("s"))
        XCTAssertTrue(t.isUsable, "usable until validated")
        t = await ToolchainResolver.validated(t)
        XCTAssertEqual(t.pythonHasSherpa, false)
        XCTAssertFalse(t.isUsable)
        XCTAssertTrue(t.pythonDescription.hasSuffix("· sin sherpa_onnx"))
        // Same path + mtime: cached, so a now-succeeding script is not re-run.
        TestSupport.writeExecutable("exit 0", to: bad)
        let mtime = TestSupport.fixedDate
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: bad)
        let again = await ToolchainResolver.validated(resolve(settingsPython: bad))
        XCTAssertEqual(again.pythonHasSherpa, true, "mtime changed → re-validated")
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: bad)
        TestSupport.writeExecutable("exit 1", to: bad)
        try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: bad)
        let cached = await ToolchainResolver.validated(resolve(settingsPython: bad))
        XCTAssertEqual(cached.pythonHasSherpa, true, "same mtime → cached result")
    }

    func testValidationFallsBackToNextPathPythonThatImportsSherpa() async {
        let first = python("path-first/python3")
        let second = python("path-second/python3")
        TestSupport.writeExecutable("exit 1", to: first)
        TestSupport.writeExecutable("exit 0", to: second)
        let scriptsDir = scripts("fallback-scripts")
        let path = dir + "/path-first:" + dir + "/path-second"

        let resolved = resolve(settingsScripts: scriptsDir, env: ["PATH": path])
        XCTAssertEqual(resolved.python, first)
        XCTAssertEqual(resolved.pythonSource, .path)

        let validated = await ToolchainResolver.validated(resolved)
        XCTAssertEqual(validated.python, second)
        XCTAssertEqual(validated.pythonSource, .path)
        XCTAssertEqual(validated.pythonHasSherpa, true)
        XCTAssertTrue(validated.isUsable)
    }

    func testValidationDoesNotFallbackFromInvalidExplicitPython() async {
        let explicit = python("explicit/python3")
        let pathPython = python("path/python3")
        TestSupport.writeExecutable("exit 1", to: explicit)
        TestSupport.writeExecutable("exit 0", to: pathPython)
        let scriptsDir = scripts("explicit-scripts")

        let resolved = resolve(settingsPython: explicit, settingsScripts: scriptsDir,
                               env: ["PATH": dir + "/path"])
        let validated = await ToolchainResolver.validated(resolved)

        XCTAssertEqual(validated.python, explicit)
        XCTAssertEqual(validated.pythonSource, .settings)
        XCTAssertEqual(validated.pythonHasSherpa, false)
        XCTAssertFalse(validated.isUsable)
    }

    func testCancellationDoesNotCacheAnUnverifiedValidationAsFailure() async {
        let candidate = python("cancel-first/python3")
        let fallback = python("cancel-fallback/python3")
        // Exit status is zero, but keep the process alive long enough to
        // cancel ProcessRunner while the import probe is running.
        TestSupport.writeExecutable("sleep 1\nexit 0", to: candidate)
        TestSupport.writeExecutable("exit 0", to: fallback)
        let resolved = resolve(settingsScripts: scripts("cancel-scripts"),
                               env: ["PATH": dir + "/cancel-first:" + dir + "/cancel-fallback"])
        XCTAssertEqual(resolved.python, candidate)

        let cancelledValidation = Task { await ToolchainResolver.validated(resolved) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        cancelledValidation.cancel()
        let cancelled = await cancelledValidation.value

        XCTAssertEqual(cancelled.python, candidate)
        XCTAssertNil(cancelled.pythonHasSherpa)

        let validated = await ToolchainResolver.validated(resolved)
        XCTAssertEqual(validated.python, candidate)
        XCTAssertEqual(validated.pythonHasSherpa, true)
        XCTAssertTrue(validated.isUsable)
    }
}
