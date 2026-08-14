// LiveASR.swift
// MeetCapture v6.1 — Live in-call streaming transcription.
//
// Streams the captured 16 kHz mono mix (system + mic) to
// scripts/meetcapture_stream_asr.py (sherpa-onnx online recognizer) over
// stdin, and renders its JSONL partial/final events in the popover while
// the call is still running.
//
// Design notes:
//  - Best-effort preview: any failure (missing python/script/model) is
//    reported via onFailure and recording continues unaffected.
//  - The FINAL transcript is still produced by the whole-file engine
//    (whisper/sherpa) for accuracy + diarization; live segments are only
//    a real-time preview (the raw PCM is the durable source of truth).
//  - Feed happens on a dedicated serial queue with a bounded backlog:
//    if the child ever falls behind, samples are dropped instead of
//    blocking the capture write path.

import Foundation
import os

// MARK: - Live ASR Segment

/// One sentence finalized by the streaming recognizer (endpoint-detected).
struct LiveASRSegment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

// MARK: - LiveASRService

final class LiveASRService: @unchecked Sendable {
    var onPartial: (@Sendable (String) -> Void)?
    var onFinal: (@Sendable (LiveASRSegment) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var running = false
    private var pendingBytes = 0
    /// Model the current process was spawned with (for warmup reuse).
    private var warmModel: String?

    /// Max buffered PCM before we drop chunks (~2s of 16 kHz mono).
    /// The streaming recognizer runs at ~0.13 RTF (7.7x realtime), so this
    /// only triggers under pathological system load.
    private let maxPendingBytes = 64 * 1024
    private let feedQueue = DispatchQueue(
        label: "com.meetcapture.liveasr.feed", qos: .userInitiated)
    private let logger = Logger(subsystem: "com.meetcapture", category: "LiveASR")
    /// Optional event log (one JSON line per ASR event). Enabled with
    /// MEETCAPTURE_LIVE_ASR_LOG=<path> — used by tests to verify the live
    /// streaming pipeline end-to-end; nil in normal operation.
    private let eventLogPath: String? = {
        let v = ProcessInfo.processInfo.environment["MEETCAPTURE_LIVE_ASR_LOG"]
        return (v?.isEmpty == false) ? v : nil
    }()
    private let eventLogLock = NSLock()
    private var cumulativeSamples = 0

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    // MARK: - Lifecycle

    /// Warm up the streaming ASR process at app startup (no audio yet).
    /// The python blocks on stdin with zero CPU until the call starts, so
    /// the recognizer (model load ~seconds) is ready before the meeting.
    func warmup(model: String) {
        start(model: model, warm: true)
    }

    /// Start (or reuse) the streaming ASR process. model is a MODEL_REGISTRY
    /// id ("zipformer-es" / "zipformer-en") or a directory path.
    func start(model: String) {
        start(model: model, warm: false)
    }

    private func start(model: String, warm: Bool) {
        lock.lock()
        // Warm process with the same model → just reuse it.
        if running, warmModel == model {
            lock.unlock()
            return
        }
        // Different model or not running → (re)spawn.
        let oldProcess = process
        let oldHandle = stdinHandle
        process = nil
        stdinHandle = nil
        lock.unlock()
        try? oldHandle?.close()
        oldProcess?.terminate()

        lock.lock()
        running = true
        warmModel = model
        lock.unlock()

        let defaults = UserDefaults.standard
        let python =
            defaults.string(forKey: "sherpaPythonPath")
            ?? "/Users/gigi/HerMaatOS/venvs/venv-meet/bin/python3"
        let script = Self.resolveScriptPath(defaults: defaults)

        guard FileManager.default.fileExists(atPath: python) else {
            fail("Live ASR unavailable: python no encontrado (\(python))")
            return
        }
        guard let script, FileManager.default.fileExists(atPath: script) else {
            fail("Live ASR unavailable: meetcapture_stream_asr.py no encontrado")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        // -B: never write __pycache__ inside the signed .app bundle
        proc.arguments = ["-B", script, "--model", model]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.terminationHandler = { [weak self] p in
            self?.logger.info("Live ASR process exited (status \(p.terminationStatus))")
        }

        do {
            try proc.run()
        } catch {
            fail("No se pudo lanzar Live ASR: \(error.localizedDescription)")
            return
        }

        lock.lock()
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        // Drain stdout JSONL on a detached task.
        let outHandle = stdoutPipe.fileHandleForReading
        Task.detached(priority: .userInitiated) { [weak self] in
            self?.readLoop(fileHandle: outHandle)
        }
        // Diagnostics from stderr (bounded tail).
        let errHandle = stderrPipe.fileHandleForReading
        Task.detached(priority: .utility) { [weak self] in
            let data = (try? errHandle.readToEnd()) ?? Data()
            let msg = String(data: data, encoding: .utf8) ?? ""
            if !msg.isEmpty {
                self?.logger.warning("Live ASR stderr: \(msg.prefix(400))")
            }
        }
        logger.info("Live ASR \(warm ? "warmup" : "started") (model=\(model))")
    }

    /// Feed 16 kHz mono Int16 samples (from the capture pipeline).
    func feed(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if eventLogPath != nil {
            eventLogLock.lock()
            cumulativeSamples += samples.count
            let cum = cumulativeSamples
            eventLogLock.unlock()
            appendEventLog("{\"type\": \"feed\", \"samples\": \(samples.count), \"cum\": \(cum)}")
        }
        feedQueue.async { [weak self] in
            guard let self else { return }
            let data = samples.withUnsafeBytes { Data($0) }
            self.lock.lock()
            guard self.running, let handle = self.stdinHandle else {
                self.lock.unlock()
                return
            }
            guard self.pendingBytes + data.count <= self.maxPendingBytes else {
                self.lock.unlock()
                return  // drop: live preview is best-effort
            }
            self.pendingBytes += data.count
            self.lock.unlock()
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.logger.warning("Live ASR feed failed: \(error.localizedDescription)")
            }
            self.lock.lock()
            self.pendingBytes -= data.count
            self.lock.unlock()
        }
    }

    /// Close stdin (child flushes finals and exits), then reap.
    /// Never blocks longer than ~3 s.
    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        let handle = stdinHandle
        stdinHandle = nil
        let proc = process
        process = nil
        lock.unlock()

        try? handle?.close()
        if let proc {
            let deadline = Date().addingTimeInterval(3)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
        }
        logger.info("Live ASR stopped")
    }

