// CallDetector.swift
// "Is a call happening right now?": a conferencing app or browser is
// capturing the microphone (Core Audio process objects, macOS 14.4+).
//
// Event driven: a listener on the process-object list plus one per
// call-app process on kAudioProcessPropertyIsRunningInput. A 30 s
// reconcile poll catches anything the listeners miss; if listeners cannot
// be installed the detector polls every 4 s as before.

import Combine
import CoreAudio
import Foundation
import os

enum CallAppMatcher {
    static let prefixes: [String] = [
        // Browsers (Meet, web Zoom/Teams/Whereby/Jitsi run here)
        "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "company.thebrowser",
        // Safari and other WebKit apps capture the mic from this helper.
        "com.apple.WebKit.GPU",
        // Native conferencing apps
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.tinyspeck.slackmacgap",
        "com.apple.facetime", "com.hnc.discord", "com.cisco.webexmeetingsapp",
        "com.skype", "com.google.meet",
        // Messaging apps with voice/video calls
        "net.whatsapp.WhatsApp", "org.whispersystems.signal", "ru.keepcoder.Telegram",
    ]

    /// Case-insensitive prefix match. Empty or nil bundle IDs never match.
    static func isCallApp(bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased(), !bid.isEmpty else { return false }
        return prefixes.contains { prefix in
            let prefix = prefix.lowercased()
            return bid == prefix || bid.hasPrefix(prefix + ".")
        }
    }
}

/// Core Audio process-object queries (thread-safe, no state).
enum CoreAudioProcesses {
    static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func isRunningInput(_ proc: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    static func pid(_ proc: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        _ = AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &pid)
        return pid
    }

    static func bundleID(_ proc: AudioObjectID) -> String? {
        InputDevices.stringProperty(proc, kAudioProcessPropertyBundleID)
    }

    /// Process objects of call apps (not us), optionally only those capturing input.
    static func callAppProcesses(capturingInputOnly: Bool) -> [AudioObjectID] {
        let own = ProcessInfo.processInfo.processIdentifier
        return processObjects().filter { proc in
            guard !capturingInputOnly || isRunningInput(proc) else { return false }
            guard pid(proc) != own else { return false }
            return CallAppMatcher.isCallApp(bundleID: bundleID(proc))
        }
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

@MainActor
final class CallDetector: ObservableObject {
    @Published private(set) var isCallActive = false
    /// Skip the reconcile poll while a manual or calendar recording runs.
    var reconcileSuspended = false

    static let reconcileInterval: TimeInterval = 30
    static let fallbackPollInterval: TimeInterval = 4
    static let confirmDelay: TimeInterval = 4

    private var debouncer = CallActivityDebouncer(confirmCount: 2)
    private var reconcileTimer: Timer?
    private var confirmWork: DispatchWorkItem?
    private let listeners = ProcessListeners()
    private let logger = AppInfo.logger("CallDetector")

    func start() {
        guard reconcileTimer == nil else { return }
        let listening = listeners.install { [weak self] in
            Task { @MainActor [weak self] in self?.evaluate(reason: "listener") }
        }
        let interval = listening ? Self.reconcileInterval : Self.fallbackPollInterval
        if !listening { logger.warning("listeners de Core Audio no disponibles; poll cada 4 s") }
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.reconcileSuspended else { return }
                self.listeners.reconcile()
                self.evaluate(reason: "reconcile")
            }
        }
        evaluate(reason: "start")
    }

    func stop() {
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        confirmWork?.cancel()
        listeners.removeAll()
    }

    /// Process objects of call apps currently capturing the mic (targeted tap).
    nonisolated func activeCallProcessIDs() -> [AudioObjectID] {
        CoreAudioProcesses.callAppProcesses(capturingInputOnly: true)
    }

    private func evaluate(reason: String) {
        let active = !CoreAudioProcesses.callAppProcesses(capturingInputOnly: true).isEmpty
        if let changed = debouncer.observe(active: active) {
            isCallActive = changed
            logger.info("llamada \(changed ? "detectada" : "terminada", privacy: .public) (\(reason, privacy: .public))")
        }
        confirmWork?.cancel()
        if debouncer.needsConfirmation {
            let work = DispatchWorkItem { [weak self] in self?.evaluate(reason: "confirm") }
            confirmWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmDelay, execute: work)
        }
    }

    /// Owns the Core Audio property listeners (installed on its own serial queue).
    private final class ProcessListeners: @unchecked Sendable {
        private let queue = DispatchQueue(label: AppInfo.bundleID + ".calldetector")
        private var block: AudioObjectPropertyListenerBlock?
        private var watched: Set<AudioObjectID> = []
        private var listInstalled = false

        func install(onChange: @escaping @Sendable () -> Void) -> Bool {
            // Core Audio calls this block on `queue`, so the reconcile must not
            // dispatch_sync onto the same queue (that trap took the app down).
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.reconcileOnQueue()
                onChange()
            }
            self.block = block
            var addr = CoreAudioProcesses.address(kAudioHardwarePropertyProcessObjectList)
            listInstalled = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block) == noErr
            if listInstalled { reconcile() }
            return listInstalled
        }

        /// Watches every call-app process object (even idle ones) for input
        /// changes. Safe from any thread: the work is enqueued on `queue`.
        func reconcile() {
            queue.async { [weak self] in self?.reconcileOnQueue() }
        }

        private func reconcileOnQueue() {
            dispatchPrecondition(condition: .onQueue(queue))
            guard listInstalled, let block else { return }
            let current = Set(CoreAudioProcesses.callAppProcesses(capturingInputOnly: false))
            for proc in watched.subtracting(current) {
                var addr = CoreAudioProcesses.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(proc, &addr, queue, block)
            }
            for proc in current.subtracting(watched) {
                var addr = CoreAudioProcesses.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectAddPropertyListenerBlock(proc, &addr, queue, block)
            }
            watched = current
        }

        func removeAll() {
            guard let block else { return }
            queue.sync {
                for proc in watched {
                    var addr = CoreAudioProcesses.address(kAudioProcessPropertyIsRunningInput)
                    AudioObjectRemovePropertyListenerBlock(proc, &addr, queue, block)
                }
                watched = []
                if listInstalled {
                    var addr = CoreAudioProcesses.address(kAudioHardwarePropertyProcessObjectList)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
                    listInstalled = false
                }
            }
            self.block = nil
        }
    }
}
