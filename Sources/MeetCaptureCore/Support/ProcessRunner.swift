// ProcessRunner.swift
// One harness for every external process (whisper-cli, python scripts,
// afconvert): drained pipes, proportional timeout, SIGTERM → SIGKILL,
// timeout detected by terminationReason, task cancellation forwarded.

import Foundation

struct ProcessSpec: Sendable {
    var executable: String
    var arguments: [String]
    /// Seconds before SIGTERM (SIGKILL follows `ProcessRunner.killGrace` later).
    var timeout: TimeInterval
    var environment: [String: String]? = nil

    init(executable: String, arguments: [String], timeout: TimeInterval, environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.environment = environment
    }
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let exitedNormally: Bool

    var succeeded: Bool { !timedOut && exitedNormally && exitCode == 0 }
    var stderrText: String {
        String(decoding: stderr.prefix(4000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProcessRunnerError: LocalizedError {
    case launchFailed(String, underlying: String)
    case timedOut(String, seconds: TimeInterval)
    case failed(String, exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let exe, let underlying):
            return "No se pudo lanzar \(exe): \(underlying)"
        case .timedOut(let exe, let seconds):
            return "\(exe) superó el tiempo máximo (\(Int(seconds)) s)"
        case .failed(let exe, let code, let stderr):
            return "\(exe) terminó con código \(code)\(stderr.isEmpty ? "" : ": \(stderr)")"
        }
    }
}

enum ProcessRunner {
    /// Seconds between SIGTERM and SIGKILL when a process ignores the timeout.
    static let killGrace: TimeInterval = 5

    /// Timeout proportional to the audio being processed: 30 s base plus
    /// 10 s per minute of audio, clamped to 30…600 s.
    static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        let raw = 30.0 + (seconds / 60.0).rounded(.down) * 10.0
        return min(600, max(30, raw))
    }

    /// Runs the process to completion. Launch failures and task cancellation
    /// throw; exit status and timeouts are reported in the result.
    static func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        try Task.checkCancellation()
        let box = RunBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
                launch(spec, box: box, continuation: cont)
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            box.terminate(timedOut: false)
        }
    }

    /// Like `run` but throws unless the process exited 0 within the timeout.
    @discardableResult
    static func runChecked(_ spec: ProcessSpec) async throws -> ProcessResult {
        let result = try await run(spec)
        let name = (spec.executable as NSString).lastPathComponent
        if result.timedOut { throw ProcessRunnerError.timedOut(name, seconds: spec.timeout) }
        guard result.succeeded else {
            throw ProcessRunnerError.failed(name, exitCode: result.exitCode, stderr: result.stderrText)
        }
        return result
    }

    // MARK: - Internals

    private final class RunBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var processGroup: Int32?
        private var finished = false
        private(set) var didTimeOut = false
        private var terminationRequested = false

        func attach(_ p: Process) {
            lock.lock()
            process = p
            let pid = p.processIdentifier
            // Foundation gives a launched process its own group on macOS.
            // Verify ownership before ever signaling a group. The leader may
            // already have exited while a child still owns an output pipe.
            if pid > 0, pid != getpgrp(),
               getpgid(pid) == pid || (!p.isRunning && kill(-pid, 0) == 0) {
                processGroup = pid
            }
            let mustTerminate = terminationRequested
            lock.unlock()
            // Cancellation can arrive between process.run() and attach().
            if mustTerminate { terminate(timedOut: false) }
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return didTimeOut
        }

        /// SIGTERM now, SIGKILL after `killGrace` if still alive.
        func terminate(timedOut: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            terminationRequested = true
            if timedOut { didTimeOut = true }
            lock.unlock()
            sendSignal(SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGrace) {
                self.sendSignal(SIGKILL)
            }
        }

        private func sendSignal(_ signal: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard !finished, let process else { return }
            if let group = processGroup {
                kill(-group, signal)
            } else if process.isRunning {
                kill(process.processIdentifier, signal)
            }
        }

        func finish() {
            lock.lock(); defer { lock.unlock() }
            finished = true
            processGroup = nil
        }
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        func setStdout(_ d: Data) { lock.lock(); out = d; lock.unlock() }
        func setStderr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
        func snapshot() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (out, err) }
    }

    private static func launch(
        _ spec: ProcessSpec, box: RunBox, continuation cont: CheckedContinuation<ProcessResult, Error>
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        if let env = spec.environment { process.environment = env }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe

        let group = DispatchGroup()
        let collector = OutputCollector()
        group.enter()  // termination
        group.enter()  // stdout EOF
        group.enter()  // stderr EOF
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            cont.resume(throwing: ProcessRunnerError.launchFailed(spec.executable, underlying: error.localizedDescription))
            return
        }
        box.attach(process)

        // Blocking reads on their own GCD threads: pipes never fill up, and
        // EOF (child closed its end) marks completion of each stream.
        let readQueue = DispatchQueue.global(qos: .utility)
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        readQueue.async {
            collector.setStdout(outHandle.readDataToEndOfFile())
            group.leave()
        }
        readQueue.async {
            collector.setStderr(errHandle.readDataToEndOfFile())
            group.leave()
        }

        let timeoutItem = DispatchWorkItem { box.terminate(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + spec.timeout, execute: timeoutItem)

        group.notify(queue: .global()) {
            timeoutItem.cancel()
            box.finish()
            let (stdout, stderr) = collector.snapshot()
            cont.resume(returning: ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: box.timedOut,
                exitedNormally: process.terminationReason == .exit))
        }
    }
}
