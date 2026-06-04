// SocketClient.swift
// MeetCapture v4 - Unix Domain Socket IPC Client
//
// Connects to the meet-daemon via /tmp/meetcapture.sock
// Sends JSON commands and receives JSON responses.

import Foundation

// MARK: - IPC Command & Response Types

enum IPCCommand: String, Codable {
    case startRecording = "start_recording"
    case stopRecording = "stop_recording"
    case getStatus = "get_status"
    case ping = "ping"
}

struct IPCRequest: Codable {
    let command: IPCCommand
    let id: String
    let payload: [String: AnyCodable]?

    init(command: IPCCommand, payload: [String: Any]? = nil) {
        self.command = command
        self.id = UUID().uuidString
        self.payload = payload?.mapValues { AnyCodable($0) }
    }
}

struct IPCResponse: Codable {
    let id: String
    let success: Bool
    let data: [String: AnyCodable]?
    let error: String?
}

struct IPCStatus: Codable {
    let isRecording: Bool
    let recordingStartTime: String?
    let meetingTitle: String?
    let uptime: Double?

    enum CodingKeys: String, CodingKey {
        case isRecording = "is_recording"
        case recordingStartTime = "recording_start_time"
        case meetingTitle = "meeting_title"
        case uptime
    }
}

// MARK: - AnyCodable Helper

/// A type-erased Codable wrapper to handle mixed JSON dictionaries.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable: unsupported type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}

// MARK: - SocketClient Errors

enum SocketClientError: Error, LocalizedError {
    case socketCreationFailed
    case connectionFailed(path: String, reason: String)
    case sendFailed(bytesNeeded: Int, bytesSent: Int)
    case receiveFailed(String)
    case responseTimeout
    case invalidResponse(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed:
            return "Failed to create Unix domain socket"
        case .connectionFailed(let path, let reason):
            return "Cannot connect to \(path): \(reason)"
        case .sendFailed(let needed, let sent):
            return "Send failed: wrote \(sent)/\(needed) bytes"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        case .responseTimeout:
            return "Timed out waiting for daemon response"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        case .notConnected:
            return "Not connected to daemon"
        }
    }
}

// MARK: - SocketClient

final class SocketClient {
    // MARK: - Configuration

    static let defaultSocketPath = "/tmp/meetcapture.sock"
    private static let receiveBufferSize = 65536
    private static let defaultTimeoutSeconds: TimeInterval = 10.0
    private static let reconnectDelaySeconds: TimeInterval = 2.0
    private static let maxReconnectAttempts = 5

    // MARK: - Properties