    // MARK: - Output parsing

    private func readLoop(fileHandle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = (try? fileHandle.read(upToCount: 4096)) ?? Data()
            if chunk.isEmpty { break }  // EOF
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: line, encoding: .utf8) {
                    handleLine(s)
                }
            }
        }
    }

    private func handleLine(_ line: String) {
        appendEventLog(line)
        guard let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return }
        switch type {
        case "ready":
            logger.info("Live ASR ready (model=\(obj["model"] as? String ?? "?"))")
        case "partial":
            guard let text = obj["text"] as? String else { return }
            let cb = onPartial
            DispatchQueue.main.async { cb?(text) }
        case "final":
            let text = obj["text"] as? String ?? ""
            let start = obj["start"] as? Double ?? 0
            let end = obj["end"] as? Double ?? 0
            let seg = LiveASRSegment(start: start, end: end, text: text)
            logger.info("Live ASR final [\(start)-\(end)] \(text.prefix(100))")
            let cb = onFinal
            DispatchQueue.main.async { cb?(seg) }
        case "error":
            let msg = obj["message"] as? String ?? "error desconocido"
            fail("Live ASR: \(msg)")
        case "done":
            break
        default:
            break
        }
    }

    // MARK: - Event log (test observability)

    private func appendEventLog(_ line: String) {
        guard let path = eventLogPath else { return }
        let entry = "\(Date().timeIntervalSince1970) \(line)\n"
        eventLogLock.lock()
        defer { eventLogLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            _ = try? Data(entry.utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Helpers

    private func fail(_ message: String) {
        logger.error("\(message)")
        lock.lock()
        running = false
        process = nil
        stdinHandle = nil
        lock.unlock()
        let cb = onFailure
        DispatchQueue.main.async { cb?(message) }
    }

    /// Script lookup: scriptsDir setting (repo/dev) → app bundle Resources
    /// (distribution) → repo fallback.
    private static func resolveScriptPath(defaults: UserDefaults) -> String? {
        let name = "meetcapture_stream_asr.py"
        let candidates = [
            defaults.string(forKey: "scriptsDir").map { "\($0)/\(name)" },
            Bundle.main.resourcePath.map { "\($0)/scripts/\(name)" },
            "/Users/gigi/HerMaatOS/work/meetcapture/scripts/\(name)",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
