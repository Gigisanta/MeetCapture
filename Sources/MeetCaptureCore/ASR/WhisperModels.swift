// WhisperModels.swift
// whisper.cpp ggml model catalogue: names, quantized variants, on-disk
// lookup and the one-shot memory-aware selection. whisper-cli is a
// per-run subprocess that mmaps the model, so there is no "loaded" state.

import Foundation
import os

enum WhisperQuant: String, Sendable {
    case f16
    case q5_1
    case q5_0

    var filenameSuffix: String {
        switch self {
        case .f16: return ".bin"
        case .q5_1: return "-q5_1.bin"
        case .q5_0: return "-q5_0.bin"
        }
    }
}

enum WhisperModelSize: String, Sendable {
    case tiny, base, small, medium, large
    case largeV3Turbo = "large-v3-turbo"

    /// Approximate f16 file size in GB.
    var estimatedMemoryGB: Double {
        switch self {
        case .tiny: return 0.05
        case .base: return 0.10
        case .small: return 0.46
        case .medium: return 1.50
        case .large: return 2.90
        case .largeV3Turbo: return 1.50
        }
    }

    var filenameStem: String { "ggml-\(rawValue)" }

    func filename(quant: WhisperQuant) -> String { filenameStem + quant.filenameSuffix }

    /// "medium", "medium-q5_0" or "large-v3-turbo" → size; unknown → nil.
    static func normalized(from setting: String) -> WhisperModelSize? {
        var base = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["-q5_0", "-q5_1", "-q8_0", "-f16"] where base.hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
            break
        }
        return WhisperModelSize(rawValue: base)
    }
}

struct WhisperModels: Sendable {
    let directory: String
    static let threads = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount))
    static let fallbackOrder: [WhisperModelSize] = [.largeV3Turbo, .medium, .small, .base, .tiny]

    /// ~/.whisper/models when it exists, else Application Support.
    static var `default`: WhisperModels {
        let preferred = AppPaths.current.whisperModelsDir
        if FileManager.default.fileExists(atPath: preferred) { return WhisperModels(directory: preferred) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("MeetCapture/Models").path }
            ?? (NSHomeDirectory() + "/Library/Application Support/MeetCapture/Models")
        try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        return WhisperModels(directory: support)
    }

    /// Best local file for a size: q5_1 > q5_0 > f16. nil when none exists.
    func bestPath(for size: WhisperModelSize) -> String? {
        for quant in [WhisperQuant.q5_1, .q5_0, .f16] {
            let path = directory + "/" + size.filename(quant: quant)
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// Newest `ggml-silero*.bin` in the models dir, if any.
    var vadModelPath: String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix("ggml-silero") && $0.hasSuffix(".bin") }.sorted().last
            .map { directory + "/" + $0 }
    }

    /// Honors the setting when the file exists and its working set (~60 % of
    /// the file, since whisper-cli mmaps it) fits in reclaimable memory;
    /// otherwise the largest downloaded model that fits. nil = nothing downloaded.
    func select(setting: String, availableMB: UInt64 = WhisperModels.availableMemoryMB()) -> (size: WhisperModelSize, path: String)? {
        func fits(_ size: WhisperModelSize) -> Bool {
            availableMB > UInt64(size.estimatedMemoryGB * 0.6 * 1024)
        }
        let preferred = WhisperModelSize.normalized(from: setting) ?? .medium
        if let path = bestPath(for: preferred), fits(preferred) { return (preferred, path) }
        for size in Self.fallbackOrder {
            if let path = bestPath(for: size), fits(size) { return (size, path) }
        }
        for size in Self.fallbackOrder.reversed() {
            if let path = bestPath(for: size) { return (size, path) }
        }
        return nil
    }

    private static let pageSize: UInt64 = {
        var size = vm_size_t(0)
        var length = MemoryLayout<vm_size_t>.size
        sysctlbyname("vm.pagesize", &size, &length, nil, 0)
        return size > 0 ? UInt64(size) : 16_384
    }()

    /// Free + inactive pages, in MB (what the OS can hand to a new mmap).
    static func availableMemoryMB() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 512 }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize / (1024 * 1024)
    }
}
