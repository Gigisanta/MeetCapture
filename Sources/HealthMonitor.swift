// HealthMonitor.swift
// MeetCapture v4 — Phase 6 health monitoring
// Background timer that pings the daemon, watches disk + memory, restarts on failure.

import Foundation
import os
import UserNotifications

@MainActor
final class HealthMonitor {
    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "Health")
    private var timer: Timer?
    private weak var socketClient: SocketClient?
    private weak var appState: AppState?
    private var daemonMissCount: Int = 0
    private let daemonMissThreshold: Int = 3  // 3 consecutive misses = restart

    /// Minimum free disk to keep recording (MB)
    var minFreeDiskMB: Int = 500

    func start(socketClient: SocketClient, appState: AppState) {
        self.socketClient = socketClient
        self.appState = appState
        stop()
        // BUG #16 fix: MenuBarExtra apps without a Dock icon don't pump the
        // main run loop the same way a regular app does. Timer.scheduledTimer
        // schedules on the current run loop (which is main) but the run loop
        // may not process timer events when the app is otherwise idle. Adding
        // explicitly to .common mode makes the timer fire regardless.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        logger.info("HealthMonitor started (30s interval, .common run loop mode)")

        // Kick off an initial tick so the daemon status reflects reality
        // within a few seconds of startup (instead of waiting 30s for the
        // first scheduled tick).
        Task { @MainActor in
            self.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let appState else { return }
        Self.appendDiag("HealthMonitor.tick()")
        Task {
            // 1. Ping daemon
            do {
                let resp = try await self.socketClient?.send(command: "ping", timeout: 2.0)
                let ok = (resp?["data"] as? [String: Any])?["pong"] as? Bool == true
                if ok {
                    self.daemonMissCount = 0
                    appState.isDaemonRunning = true
                } else {
                    self.daemonMissCount += 1
                }
            } catch {
                self.daemonMissCount += 1
                if self.daemonMissCount >= self.daemonMissThreshold {
                    self.logger.warning("Daemon missed \(self.daemonMissCount) pings — attempting restart")
                    self.notify(title: "meet-daemon unresponsive",
                                body: "Attempting to restart background transcription service.")
                    self.restartDaemon()
                    self.daemonMissCount = 0
                }
                appState.isDaemonRunning = false
            }

            // 2. Disk check
            if let free = try? self.freeDiskMB(), free < self.minFreeDiskMB, appState.phase == .recording {
                self.logger.error("Low disk: \(free)MB free, stopping recording")
                appState.stopRecording()
                self.notify(title: "Low disk space",
                            body: "MeetCapture stopped recording to protect your data. Free up space and restart.")
            }
        }
    }

    private func freeDiskMB() throws -> Int {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let cap = values.volumeAvailableCapacityForImportantUsage {
            return Int(cap / 1_000_000)
        }
        return 0
    }

    private func restartDaemon() {
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p1.arguments = ["unload", plist]
        try? p1.run()
        p1.waitUntilExit()

        // Brief wait then reload
        Thread.sleep(forTimeInterval: 0.5)

        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p2.arguments = ["load", plist]
        try? p2.run()
        p2.waitUntilExit()
        logger.info("Daemon restart attempted")
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = UNNotificationSound.default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Always-on diagnostic log so we can debug IPC issues even in release builds.
    static let diagPath = "/tmp/meetcapture-socket-diag.log"
    static func appendDiag(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [Health] \(msg)\n"
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
}
