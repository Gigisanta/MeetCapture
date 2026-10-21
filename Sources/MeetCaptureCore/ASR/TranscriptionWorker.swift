// TranscriptionWorker.swift
// One short-lived process owns the models for each transcription. The parent
// keeps stdin open as a lifetime lease and reads versioned JSON from stdout.

import Darwin
import Foundation

private struct WorkerRequest: Codable, Sendable {
    var audioPath: String
    var captureSampleRate: Double
    var language: String
    var diarize: Bool
    var aliases: [String: [String]]

    init(_ job: TranscriptionJob) {
        audioPath = job.audioPath
        captureSampleRate = job.captureSampleRate
        language = job.language
        diarize = job.diarize
        aliases = job.aliases
    }

    var job: TranscriptionJob {
        TranscriptionJob(audioPath: audioPath, captureSampleRate: captureSampleRate,
                         language: language, diarize: diarize, aliases: aliases)
    }
}

private struct WorkerMessage: Codable {
    struct Failure: Codable {
        var kind: String
        var message: String
    }

    var progress: Double? = nil
    var outcome: TranscriptionJob.Outcome? = nil
    var error: Failure? = nil
    static let prefix = Data("MCW1 ".utf8)
}

public enum TranscriptionWorker {
    /// This entry point must precede every app, prefetch and QA mode.
    public static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["MEETCAPTURE_TRANSCRIPTION_WORKER"] == "1" else { return false }
        let output = WorkerOutput()
        let cancellation = WorkerTaskCancellation()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termination.setEventHandler { cancellation.cancel() }
        termination.resume()

        // Do not block a Swift concurrency executor while the parent keeps the
        // pipe open. readLine also preserves any buffered EOF after the request.
        DispatchQueue.global(qos: .userInitiated).async {
            let request: WorkerRequest
            do {
                guard let line = readLine() else {
                    throw TranscriptionWorkerError.failed("Falta el pedido de transcripción")
                }
                request = try JSONDecoder().decode(WorkerRequest.self, from: Data(line.utf8))
            } catch {
                output.finish(WorkerMessage(error: .init(kind: "other", message: "Pedido de transcripción inválido: \(error.localizedDescription)")))
                exit(2)
            }
            let task: Task<Void, Never> = Task.detached(priority: .userInitiated) {
                do {
                    try Task.checkCancellation()
                    let outcome = try await request.job.run { output.progress($0) }
                    try Task.checkCancellation()
                    output.finish(WorkerMessage(outcome: outcome))
                } catch {
                    let kind = Task.isCancelled || error is CancellationError
                        ? "cancelled" : (error as? TranscriptionError)?.rawValue ?? "other"
                    let message = kind == "cancelled" ? "La transcripción fue cancelada" : error.localizedDescription
                    output.finish(WorkerMessage(error: .init(kind: kind, message: message)))
                }
                exit(0)
            }
            cancellation.attach(task)
            while readLine() != nil {}
            cancellation.cancel()
        }
        withExtendedLifetime(termination) { dispatchMain() }
    }
}

private final class WorkerTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let mustCancel = cancelled
        lock.unlock()
        if mustCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
        // The parent may already be dead, so its kill timer cannot help.
        // Core ML/model preparation may not cooperate with cancellation.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            _exit(ECANCELED)
        }
    }
}

private final class WorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var lastProgress: Double?
    private var finished = false

    func progress(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, value.isFinite,
              lastProgress.map({ abs(value - $0) >= 0.01 }) ?? true else { return }
        lastProgress = value
        write(WorkerMessage(progress: value))
    }

    func finish(_ message: WorkerMessage) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        write(message)
    }

    private func write(_ message: WorkerMessage) {
        do {
            var line = WorkerMessage.prefix
            line.append(try encoder.encode(message))
            line.append(0x0A)
            // FileHandle writes directly to the pipe, without stdio buffering.
            try FileHandle.standardOutput.write(contentsOf: line)
        } catch {
            AppInfo.logger("TranscriptionWorker").error("worker protocol: \(error.localizedDescription, privacy: .public)")
            exit(2)
        }
    }
}

enum TranscriptionWorkerError: LocalizedError, Equatable {
    case failed(String)
    case crashed(Int32)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return "No se pudo transcribir: \(message)"
        case .crashed(let status):
            return "El proceso de transcripción terminó sin resultado (código \(status)); se conserva el audio para reintentar"
        }
    }
}

