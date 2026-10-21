// Opt-in acceptance check. Uses the actual AppState, capture, ASR, SQLite and
// handoff; never the UI fixture or injected recognizer/recording implementations.
import AppKit
import CryptoKit
import Foundation
import SwiftUI

public enum RealPipelineCheck {
    @MainActor
    public static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["MEETCAPTURE_REAL_CHECK"] else { return false }
        var reportURL: URL?
        do {
            guard ["import", "capture", "ui"].contains(mode),
                  let output = env["MEETCAPTURE_TEST_OUTPUT_DIR"],
                  let input = env["MEETCAPTURE_CHECK_INPUT"],
                  let report = env["MEETCAPTURE_CHECK_REPORT"] else {
                throw CheckError.failed("mode, input WAV, isolated output and report are required")
            }
            let root = URL(fileURLWithPath: output).resolvingSymlinksInPath()
            let allowed = [URL(fileURLWithPath: "/tmp"), FileManager.default.temporaryDirectory]
            guard allowed.contains(where: { root.path.hasPrefix($0.resolvingSymlinksInPath().path + "/") }) else {
                throw CheckError.failed("output must be a new temporary directory")
            }
            // Resolve the existing parent: Foundation strips /private only
            // from paths that exist, so the new report file would not match.
            let requested = URL(fileURLWithPath: report)
            let target = requested.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(requested.lastPathComponent)
            guard target.path.hasPrefix(root.path + "/"),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent("meetcapture.db").path),
                  !FileManager.default.fileExists(atPath: target.path) else {
                throw CheckError.failed("report must be inside fresh output; existing results are never reused")
            }
            if FileManager.default.fileExists(atPath: root.path),
               !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty {
                throw CheckError.failed("output directory must be empty")
            }
            try AppPaths.ensurePrivateDirectory(root.path)
            reportURL = target
            let source = URL(fileURLWithPath: input).resolvingSymlinksInPath()
            guard PCMToWAV.is16kMonoWAV(source.path), PCMToWAV.wavDurationSeconds(source.path) > 0 else {
                throw CheckError.failed("input must be nonempty 16 kHz mono Int16 WAV")
            }
            // Highest-priority volatile domain: no user's saved preferences are
            // changed, and every operational setting is explicit for this run.
            var settings = Settings.defaults
            settings[Settings.Key.asrLanguage.rawValue] = env["MEETCAPTURE_CHECK_LANGUAGE"] ?? "es"
            settings[Settings.Key.notifyHermes.rawValue] = false
            settings[Settings.Key.autoRecord.rawValue] = false
            settings[Settings.Key.diarize.rawValue] = env["MEETCAPTURE_CHECK_DIARIZE"] == "1"
            settings[Settings.Key.micOnlyMode.rawValue] = env["MEETCAPTURE_CHECK_MIC_ONLY"] == "1"
            settings[Settings.Key.retention.rawValue] = RetentionPolicy.keep.rawValue
            UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)
            let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": root.path], home: root.path)
            let app = AppState(paths: paths, store: MeetingStore(path: paths.databasePath), errorDismissalDelay: 300)
            app.hasAudioPermission = app.audioCapture.checkPermission()
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            if mode == "ui" {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.title = "MeetCapture · Real pipeline"
                window.isReleasedWhenClosed = false
                // SettingsView intentionally edits the normal preferences and
                // summary configuration; this check only exercises the pipeline.
                window.contentView = NSHostingView(rootView: PopoverContent(appState: app, allowsSettings: false))
                window.center()
                application.setActivationPolicy(.regular)
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
                FileHandle.standardOutput.write(Data("REAL_UI_READY (no acceptance result yet)\n".utf8))
                withExtendedLifetime(window) { application.run() }
                return true
            }
            Task { @MainActor in
                do {
                    let result = try await run(app, mode: mode, source: source)
                    finish(result, to: target, code: 0)
                } catch {
                    let blocked: Bool
                    if case CheckError.blocked = error { blocked = true } else { blocked = false }
                    finish(["status": blocked ? "blocked" : "failed", "mode": mode,
                            "error": error.localizedDescription], to: target, code: blocked ? 77 : 1)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 240_000_000_000)
                finish(["status": "failed", "mode": mode, "error": "pipeline exceeded 240 seconds"],
                       to: target, code: 1)
            }
            application.run()
        } catch {
            finish(["status": "failed", "mode": mode, "error": error.localizedDescription],
                   to: reportURL, code: 1)
        }
        return true
    }

    @MainActor
    private static func run(_ app: AppState, mode: String, source: URL) async throws -> [String: Any] {
        let start = Date()
        let originalHash = try digest(source)
        let duration = PCMToWAV.wavDurationSeconds(source.path)
        var capture: [String: Any] = [:]
        if mode == "capture" {
            guard app.audioCapture.checkPermission() else {
                throw CheckError.blocked("microphone permission is not granted to this app")
            }
            guard app.callDetector.activeCallProcessIDs().isEmpty else {
                throw CheckError.blocked("a conferencing application is using audio; capture check postponed")
            }
            app.startRecording()
            // Allow the service's own bounded startup error to reach AppState.
            try await wait(app, seconds: 20) { app.recorder.isRecording }
            try await Task.sleep(nanoseconds: 500_000_000)
            let playback = try await ProcessRunner.run(ProcessSpec(
                executable: "/usr/bin/afplay", arguments: [source.path], timeout: duration + 15))
            guard playback.succeeded else { throw CheckError.failed("afplay failed") }
            try await Task.sleep(nanoseconds: 500_000_000)
            app.stopRecording()
            try await wait(app, seconds: 180) { app.phase == .done }
            guard let raw = app.lastAudioPath,
                  FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: raw)) else {
                throw CheckError.failed("capture or its format sidecar is missing")
            }
            capture = ["capturePath": raw, "droppedCallbacks": app.audioCapture.droppedCallbacks]
        } else {
            await app.importAudio(url: source)
            try requireDone(app)
            let first = try Data(contentsOf: URL(fileURLWithPath: app.lastTranscriptPath!))
            let firstPath = app.lastTranscriptPath!
            await app.importAudio(url: source)
            try requireDone(app)
            await app.retranscribeLastAudio()
            try requireDone(app)
            guard try Data(contentsOf: URL(fileURLWithPath: firstPath)) == first else {
                throw CheckError.failed("earlier transcript was overwritten")
            }
        }
        try requireDone(app)
        guard try digest(source) == originalHash else { throw CheckError.failed("source audio changed") }
        let reopened = MeetingStore(path: app.paths.databasePath)
        let history = reopened.recent(limit: 10)
        guard history.count == (mode == "capture" ? 1 : 3),
              Set(history.map(\.transcriptPath)).count == history.count else {
            throw CheckError.failed("history is incomplete or shares transcript paths")
        }
        let records: [[String: Any]] = try history.map { item in
            let data = try Data(contentsOf: URL(fileURLWithPath: item.transcriptPath))
            let pending = app.paths.meetingsDir + "/" + item.id + ".pending"
            let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: pending))) as? [String: Any]
            let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard contract?["checksum"] as? String == checksum,
                  contract?["transcriptPath"] as? String == item.transcriptPath,
                  FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: item.transcriptPath)) else {
                throw CheckError.failed("handoff, transcript, or marker disagree")
            }
            return ["id": item.id, "transcriptPath": item.transcriptPath, "pendingPath": pending,
                    "text": String(decoding: data, as: UTF8.self), "engine": item.engine,
                    "model": item.model, "durationSec": item.durationSec]
        }
        let text = app.lastSegments.map(\.text).joined(separator: " ")
        if let word = app.lastSegments.first?.text.split(whereSeparator: { !$0.isLetter }).first {
            guard !reopened.search(String(word)).isEmpty else { throw CheckError.failed("history search cannot find recognized speech") }
        }
        var result: [String: Any] = ["status": "passed", "mode": mode, "text": text,
            "inputDurationSec": duration, "elapsedSec": Date().timeIntervalSince(start),
            "historyCount": history.count, "records": records, "diarize": Settings.diarize,
            "speakers": PendingContractV2.speakers(of: app.lastSegments),
            "micOnly": Settings.micOnlyMode]
        result.merge(capture) { _, new in new }
        return result
    }

    /// Check integrity without retaining a second meeting-sized audio buffer.
    private static func digest(_ source: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty {
            hash.update(data: block)
        }
        return hash.finalize()
    }

    @MainActor
    private static func requireDone(_ app: AppState) throws {
        guard app.phase == .done, app.errorMessage == nil, app.lastTranscriptPath != nil else {
            throw CheckError.failed(app.errorMessage ?? "pipeline did not finish")
        }
    }

    @MainActor
    private static func wait(_ app: AppState, seconds: TimeInterval, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if let error = app.errorMessage { throw CheckError.failed(error) }
            if Date() >= deadline { throw CheckError.failed("timed out waiting for pipeline state") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func finish(_ report: [String: Any], to url: URL?, code: Int32) -> Never {
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            if let url { try data.write(to: url, options: .atomic) }
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("report write failed: \(error)\n".utf8))
            exit(1)
        }
        exit(code)
    }

    private enum CheckError: LocalizedError {
        case failed(String), blocked(String)
        var errorDescription: String? {
            switch self { case .failed(let text), .blocked(let text): return text }
        }
    }
}
