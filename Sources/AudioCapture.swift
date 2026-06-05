// AudioCapture.swift
// MeetCapture v4 — System audio capture via ScreenCaptureKit

import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import os.log

// MARK: - Capture Errors

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied
    case fileCreationFailed(path: String, reason: String)
    case streamStartFailed(Error)
    case streamStoppedWithError(Error)
    case invalidAudioConfiguration(String)
    case invalidFileHandle

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found."
        case .permissionDenied:
            return "Screen recording permission denied. Grant access in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .fileCreationFailed(let path, let reason):
            return "Failed to create output file at '\(path)': \(reason)"
        case .streamStartFailed(let error):
            return "Failed to start audio capture: \(error.localizedDescription)"
        case .streamStoppedWithError(let error):
            return "Audio capture stopped unexpectedly: \(error.localizedDescription)"
        case .invalidAudioConfiguration(let detail):
            return "Invalid audio configuration: \(detail)"
        case .invalidFileHandle:
            return "Output file handle became invalid."
        }
    }
}

// MARK: - Capture State

enum CaptureState: Equatable {
    case idle
    case recording
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

// MARK: - AudioCaptureService

final class AudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var bytesCaptured: Int = 0
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.meetcapture.audio", qos: .userInitiated)
    private var fileHandle: FileHandle?
    private var outputPath: String?
    private(set) var currentOutputPath: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetcapture", category: "AudioCapture")

    static let sampleRate: Int = 16_000
    static let channelCount: Int = 1
    static let minimumFrameInterval = CMTime(value: 10, timescale: 1)
    static let videoWidth: Int = 2
    static let videoHeight: Int = 2
    static let queueDepth: Int = 3

    override init() {
        super.init()
        logger.info("AudioCaptureService initialized")
    }

    deinit {
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: - Permission

    func checkPermission() -> Bool {
        var granted = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                granted = true
            } catch {
                granted = false
            }
            semaphore.signal()
        }
        let timeout = semaphore.wait(timeout: .now() + 5.0)
        if timeout == .timedOut {
            granted = CGPreflightScreenCaptureAccess()
        }
        return granted
    }

    func requestPermission() {
        if Thread.isMainThread {
            CGRequestScreenCaptureAccess()
        } else {
            DispatchQueue.main.async { CGRequestScreenCaptureAccess() }
        }
    }

    /// Open the Screen & System Audio Recording privacy pane in System Settings.
    /// Falls back to the parent Security pane if the deep link is rejected.
    func openPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenRecording",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for urlString in candidates {
            if let url = URL(string: urlString),
               NSWorkspace.shared.open(url) {
                logger.info("Opened privacy pane: \(urlString)")
                return
            }
        }
        logger.error("Failed to open any privacy pane URL")
    }

    @discardableResult
    func ensurePermission() -> Bool {
        if checkPermission() { return true }
        requestPermission()
        return false
    }

    // MARK: - Capture Lifecycle

    func startCapture(outputPath: String, excludeApps: [SCRunningApplication] = []) async throws {
        guard state != .recording else { return }
        guard checkPermission() else {
            state = .error(CaptureError.permissionDenied.localizedDescription)
            lastError = CaptureError.permissionDenied.localizedDescription
            throw CaptureError.permissionDenied
        }

        lastError = nil
        bytesCaptured = 0

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            state = .error(CaptureError.noDisplay.localizedDescription)
            throw CaptureError.noDisplay
        }

        let appExclusions = content.applications.filter { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ||
            excludeApps.contains { $0.processID == app.processID }
        }

        let filter = SCContentFilter(display: display, excludingApplications: appExclusions, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = Self.channelCount
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = Self.minimumFrameInterval
        config.width = Self.videoWidth
        config.height = Self.videoHeight
        config.queueDepth = Self.queueDepth

        // Open file
        guard FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil) else {
            throw CaptureError.fileCreationFailed(path: outputPath, reason: "Could not create file")
        }
        let handle = FileHandle(forWritingAtPath: outputPath)
        guard let handle else {
            throw CaptureError.fileCreationFailed(path: outputPath, reason: "Could not open file for writing")
        }
        self.fileHandle = handle
        self.outputPath = outputPath
        self.currentOutputPath = outputPath

        // Start stream
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try await stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        state = .recording
        logger.info("Audio capture started → \(outputPath)")
    }

    func stopCapture() async {
        guard state == .recording else { return }
        do {
            try await stream?.stopCapture()
        } catch {
            logger.warning("stopCapture error: \(error.localizedDescription)")
        }
        stream = nil
        fileHandle?.closeFile()
        fileHandle = nil
        state = .idle
        logger.info("Audio capture stopped. File: \(self.outputPath ?? "unknown")")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutput sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let handle = fileHandle else { return }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard length > 0, let ptr = dataPointer else { return }

        let data = Data(bytes: ptr, count: length)
        do {
            try handle.write(contentsOf: data)
            Task { @MainActor in self.bytesCaptured += data.count }
        } catch {
            logger.error("Failed to write audio data: \(error.localizedDescription)")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        fileHandle?.closeFile()
        fileHandle = nil
        Task { @MainActor in
            state = .error(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }
}
