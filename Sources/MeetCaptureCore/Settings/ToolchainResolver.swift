// ToolchainResolver.swift
// Finds the python interpreter (with sherpa-onnx) and the scripts directory
// without any hardcoded per-machine path.
//
//   scripts: Settings › ASR → config.json → $MEETCAPTURE_SCRIPTS_DIR → app bundle
//   python:  Settings › ASR → config.json → $MEETCAPTURE_PYTHON → ~/.meetcapture/venv → PATH
//
// `validated()` additionally checks `import sherpa_onnx` once per
// interpreter (cached by path + mtime, run off the main thread). Automatic
// candidates fall through to the next interpreter when the import fails;
// explicit Settings/config/environment paths remain authoritative.

import Foundation
import os

enum ToolchainSource: String, Sendable {
    case settings = "ajustes"
    case config = "config"
    case environment = "entorno"
    case venv = "venv"
    case bundle = "bundle"
    case path = "PATH"
    case none = "no encontrado"
}

fileprivate struct ToolchainPythonCandidate: Sendable, Equatable {
    let path: String
    let source: ToolchainSource
}

struct Toolchain: Sendable, Equatable {
    var python: String?
    var pythonSource: ToolchainSource
    var scriptsDir: String?
    var scriptsSource: ToolchainSource
    /// nil = not checked yet; false = interpreter lacks sherpa_onnx.
    var pythonHasSherpa: Bool? = nil
    /// All executable candidates in precedence order, retained for validation
    /// so automatic discovery can try the next PATH interpreter if needed.
    fileprivate var pythonCandidates: [ToolchainPythonCandidate]

    init(python: String?, pythonSource: ToolchainSource, scriptsDir: String?, scriptsSource: ToolchainSource,
         pythonHasSherpa: Bool? = nil) {
        self.python = python
        self.pythonSource = pythonSource
        self.scriptsDir = scriptsDir
        self.scriptsSource = scriptsSource
        self.pythonHasSherpa = pythonHasSherpa
        pythonCandidates = []
    }

    static let unavailable = Toolchain(python: nil, pythonSource: .none, scriptsDir: nil, scriptsSource: .none)

    static func == (lhs: Toolchain, rhs: Toolchain) -> Bool {
        lhs.python == rhs.python &&
            lhs.pythonSource == rhs.pythonSource &&
            lhs.scriptsDir == rhs.scriptsDir &&
            lhs.scriptsSource == rhs.scriptsSource &&
            lhs.pythonHasSherpa == rhs.pythonHasSherpa
    }

    /// Absolute path of a script if the scripts dir is known and the file exists.
    func script(_ name: String) -> String? {
        guard let dir = scriptsDir else { return nil }
        let path = dir + "/" + name
        return FileManager.default.isReadableFile(atPath: path) ? path : nil
    }

    /// Ready for diarization: python present (and, if validated, importable) + scripts.
    var isUsable: Bool {
        python != nil && scriptsDir != nil && pythonHasSherpa != false
    }

    var pythonDescription: String {
        guard let python else { return "python: \(ToolchainSource.none.rawValue)" }
        let sherpa = pythonHasSherpa == false ? " · sin sherpa_onnx" : ""
        return "python: \(python) (fuente: \(pythonSource.rawValue))\(sherpa)"
    }

    var scriptsDescription: String {
        guard let scriptsDir else { return "scripts: \(ToolchainSource.none.rawValue)" }
        return "scripts: \(scriptsDir) (fuente: \(scriptsSource.rawValue))"
    }
}

enum ToolchainResolver {
    static let sentinelScript = "speaker_diarize.py"

