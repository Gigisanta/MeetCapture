// PCMFileWriter.swift
// Buffered raw PCM writer: 0700 directory, 0600 file, one write(2) per
// 64 KB (~1 s of 16 kHz stereo Int16) instead of one per callback.

import Foundation

final class PCMFileWriter {
    enum WriterError: LocalizedError {
        case cannotCreate(String)
        case alreadyExists(String)
        case writeFailed(path: String, reason: String)
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let path): return "No se pudo crear \(path)"
            case .alreadyExists(let path): return "Ya existe \(path)"
            case .writeFailed(let path, let reason):
                return "No se pudo guardar el audio en \(path): \(reason). El archivo parcial se conserva para diagnóstico o reintento."
            }
        }
    }

    static let bufferSize = 64 * 1024

    let path: String
    private let handle: FileHandle
    private var buffer: Data
    private var writeFailure: WriterError?
    private(set) var bytesWritten = 0
    var bufferedByteCount: Int { buffer.count }

    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try AppPaths.ensurePrivateDirectory(dir)
        guard !FileManager.default.fileExists(atPath: path) else {
            throw WriterError.alreadyExists(path)
        }
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WriterError.cannotCreate(path)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            // The create succeeded, so this path belongs to this writer even
            // though opening it failed. Do not remove it before that point:
            // a concurrent/preexisting path is never ours to delete.
            try? FileManager.default.removeItem(atPath: path)
            throw WriterError.cannotCreate(path)
        }
        self.path = path
        self.handle = handle
        buffer = Data(capacity: Self.bufferSize)
    }

    init(path: String, fileHandle: FileHandle) {
        self.path = path
        handle = fileHandle
        buffer = Data(capacity: Self.bufferSize)
    }

    func write(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        if let writeFailure { throw writeFailure }
        let bytes = UnsafeBufferPointer(
            start: UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self),
            count: samples.count * MemoryLayout<Int16>.size)
        var offset = 0
        while offset < bytes.count {
            let count = min(Self.bufferSize - buffer.count, bytes.count - offset)
            buffer.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
            if buffer.count == Self.bufferSize { try flush() }
        }
    }

    func write(_ samples: [Int16]) throws {
        try samples.withUnsafeBufferPointer { try write($0) }
    }

    func flush() throws {
        if let writeFailure { throw writeFailure }
        guard !buffer.isEmpty else { return }
        do {
            try handle.write(contentsOf: buffer)
            bytesWritten += buffer.count
            buffer.removeAll(keepingCapacity: true)
        } catch {
            throw recordWriteFailure(error)
        }
    }

    func close() throws {
        var closeError: Error?
        do {
            try flush()
        } catch {
            closeError = error
        }
        do {
            try handle.close()
        } catch {
            if closeError == nil { closeError = recordWriteFailure(error) }
        }
        if let closeError { throw closeError }
    }

    private func recordWriteFailure(_ error: Error) -> WriterError {
        if let writeFailure { return writeFailure }
        let failure = WriterError.writeFailed(path: path, reason: error.localizedDescription)
        writeFailure = failure
        AppInfo.logger("PCMFileWriter").error("write falló: \(error.localizedDescription, privacy: .public)")
        return failure
    }
}
