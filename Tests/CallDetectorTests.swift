// Tests/CallDetectorTests.swift
// MeetCapture v5 — Tests para la logica de CallDetector (activeCallPIDs, bundle matching).
//
// Compilar: swiftc -o /tmp/meetcapture_test_cd Tests/CallDetectorTests.swift
// Ejecutar: /tmp/meetcapture_test_cd; echo $?
// Exit 0 = todo OK, exit >0 = fallos.
//
// NOTA: Tests de logica pura sin dependencia de Core Audio (simulamos proceso).

import Foundation

// MARK: - Test helpers

var failures: [String] = []

func assertEqual(_ label: String, _ actual: Int, _ expected: Int) {
  if actual != expected {
    failures.append("\(label): esperado \(expected), obtenido \(actual)")
  }
}

func assertEqual(_ label: String, _ actual: [Int], _ expected: [Int]) {
  if actual != expected {
    failures.append("\(label): esperado \(expected), obtenido \(actual)")
  }
}

func assertTrue(_ label: String, _ cond: Bool) {
  if !cond { failures.append("\(label): se esperaba true, obtenido false") }
}

func assertFalse(_ label: String, _ cond: Bool) {
  if cond { failures.append("\(label): se esperaba false, obtenido true") }
}

// MARK: - Simulated Core Audio process object

/// Simula un AudioProcess con bundle ID, PID y estado "runningInput".
struct SimProcess {
  let pid: Int
  let bundleID: String
  let isRunning: Bool  // isRunningInput
}

// MARK: - Logic under test (replica de CallDetector.swift)

private let callApps: [String] = [
  "com.google.chrome", "com.apple.safari", "org.mozilla.firefox",
  "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera",
  "com.vivaldi.vivaldi", "company.thebrowser",
  "us.zoom.xos", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
  "com.apple.facetime", "com.hnc.discord", "com.cisco.webexmeetingsapp",
  "com.skype", "com.google.meet",
]

func isCallApp(bundleID: String) -> Bool {
  let lower = bundleID.lowercased()
  return callApps.contains(where: { lower.hasPrefix($0) })
}

/// Replica de CallDetector.activeCallPIDs()
func activeCallPIDs(processes: [SimProcess], ownPID: Int) -> [Int] {
  var pids: [Int] = []
  for proc in processes {
    guard proc.isRunning else { continue }
    guard proc.pid != ownPID else { continue }
    if isCallApp(bundleID: proc.bundleID) {
      pids.append(proc.pid)
    }
  }
  return pids.sorted()
}

/// Replica de CallDetector.anyCallAppCapturingInput()
func anyCallAppCapturingInput(processes: [SimProcess], ownPID: Int) -> Bool {
  for proc in processes {
    guard proc.isRunning else { continue }
    guard proc.pid != ownPID else { continue }
    if isCallApp(bundleID: proc.bundleID) { return true }
  }
  return false
}

// MARK: - Tests

func testEmptyProcessList() {
  let pids = activeCallPIDs(processes: [], ownPID: 42)
  assertEqual("empty_pids", pids.count, 0)
  assertFalse("empty_any", anyCallAppCapturingInput(processes: [], ownPID: 42))
}

