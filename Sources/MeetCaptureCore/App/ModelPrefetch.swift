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
                let identity = try await ParakeetEngine.shared.prepare()
                await ParakeetEngine.shared.release()
                try await FluidDiarizer.prefetch()
                print("MODELS_READY \(identity.model)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("MODELS_FAILED \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