    static func resolve(
        settingsPython: String? = Settings.sherpaPythonPath,
        settingsScriptsDir: String? = Settings.scriptsDir,
        config: LocalConfig = LocalConfig.load(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourcePath: String? = Bundle.main.resourcePath,
        paths: AppPaths = .current
    ) -> Toolchain {
        var toolchain = Toolchain.unavailable

        let scriptCandidates: [(String?, ToolchainSource)] = [
            (settingsScriptsDir, .settings),
            (config.scriptsDir, .config),
            (environment["MEETCAPTURE_SCRIPTS_DIR"], .environment),
            (bundleResourcePath.map { $0 + "/scripts" }, .bundle),
        ]
        for (dir, source) in scriptCandidates {
            guard let dir = dir.map(LocalConfig.expandTilde), !dir.isEmpty,
                  FileManager.default.isReadableFile(atPath: dir + "/" + sentinelScript)
            else { continue }
            toolchain.scriptsDir = dir
            toolchain.scriptsSource = source
            break
        }

        var pythonCandidates: [(String?, ToolchainSource)] = [
            (settingsPython, .settings),
            (config.python, .config),
            (environment["MEETCAPTURE_PYTHON"], .environment),
            (paths.venvPython, .venv),
        ]
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            pythonCandidates.append((String(dir) + "/python3", .path))
        }
        var resolvedPythonCandidates: [ToolchainPythonCandidate] = []
        var seenPythonPaths = Set<String>()
        for (python, source) in pythonCandidates {
            guard let python = python.map(LocalConfig.expandTilde), !python.isEmpty,
                  FileManager.default.isExecutableFile(atPath: python)
            else { continue }
            guard seenPythonPaths.insert(python).inserted else { continue }
            resolvedPythonCandidates.append(ToolchainPythonCandidate(path: python, source: source))
        }
        if let first = resolvedPythonCandidates.first {
            toolchain.python = first.path
            toolchain.pythonSource = first.source
        }
        toolchain.pythonCandidates = resolvedPythonCandidates
        return toolchain
    }

    // MARK: - Validation (import sherpa_onnx), cached by path + mtime

    private struct CacheEntry { let mtime: Date; let ok: Bool }
    private static let cache = OSAllocatedUnfairLock<[String: CacheEntry]>(initialState: [:])

    static func validated(_ toolchain: Toolchain = resolve()) async -> Toolchain {
        var result = toolchain
        guard let selectedPython = toolchain.python else { return result }
        // A cancelled check leaves the importability unknown. In particular,
        // do not let it become a cached failure or advance to another path.
        result.pythonHasSherpa = nil
        guard !Task.isCancelled else { return result }

        let selected = ToolchainPythonCandidate(path: selectedPython, source: toolchain.pythonSource)
        let candidates = toolchain.pythonCandidates.isEmpty ? [selected] : toolchain.pythonCandidates
        for candidate in candidates {
            guard let ok = await validates(candidate.path), !Task.isCancelled else { return result }
            if ok {
                result.python = candidate.path
                result.pythonSource = candidate.source
                result.pythonHasSherpa = true
                return result
            }
            guard candidate.source == .venv || candidate.source == .path else { break }
        }
        guard !Task.isCancelled else { return result }
        // Keep the highest-precedence selection visible when no candidate is
        // usable. This preserves the configured path for diagnostics and UI.
        result.python = selectedPython
        result.pythonSource = toolchain.pythonSource
        result.pythonHasSherpa = false
        AppInfo.logger("Toolchain").warning("python at \(selectedPython, privacy: .public) cannot import sherpa_onnx")
        return result
    }

    private static func validates(_ python: String) async -> Bool? {
        guard !Task.isCancelled else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: python)[.modificationDate] as? Date) ?? .distantPast
        if let cached = cache.withLock({ $0[python] }), cached.mtime == mtime {
            return cached.ok
        }
        let spec = ProcessSpec(executable: python, arguments: ["-B", "-c", "import sherpa_onnx"], timeout: 30)
        do {
            let processResult = try await ProcessRunner.run(spec)
            guard !Task.isCancelled else { return nil }
            let ok = processResult.succeeded
            cache.withLock { $0[python] = CacheEntry(mtime: mtime, ok: ok) }
            return ok
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            cache.withLock { $0[python] = CacheEntry(mtime: mtime, ok: false) }
            return false
        }
    }
}
