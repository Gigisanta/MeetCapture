// AppPaths.swift
// Every on-disk location the app uses, resolved once. MEETCAPTURE_TEST_OUTPUT_DIR
// redirects all meeting output (recordings, transcripts, .pending, SQLite)
// into one directory for isolated tests.

import Foundation

struct AppPaths: Sendable, Equatable {
    /// Where .pending / .done contracts live; watched by the summary dispatcher.
    let meetingsDir: String
    let transcriptsDir: String
    let importsDir: String
    let databasePath: String
    /// ~/.meetcapture: config.json, summary.json, optional venv.
    let configDir: String
    /// ~/.whisper/models (whisper ggml models + Silero VAD).
    let whisperModelsDir: String

    var configFile: String { configDir + "/config.json" }
    var summaryConfigFile: String { configDir + "/summary.json" }
    var venvPython: String { configDir + "/venv/bin/python3" }
    var sherpaModelsDir: String { whisperModelsDir + "/sherpa" }

    static let current = AppPaths(
        environment: ProcessInfo.processInfo.environment,
        home: FileManager.default.homeDirectoryForCurrentUser.path)

    init(environment: [String: String], home: String) {
        if let testDir = environment["MEETCAPTURE_TEST_OUTPUT_DIR"], !testDir.isEmpty {
            meetingsDir = testDir
            transcriptsDir = testDir
            importsDir = testDir + "/imports"
            databasePath = testDir + "/meetcapture.db"
        } else {
            meetingsDir = home + "/meetings"
            transcriptsDir = home + "/meetings/transcripts"
            importsDir = home + "/meetings/imports"
            databasePath = home + "/meetings/meetcapture.db"
        }
        configDir = home + "/.meetcapture"
        whisperModelsDir = home + "/.whisper/models"
    }

    /// Creates a directory with 0700 permissions if missing.
    static func ensurePrivateDirectory(_ path: String) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return }
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
