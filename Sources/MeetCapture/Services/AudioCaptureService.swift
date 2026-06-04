//
//  AudioCaptureService.swift
//  MeetCapture
//
//  Created for MeetCapture v4 - macOS Menu Bar App
//  Captures system audio using ScreenCaptureKit for Google Meet transcription.
//
//  ScreenCaptureKit provides native system audio capture without requiring
//  third-party virtual audio drivers (e.g., BlackHole). It captures all
//  system audio mixed together — perfect for capturing both sides of a
//  Google Meet call.
//
//  Output format: 16kHz mono Float32 PCM (matches Whisper.cpp input format)
//
//  Requirements:
//  - macOS 14+ (Sonoma)
//  - Screen Recording permission in System Settings > Privacy & Security
//  - The app must be sandboxed with the com.apple.security.screen-capture
//    entitlement, or run outside the sandbox with screen capture access.
//

import Foundation
import ScreenCaptureKit
import CoreMedia
import os.log

// MARK: - Capture Errors

/// Errors that can occur during audio capture operations.
/// Each case provides a descriptive message for logging and UI display.
enum CaptureError: LocalizedError {
    /// No display found on the system (shouldn't happen on a real Mac).
    case noDisplay

    /// Screen recording permission has not been granted.
    case permissionDenied

    /// Failed to create the output file or open it for writing.
    case fileCreationFailed(path: String, reason: String)

    /// The SCStream failed to start.
    case streamStartFailed(Error)

    /// The SCStream stopped unexpectedly with an error.
    case streamStoppedWithError(Error)

    /// Audio configuration is invalid (e.g., unsupported sample rate).
    case invalidAudioConfiguration(String)

    /// The output file handle became invalid during capture.
    case invalidFileHandle

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display found. ScreenCaptureKit requires at least one active display."
        case .permissionDenied:
            return """
                Screen recording permission denied. \
                Please grant access in System Settings > Privacy & Security \
                > Screen & System Audio Recording.
                """
        case .fileCreationFailed(let path, let reason):
            return "Failed to create output file at '\(path)': \(reason)"
        case .streamStartFailed(let error):
            return "Failed to start audio capture stream: \(error.localizedDescription)"
        case .streamStoppedWithError(let error):
            return "Audio capture stream stopped unexpectedly: \(error.localizedDescription)"
        case .invalidAudioConfiguration(let detail):
            return "Invalid audio configuration: \(detail)"
        case .invalidFileHandle:
            return "Output file handle became invalid during capture."
        }
    }
}

// MARK: - Capture State

/// Represents the current state of the audio capture service.
enum CaptureState: Equatable {
    /// Not capturing. Ready to start.
    case idle
    /// Actively capturing audio.
    case recording
    /// An error occurred. The associated value is the error message.
    case error(String)

    /// Whether the service is currently recording.
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

// MARK: - AudioCaptureService

/// Service that captures system audio using ScreenCaptureKit.
///
/// This service wraps ScreenCaptureKit's `SCStream` to capture system audio
/// (e.g., both sides of a Google Meet call) and write raw PCM data to a file.
/// The output is 16kHz mono Float32 PCM, which is the native input format
/// expected by Whisper.cpp for speech-to-text transcription.
///
/// ## Architecture
///
/// ScreenCaptureKit works by capturing the entire display output (including
/// all audio). Even though we only want audio, ScreenCaptureKit requires a
/// display to capture. We minimize video overhead by using a 2x2 pixel
/// capture at the lowest possible frame rate (0.1 fps = one frame every 10s).
///
/// The audio pipeline:
/// ```
/// System Audio → SCStream → CMSampleBuffer (Float32) → FileHandle → PCM file
/// ```
///
/// ## Thread Safety
///
/// Audio samples arrive on the `audioQueue` (a serial background queue).
/// The `fileHandle` is only accessed from this queue, ensuring thread safety.
/// State changes are published to the `state` property (main-actor-isolated).
///
/// ## Usage
///
/// ```swift
/// let service = AudioCaptureService()
///
/// // Check permissions first
/// guard service.checkPermission() else {
///     service.requestPermission()
///     return
/// }
///
/// // Start capturing to a file
/// try await service.startCapture(outputPath: "/tmp/meeting_audio.pcm")
///
/// // ... capture runs in background ...
///
/// // Stop when done
/// await service.stopCapture()
/// ```
///
final class AudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    // MARK: - Published Properties

