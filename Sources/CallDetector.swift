// CallDetector.swift
// MeetCapture v4 — Real "is a call happening right now" detection.
//
// The calendar tells us when a meeting is *scheduled*; this tells us when one is
// *actually live* — including ad-hoc Meet/Zoom links that were never on a
// calendar. We poll Core Audio's process-object list (macOS 14.4+) for any
// conferencing app or browser that is currently capturing the microphone
// (`kAudioProcessPropertyIsRunningInput`). Mic-in-use by a browser/Zoom/Teams
// ≈ a live call. Our own recording process is excluded by PID.

import Combine
import CoreAudio
import Foundation
import os.log

/// Bundle-ID substrings of apps whose mic usage means "in a call". Gating on
/// these avoids false positives from Dictation, Voice Memos, etc.
/// Declared at file level (nonisolated) for access from nonisolated functions.
private let callAppPrefixes: [String] = [
  // Browsers (Meet, web Zoom/Teams/Whereby/Jitsi run here)
  "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
  "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera",
  "com.vivaldi.vivaldi", "company.thebrowser",
  // Native conferencing apps
  "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
  "com.apple.facetime", "com.hnc.discord", "com.cisco.webexmeetingsapp",
  "com.skype", "com.google.meet",
]

@MainActor
final class CallDetector: ObservableObject {
  /// True while a conferencing app / browser is actively capturing the mic.
  @Published private(set) var isCallActive = false

  private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "CallDetector")
  private var timer: Timer?
  private let ownPID = ProcessInfo.processInfo.processIdentifier
  /// Consecutive "inactive" polls before we declare the call over — a brief mic
  /// blip (device switch, momentary release) shouldn't end a meeting.
  private var inactiveStreak = 0
  private static let inactiveConfirmCount = 2  // 2 × 4s ≈ 8s grace

  func start() {
    guard timer == nil else { return }
    // 4s cadence: responsive enough to auto-record within seconds of joining,
    // cheap enough to be invisible on the energy graph.
    // ponytail: timer poll over per-process listeners — process objects come
    // and go and the wiring is fiddly; a 4s scan of ~dozens of objects is
    // free. Switch to AudioObjectAddPropertyListenerBlock if this ever shows
    // on a power profile.
    let t = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.poll() }
    }
    timer = t
    poll()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func poll() {
    let active = anyCallAppCapturingInput()
    if active {
      inactiveStreak = 0
      if !isCallActive {
        isCallActive = true
        logger.info("Live call detected (mic in use by a call app)")
      }
    } else {
      inactiveStreak += 1
      if isCallActive && inactiveStreak >= Self.inactiveConfirmCount {
        isCallActive = false
        logger.info("Live call ended")
      }
    }
  }

  // MARK: — Public API for targeted tap

  /// Returns the Core Audio process object IDs of all call apps currently
  /// capturing the microphone. These AudioObjectIDs are used directly by
  /// CATapDescription(stereoMixdownOfProcesses:) to create a targeted tap.
  /// Falls back gracefully if no process objects can be identified.
  nonisolated func activeCallProcessIDs() -> [AudioObjectID] {
    var ids: [AudioObjectID] = []
    let own = ProcessInfo.processInfo.processIdentifier
    for proc in processObjects() {
      guard isRunningInput(proc) else { continue }
      guard procPID(proc) != own else { continue }
      guard let bid = procBundleID(proc)?.lowercased() else { continue }
      if callAppPrefixes.contains(where: { bid.hasPrefix($0) }) {
        ids.append(proc)
      }
    }
    return ids
  }

  // MARK: — Core Audio process inspection (nonisolated para acceso desde AudioCapture)

  private nonisolated func anyCallAppCapturingInput() -> Bool {
    let own = ProcessInfo.processInfo.processIdentifier
    for proc in processObjects() {
      guard isRunningInput(proc) else { continue }
      guard procPID(proc) != own else { continue }
      guard let bid = procBundleID(proc)?.lowercased() else { continue }
      if callAppPrefixes.contains(where: { bid.hasPrefix($0) }) { return true }
    }
    return false
  }

  private nonisolated func processObjects() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
      return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private nonisolated func isRunningInput(_ proc: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyIsRunningInput,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &running) == noErr else {
      return false
    }
    return running != 0
  }

  private nonisolated func procPID(_ proc: AudioObjectID) -> pid_t {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyPID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    _ = AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &pid)
    return pid
  }

  private nonisolated func procBundleID(_ proc: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioProcessPropertyBundleID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &cf) == noErr else { return nil }
    return cf?.takeRetainedValue() as String?
  }
}