actor TranscriptionWorkerClient {
    static let shared = TranscriptionWorkerClient()

    private struct Waiter {
        var ticket: Ticket
        var continuation: CheckedContinuation<Void, Error>
    }

    private final class Ticket: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private let executableURL: URL?
    private let arguments: [String]
    private let environment: [String: String]
    private let cancellationGrace: TimeInterval
    private var busy = false
    private var waiters: [Waiter] = []

    init(executableURL: URL? = Bundle.main.executableURL, arguments: [String] = [],
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
         cancellationGrace: TimeInterval = 10) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.cancellationGrace = max(0, cancellationGrace)
        let modes: Set<String> = ["MEETCAPTURE_REAL_CHECK", "MEETCAPTURE_PREFETCH_MODELS",
                                  "MEETCAPTURE_UI_TEST", "MEETCAPTURE_LAUNCH_PROBE", "MEETCAPTURE_SNAPSHOT_PATH"]
        var environment = baseEnvironment.filter { !modes.contains($0.key) && !$0.key.hasPrefix("MEETCAPTURE_CHECK_") }
        environment["MEETCAPTURE_TRANSCRIPTION_WORKER"] = "1"
        self.environment = environment
    }

    func run(_ job: TranscriptionJob, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionJob.Outcome {
        let ticket = Ticket()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if ticket.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if busy {
                    waiters.append(Waiter(ticket: ticket, continuation: continuation))
                } else {
                    busy = true
                    continuation.resume()
                }
            }
        } onCancel: {
            ticket.cancel()
            Task { await self.cancelWaiter(ticket.id) }
        }
        defer { releaseNext() }
        try Task.checkCancellation()
        guard let executableURL else { throw TranscriptionWorkerError.failed("No se encontró el ejecutable de MeetCapture") }
        var request = try JSONEncoder().encode(WorkerRequest(job))
        request.append(0x0A)
        let process = WorkerProcess(cancellationGrace: cancellationGrace)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let output = try await process.run(executableURL: executableURL, arguments: arguments,
                                               environment: environment, request: request, progress: progress)
            try Task.checkCancellation()
            do {
                if let protocolFailure = output.protocolFailure { throw TranscriptionWorkerError.failed(protocolFailure) }
                guard let final = output.final else { throw TranscriptionWorkerError.crashed(output.status) }
                if let outcome = final.outcome { return outcome }
                guard let failure = final.error else { throw TranscriptionWorkerError.failed("Respuesta incompleta del proceso de transcripción") }
                if let error = TranscriptionError(rawValue: failure.kind) { throw error }
                if failure.kind == "cancelled" { throw CancellationError() }
                throw TranscriptionWorkerError.failed(failure.message)
            } catch {
                AppInfo.logger("TranscriptionWorkerClient").error(
                    "worker failed: \(error.localizedDescription, privacy: .public); stderr: \(output.stderr, privacy: .private)")
                throw error
            }
        } onCancel: {
            process.cancel()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.ticket.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func releaseNext() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.ticket.isCancelled {
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                waiter.continuation.resume()
                return
            }
        }
        busy = false
    }
}

private struct WorkerProcessOutput {
    var status: Int32
    var final: WorkerMessage?
    var protocolFailure: String?
    var stderr: String
}