    private let socketPath: String
    private var socketFD: Int32 = -1
    private let socketQueue = DispatchQueue(label: "com.meetcapture.socket", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isConnected: Bool = false

    var onDisconnect: (() -> Void)?
    var onReconnect: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Init / Deinit

    init(socketPath: String = SocketClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Lifecycle

    /// Connect to the Unix domain socket server.
    func connect() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isConnected else { return }

        // Create socket
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw SocketClientError.socketCreationFailed
        }

        // Set up address
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        guard socketPath.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(socketFD)
            socketFD = -1
            throw SocketClientError.connectionFailed(
                path: socketPath,
                reason: "Socket path too long"
            )
        }

        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            socketPath.withCString { src in
                _ = strncpy(dest, src, pathSize)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(socketFD, sockPtr, addrLen)
            }
        }

        guard result == 0 else {
            let errNo = errno
            close(socketFD)
            socketFD = -1
            let reason: String
            switch errNo {
            case ENOENT:
                reason = "Socket file not found (daemon not running?)"
            case EACCES:
                reason = "Permission denied"
            case ECONNREFUSED:
                reason = "Connection refused"
            default:
                reason = "errno \(errNo): \(String(cString: strerror(errNo)))"
            }
            throw SocketClientError.connectionFailed(path: socketPath, reason: reason)
        }

        isConnected = true
    }

    /// Disconnect from the socket server.
    func disconnect() {
        stateLock.lock()
        defer { stateLock.unlock() }

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        isConnected = false
    }

    // MARK: - Send Commands

    /// Send a command and wait for the response (synchronous wrapper).
    func sendCommand(
        _ command: IPCCommand,
        payload: [String: Any]? = nil,
        timeout: TimeInterval = SocketClient.defaultTimeoutSeconds
    ) throws -> IPCResponse {
        let request = IPCRequest(command: command, payload: payload)
        return try sendRequest(request, timeout: timeout)
    }

    /// Send a request and wait for the matching response.
    func sendRequest(
        _ request: IPCRequest,
        timeout: TimeInterval = SocketClient.defaultTimeoutSeconds
    ) throws -> IPCResponse {
        guard isConnected else { throw SocketClientError.notConnected }

        // Encode request
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            data = try encoder.encode(request)
        } catch {
            throw SocketClientError.invalidResponse("Failed to encode request: \(error)")
        }

        // Send with newline delimiter
        var sendData = data
        sendData.append(0x0A) // newline as message delimiter

        try sendData.withUnsafeBytes { buffer in
            let ptr = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var totalSent = 0
            while totalSent < sendData.count {
                let sent = send(socketFD, ptr + totalSent, sendData.count - totalSent, 0)
                if sent <= 0 {
                    isConnected = false
                    throw SocketClientError.sendFailed(
                        bytesNeeded: sendData.count,
                        bytesSent: totalSent
                    )
                }
                totalSent += sent
            }
        }

        // Receive response with timeout
        return try receiveResponse(timeout: timeout)
    }

    // MARK: - Convenience Methods

    func startRecording(meetingTitle: String? = nil) throws -> IPCResponse {
        var payload: [String: Any] = [:]
        if let title = meetingTitle {
            payload["meeting_title"] = title
        }
        return try sendCommand(.startRecording, payload: payload.isEmpty ? nil : payload)
    }

    func stopRecording() throws -> IPCResponse {
        return try sendCommand(.stopRecording)
    }

    func getStatus() throws -> IPCResponse {
        return try sendCommand(.getStatus)
    }

    func ping() throws -> IPCResponse {
        return try sendCommand(.ping)
    }

    /// Send command asynchronously with completion handler.
    func sendCommandAsync(
        _ command: IPCCommand,
        payload: [String: Any]? = nil,
        completion: @escaping (Result<IPCResponse, Error>) -> Void
    ) {
        socketQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let response = try self.sendCommand(command, payload: payload)
                completion(.success(response))
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// Send command asynchronously using async/await.
    @available(macOS 12.0, *)
    func sendCommandAsync(
        _ command: IPCCommand,
        payload: [String: Any]? = nil
    ) async throws -> IPCResponse {
        try await withCheckedThrowingContinuation { continuation in
            sendCommandAsync(command, payload: payload) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Reconnection

    /// Attempt to reconnect with exponential backoff.
    func reconnect(maxAttempts: Int = SocketClient.maxReconnectAttempts) throws {
        disconnect()

        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            let delay = SocketClient.reconnectDelaySeconds * TimeInterval(attempt)

            Thread.sleep(forTimeInterval: delay)

            do {
                try connect()
                onReconnect?()
                return
            } catch {
                continue
            }
        }

        throw SocketClientError.connectionFailed(
            path: socketPath,
            reason: "Failed after \(maxAttempts) reconnection attempts"
        )
    }

    // MARK: - Private Helpers

    private func receiveResponse(timeout: TimeInterval) throws -> IPCResponse {
        var buffer = [UInt8](repeating: 0, count: SocketClient.receiveBufferSize)
        var receivedData = Data()
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }

            // Set receive timeout
            var tv = timeval(
                tv_sec: Int(remaining),
                tv_usec: Int32((remaining - Double(Int(remaining))) * 1_000_000)
            )
            setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

            let bytesRead = recv(socketFD, &buffer, buffer.count, 0)

            if bytesRead < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    continue // Timeout, try again
                }
                isConnected = false
                throw SocketClientError.receiveFailed(
                    "recv error: \(String(cString: strerror(errno)))"
                )
            }

            if bytesRead == 0 {
                // Server closed connection
                isConnected = false
                throw SocketClientError.receiveFailed("Server closed connection")
            }

            receivedData.append(contentsOf: buffer[0..<bytesRead])

            // Check for complete message (newline-delimited)
            if let newlineIndex = receivedData.firstIndex(of: 0x0A) {
                let messageData = receivedData[receivedData.startIndex..<newlineIndex]
                return try decodeResponse(messageData)
            }
        }

        throw SocketClientError.responseTimeout
    }

    private func decodeResponse(_ data: Data) throws -> IPCResponse {
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(IPCResponse.self, from: data)
        } catch {
            throw SocketClientError.invalidResponse(
                "JSON decode error: \(error). Raw: \(String(data: data, encoding: .utf8) ?? "<binary>")"
            )
        }
    }
}

// MARK: - SocketClient + AsyncStream (for streaming responses)

@available(macOS 12.0, *)
extension SocketClient {
    /// Returns an async stream of responses for a long-running command.
    func responses(for request: IPCRequest) -> AsyncThrowingStream<IPCResponse, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Send the initial request
                    let response = try self.sendRequest(request)
                    continuation.yield(response)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Convenience initializer for IPCStatus

extension IPCStatus {
    init(from response: IPCResponse) throws {
        guard response.success, let data = response.data else {
            throw SocketClientError.invalidResponse(response.error ?? "Unsuccessful response")
        }
        self.isRecording = (data["is_recording"]?.value as? Bool) ?? false
        self.recordingStartTime = data["recording_start_time"]?.value as? String
        self.meetingTitle = data["meeting_title"]?.value as? String
        self.uptime = data["uptime"]?.value as? Double
    }
}
