// RecognitionIdentity.swift
// Checkpoints belong to the effective recognizer, not merely an engine label.

import CryptoKit
import Foundation

struct RecognitionIdentity: Codable, Equatable, Sendable {
    var engine: ASREngine
    var model: String
    var modelRepository: String
    /// A local content digest when the SDK does not expose an immutable upstream revision.
    var modelRevision: String
    var sdk: String
    var sdkRevision: String
    var configuration: [String: String]
}

enum ContentFingerprint {
    /// Bounded reads: hashing a model or a long recording never loads it into an array.
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