    /// Current state of the capture service. Observers can watch this
    /// to update the UI (e.g., show recording indicator in menu bar).
    @Published private(set) var state: CaptureState = .idle

    /// Total number of audio bytes written during the current capture session.
    /// Useful for showing elapsed time or data rate to the user.
    @Published private(set) var bytesCaptured: Int = 0

    /// The most recent error, if any. Cleared when capture starts.
    @Published private(set) var lastError: String?

    // MARK: - Private Properties

    /// The ScreenCaptureKit stream. Created fresh for each capture session.
    /// We don't reuse streams because SCStream lifecycle is tied to a single
    /// start/stop cycle.
    private var stream: SCStream?

    /// Serial dispatch queue for receiving audio sample buffers.
    /// Using `.userInitiated` QoS because transcription is user-initiated
    /// and latency-sensitive.
    private let audioQueue = DispatchQueue(
        label: "com.meetcapture.audio",
        qos: .userInitiated
    )

    /// File handle for writing raw PCM data. Created when capture starts,
    /// closed when capture stops.
    private var fileHandle: FileHandle?

    /// Path to the current output PCM file. Stored so we can reference
    /// it in error messages and for cleanup.
    private var outputPath: String?

    /// Logger for structured logging. Uses Apple's unified logging system
    /// which is efficient and integrates with Console.app.
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.meetcapture",
        category: "AudioCapture"
    )

    // MARK: - Audio Configuration Constants

    /// Target sample rate in Hz. 16kHz is the standard for speech recognition
    /// and matches Whisper.cpp's expected input format. Using a lower rate
    /// reduces file size without losing speech intelligibility.
    static let sampleRate: Int = 16_000

    /// Number of audio channels. Mono (1 channel) is used because speech
    /// is effectively mono — the stereo spatial information isn't needed
    /// for transcription and would double the data rate.
    static let channelCount: Int = 1

    /// Minimum frame interval for the dummy video capture.
    /// We use 10 seconds (0.1 fps) to minimize CPU and GPU overhead.
    /// ScreenCaptureKit requires a display capture even for audio-only,
    /// so we make the video component as lightweight as possible.
    static let minimumFrameInterval = CMTime(value: 10, timescale: 1)

    /// Video dimensions for the dummy capture. 2x2 pixels is the minimum
    /// allowed by ScreenCaptureKit. This is purely to satisfy the API
    /// requirement — the video output is discarded.
    static let videoWidth: Int = 2
    static let videoHeight: Int = 2

    /// Number of frames ScreenCaptureKit buffers ahead. A small queue depth
    /// (3) keeps memory usage low while preventing audio dropouts.
    /// Higher values would increase latency without benefit for audio capture.
    static let queueDepth: Int = 3

    // MARK: - Initialization

    override init() {
        super.init()
        logger.info("AudioCaptureService initialized")
    }

    deinit {
        // Ensure cleanup happens even if the caller forgets to stop.
        // We can't await in deinit, but closeFile() is synchronous.
        fileHandle?.closeFile()
        fileHandle = nil
        logger.info("AudioCaptureService deinitialized")
    }

    // MARK: - Permission Management

    /// Checks whether the app currently has screen recording permission.
    ///
    /// This uses `CGPreflightScreenCaptureAccess()` which is a synchronous,
    /// non-prompting check. It returns `true` only if the user has already
    /// granted permission in System Settings.
    ///
    /// - Returns: `true` if screen recording permission is granted.
    func checkPermission() -> Bool {
        // Use ScreenCaptureKit API (more reliable than CGPreflightScreenCaptureAccess)
        // This queries the actual SCShareableContent which requires permission
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
            // Fallback: use CG API if SCKit times out
            granted = CGPreflightScreenCaptureAccess()
            logger.warning("SCShareableContent timed out, fallback to CG: \(granted)")
        }
        logger.info("Screen capture permission: \(granted ? "granted" : "not granted", privacy: .public)")
        return granted
    }

    /// Requests screen recording permission from the user.
    ///
    /// Uses ScreenCaptureKit API to trigger the permission dialog.
    /// On macOS 14+, this shows the "Screen & System Audio Recording" prompt.
    /// After granting, the app must be restarted for permission to take effect.
    func requestPermission() {
        logger.info("Requesting screen capture permission via CGRequestScreenCaptureAccess")
        // CGRequestScreenCaptureAccess triggers the system permission dialog
        // This must be called from the main thread
        if Thread.isMainThread {
            CGRequestScreenCaptureAccess()
        } else {
            DispatchQueue.main.async {
                CGRequestScreenCaptureAccess()
            }
        }
    }

    /// Convenience method that checks permission and requests it if not granted.
    ///
    /// - Returns: `true` if permission was already granted, `false` if
    ///   permission request was initiated (caller should wait for user action).
    @discardableResult
    func ensurePermission() -> Bool {
        if checkPermission() {
            return true
        }
        requestPermission()
        return false
    }

    // MARK: - Capture Lifecycle

    /// Starts capturing system audio and writing it to the specified file.
    ///
    /// This method:
    /// 1. Checks that screen recording permission is granted
    /// 2. Queries available displays and running applications
    /// 3. Creates an SCStream with audio-only configuration
    /// 4. Opens the output file for writing
    /// 5. Starts the capture stream
    ///
    /// The capture runs in the background. Audio samples are written to the
    /// file on the `audioQueue` as they arrive. Call `stopCapture()` to end.
    ///
    /// - Parameters:
    ///   - outputPath: Absolute path to the PCM output file. The file will be
    ///     created if it doesn't exist, or truncated if it does.
    ///   - excludeApps: Optional list of running applications to exclude from
    ///     the capture filter. By default, MeetCapture itself is excluded to
    ///     avoid recording its own audio output.
    /// - Throws: `CaptureError` if any step fails.
    func startCapture(
        outputPath: String,
        excludeApps: [SCRunningApplication] = []
    ) async throws {
        logger.info("Starting audio capture to: \(outputPath)")

        // Guard against starting a capture when one is already in progress.
        guard state != .recording else {
            logger.warning("Capture already in progress, ignoring start request")
            return
        }

        // Step 1: Verify screen recording permission.
        guard checkPermission() else {
            logger.error("Screen capture permission not granted")
            state = .error(CaptureError.permissionDenied.localizedDescription)
            lastError = CaptureError.permissionDenied.localizedDescription
            throw CaptureError.permissionDenied
        }

        // Step 2: Clear any previous error state.
        lastError = nil
        bytesCaptured = 0

        // Step 3: Get shareable content (all displays and running applications).
        // `excludingDesktopWindows: false` includes desktop windows which is
        // fine since we're only capturing audio, not video content.
        // `onScreenWindowsOnly: true` limits to visible windows for efficiency.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            logger.error("Failed to get shareable content: \(error.localizedDescription)")
            state = .error("Failed to query displays: \(error.localizedDescription)")
            throw error
        }

        // Step 4: Get the primary display. ScreenCaptureKit requires a display
        // to create a filter, even for audio-only capture. On a Mac with
        // multiple displays, we use the main display (the one with the menu bar).
        guard let display = content.displays.first else {
            logger.error("No display found")
            state = .error(CaptureError.noDisplay.localizedDescription)
            lastError = CaptureError.noDisplay.localizedDescription
            throw CaptureError.noDisplay
        }

        // Step 5: Build the list of applications to exclude from the filter.
        // We always exclude MeetCapture itself to prevent recording our own
        // audio output, which would create feedback loops.
        let appExclusions = content.applications.filter { app in
            // Always exclude the current process
            if app.bundleIdentifier == Bundle.main.bundleIdentifier {
                return true
            }
            // Also exclude any apps the caller explicitly requested
            return excludeApps.contains { $0.processID == app.processID }
        }

        // Step 6: Create the content filter.
        // The filter determines what ScreenCaptureKit captures. For audio,
        // we capture all audio from the display. The application exclusion
        // list prevents our own audio from being captured.
        let filter = SCContentFilter(
            display: display,
            excludingApplications: appExclusions,
            exceptingWindows: []
        )

        // Step 7: Configure the stream.
        // This is the core of the audio-only configuration. We capture audio
        // at 16kHz mono (matching Whisper's input) while minimizing video
        // overhead to near-zero.
        let config = SCStreamConfiguration()

        // Audio settings
        config.capturesAudio = true
        config.sampleRate = Self.sampleRate
        config.channelCount = Self.channelCount
        config.excludesCurrentProcessAudio = true  // Don't capture our own audio

        // Video settings (minimized — we don't need video, but SCK requires it)
        config.minimumFrameInterval = Self.minimumFrameInterval
        config.width = Self.videoWidth
        config.height = Self.videoHeight
        config.queueDepth = Self.queueDepth

        // Step 8: Create the SCStream and add ourselves as the output handler.
        // The stream object manages the capture lifecycle and delivers
        // sample buffers to our `stream(_:didOutputSampleBuffer:of:)` method.
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)

        do {
            // Register for audio output. The `sampleHandlerQueue` parameter
            // specifies the queue on which our handler will be called. Using
            // a dedicated serial queue ensures audio samples are processed
            // in order without blocking the main thread.
            try newStream.addStreamOutput(
                self,
                type: .audio,
                sampleHandlerQueue: audioQueue
            )
        } catch {
            logger.error("Failed to add stream output: \(error.localizedDescription)")
            state = .error("Failed to configure audio output: \(error.localizedDescription)")
            throw error
        }

        // Step 9: Create and open the output file.
        // We create an empty file and open it for writing. The raw Float32
        // PCM data will be appended to this file as samples arrive.
        do {
            // Create the file (or truncate if it exists)
            let fm = FileManager.default

            // Ensure parent directory exists
            let parentDir = (outputPath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: parentDir) {
                try fm.createDirectory(
                    atPath: parentDir,
                    withIntermediateDirectories: true
                )
            }

            // Create the file
            guard fm.createFile(atPath: outputPath, contents: nil) else {
                throw CaptureError.fileCreationFailed(
                    path: outputPath,
                    reason: "FileManager.createFile returned false"
                )
            }

            // Open for writing at end (append mode for resuming captures)
            guard let handle = FileHandle(forWritingAtPath: outputPath) else {
                throw CaptureError.fileCreationFailed(
                    path: outputPath,
                    reason: "FileHandle(forWritingAtPath:) returned nil"
                )
            }

            self.fileHandle = handle
            self.outputPath = outputPath
        } catch let error as CaptureError {
            state = .error(error.localizedDescription)
            lastError = error.localizedDescription
            throw error
        } catch {
            let captureError = CaptureError.fileCreationFailed(
                path: outputPath,
                reason: error.localizedDescription
            )
            state = .error(captureError.localizedDescription)
            lastError = captureError.localizedDescription
            throw captureError
        }

        // Step 10: Start the capture stream.
        // This is the async call that begins delivering audio samples.
        // The stream will continue until `stopCapture()` is called or
        // an error occurs.
        do {
            self.stream = newStream
            try await newStream.startCapture()
            state = .recording
            logger.info("Audio capture started successfully")
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            // Clean up on failure
            fileHandle?.closeFile()
            fileHandle = nil
            self.stream = nil
            let captureError = CaptureError.streamStartFailed(error)
            state = .error(captureError.localizedDescription)
            lastError = captureError.localizedDescription
            throw captureError
        }
    }

    /// Stops the current audio capture session.
    ///
    /// This method gracefully shuts down the SCStream, closes the output
    /// file, and resets the service to idle state. The PCM file remains
    /// on disk and can be passed to Whisper.cpp for transcription.
    ///
    /// This is safe to call even if no capture is in progress — it will
    /// be a no-op in that case.
    func stopCapture() async {
        guard state == .recording else {
            logger.info("No active capture to stop")
            return
        }

        logger.info("Stopping audio capture. Total bytes written: \(self.bytesCaptured)")

        // Stop the SCStream. This is an async call that may throw,
        // but we swallow errors here because we want to clean up
        // regardless of how the stop fails.
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                logger.warning("Error stopping stream (non-fatal): \(error.localizedDescription)")
            }
        }

        // Close the file handle to flush any buffered writes.
        fileHandle?.synchronizeFile()  // Ensure data is written to disk
        fileHandle?.closeFile()
        fileHandle = nil

        // Release the stream and reset state.
        stream = nil
        outputPath = nil
        state = .idle
        logger.info("Audio capture stopped. File written to: \(self.outputPath ?? "unknown")")
    }

    // MARK: - SCStreamOutput

    /// Called by ScreenCaptureKit for each audio sample buffer captured.
    ///
    /// This method is called on the `audioQueue` (background serial queue).
    /// It extracts raw Float32 PCM data from the CMSampleBuffer and writes
    /// it directly to the output file.
    ///
    /// The data flow:
    /// ```
    /// CMSampleBuffer → CMSampleBufferGetDataBuffer → CMBlockBuffer
    ///     → CMBlockBufferGetDataPointer → raw bytes → FileHandle.write
    /// ```
    ///
    /// We don't perform any format conversion because ScreenCaptureKit
    /// delivers audio in Float32 format at the configured sample rate
    /// (16kHz) and channel count (mono), which is exactly what Whisper
    /// expects.
    ///
    /// - Parameters:
    ///   - stream: The stream that produced the sample buffer.
    ///   - sampleBuffer: The audio sample buffer containing PCM data.
    ///   - outputType: The type of output (`.audio` in our case).
    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        // Guard: Only process audio buffers, skip any video frames.
        // Even though we only registered for audio output, this is a
        // safety check against unexpected output types.
        guard outputType == .audio else { return }

        // Guard: Validate the sample buffer. An invalid buffer could
        // indicate a stream error or transient issue.
        guard sampleBuffer.isValid else {
            // This can happen during stream startup/shutdown. It's not
            // necessarily an error — just skip this buffer.
            return
        }

        // Extract the block buffer containing the raw audio data.
        // A CMSampleBuffer wraps a CMBlockBuffer which holds the actual bytes.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            // Can't extract data — log at debug level since this may be
            // transient during startup/shutdown.
            return
        }

        // Get a pointer to the raw audio data and its length.
        // CMBlockBuffer stores data as a contiguous block of bytes.
        // For Float32 mono audio at 16kHz, each sample is 4 bytes.
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == noErr, let dataPointer = dataPointer else {
            return
        }

        // Guard: Validate that we have actual data to write.
        guard totalLength > 0 else { return }

        // Write the raw PCM data to the file handle.
        // We use Data(bytesNoCopy:count:deallocator:) for zero-copy
        // access to the buffer — this avoids allocating new memory
        // for the data copy, which is important for real-time audio.
        //
        // NOTE: We must write to the file handle BEFORE the sample buffer
        // is released by ScreenCaptureKit, which happens after this method
        // returns. Data(bytesNoCopy:) with .none deallocator gives us a
        // view into the buffer that's valid for the duration of this call.
        let pcmData = Data(bytesNoCopy: dataPointer, count: totalLength, deallocator: .none)

        // Write to file. This is done on the audio queue, so it won't
        // block the main thread. FileHandle.write() is synchronous and
        // thread-safe for a single writer.
        do {
            try fileHandle?.write(contentsOf: pcmData)
        } catch {
            // File write errors during capture are non-recoverable.
            // The file handle may have become invalid. We log the error
            // but can't safely stop the stream from this nonisolated context.
            // The stream will be cleaned up when stopCapture() is called
            // or when the stream delegate's error handler fires.
            return
        }

        // Update the byte counter (dispatched to main actor for @Published).
        // Read current value from nonisolated context is safe for approximate display.
        let currentBytes = bytesCaptured
        let newTotal = currentBytes + totalLength
        // We use nonisolated(unsafe) to update from the audio queue.
        // This is safe because bytesCaptured is only read for UI display
        // and approximate values are fine.
        Task { @MainActor in
            self.bytesCaptured = newTotal
        }
    }

    // MARK: - SCStreamDelegate

    /// Called when the SCStream stops unexpectedly due to an error.
    ///
    /// This can happen if:
    /// - The user revokes screen recording permission mid-capture
    /// - The display is disconnected (e.g., closing a laptop lid)
    /// - The system terminates the capture due to resource constraints
    /// - The user clicks "Stop Sharing" in the system dialog
    ///
    /// We clean up resources and update the state to reflect the error.
    ///
    /// - Parameters:
    ///   - stream: The stream that stopped.
    ///   - error: The error that caused the stream to stop.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Dispatch to main actor for state updates
        Task { @MainActor in
            self.logger.error("Stream stopped with error: \(error.localizedDescription)")

            // Clean up resources
            self.fileHandle?.synchronizeFile()
            self.fileHandle?.closeFile()
            self.fileHandle = nil
            self.stream = nil

            let captureError = CaptureError.streamStoppedWithError(error)
            self.state = .error(captureError.localizedDescription)
            self.lastError = captureError.localizedDescription
        }
    }

    // MARK: - Utility Methods

    /// Returns a human-readable description of the current capture status.
    ///
    /// Useful for displaying in the menu bar or status window.
    var statusDescription: String {
        switch state {
        case .idle:
            return "Ready to record"
        case .recording:
            let mb = Double(bytesCaptured) / (1024.0 * 1024.0)
            return String(format: "Recording (%.1f MB)", mb)
        case .error(let message):
            return "Error: \(message)"
        }
    }

    /// Returns the path to the last capture file, if any.
    var currentOutputPath: String? {
        outputPath
    }
}
