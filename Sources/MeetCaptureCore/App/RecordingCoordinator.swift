// RecordingCoordinator.swift
// One recording from start to stop: capture service, energy assertion
// and the 1 s duration timer. Phases and policies live
// in AppState.

import AppKit
import Foundation

@MainActor
final class RecordingCoordinator {
    let audioCapture = AudioCaptureService()

    private(set) var startedAt: Date?
    private(set) var outputPath: String?
    private var timer: Timer?
    private var energyActivity: NSObjectProtocol?
    private let logger = AppInfo.logger("Recording")

    var onTick: ((TimeInterval) -> Void)?

    var isRecording: Bool { audioCapture.state.isRecording }

    func start(outputPath: String, configuration: TapConfiguration) async throws {
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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startedAt else { return }
                self.onTick?(Date().timeIntervalSince(start))
            }
        }
    }

    /// Stops capture (drains + flushes the file).
    func stop() async throws -> String? {
        timer?.invalidate()
        timer = nil
        defer {
            endActivity()
            startedAt = nil
        }
        try await audioCapture.stopCapture()
        let path = outputPath
        outputPath = nil
        return path
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
