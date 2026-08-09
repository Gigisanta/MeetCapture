// MeetingStore.swift
// MeetCapture v5.1 — SQLite store for meeting history + search.
//
// DB lives at ~/meetings/meetcapture.db (overridable via
// MEETCAPTURE_TEST_OUTPUT_DIR for isolated tests). Single connection
// guarded by a lock — all access is synchronous and fast.
//
// ponytail: no migration framework, no ORM. Raw sqlite3 C API with a
// fixed schema (v1). If the schema ever needs to evolve, bump a
// user_version pragma and add ALTERs here.

import Foundation
import SQLite3

/// SQLITE_TRANSIENT is a C macro ((sqlite3_destructor_type)-1) that macros
/// don't cross into Swift — reproduce it so sqlite3_bind_text copies its
/// argument instead of assuming static lifetime.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Record

struct MeetingRecord: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date
    let durationSec: Double
    let engine: String
    let model: String
    let language: String
    let transcriptPath: String
    let summaryPath: String?
    let speakerCount: Int
    let transcriptText: String
}

// MARK: - Store

final class MeetingStore: @unchecked Sendable {
    static let shared = MeetingStore()

    private let lock = NSLock()
    private var db: OpaquePointer?

    private init() {
        let path: String
        if let testDir = ProcessInfo.processInfo.environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
           !testDir.isEmpty {
            path = "\(testDir)/meetcapture.db"
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            path = "\(home)/meetings/meetcapture.db"
        }
        openDatabase(path: path)
    }

    private func openDatabase(path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS meetings (
          id TEXT PRIMARY KEY,
          title TEXT,
          started_at TEXT,
          ended_at TEXT,
          duration_sec REAL,
          engine TEXT,
          model TEXT,
          language TEXT,
          transcript_path TEXT,
          summary_path TEXT,
          speaker_count INTEGER,
          transcript_text TEXT
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    // MARK: - Write

    func insert(_ record: MeetingRecord) {
        guard let db else { return }
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO meetings
          (id, title, started_at, ended_at, duration_sec, engine, model, language,
           transcript_path, summary_path, speaker_count, transcript_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let iso = ISO8601DateFormatter()
        sqlite3_bind_text(stmt, 1, (record.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (record.title as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, (iso.string(from: record.startedAt) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, (iso.string(from: record.endedAt) as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, record.durationSec)
        sqlite3_bind_text(stmt, 6, (record.engine as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, (record.model as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, (record.language as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, (record.transcriptPath as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let summary = record.summaryPath {
            sqlite3_bind_text(stmt, 10, (summary as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_bind_int(stmt, 11, Int32(record.speakerCount))
        sqlite3_bind_text(stmt, 12, (record.transcriptText as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Read

    func recent(limit: Int) -> [MeetingRecord] {
        query("SELECT * FROM meetings ORDER BY started_at DESC LIMIT \(max(1, limit));")
    }

    func search(_ queryText: String) -> [MeetingRecord] {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: 20) }
        // Escape LIKE wildcards so user input is matched literally.
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = """
        SELECT * FROM meetings
        WHERE title LIKE '%' || ? || '%' ESCAPE '\\'
           OR transcript_text LIKE '%' || ? || '%' ESCAPE '\\'
        ORDER BY started_at DESC LIMIT 50;
        """
        return query(sql, binds: [escaped, escaped])
    }

    private func query(_ sql: String, binds: [String] = []) -> [MeetingRecord] {
        guard let db else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }

        let iso = ISO8601DateFormatter()
        var rows: [MeetingRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ idx: Int32) -> String {
                guard let c = sqlite3_column_text(stmt, idx) else { return "" }
                return String(cString: c)
            }
            func colOpt(_ idx: Int32) -> String? {
                guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
                      let c = sqlite3_column_text(stmt, idx) else { return nil }
                return String(cString: c)
            }
            let started = iso.date(from: col(2)) ?? Date()
            let ended = iso.date(from: col(3)) ?? started
            rows.append(MeetingRecord(
                id: col(0),
                title: col(1),
                startedAt: started,
                endedAt: ended,
                durationSec: sqlite3_column_double(stmt, 4),
                engine: col(5),
                model: col(6),
                language: col(7),
                transcriptPath: col(8),
                summaryPath: colOpt(9),
                speakerCount: Int(sqlite3_column_int(stmt, 10)),
                transcriptText: col(11)
            ))
        }
        return rows
    }
}
