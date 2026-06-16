// SocketClient.swift
// MeetCapture v4 — Unix Domain Socket IPC to meet-daemon
// Restored 2026-06-05 after accidental deletion in refactor.

import Foundation
import os.log

/// Errors thrown by SocketClient
enum SocketClientError: LocalizedError {
    case notConnected
    case sendFailed(String)
    case receiveFailed(String)
    case decodeFailed(String)
    case daemonUnreachable

    var errorDescription: String? {
        switch self {
        case .notConnected:                return "Socket not connected to daemon"
        case .sendFailed(let r):           return "Socket send failed: \(r)"
        case .receiveFailed(let r):        return "Socket receive failed: \(r)"
        case .decodeFailed(let r):         return "Socket response decode failed: \(r)"
        case .daemonUnreachable:           return "meet-daemon unreachable at /tmp/meetcapture.sock"
        }
    }
}

/// Lightweight Unix Domain Socket client for /tmp/meetcapture.sock.
/// Uses blocking I/O on a dedicated serial queue so we don't have to
/// juggle URLSession data tasks for a non-HTTP socket.
final class SocketClient: NSObject, @unchecked Sendable {
    static let socketPath = "/tmp/meetcapture.sock"

    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "SocketClient")
    private let queue = DispatchQueue(label: "com.meetcapture.socket", qos: .userInitiated)
    private var socketFD: Int32 = -1
    private let lock = NSLock()
    private var reconnectAttempts = 0
    private let maxReconnectDelay: TimeInterval = 30.0

    /// Synchronous best-effort connect. Returns true if connected.
    @discardableResult
    func connect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { return true }

        // Always-on diagnostic: write to a file so we can see exactly what
        // happened even when OSLog strips debug-level messages in release.
        Self.appendDiag("connect() called, path=\(Self.socketPath)")

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            let err = String(cString: strerror(errno))
            logger.error("socket() failed: \(err)")
            Self.appendDiag("socket() failed: \(err)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = pathBytes.withUnsafeBufferPointer { src in
                memcpy(buf.baseAddress!, src.baseAddress!, src.count)
            }
        }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let err = String(cString: strerror(errno))
            logger.warning("connect() failed (attempt \(self.reconnectAttempts)): \(err)")
            Self.appendDiag("connect() failed (attempt \(self.reconnectAttempts)): \(err)")
            close(fd)
            return false
        }

        socketFD = fd
        reconnectAttempts = 0
        logger.info("Connected to meet-daemon at \(Self.socketPath)")
        Self.appendDiag("connected OK fd=\(fd)")
        return true
    }

    /// Always-on diagnostic log so we can debug IPC issues even in release builds.
    static let diagPath = "/tmp/meetcapture-socket-diag.log"
    static func appendDiag(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: diagPath)) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: diagPath))
            }
        }
    }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        if socketFD >= 0 { close(socketFD) }
        socketFD = -1
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socketFD >= 0
    }

    /// Send a JSON command, return parsed response. Throws on failure.
    func send(command: String, payload: [String: Any] = [:], timeout: TimeInterval = 5.0) async throws -> [String: Any] {
        let id = UUID().uuidString
        let envelope: [String: Any] = [
            "id": id,
            "command": command,
            "payload": payload
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        guard var line = String(data: data, encoding: .utf8) else {
            throw SocketClientError.sendFailed("JSON encode failed")
        }
        line += "\n"

        return try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self else { cont.resume(throwing: SocketClientError.notConnected); return }

                if !self.connect() {
                    cont.resume(throwing: SocketClientError.daemonUnreachable)
                    return
                }

                guard let bytes = line.data(using: .utf8) else {
                    cont.resume(throwing: SocketClientError.sendFailed("utf8 encode failed"))
                    return
                }

                let fd = self.lock.withLock { self.socketFD }
                let sent = bytes.withUnsafeBytes { buf -> Int in
                    Darwin.send(fd, buf.baseAddress, buf.count, 0)
                }
                if sent < 0 {
                    self.disconnect()
                    cont.resume(throwing: SocketClientError.sendFailed(String(cString: strerror(errno))))
                    return
                }

                // Read with timeout using select(). select()/fd_set only address
                // descriptors < FD_SETSIZE (1024); a higher fd would index past
                // the fd_set bitmap (stack corruption). Fail safely instead.
                guard fd >= 0, fd < 1024 else {
                    self.disconnect()
                    cont.resume(throwing: SocketClientError.receiveFailed("fd \(fd) ≥ FD_SETSIZE"))
                    return
                }
                var readFds = fd_set()
                fdZero(&readFds)
                fdSet(fd, &readFds)
                var tv = timeval(
                    tv_sec: Int(timeout),
                    tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
                )
                let sel = select(fd + 1, &readFds, nil, nil, &tv)
                if sel <= 0 {
                    cont.resume(throwing: SocketClientError.receiveFailed("timeout or no data"))
                    return
                }

                var buf = [UInt8](repeating: 0, count: 65536)
                let n = recv(fd, &buf, buf.count, 0)
                if n <= 0 {
                    self.disconnect()
                    cont.resume(throwing: SocketClientError.receiveFailed("recv returned \(n)"))
                    return
                }
                let respData = Data(bytes: buf, count: n)
                guard let respStr = String(data: respData, encoding: .utf8) else {
                    cont.resume(throwing: SocketClientError.decodeFailed("non-utf8 response"))
                    return
                }
                // Daemon prefixes responses with a JSON "id" envelope; take the first line
                let firstLine = respStr.split(separator: "\n").first.map(String.init) ?? respStr
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any] else {
                    cont.resume(throwing: SocketClientError.decodeFailed(firstLine))
                    return
                }
                cont.resume(returning: parsed)
            }
        }
    }

    /// Fire-and-forget send. Best-effort. Logs failures but never throws.
    func sendFireAndForget(command: String, payload: [String: Any] = [:]) {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.send(command: command, payload: payload, timeout: 3.0)
            } catch {
                self.logger.debug("Fire-and-forget send failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - NSLock helper

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

// MARK: - fd_set helpers (Swift doesn't import C macros directly)

private func fdZero(_ set: inout fd_set) {
    set = fd_set()
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd / 32)
    let bitOffset = Int(fd % 32)
    let mask: Int32 = Int32(bitPattern: UInt32(1) << UInt32(bitOffset))
    withUnsafeMutablePointer(to: &set.fds_bits) {
        $0.withMemoryRebound(to: Int32.self, capacity: 32) {
            $0[intOffset] |= mask
        }
    }
}
