import CryptoKit
import Foundation

/// Launch-scoped identity of the bytes used by the research arm, not an invented upstream revision.
enum QAModelArtifacts {
    static let parakeetFingerprint: Result<String, Error> = Result {
        guard QAExperiment.isEnabled else { return "SDK-managed-cache; artifact revision unverified" }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-ultra")
        var paths = ["config.json", "parakeet_vocab.json"]
        for model in ["Decoder", "Encoder", "JointDecisionv3", "Preprocessor"] {
            paths += ["model.mil", "coremldata.bin", "weights/weight.bin"].map { "\(model).mlmodelc/\($0)" }
        }
        var manifest = SHA256()
        for path in paths.sorted() {
            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(path))
            defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            manifest.update(data: Data("\(path)\t\(digest)\n".utf8))
        }
        return manifest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
