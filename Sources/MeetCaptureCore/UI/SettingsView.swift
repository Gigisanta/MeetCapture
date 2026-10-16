// SettingsView.swift
// General / Audio / ASR / Resumen / Calendario / Acerca de.
// UserDefaults keys and defaults come from Settings; summary.json and
// config.json are edited through their own types.

import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @AppStorage(Settings.Key.autoRecord.rawValue) private var autoRecord = Settings.Default.autoRecord
    @AppStorage(Settings.Key.notifyHermes.rawValue) private var notifyHermes = Settings.Default.notifyHermes
    @AppStorage(Settings.Key.retention.rawValue) private var retention = Settings.Default.retention.rawValue
    @AppStorage(Settings.Key.maxRecordingDuration.rawValue) private var maxRecordingDuration = Settings.Default.maxRecordingDuration
    @AppStorage(Settings.Key.asrModel.rawValue) private var asrModel = Settings.Default.asrModel
    @AppStorage(Settings.Key.asrLanguage.rawValue) private var asrLanguage = Settings.Default.asrLanguage
    @AppStorage(Settings.Key.diarize.rawValue) private var diarize = Settings.Default.diarize
    @AppStorage(Settings.Key.sherpaPythonPath.rawValue) private var sherpaPythonPath = Settings.Default.sherpaPythonPath
    @AppStorage(Settings.Key.scriptsDir.rawValue) private var scriptsDir = Settings.Default.scriptsDir
    @AppStorage(Settings.Key.micOnlyMode.rawValue) private var micOnlyMode = Settings.Default.micOnlyMode
    @AppStorage(Settings.Key.inputDeviceUID.rawValue) private var inputDeviceUID = Settings.Default.inputDeviceUID

    @State private var inputDevices: [InputDevice] = []
    @State private var summaryConfig = SummaryDispatcherConfig.load()
    @State private var summarySaved = false
    @State private var localConfig = LocalConfig.load()

    private typealias S = Strings.Settings

    var body: some View {
        TabView {
            general.tabItem { Label(S.general, systemImage: "gear") }
            audio.tabItem { Label(S.audio, systemImage: "speaker.wave.3") }
            asr.tabItem { Label(S.asr, systemImage: "waveform.badge.mic") }
            summary.tabItem { Label(S.summary, systemImage: "text.badge.checkmark") }
            calendar.tabItem { Label(S.calendar, systemImage: "calendar") }
            about.tabItem { Label(S.about, systemImage: "info.circle") }
        }
        .frame(width: 480, height: 400)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Toggle(S.autoRecord, isOn: $autoRecord)
            help(S.autoRecordHelp)
            Toggle(S.notify, isOn: $notifyHermes)
            Divider()
            Picker(S.retention, selection: $retention) {
                ForEach(RetentionPolicy.allCases) { policy in
                    Text(S.retention(policy)).tag(policy.rawValue)
                }
            }
            Picker(S.maxDuration, selection: $maxRecordingDuration) {
                ForEach([1, 2, 3, 4, 8], id: \.self) { hours in
                    Text(S.hours(hours)).tag(Double(hours) * 3_600)
                }
            }
        }
        .padding()
    }

    // MARK: - Audio

    private var audio: some View {
        Form {
            help(S.audioHelp)
            Toggle(S.micOnly, isOn: $micOnlyMode)
            help(S.micOnlyHelp)
            Picker(S.inputDevice, selection: $inputDeviceUID) {
                Text(S.systemDefault).tag("")
                ForEach(inputDevices) { device in Text(device.name).tag(device.uid) }
            }
            .onAppear { inputDevices = InputDevices.list() }
            permissionRow(S.micPermission, granted: appState.hasAudioPermission) {
                appState.audioCapture.requestPermission { granted in
                    Task { @MainActor in appState.hasAudioPermission = granted }
                }
            }
        }
        .padding()
    }

    // MARK: - ASR

    private var asr: some View {
        Form {
            TextField(S.model, text: $asrModel)
            help(S.modelHelp)
            Picker(S.language, selection: $asrLanguage) {
                Text(S.spanish).tag("es")
                Text(S.english).tag("en")
                Text(S.autoDetect).tag("auto")
            }
            Toggle(S.diarize, isOn: $diarize)
            Divider()
            LabeledContent(S.toolchain) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.toolchain.pythonDescription)
                    Text(appState.toolchain.scriptsDescription)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(S.choosePython) { choose(directories: false) { sherpaPythonPath = $0 } }
                Button(S.chooseScripts) { choose(directories: true) { scriptsDir = $0 } }
                Button(S.resetToolchain) {
                    sherpaPythonPath = ""
                    scriptsDir = ""
                    Task { await appState.refreshToolchain() }
                }
            }
            .controlSize(.small)
            help(S.toolchainHelp)
        }
        .padding()
        .onChange(of: sherpaPythonPath) { _, _ in Task { await appState.refreshToolchain() } }
        .onChange(of: scriptsDir) { _, _ in Task { await appState.refreshToolchain() } }
    }

    // MARK: - Resumen

    private var summary: some View {
        Form {
            help(S.summaryHelp)
            TextField(S.endpoint, text: $summaryConfig.endpoint)
            TextField(S.summaryModel, text: $summaryConfig.model)
            SecureField(S.apiKey, text: $summaryConfig.apiKey)
            Stepper("\(S.maxTokens): \(summaryConfig.maxTokens)", value: $summaryConfig.maxTokens, in: 256...16_000, step: 256)
            Toggle(S.keepAudio, isOn: $summaryConfig.keepAudio)
            Toggle(S.dryRun, isOn: $summaryConfig.dryRun)
            TextField(S.tagVocabularyDir, text: $summaryConfig.tagVocabularyDir)
            help(S.tagVocabularyHelp)
            HStack {
                Button(S.save) {
                    do {
                        try summaryConfig.save()
                        summarySaved = true
                    } catch {
                        appState.errorMessage = error.localizedDescription
                    }
                }
                if summarySaved { Text(S.saved).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding()
        .onAppear { summaryConfig = SummaryDispatcherConfig.load(); summarySaved = false }
    }

    // MARK: - Calendario

    private var calendar: some View {
        Form {
            permissionRow(S.calendarPermission, granted: appState.hasCalendarAccess) {
                Task {
                    await appState.calendarService.requestAccess()
                    appState.hasCalendarAccess = appState.calendarService.isAuthorized
                }
            }
            help(S.calendarHelp)
            Divider()
            Text(S.whitelist).font(.caption)
            if localConfig.whitelistedEmails.isEmpty {
                help(S.whitelistEmpty)
            } else {
                ForEach(localConfig.whitelistedEmails, id: \.self) { email in
                    Text(email).font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(S.editConfig) { editConfig() }
                Button(S.reloadConfig) {
                    localConfig = LocalConfig.load()
                    appState.calendarService.whitelist = Set(localConfig.whitelistedEmails)
                    appState.calendarService.refreshMeetings()
                    Task { await appState.refreshToolchain() }
                }
            }
            .controlSize(.small)
        }
        .padding()
        .onAppear { localConfig = LocalConfig.load() }
    }

    // MARK: - Acerca de

    private var about: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(AppInfo.name).font(.title2)
            Text("v\(AppInfo.version)").font(.caption).foregroundStyle(.secondary)
            Text(S.aboutTagline).font(.caption).multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link(S.website, destination: AppInfo.websiteURL)
                Link(S.source, destination: AppInfo.repositoryURL)
            }
            .font(.caption)
        }
        .padding()
    }

    // MARK: - Helpers

    private func help(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }

    private func permissionRow(_ label: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
            Spacer()
            Circle().fill(granted ? Brand.successGreen : Brand.recordingRed).frame(width: 8, height: 8)
            Text(granted ? S.granted : S.required).font(.caption)
            if !granted { Button(Strings.grant) { request() }.controlSize(.small) }
        }
    }

    private func choose(directories: Bool, _ apply: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { apply(url.path) }
    }

    private func editConfig() {
        let path = AppPaths.current.configFile
        if !FileManager.default.fileExists(atPath: path) {
            try? AppPaths.ensurePrivateDirectory(AppPaths.current.configDir)
            let example = Bundle.main.resourcePath.map { $0 + "/config.example.json" }
            if let example, FileManager.default.fileExists(atPath: example) {
                try? FileManager.default.copyItem(atPath: example, toPath: path)
            } else {
                let template = """
                {
                  "whitelistedEmails": [],
                  "domainPrompt": "",
                  "python": "",
                  "scriptsDir": ""
                }
                """
                try? template.write(toFile: path, atomically: true, encoding: .utf8)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