private final class WorkerProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationGrace: TimeInterval
    private var process: Process?
    private var processGroup: Int32?
    private var input: FileHandle?
    private var cancelled = false
    private var finished = false
    private var killItem: DispatchWorkItem?

    init(cancellationGrace: TimeInterval) { self.cancellationGrace = cancellationGrace }

    func run(executableURL: URL, arguments: [String], environment: [String: String], request: Data,
             progress: @escaping @Sendable (Double) -> Void) async throws -> WorkerProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            process.qualityOfService = .userInitiated
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            // A child that exits before reading must not send SIGPIPE to the app.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                finish()
                continuation.resume(throwing: TranscriptionWorkerError.failed("No se pudo preparar la entrada del proceso de transcripción"))
                return
            }
            let group = DispatchGroup()
            let collector = WorkerProcessCollector(progress: progress)
            group.enter() // process termination
            group.enter() // stdout EOF
            group.enter() // stderr EOF
            process.terminationHandler = { [weak self] _ in
                // An exited worker may leave descendants holding its pipes.
                // Close the lease and bound draining with the same kill grace.
                self?.cancel()
                group.leave()
            }
            do {
                try process.run()
            } catch {
                finish()
                continuation.resume(throwing: TranscriptionWorkerError.failed("No se pudo iniciar el proceso: \(error.localizedDescription)"))
                return
            }
            attach(process, input: input.fileHandleForWriting)
            let readQueue = DispatchQueue.global(qos: .utility)
            readQueue.async {
                collector.readStdout(output.fileHandleForReading)
                group.leave()
            }
            readQueue.async {
                collector.readStderr(errors.fileHandleForReading)
                group.leave()
            }
            do { try input.fileHandleForWriting.write(contentsOf: request) }
            catch { cancel() }
            group.notify(queue: .global()) {
                self.finish()
                continuation.resume(returning: collector.snapshot(status: process.terminationStatus))
            }
        }
    }

    private func attach(_ process: Process, input: FileHandle) {
        lock.lock()
        self.process = process
        self.input = input
        let pid = process.processIdentifier
        // Match ProcessRunner: only signal a group owned by this child, even
        // when its leader exits before a descendant closes an inherited pipe.
        if pid > 0, pid != getpgrp(), getpgid(pid) == pid || (!process.isRunning && kill(-pid, 0) == 0) {
            processGroup = pid
        }
        let mustCancel = cancelled
        lock.unlock()
        if mustCancel { cancel() }
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        cancelled = true
        let input = input
        self.input = nil
        if process != nil, killItem == nil {
            let item = DispatchWorkItem { self.killIfNeeded() }
            killItem = item
            DispatchQueue.global().asyncAfter(deadline: .now() + cancellationGrace, execute: item)
        }
        lock.unlock()
        // EOF is the cooperative cancellation signal; SIGKILL is the fallback.
        try? input?.close()
    }

    private func killIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let process else { return }
        if let group = processGroup { kill(-group, SIGKILL) }
        else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    private func finish() {
        lock.lock()
        finished = true
        processGroup = nil
        killItem?.cancel()
        killItem = nil
        let input = input
        self.input = nil
        lock.unlock()
        try? input?.close()
    }
}

private final class WorkerProcessCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var final: WorkerMessage?
    private var protocolFailure: String?
    private var stderr = Data()

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    func readStdout(_ handle: FileHandle) {
        defer { try? handle.close() }
        var pending = Data()
        while true {
            // read(upToCount:) may wait to fill the requested size on a pipe.
            // availableData delivers progress as soon as the child writes it.
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let end = chunk[start...].firstIndex(of: 0x0A) {
                pending.append(contentsOf: chunk[start..<end])
                consume(pending)
                pending.removeAll(keepingCapacity: true)
                start = chunk.index(after: end)
            }
            pending.append(contentsOf: chunk[start...])
        }
        if !pending.isEmpty { consume(pending) }
    }

    private func consume(_ line: Data) {
        guard line.starts(with: WorkerMessage.prefix) else { return }
        do {
            let message = try JSONDecoder().decode(WorkerMessage.self, from: line.dropFirst(WorkerMessage.prefix.count))
            let fields = (message.progress == nil ? 0 : 1) + (message.outcome == nil ? 0 : 1) + (message.error == nil ? 0 : 1)
            guard fields == 1 else {
                throw TranscriptionWorkerError.failed("Respuesta inválida del proceso de transcripción")
            }
            if let value = message.progress {
                guard value.isFinite else { throw TranscriptionWorkerError.failed("Progreso inválido del proceso de transcripción") }
                progress(value)
            } else {
                lock.lock()
                if final == nil { final = message }
                else { protocolFailure = "El proceso devolvió más de un resultado" }
                lock.unlock()
            }
        } catch {
            lock.lock(); protocolFailure = "Respuesta inválida del proceso de transcripción"; lock.unlock()
        }
    }

    func readStderr(_ handle: FileHandle) {
        defer { try? handle.close() }
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            lock.lock()
            stderr.append(chunk)
            if stderr.count > 4096 { stderr.removeFirst(stderr.count - 4096) }
            lock.unlock()
        }
    }

    func snapshot(status: Int32) -> WorkerProcessOutput {
        lock.lock(); defer { lock.unlock() }
        return WorkerProcessOutput(status: status, final: final, protocolFailure: protocolFailure,
                                   stderr: String(decoding: stderr, as: UTF8.self))
    }
}
