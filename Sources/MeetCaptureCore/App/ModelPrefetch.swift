// ModelPrefetch.swift
// MEETCAPTURE_PREFETCH_MODELS=1: download and compile the speech models, then
// exit. install.sh runs it so the first meeting needs no network or wait.

import Foundation

public enum ModelPrefetch {
    @MainActor
    public static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["MEETCAPTURE_PREFETCH_MODELS"] == "1" else { return false }
        Task.detached {
            do {
                try QAExperiment.validate()
                let recognizer = SpeechBackend.selected
                try await recognizer.prepare()
                await recognizer.unload()
                if !QAExperiment.isEnabled { try await FluidDiarizer.prefetch() }
                print("MODELS_READY \(recognizer.modelName)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("MODELS_FAILED \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
