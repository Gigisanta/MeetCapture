// SettingsView.swift
// MeetCapture v5.1 — Preferences window with General / Audio / ASR / IA /
// Calendar / About tabs. ASR + IA settings persist to UserDefaults and are
// read at transcription time by the pipeline.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("notifyHermes") private var notifyHermes = true
    @AppStorage("transcriptDir") private var transcriptDir = ""
    @AppStorage("retention") private var retention = RetentionPolicy.deleteAfterHandoff.rawValue
    @AppStorage("maxRecordingDuration") private var maxRecordingDuration = 10_800.0

    // ASR
    @AppStorage("engine") private var engine = ASREngine.whisper.rawValue
    @AppStorage("asrModel") private var asrModel = "medium-q5_0"
    @AppStorage("asrLanguage") private var asrLanguage = "es"
    @AppStorage("diarize") private var diarize = true
    @AppStorage("sherpaPythonPath") private var sherpaPythonPath = "/Users/gigi/HerMaatOS/venvs/venv-meet/bin/python3"
    @AppStorage("scriptsDir") private var scriptsDir = "/Users/gigi/HerMaatOS/work/meetcapture/scripts"

    // Live streaming ASR (in-call preview)
    @AppStorage("liveTranscribe") private var liveTranscribe = true
    @AppStorage("liveModel") private var liveModel = "zipformer-es"

    // Conversation mode (mic-only)
    @AppStorage("micOnlyMode") private var micOnlyMode = false
    @AppStorage("inputDeviceUID") private var inputDeviceUID = ""
    @State private var inputDevices: [(uid: String, name: String)] = []

    // IA (summary endpoint — consumed by the external summary dispatcher)
    @AppStorage("aiEndpoint") private var aiEndpoint = "http://127.0.0.1:8083/v1"
    @AppStorage("aiModel") private var aiModel = ""
    @AppStorage("aiApiKey") private var aiApiKey = "mlx-local"

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }

            audioSettings
                .tabItem { Label("Audio", systemImage: "speaker.wave.3") }

            asrSettings
                .tabItem { Label("ASR", systemImage: "waveform.badge.mic") }

            iaSettings
                .tabItem { Label("IA", systemImage: "brain.head.profile") }

            calendarSettings
                .tabItem { Label("Calendar", systemImage: "calendar") }

            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 470, height: 380)
    }

    // MARK: - General

    private var generalSettings: some View {
        Form {
            Toggle("Auto-record live calls & calendar meetings", isOn: $autoRecord)
            Text("Starts recording when a browser, Zoom, Teams or FaceTime is using the mic — even for ad-hoc calls not on your calendar.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Show local notification on transcript ready", isOn: $notifyHermes)

            Divider()

            Picker("Retention", selection: $retention) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy.rawValue)
                }
            }
            Text("Controls how long raw audio is kept after transcription. 'Delete after handoff' removes it immediately. 'Keep 24h' defers cleanup to the next launch. 'Keep forever' preserves everything.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Maximum recording", selection: $maxRecordingDuration) {
                Text("1 hour").tag(3_600.0)
                Text("2 hours").tag(7_200.0)
                Text("3 hours").tag(10_800.0)
                Text("4 hours").tag(14_400.0)
                Text("8 hours").tag(28_800.0)
            }
        }
        .padding()
    }

    // MARK: - Audio

    private var audioSettings: some View {
        Form {
            Text("Capture writes a 16kHz Int16 stereo PCM file (L = system audio, R = mic). Model and engine selection live in the ASR tab.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Modo conversación (solo micrófono)", isOn: $micOnlyMode)
            Text("Para conversaciones al lado de la Mac (WhatsApp del celular, llamadas telefónicas): graba solo el micrófono elegido, sin audio del sistema. Para Meet/WhatsApp Desktop/llamadas de apps se usa el modo normal (audio de la app + micrófono).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Dispositivo de entrada", selection: $inputDeviceUID) {
                Text("Sistema (predeterminado)").tag("")
                ForEach(inputDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            Text("Podés elegir el micrófono del iPhone (Continuity) para capturar una llamada del teléfono con mejor audio.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .onAppear {
                    inputDevices = appState.audioCapture.inputDevices()
                }

            HStack {
                Text("Microphone permission:")
                Spacer()
                Circle()
                    .fill(appState.hasAudioPermission ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.hasAudioPermission ? "Granted" : "Required")
                    .font(.caption)
            }

            if !appState.hasAudioPermission {
                Button("Grant Permission") {
                    appState.audioCapture.requestPermission { granted in
                        Task { @MainActor in appState.hasAudioPermission = granted }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - ASR

    private var asrSettings: some View {
        Form {
            Picker("Engine", selection: $engine) {
                Text("Whisper (whisper.cpp, local)").tag(ASREngine.whisper.rawValue)
                Text("Sherpa (transcribe_sherpa.py, whole-file)").tag(ASREngine.sherpa.rawValue)
            }
            Text("Sherpa runs after the recording finishes. If the sherpa script is missing or fails, the app falls back to Whisper automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Model", text: $asrModel)
            Text("Whisper: tiny/base/small/medium/large-v3-turbo (medium-q5_0 recommended for Spanish). Sherpa: parakeet or zipformer-es.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Language", selection: $asrLanguage) {
                Text("Spanish (es)").tag("es")
                Text("Auto-detect").tag("auto")
            }

            Toggle("Speaker diarization (post-transcription)", isOn: $diarize)
            Text("Runs scripts/speaker_diarize.py after transcribing; labels each segment with its speaker. Falls back to no labels if the script is unavailable.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Toggle("Live transcription while recording", isOn: $liveTranscribe)
            Text("Streams the captured audio to sherpa-onnx in real time — partial text appears in the popover during the call. The final transcript still uses the engine above (more accurate + diarized).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Picker("Live model", selection: $liveModel) {
                Text("Español (zipformer-es)").tag("zipformer-es")
                Text("English (zipformer-en)").tag("zipformer-en")
            }

            Divider()

            TextField("Sherpa Python", text: $sherpaPythonPath)
            TextField("Scripts directory", text: $scriptsDir)
                .font(.caption2)
        }
        .padding()
    }

    // MARK: - IA

    private var iaSettings: some View {
        Form {
            TextField("Endpoint URL", text: $aiEndpoint)
            Text("OpenAI-compatible endpoint used by the summary dispatcher. Default: local MLX server.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Summary model", text: $aiModel)
            Text("Empty = auto (server default).")
                .font(.caption2)
                .foregroundStyle(.secondary)

            SecureField("API key", text: $aiApiKey)
            Text("Default 'mlx-local' for the local MLX stack.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Calendar

    private var calendarSettings: some View {
        Form {
            HStack {
                Text("Calendar access:")
                Spacer()
                Circle()
                    .fill(appState.hasCalendarAccess ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.hasCalendarAccess ? "Granted" : "Required")
                    .font(.caption)
            }

            if !appState.hasCalendarAccess {
                Button("Grant Access") {
                    Task {
                        await appState.calendarService.requestAccess()
                    }
                }
            }

            Text("Whitelisted emails:")
                .font(.caption)
            ForEach(Array(CalendarService.whitelistedEmails), id: \.self) { email in
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - About

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("MeetCapture")
                .font(.title2)

            Text("v6.2.0")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Automatic call transcription — Meet, Zoom, Teams, WhatsApp & more")
                .font(.caption)

            Link("GitHub", destination: URL(string: "https://github.com/Gigisanta/MeetCapture")!)
                .font(.caption)
        }
        .padding()
    }
}
