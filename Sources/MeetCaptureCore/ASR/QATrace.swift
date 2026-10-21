// Explicitly opt-in evidence for isolated QA runs, never production telemetry.
import CryptoKit
import Foundation

enum QATrace {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return Bundle.main.bundleIdentifier == "com.maatwork.meetcapture.qa"
            && environment["MEETCAPTURE_QA_TRACE"] == "1"
            && ["import", "capture", "ui", "diagnostic", "resampler", "cancel"].contains(environment["MEETCAPTURE_REAL_CHECK"] ?? "")
    }()

    struct Context: Codable, Sendable {
        var jobID: String
        var channel: String? = nil
        var chunkIndex: Int? = nil
        var chunkCount: Int? = nil
        var startSample: Int? = nil
        var endSample: Int? = nil
        var sampleRate: Int? = nil
        var offsetSeconds: Double? = nil
        var inputSHA256: String? = nil
        var attempt: Int? = nil
        var invocationID: String? = nil
    }

    /// Inherited by SDK work without sharing mutable decoder state or adding locks.
    @TaskLocal static var context: Context?

    struct RecognizerIdentity: Codable, Equatable, Sendable {
        var adapterType: String
        var engine: String? = nil
        var model: String? = nil
        var sdk: String? = nil
        var sdkRevision: String? = nil
        var modelRepository: String? = nil
        var modelRevisionStatus: String? = nil
        var configuration: [String: String]? = nil
    }

    enum Failure: LocalizedError {
        case evidence(String)

        var errorDescription: String? {
            switch self {
            case .evidence(let message): return "QA trace evidence failed: \(message)"
            }
        }
    }

    private struct Record<Value: Encodable>: Encodable {
        let schemaVersion = 1
        var traceID: String
        var name: String
        var createdAt: Date
        var context: Context?
        var value: Value
    }

    private struct AudioDescriptor: Encodable {
        var file: String
        let encoding = "float32-le"
        let channels = 1
        var sampleRate: Int
        var sampleCount: Int
        var byteCount: Int
        var sha256: String
    }

    static func write<T: Encodable>(_ value: T, name: String) throws {
        guard isEnabled else { return }
        do {
            let directory = try outputDirectory()
            let id = UUID().uuidString
            let stem = try fileStem(name: name, id: id)
            try writeRecord(value, name: name, id: id, to: directory.appendingPathComponent(stem + ".json"))
        } catch {
            throw Failure.evidence("\(name): \(error.localizedDescription)")
        }
    }

    /// Headerless, lossless Float32 samples plus a checksummed JSON sidecar.
    /// MeetCapture's supported macOS architectures are both little-endian.
    static func writeAudio(_ samples: [Float], name: String) throws {
        guard isEnabled else { return }
        do {
            let directory = try outputDirectory()
            let id = UUID().uuidString
            let stem = try fileStem(name: name, id: id)
            let audioURL = directory.appendingPathComponent(stem + ".f32le")
            let data = samples.withUnsafeBytes { Data($0) }
            try writePrivate(data, to: audioURL)
            let descriptor = AudioDescriptor(file: audioURL.lastPathComponent,
                                             sampleRate: context?.sampleRate ?? PCMToWAV.targetSampleRate,
                                             sampleCount: samples.count, byteCount: data.count,
                                             sha256: audioSHA256(samples))
            try writeRecord(descriptor, name: name, id: id,
                            to: directory.appendingPathComponent(stem + ".json"))
        } catch {
            throw Failure.evidence("\(name): \(error.localizedDescription)")
        }
    }

    static func audioSHA256(_ samples: [Float]) -> String {
        var hash = SHA256()
        samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func writeRecord<T: Encodable>(_ value: T, name: String, id: String, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        // Invalid SDK timestamps/confidences must remain inspectable instead of
        // making their raw result impossible to persist before validation.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let record = Record(traceID: id, name: name, createdAt: Date(), context: context, value: value)
        try writePrivate(encoder.encode(record), to: url)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func fileStem(name: String, id: String) throws -> String {
        guard !name.isEmpty, name.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 95
        }) else {
            throw Failure.evidence("invalid trace name")
        }
        return name + "-" + id
    }

    private static func outputDirectory() throws -> URL {
        guard let output = ProcessInfo.processInfo.environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
              !output.isEmpty, (output as NSString).isAbsolutePath else {
            throw Failure.evidence("MEETCAPTURE_TEST_OUTPUT_DIR must be an absolute isolated path")
        }
        let root = URL(fileURLWithPath: output, isDirectory: true).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent("qa-traces", isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw Failure.evidence("qa-traces must not redirect outside the isolated output")
        }
        try AppPaths.ensurePrivateDirectory(directory.path)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw Failure.evidence("qa-traces changed while creating the evidence directory")
        }
        return directory
    }
}
