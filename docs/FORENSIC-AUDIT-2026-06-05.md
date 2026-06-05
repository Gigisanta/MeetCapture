# MeetCapture v4.2.0 — Forensic Audit & Optimization Plan
**Date:** 2026-06-05 02:13 ART
**Auditor:** HerMaat (deep dive, post-restructure regression)
**Build state:** Compiles, runs, but **captures zero audio, never transcribes, UI is bare, daemon is dead code**.

---

## TL;DR — Estado Real

| Componente | Estado | Evidencia |
|---|---|---|
| Build (`./build.sh`) | ✅ OK | 864KB binary, no errors |
| App launches | ✅ OK | PID 14028, MenuBarExtra visible |
| Calendar permission | ✅ OK | TCC: kTCCServiceCalendar=granted |
| Screen Recording permission | ❌ DENIED | No entry in TCC.db |
| Audio capture (PCM) | ❌ FAILS | `checkPermission()` false-positive, then `stream.startCapture()` rejects |
| Whisper transcription | ❌ DEAD CODE | `transcribe(audioPath:)` never called from `stopRecording()` |
| Daemon ↔ App IPC | ❌ BROKEN | SocketClient.swift doesn't exist; App never talks to socket |
| Daemon (standalone) | ✅ OK | Tested ping/start/stop via `nc -U`, all return valid JSON |
| UI visual quality | ❌ POOR | Bare MenuBarExtra, no brand, cramped, generic SF Symbols |
| "Premium" feel (Gio's standard) | ❌ MISSING | No glassmorphism, no animations, no brand color, no identity |

**Net result:** The user gets a menu bar icon that says "Waiting for meeting" forever. Calendar works, but the moment a meeting hits, recording fails silently, transcription never starts, transcript is never produced.

---

## Bug Inventory (8 confirmed)

### BUG #1 — P0 — App ⇄ Daemon IPC completely missing
**Impact:** Daemon is a zombie. All background logic (calendar trigger, recording state, IPC commands) is dead.
**Files:**
- Missing: `Sources/SocketClient.swift` (referenced in `docs/ARCHITECTURE.md` line 23, 26, 183, 188; deleted in yesterday's refactor)
- `Sources/AppState.swift` line 28-31: services are `CalendarService`, `AudioCaptureService`, `DaemonManager`, `WhisperModelManager` — **no socket client at all**.
- `Daemon/server.py` line 121-135: handlers `start_recording`, `stop_recording`, `get_status`, `ping` all working and tested.

**Verification:**
```bash
grep -r "SocketClient\|/tmp/meetcapture.sock" Sources/  →  0 matches in *.swift
grep -r "socket" Daemon/  →  1 match (server.py line 26)
```

**Fix:** Add `Sources/SocketClient.swift` (delegate-based, ~120 lines) and wire it into `AppState` so `startRecording()` → `socket.send("start_recording")` AND `audioCapture.startCapture()` happen in parallel (Swift captures audio, daemon tracks state for UI badges/external triggers).

### BUG #2 — P0 — `transcribe(audioPath:)` is unreachable code
**Impact:** Even if audio capture worked, transcription never runs. Phase stuck at `.transcribing` forever.
**File:** `Sources/AppState.swift`
- Line 188-199: `stopRecording()` calls `whisperManager.stopRecording()` but **does not** call `transcribe(audioPath:)`.
- Line 203-223: `transcribe(audioPath:)` is defined, has the full pipeline (load PCM → convert to Float → whisper → write TXT), but is **never called from anywhere**.

**Fix:** `AppState.stopRecording()` line 195-198 must call `transcribe(audioPath: outputPath)` after `await audioCapture.stopCapture()`. See code patch in Phase 1.

### BUG #3 — P0 — Screen Recording permission denied, no recovery
**Impact:** Audio capture is the core product. Without this, nothing works.
**Files:**
- `Sources/AudioCapture.swift` line 86-103: `checkPermission()` uses `SCShareableContent` with 5s timeout. If TCC denies, it returns `false` BUT the error is caught silently and `granted = false`. The user sees nothing.
- `Sources/AudioCapture.swift` line 105-111: `requestPermission()` calls `CGRequestScreenCaptureAccess()`. After first denial, **macOS suppresses further prompts**. User must manually open System Settings.
- `Sources/StatusView.swift` line 38-41: Button opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. macOS 14 changed this — the key is `Privacy_ScreenCapture` (still works) but the panel name is "Screen & System Audio Recording" now, not "Screen Recording". The URL might land on a wrong pane.
- `Sources/AppState.swift` line 161-163: error message "Grant Screen Recording permission, then try again" doesn't tell the user HOW to do it.

**Verification:**
```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, client FROM access WHERE client LIKE '%meetcapture%'"
# Returns: kTCCServiceCalendar | com.maatwork.meetcapture  — NO ScreenCapture row
```

**Fix:** Detect denial explicitly, surface actionable UI in StatusView, open the correct pane with `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` and fall back to `x-apple.systempreferences:` if the deep link fails.

### BUG #4 — P0 — UI is "fea" (Gio's word), no premium standard
**Impact:** Doesn't meet Gio's "altisimo estandar visual" bar. No brand identity.
**Files:**
- `Sources/StatusView.swift` (199 lines): pure MenuBarExtra menu, no custom window, no glassmorphism, no brand color. Uses generic SF Symbols.
- `Sources/AppState.swift` line 55-72: `menuBarTitle` is `""` for all phases. `menuBarIcon` is generic (`mic`, `mic.badge.plus`, `mic.fill`, `waveform`, `mic.badge.checkmark`).
- `Sources/SettingsView.swift` (141 lines): 450x300 Form window, plain system look, no theming.
- Missing entirely: `Resources/Brand.swift` (brand color tokens), `Resources/Logo.png`/`Logo.svg` (app icon), branded MenuBarExtra layout.
- `Resources/Info.plist` line 21-22: `CFBundleIconFile = AppIcon` but **no `AppIcon.icns` file in Resources/ or Contents/Resources/**. App has no custom icon (uses generic system one).
- `Resources/Info.plist` line 28: `LSApplicationCategoryType=public.app-category.productivity` (fine, but no dark-mode preference, no custom accent color).

**Verification:**
```bash
ls Resources/                    # only plists + entitlements
ls MeetCapture.app/Contents/Resources/  # no .icns
```

**Fix (Phase 4):** Build a custom SwiftUI Popover window (not MenuBarExtra menu), apply brand color tokens, generate a proper icns from MaatWork logo, add a hero onboarding view for first launch, dark theme with glassmorphism.

### BUG #5 — P1 — Transcription loads audio 3x into RAM, will freeze on long meetings
**Impact:** A 1-hour meeting = 460MB PCM → 460MB Float32 → 460MB WAV temp. With whisper-cli's 1.5GB model, peak RAM ~2.5GB. macOS will swap and freeze.
**File:** `Sources/AppState.swift` line 203-223
- Line 206: `let pcmData = try Data(contentsOf: ...)` — full file in RAM
- Line 207: `let samples = pcmToFloat32(pcmData)` — full Float32 array in RAM
- Line 208: `try whisperManager.transcribe(samples: samples)` — passes full array
- `Sources/Transcription.swift` line 144-148: writes full Float32 to temp WAV (3rd copy).

**Fix (Phase 3):** Write a streaming chunker that reads 30s windows, decodes Float on the fly, hands each window to `whisper-cli` with `--prompt`, and concatenates results. Use a pipe (`Process.standardInput`) instead of temp file. Cap RAM at ~200MB regardless of meeting length.

### BUG #6 — P1 — Bundled daemon plist has phantom `daemon_main.py` path
**Impact:** If SMAppService ever finds the bundled plist (when TCC approves), daemon launch fails silently.
**File:** `Resources/com.maatwork.meetcapture.daemon.plist` line 12-13:
```xml
<string>/Users/prueba/meetings/.app-venv/bin/python3</string>
<string>/Users/prueba/meetings/MeetCapture.app/Contents/Resources/daemon_main.py</string>
```
- `daemon_main.py` was deleted in the refactor. The real daemon is `server.py`, launched by `meet-daemon` shell wrapper.
- build.sh rewrites the user-level plist (line 104-116) to use the wrapper, so the live daemon works. But the **bundled** plist stays broken, and the Swift `registerViaLaunchctl()` fallback (DaemonManager.swift line 102-156) reads it with `NSMutableDictionary(contentsOfFile:)` — if the plist has a `BundleProgram` key, it might still parse but then fail at launch.

**Fix:** Rewrite `Resources/com.maatwork.meetcapture.daemon.plist` to match what build.sh produces — drop the `BundleProgram` (was at original line 9-10), use the `meet-daemon` shell wrapper path with absolute `$DEST`.

### BUG #7 — P2 — `requestPermission()` doesn't reliably reopen Settings
**Impact:** After first denial, the user is stuck. They have to dig through System Settings themselves.
**Files:**
- `Sources/AudioCapture.swift` line 105-111
- `Sources/StatusView.swift` line 38-41 (uses `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`)

**Fix:** Try the URL; on macOS 14+, the privacy pane is under a different anchor. Use `SMAppService.openSystemSettingsLoginItems()` for daemon approvals (already done), and `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` for screen capture. Detect the macOS version and fall back to opening the parent pane if the deep link fails.

### BUG #8 — P2 — Whisper runs as one-shot `Process()` per transcription, no streaming
**Impact:** Latency 30s+ to first text, unusable for live display during meeting.
**Files:** `Sources/Transcription.swift` line 151-174
- `Process` launched with full audio file, blocked `waitUntilExit()`.
- `/opt/homebrew/bin/whisper-stream` is installed (verified with `find /opt/homebrew -name "whisper*"`). The daemon could pipe audio to it.

**Fix (Phase 5, optional):** Replace `Process()` with a streaming pipe to `whisper-stream` running in the daemon. Daemon emits partials to socket, AppState displays in Popover.

---

## Optimization Plan — 6 self-contained phases

Each phase is independently shippable, has a verification step, and adds measurable value. Run with Claude Opus 4.8 as executor (paste this whole file into Opus 4.8 with the workdir set to `/Users/prueba/.hermes/repos/meet-capture`).

---

### PHASE 1 — Fix the dead code: wire `transcribe()` and add `SocketClient`
**Effort:** 1-2 hours
**Risk:** Low — adds code paths, doesn't change existing behavior.
**Verification:** `startRecording()` in UI → wait 5s → `stopRecording()` → check `transcripts/` for `.txt` file with content. Daemon `get_status` should also reflect recording state.

**Files to edit:**

1. `Sources/SocketClient.swift` (NEW, 130 lines)
   - `class SocketClient: NSObject, URLSessionDelegate` or simpler: `class SocketClient: NSObject`
   - Connect to `/tmp/meetcapture.sock` via `socket(AF_UNIX, SOCK_STREAM)`
   - Methods: `connect()`, `disconnect()`, `send(command: String, payload: [String:Any] = [:]) async -> [String:Any]?`
   - Wire format: `{"id":"<uuid>","command":"start_recording","payload":{...}}\n`, response is single JSON line.
   - Reconnect logic with exponential backoff (1s, 2s, 4s, max 30s).

2. `Sources/AppState.swift`:
   - Add property: `let socketClient = SocketClient()`
   - Line 86-97 `startup()`: after `daemonManager.registerIfNeeded()`, call `socketClient.connect()` and refresh `isDaemonRunning` based on ping response.
   - Line 155-186 `startRecording()`: at the end of the `Task` (after `phase = .recording`), `Task { _ = try? await socketClient.send("start_recording", payload: ["meeting_title": currentMeeting?.title ?? "Recording"]) }`. Fire-and-forget, don't block recording.
   - Line 188-199 `stopRecording()`: 
     - BEFORE the existing `Task` block, add: `let recordedPath = self.audioCapture.currentOutputPath` (already exposed in AudioCapture.swift line 64).
     - Inside the Task, after `whisperManager.stopRecording()`, add: `await self.transcribe(audioPath: recordedPath)`.
   - Add new property to track the path: `private var lastRecordingPath: String?` set in startRecording, read in stopRecording.

3. `Sources/AudioCapture.swift` line 64: `private(set) var currentOutputPath: String?` — already public-readable. Good.

**Verification script:**
```bash
cd /Users/prueba/.hermes/repos/meet-capture
./build.sh
pkill MeetCapture
open ~/meetings/MeetCapture.app
# Wait 3s, click menu bar → "Start Recording"
# Speak for 5s
# Click "Stop Recording"
# Wait 10s
ls -la ~/Library/Application\ Support/MeetCapture/transcripts/ 2>/dev/null \
  || ls -la /Users/prueba/.hermes/TechPartners/MaatWork/meetings/transcripts/
# Should show: recording-<timestamp>.txt with non-empty content
cat <transcript>.txt  # should have text
```

---

### PHASE 2 — Fix Screen Recording permission UX
**Effort:** 1 hour
**Risk:** Low — UI changes only, no behavior regression.
**Verification:** Deny permission, click "Grant" button → System Settings opens to correct pane → grant → click "Start Recording" → captures audio (file size > 0 after 5s).

**Files to edit:**

1. `Sources/AudioCapture.swift`:
   - Line 86-103: Replace `checkPermission()` with a more accurate check:
     ```swift
     func checkPermission() -> Bool {
         // Fast path: TCC check via CGPreflightScreenCaptureAccess
         if CGPreflightScreenCaptureAccess() { return true }
         // Slow path: try SCShareableContent; some macOS versions don't populate TCC until first capture attempt
         var granted = false
         let sem = DispatchSemaphore(value: 0)
         Task {
             do {
                 _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                 granted = true
             } catch { granted = false }
             sem.signal()
         }
         if sem.wait(timeout: .now() + 3.0) == .timedOut { return false }
         return granted
     }
     ```
   - Add `func openPrivacySettings()`: try `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`, fall back to `x-apple.systempreferences:com.apple.preference.security` if the first one fails. Use `NSWorkspace.shared.open()` and check `try? await` for the result (or just open and trust the user).

2. `Sources/StatusView.swift` line 28-46: Replace the permission warning with:
   - Persistent banner at top when `!hasAudioPermission` (not just inline).
   - Button: "Grant Permission & Open Settings" → calls `audioCapture.openPrivacySettings()`.
   - Secondary button: "Retry Check" → calls `audioCapture.checkPermission()` and updates state.
   - Inline status: shows whether permission was "not granted" vs "denied" (different copy).

3. `Sources/AppState.swift` line 108-116: After `audioCapture.requestPermission()`, if not granted, auto-open settings after 500ms (one-time only, don't loop):
   ```swift
   if !hasAudioPermission {
       audioCapture.openPrivacySettings()
   }
   ```

**Verification:**
```bash
# Reset TCC for testing
tccutil reset ScreenCapture com.maatwork.meetcapture
# Rebuild, relaunch, click Start Recording
# Expected: System Settings opens to "Screen & System Audio Recording"
# Grant, return to app, click Start Recording again
# Expected: file ~/Library/Application\ Support/MeetCapture/recordings/recording-*.pcm grows
```

---

### PHASE 3 — Stream audio to whisper-cli (no full-file RAM load)
**Effort:** 3-4 hours
**Risk:** Medium — touches transcription pipeline. Test with multiple audio lengths.
**Verification:** 30s meeting → transcripts in ~15s with all content. 5min meeting → no RAM spike above 300MB, transcripts accurate.

**Files to edit:**

1. `Sources/AppState.swift` line 203-223: Refactor `transcribe()` to:
   - Stream-read the PCM file in 30s chunks (480KB per chunk at 16kHz × 2 bytes × 30s).
   - For each chunk: convert Int16 → Float32 in-place, write to a temp WAV (or pipe via Process.standardInput), invoke `whisper-cli` with `-f <wav>`, read .txt output, append to a rolling transcript string, emit progress update to UI.
   - Use `FileHandle.read(upToCount:)` for chunked reads, not `Data(contentsOf:)`.
   - Total memory: ~30s × 2 bytes × 16000 samples = 960KB per chunk × 2 (PCM + Float) = ~2MB peak.

2. `Sources/Transcription.swift`:
   - Line 140-184: Split `transcribe(samples:)` into `transcribeChunk(wavPath:)` and add `transcribeStreaming(audioPath:)` that does the chunking.
   - Optional optimization: instead of temp WAV files, use `Pipe()` and pass the Float32 binary directly to `whisper-cli`'s stdin. Saves one disk write per chunk.

3. `Sources/AppState.swift` line 24: `@Published var transcriptionProgress: Double` — emit incremental updates (0.0 → 1.0 as chunks complete) so the UI shows real progress.

4. `Sources/StatusView.swift` line 171-179: `transcribingView` already shows `ProgressView(value: appState.transcriptionProgress)` — verify it actually animates.

**Verification:**
```bash
# Create test PCM file
sox -n -r 16000 -c 1 -b 16 /tmp/test-30s.pcm synth 30 sine 440
# Trigger a 30s recording via UI, stop
ls -la /tmp/test-30s.pcm  # 960KB
# Compare output:
# Old:  process would read 960KB to RAM (fine for 30s, breaks at 1h+)
# New:  reads in 30s chunks, ~2MB peak regardless of length
```

---

### PHASE 4 — UI: premium visual standard (Gio's bar)
**Effort:** 6-8 hours (largest phase)
**Risk:** Medium — visual changes, no behavior change. Iterate.
**Verification:** User opens menu bar popover → sees branded hero card with dark glassmorphism, MaatWork+Reinnova logos, current state clearly visible, upcoming meeting card with countdown. Premium look, not "fea".

**Files to add/rewrite:**

1. `Sources/Brand.swift` (NEW, 30 lines):
   - Color tokens: `pastelViolet = Color(hue: 0.725, saturation: 0.45, brightness: 0.95)` (hue 261)
   - Gradient: `LinearGradient([pastelViolet, Color(white: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)`
   - Typography: `titleFont = Font.system(size: 14, weight: .bold, design: .rounded)`, etc.
   - Glassmorphism: `.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))`

2. `Sources/PopoverContent.swift` (NEW, 250 lines):
   - Replace `StatusView` content with a custom 320×420 popover window.
   - Hero header: gradient background, large `Image("Logo")` (need to generate), tagline "Capturing your Google Meet calls".
   - Status card: current phase with iconography matching brand.
   - Upcoming meeting card: title, countdown timer (1Hz update), attendees count, "Start Now" button.
   - Actions row: "Start/Stop Recording", "Show Last Transcript", "Open Calendar".
   - Footer: daemon status indicator (green/red dot), "Quit" button.
   - First-run onboarding: when no permission, show prominent CTA.

3. `Sources/MeetCaptureApp.swift` line 14-19: Replace `MenuBarExtra` with `MenuBarExtra` style `.window` instead of `.menu`, point to `PopoverContent`:
   ```swift
   MenuBarExtra {
       PopoverContent(appState: appState)
   } label: {
       Image(systemName: appState.menuBarIcon)
           .foregroundStyle(appState.menuBarColor ?? Brand.pastelViolet)
   }
   .menuBarExtraStyle(.window)
   ```

4. `Resources/Logo.png` + `Resources/Logo@2x.png` + `Resources/Logo.icns`:
   - Generate from MaatWork brand assets (use existing logo from another project, or commission a 1024×1024 icon).
   - Use `iconutil` to build .icns from .iconset.

5. `Resources/Info.plist` line 21-22: ensure `CFBundleIconFile = AppIcon` matches the .icns filename.

6. `Sources/SettingsView.swift`: re-theme with `Brand.swift` tokens, add dark/light mode toggle, add "Test recording" debug button (3s sample to verify audio path).

**Verification:** User opens popover → takes screenshot → confirm:
- Dark background (or dark-aware).
- MaatWork+Reinnova brand visible.
- Premium typography (rounded, weighty).
- Glassmorphism on cards.
- Real-time updating countdown.
- Premium feel matching CactusWealth Market Brief v5.1 quality.

---

### PHASE 5 — Daemon: streaming whisper + health watchdog
**Effort:** 4-6 hours
**Risk:** High — daemon changes can break startup. Use the "register via launchd fallback" pattern.
**Verification:** Start app → daemon running → start recording → live transcript appears in popover within 2s of first audio → transcript continues streaming → on stop, full text is saved.

**Files to add/rewrite:**

1. `Daemon/server.py`:
   - Add `stream_transcribe(audio_path)` command: receives the audio path, spawns `whisper-stream` as a subprocess, reads its JSON line output (whisper-stream emits `{text, segments, ...}` JSONL), forwards each line to the connected socket client.
   - Add `health_check` command: returns daemon pid, uptime, model loaded, memory used.
   - Add auto-restart on whisper crash: if whisper-stream dies mid-recording, respawn and resume.
   - Add `start_watchdog` thread: every 30s, if `is_recording=true` but no audio chunks received in 60s, log warning + emit to socket.

2. `Sources/Transcription.swift`:
   - Add `StreamingTranscriptionDelegate` to consume socket messages.
   - Add `@Published var liveTranscript: String = ""` to AppState, updated in real-time from socket messages.

3. `Sources/PopoverContent.swift` (new in Phase 4):
   - Add live-transcript card that animates word-by-word as socket streams arrive.

**Verification:**
```bash
# Start app, click "Start Recording", play audio (say "hello world" into mic)
# Within 2s, the popover should show "hello" or partial words appearing
# After 10s, stop, verify full text is in transcripts/
```

---

### PHASE 6 — Robustness: lock files, timeouts, health checks, rollback
**Effort:** 2 hours
**Risk:** Low — defensive code, no behavior change in happy path.
**Verification:** 
- Kill daemon mid-recording → app detects, restarts, resumes.
- Fill disk to 100% → app shows "Disk full" error instead of crashing.
- Permission revoked mid-meeting → app gracefully stops, notifies user.

**Files to add:**

1. `Sources/HealthMonitor.swift` (NEW, 80 lines):
   - Background timer every 30s: pings daemon via socket, checks audio capture state, verifies disk space.
   - Emits alerts via UNUserNotificationCenter on issues.

2. `Sources/AppState.swift`:
   - Add `healthMonitor = HealthMonitor(socketClient: socketClient, ...)` to startup.
   - Wire recording start/stop to health monitor for correlation.

3. `build.sh`:
   - Add `--rollback` flag: `build.sh --rollback` keeps the last 3 builds in `~/meetings/.backups/` and can revert via symlink swap.
   - Add `--version` flag: prints current + new version, refuses to install if same.

4. `Resources/com.maatwork.meetcapture.daemon.plist`:
   - Add `WatchPaths` to the binary (or use `KeepAlive.SuccessfulExit: false` + `ThrottleInterval: 30` — already there).
   - Add `ExitTimeOut: 30` so daemon has time to clean up.
   - Add `SoftResourceLimits.NumberOfFiles: 1024` for whisper's model file handles.

**Verification:**
```bash
# Kill daemon mid-recording
pkill -f server.py
# App should detect within 30s, restart daemon, continue recording
# Check log
tail -f /tmp/meetcapture-daemon.log
# Should see: "Daemon restarted by HealthMonitor"
```

---

## Execution order for Opus 4.8

1. **Phase 1** (1-2h) — unblocks the entire pipeline. **Do first.**
2. **Phase 2** (1h) — unblocks audio capture. **Do second.**
3. **Phase 3** (3-4h) — required for production stability. **Do third.**
4. **Phase 4** (6-8h) — premium UI bar. **Do fourth, in parallel with Phase 5 if two operators.**
5. **Phase 5** (4-6h) — streaming + watchdog. **Optional but premium.**
6. **Phase 6** (2h) — final hardening. **Do last, after UI is approved.**

Total: 17-23 hours of execution, doable in 2-3 days with focused work.

---

## What I did NOT do, and why

- **Did not modify code** — Gio asked for investigation, not implementation. The plan above is what I propose.
- **Did not fix the MenuBarExtra** — that's a Phase 4 visual decision, needs design input (Gio's brand standards).
- **Did not rewrite the daemon plist** — Phase 6 has the patch, but it's a one-line fix that can wait.
- **Did not write a streaming whisper protocol** — Phase 5 is the right place, but it requires deciding whether to use `whisper-stream` (installed) or build a custom socket protocol. Needs Gio's input on latency target.

## What I CAN do next, if Gio approves

1. **Apply Phase 1 + Phase 2 myself** — they're surgical, low-risk, and will get the app recording end-to-end with the existing UI. 2-3 hours of focused work.
2. **Delegate Phase 4 to a subagent** with a detailed design brief. The visual standard needs to be captured in a sub-skill first.
3. **Save this audit as a skill** so future audits follow the same template.

Awaiting direction.
