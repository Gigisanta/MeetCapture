// LiveASRService.swift
// Streams the 16 kHz mono mix to scripts/meetcapture_stream_asr.py over
// stdin and forwards its JSONL partial/final events. Best-effort preview:
// the whole-file engine still produces the final transcript.
//
// One service lives for the whole app. A recording is a "session": the
// child stays warm between sessions, is respawned if it exited, and is
// unloaded by AppState according to LiveASRWarmPolicy.

import Foundation
import os

struct LiveASRSegment: Identifiable, Equatable, Sendable {
    let id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum LiveASRState: Equatable, Sendable {
    case cold
    case warming
    case ready
    case failed(String)
}

final class LiveASRService: @unchecked Sendable {
    var onState: (@Sendable (LiveASRState) -> Void)?
    var onPartial: (@Sendable (String) -> Void)?
    var onFinal: (@Sendable (LiveASRSegment) -> Void)?

    private struct Child {
        let process: Process
        let stdin: FileHandle
        let model: String
        let toolchain: Toolchain
        let generation: UInt64
        var ready = false
    }

    private let lock = NSLock()
    private var child: Child?
    private var pendingBytes = 0
    private var inSession = false
    private var sessionGeneration: UInt64 = 0
    private var childGeneration: UInt64 = 0
    private var drainingOutputGenerations = Set<UInt64>()
    private var restartAttempts = 0
    private var unloadWork: DispatchWorkItem?

    /// ~2 s of 16 kHz mono; beyond this the feed drops instead of blocking.
    private let maxPendingBytes = 64 * 1024
    private let feedQueue: DispatchQueue
    private let logger = AppInfo.logger("LiveASR")

    /// One JSON line per ASR event when MEETCAPTURE_LIVE_ASR_LOG=<path> (tests only).
    private let eventLogPath: String? = {
        let v = ProcessInfo.processInfo.environment["MEETCAPTURE_LIVE_ASR_LOG"]
        return (v?.isEmpty == false) ? v : nil
    }()
    private let eventLogLock = NSLock()
    private var cumulativeSamples = 0

    init(feedQueue: DispatchQueue? = nil) {
        self.feedQueue = feedQueue ?? DispatchQueue(label: AppInfo.bundleID + ".liveasr.feed", qos: .userInitiated)
    }

    private(set) var state: LiveASRState = .cold {
        didSet {
            guard state != oldValue else { return }
            let cb = onState, s = state
            DispatchQueue.main.async { cb?(s) }
        }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return child?.process.isRunning == true
    }

    // MARK: - Lifecycle

    /// Spawns the recognizer (or reuses a live one with the same model).
    func warm(model: String, toolchain: Toolchain) {
        lock.lock()
        unloadWork?.cancel(); unloadWork = nil
        if let child, child.process.isRunning, child.model == model, child.toolchain == toolchain {
            lock.unlock()
            return
        }
        let old = child
        child = nil
        drainingOutputGenerations.removeAll()
        lock.unlock()
        if let old { terminate(old) }
        spawn(model: model, toolchain: toolchain)
    }

    func beginSession(model: String, toolchain: Toolchain) {
        lock.lock()
        inSession = true
        sessionGeneration &+= 1
        restartAttempts = 0
        lock.unlock()
        warm(model: model, toolchain: toolchain)
    }

    /// Ends the recording session. The child stays warm; `unload()` (policy
    /// driven) or a model change is what kills it.
    func endSession() {
        lock.lock()
        inSession = false
        sessionGeneration &+= 1
        restartAttempts = 0
        lock.unlock()
    }

    /// Stops the child without blocking: closes stdin so it drains and
    /// exits on its own; SIGTERM after 3 s if it is still around.
    func unload() {
        lock.lock()
        let old = child
        if let old { drainingOutputGenerations.insert(old.generation) }
        child = nil
        inSession = false
        sessionGeneration &+= 1
        restartAttempts = 0
        lock.unlock()
        if let old { terminate(old) }
        setState(.cold)
    }

    private func terminate(_ child: Child) {
        try? child.stdin.close()
        let process = child.process
        let work = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        lock.lock(); unloadWork = work; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func spawn(model: String, toolchain: Toolchain) {
        guard let python = toolchain.python else {
            fail("python con sherpa-onnx no encontrado"); return
        }
        guard let script = toolchain.script("meetcapture_stream_asr.py") else {
            fail("meetcapture_stream_asr.py no encontrado"); return
        }
        setState(.warming)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script, "--model", model]
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            self.logger.info("live ASR salió (status \(p.terminationStatus))")
            self.lock.lock()
            let current = self.child
            let wasCurrent = current?.process === p
            if wasCurrent { self.child = nil }
            let sessionActive = self.inSession
            let shouldRestart = wasCurrent && sessionActive && p.terminationStatus != 0
                && self.restartAttempts < 1
            if shouldRestart { self.restartAttempts += 1 }
            self.lock.unlock()
            if shouldRestart, let current {
                self.spawn(model: current.model, toolchain: current.toolchain)
            } else if wasCurrent {
                self.setState(sessionActive && p.terminationStatus != 0
                              ? .failed("el reconocedor terminó (status \(p.terminationStatus))") : .cold)
            }
        }
        do {
            try process.run()
        } catch {
            fail("no se pudo lanzar el reconocedor: \(error.localizedDescription)"); return
        }
        lock.lock()
        childGeneration &+= 1
        let generation = childGeneration
        child = Child(process: process, stdin: stdinPipe.fileHandleForWriting, model: model,
                      toolchain: toolchain, generation: generation)
        lock.unlock()