func testOwnPIDExcluded() {
  let procs = [
    SimProcess(pid: 100, bundleID: "com.google.Chrome", isRunning: true),
    SimProcess(pid: 100, bundleID: "com.apple.Safari", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 100)
  assertEqual("ownPID_excluded", pids.count, 0)
  assertFalse("ownPID_any", anyCallAppCapturingInput(processes: procs, ownPID: 100))
}

func testNotRunningExcluded() {
  let procs = [
    SimProcess(pid: 200, bundleID: "com.google.Chrome", isRunning: false),
    SimProcess(pid: 201, bundleID: "us.zoom.xos", isRunning: false),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("notrunning", pids.count, 0)
  assertFalse("notrunning_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testSingleCallApp() {
  let procs = [
    SimProcess(pid: 300, bundleID: "com.google.Chrome", isRunning: true),
    SimProcess(pid: 301, bundleID: "com.apple.Terminal", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("single_pids", pids, [300])
  assertTrue("single_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testMultipleCallApps() {
  let procs = [
    SimProcess(pid: 400, bundleID: "com.google.Chrome", isRunning: true),
    SimProcess(pid: 401, bundleID: "us.zoom.xos", isRunning: true),
    SimProcess(pid: 402, bundleID: "com.apple.FaceTime", isRunning: true),
    SimProcess(pid: 403, bundleID: "com.spotify.client", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("multi_pids", pids, [400, 401, 402])
  assertTrue("multi_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testNonCallAppsIgnored() {
  let procs = [
    SimProcess(pid: 500, bundleID: "com.spotify.client", isRunning: true),
    SimProcess(pid: 501, bundleID: "com.apple.dt.Xcode", isRunning: true),
    SimProcess(pid: 502, bundleID: "com.apple.Terminal", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("noncall", pids.count, 0)
  assertFalse("noncall_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testBundleIDCaseInsensitive() {
  let procs = [
    SimProcess(pid: 600, bundleID: "COM.GOOGLE.CHROME", isRunning: true),
    SimProcess(pid: 601, bundleID: "Us.Zoom.Xos", isRunning: true),
    SimProcess(pid: 602, bundleID: "com.Apple.Safari", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("case_pids", pids.sorted(), [600, 601, 602])
  assertTrue("case_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testMixedOwnPIDAndCallApps() {
  let procs = [
    SimProcess(pid: 42, bundleID: "com.meetcapture", isRunning: true),
    SimProcess(pid: 700, bundleID: "com.google.Chrome", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("mixed", pids, [700])
  assertTrue("mixed_any", anyCallAppCapturingInput(processes: procs, ownPID: 42))
}

func testTeamsAndSlack() {
  let procs = [
    SimProcess(pid: 800, bundleID: "com.microsoft.Teams", isRunning: true),
    SimProcess(pid: 801, bundleID: "com.tinyspeck.slackmacgap", isRunning: true),
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("teams_slack", pids, [800, 801])
}

func testEdgeCaseEmptyBundleID() {
  let procs = [
    SimProcess(pid: 900, bundleID: "", isRunning: true)
  ]
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("empty_bundle", pids.count, 0)
}

func testAllCallAppsMatched() {
  let expectedBundles: [(Int, String)] = [
    (1000, "com.google.Chrome"),
    (1001, "com.apple.Safari"),
    (1002, "org.mozilla.Firefox"),
    (1003, "com.microsoft.edgemac"),
    (1004, "com.brave.browser"),
    (1005, "com.operasoftware.opera"),
    (1006, "com.vivaldi.vivaldi"),
    (1007, "company.thebrowser"),
    (1008, "us.zoom.xos"),
    (1009, "com.microsoft.teams"),
    (1010, "com.tinyspeck.slackmacgap"),
    (1011, "com.apple.facetime"),
    (1012, "com.hnc.discord"),
    (1013, "com.cisco.webexmeetingsapp"),
    (1014, "com.skype"),
    (1015, "com.google.meet"),
  ]
  let procs = expectedBundles.map { SimProcess(pid: $0.0, bundleID: $0.1, isRunning: true) }
  let pids = activeCallPIDs(processes: procs, ownPID: 42)
  assertEqual("all_callapps_count", pids.count, expectedBundles.count)
  // Verify all PIDs present
  let expectedPids = expectedBundles.map { $0.0 }.sorted()
  assertEqual("all_callapps_pids", pids, expectedPids)
}

// MARK: - Main

func main() {
  print("=== CallDetectorTests ===")

  testEmptyProcessList()
  print("  emptyProcessList: \(failures.isEmpty ? "PASS" : "FAIL")")

  testOwnPIDExcluded()
  print("  ownPIDExcluded: \(failures.isEmpty ? "PASS" : "FAIL")")

  testNotRunningExcluded()
  print("  notRunningExcluded: \(failures.isEmpty ? "PASS" : "FAIL")")

  testSingleCallApp()
  print("  singleCallApp: \(failures.isEmpty ? "PASS" : "FAIL")")

  testMultipleCallApps()
  print("  multipleCallApps: \(failures.isEmpty ? "PASS" : "FAIL")")

  testNonCallAppsIgnored()
  print("  nonCallAppsIgnored: \(failures.isEmpty ? "PASS" : "FAIL")")

  testBundleIDCaseInsensitive()
  print("  bundleIDCaseInsensitive: \(failures.isEmpty ? "PASS" : "FAIL")")

  testMixedOwnPIDAndCallApps()
  print("  mixedOwnPID: \(failures.isEmpty ? "PASS" : "FAIL")")

  testTeamsAndSlack()
  print("  teamsSlack: \(failures.isEmpty ? "PASS" : "FAIL")")

  testEdgeCaseEmptyBundleID()
  print("  edgeCaseEmptyBundleID: \(failures.isEmpty ? "PASS" : "FAIL")")

  testAllCallAppsMatched()
  print("  allCallAppsMatched: \(failures.isEmpty ? "PASS" : "FAIL")")

  if failures.isEmpty {
    print("RESULT: TODOS LOS TESTS PASARON")
    exit(0)
  } else {
    print("FALLOS:")
    for f in failures { print("  - \(f)") }
    print("RESULT: \(failures.count) FALLO(S)")
    exit(1)
  }
}

main()
