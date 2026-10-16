// RecordingCoordinator.swift
// One recording from start to stop: capture service, live ASR session,
// energy assertion and the 1 s duration timer. Phases and policies live
// in AppState.

import AppKit
import Foundation

@MainActor
final class RecordingCoordinator {
    let audioCapture = AudioCaptureService()
    let liveASR = LiveASRService()

    private(set) var startedAt: Date?
    private(set) var outputPath: String?
    private var timer: Timer?
    private var energyActivity: NSObjectProtocol?
    /// When the live recognizer last did useful work (for idle unload).
    private(set) var liveIdleSince = Date()
    private let logger = AppInfo.logger("Recording")

    var onTick: ((TimeInterval) -> Void)?

    var isRecording: Bool { audioCapture.state.isRecording }

    struct LiveOptions: Sendable {
        var model: String
        var toolchain: Toolchain
    }

    func start(outputPath: String, configuration: TapConfiguration, live: LiveOptions?) async throws {
        let signpost = Signposts.pipeline.beginInterval("recording-start")
        defer { Signposts.pipeline.endInterval("recording-start", signpost) }
        beginActivity()
        do {
            try await audioCapture.startCapture(outputPath: outputPath, configuration: configuration)
        } catch {
            endActivity()
            throw error
        }
        self.outputPath = outputPath
        startedAt = Date()
        if let live {
            liveASR.beginSession(model: live.model, toolchain: live.toolchain)
            let liveASR = self.liveASR
            audioCapture.liveSink = { samples in liveASR.feed(samples) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startedAt else { return }
                self.onTick?(Date().timeIntervalSince(start))
            }
        }
    }

    /// Stops capture (drains + flushes the file) and the live session.
    func stop() async throws -> String? {
        timer?.invalidate()
        timer = nil
        audioCapture.liveSink = nil
        liveASR.endSession()
        liveIdleSince = Date()
        defer {
            endActivity()
            startedAt = nil
        }
        try await audioCapture.stopCapture()
        let path = outputPath
        outputPath = nil
        return path
    }

    func warmLive(_ options: LiveOptions) {
        liveIdleSince = Date()
        liveASR.warm(model: options.model, toolchain: options.toolchain)
    }

    func unloadLive() {
        liveASR.unload()
    }

    private func beginActivity() {
        guard energyActivity == nil else { return }
        energyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "MeetCapture recording")
    }

    private func endActivity() {
        if let activity = energyActivity { ProcessInfo.processInfo.endActivity(activity) }
        energyActivity = nil
    }
}