        let out = stdoutPipe.fileHandleForReading
        let readThread = Thread { [weak self] in self?.readLoop(out, generation: generation) }
        readThread.stackSize = AudioCaptureService.workerStackSize
        readThread.name = "meetcapture.liveasr.stdout"
        readThread.qualityOfService = .userInitiated
        readThread.start()

        let err = stderrPipe.fileHandleForReading
        let errThread = Thread { [weak self] in
            let data = (try? err.readToEnd()) ?? Data()
            if let msg = String(data: data, encoding: .utf8), !msg.isEmpty {
                self?.logger.warning("live ASR stderr: \(msg.prefix(400), privacy: .public)")
            }
        }
        errThread.name = "meetcapture.liveasr.stderr"
        errThread.qualityOfService = .utility
        errThread.stackSize = AudioCaptureService.workerStackSize
        errThread.start()
        logger.info("live ASR lanzado (model=\(model, privacy: .public))")
    }

    // MARK: - Feed

    /// 16 kHz mono Int16 samples from the capture pipeline (any thread).
    func feed(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        if eventLogPath != nil {
            eventLogLock.lock()
            cumulativeSamples += samples.count
            let cum = cumulativeSamples
            eventLogLock.unlock()
            appendEventLog("{\"type\": \"feed\", \"samples\": \(samples.count), \"cum\": \(cum)}")
        }
        let data = samples.withUnsafeBytes { Data($0) }
        lock.lock()
        guard inSession, let child,
              pendingBytes >= 0, data.count <= maxPendingBytes - pendingBytes else {
            lock.unlock()
            return
        }
        pendingBytes += data.count
        let sessionGeneration = self.sessionGeneration
        let childGeneration = child.generation
        lock.unlock()
        feedQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.pendingBytes = max(0, self.pendingBytes - data.count)
                self.lock.unlock()
            }
            self.lock.lock()
            let handle = self.inSession && self.sessionGeneration == sessionGeneration &&
                self.child?.generation == childGeneration ? self.child?.stdin : nil
            self.lock.unlock()
            guard let handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                self.logger.warning("feed falló: \(error.localizedDescription, privacy: .public)")
                self.fail("no se pudo enviar audio al reconocedor: \(error.localizedDescription)",
                          generation: childGeneration)
            }
        }
    }

    // MARK: - Output

    private func readLoop(_ handle: FileHandle, generation: UInt64) {
        defer { finishOutputStream(generation) }
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let s = String(data: line, encoding: .utf8) {
                    handleLine(s, generation: generation)
                }
            }
        }
        if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
            handleLine(line, generation: generation)
        }
    }

    private func handleLine(_ line: String, generation: UInt64) {
        appendEventLog(line)
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            lock.lock()
            guard child?.generation == generation else {
                lock.unlock()
                return
            }
            child?.ready = true
            lock.unlock()
            setState(.ready)
        case "partial":
            guard acceptsOutput(generation) else { return }
            guard let raw = obj["text"] as? String else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let cb = onPartial
            DispatchQueue.main.async { cb?(text) }
        case "final":
            guard acceptsOutput(generation) else { return }
            guard let raw = obj["text"] as? String else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = obj["start"] as? Double ?? 0
            let end = obj["end"] as? Double ?? 0
            guard !text.isEmpty, start.isFinite, end.isFinite, start >= 0, end >= start else { return }
            let seg = LiveASRSegment(start: start, end: end, text: text)
            let cb = onFinal
            DispatchQueue.main.async { cb?(seg) }
        case "error":
            fail(obj["message"] as? String ?? "error desconocido", generation: generation)
        default:
            break
        }
    }

    private func setState(_ new: LiveASRState) {
        lock.lock(); state = new; lock.unlock()
    }

    private func acceptsOutput(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return child?.generation == generation || drainingOutputGenerations.contains(generation)
    }

    private func finishOutputStream(_ generation: UInt64) {
        lock.lock()
        drainingOutputGenerations.remove(generation)
        lock.unlock()
    }

    private func fail(_ message: String, generation: UInt64? = nil) {
        logger.error("\(message, privacy: .public)")
        lock.lock()
        if let generation, child?.generation != generation {
            lock.unlock()
            return
        }
        let old = child
        child = nil
        lock.unlock()
        if let old { terminate(old) }
        setState(.failed(message))
    }

    private func appendEventLog(_ line: String) {
        guard let path = eventLogPath else { return }
        let entry = "\(Date().timeIntervalSince1970) \(line)\n"
        eventLogLock.lock(); defer { eventLogLock.unlock() }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(entry.utf8))
        } else {
            _ = try? Data(entry.utf8).write(to: URL(fileURLWithPath: path))
        }
    }
}
