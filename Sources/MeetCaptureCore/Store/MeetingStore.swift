// MeetingStore.swift
// SQLite history + full-text search. Single connection behind a lock; raw
// sqlite3 C API. Schema versioned with PRAGMA user_version:
//   1  meetings table (original)
//   2  meetings_fts (FTS5 external-content index) + sync triggers

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct MeetingRecord: Identifiable, Codable, Equatable, Sendable {
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

/// Everything but the transcript text: what lists and search results show.
struct MeetingSummary: Identifiable, Equatable, Sendable {
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
}

final class MeetingStore: @unchecked Sendable {
    static let shared = MeetingStore(path: AppPaths.current.databasePath)
    static let currentSchemaVersion: Int32 = 2

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let logger = AppInfo.logger("MeetingStore")

    init(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? AppPaths.ensurePrivateDirectory(dir)
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            logger.error("no se pudo abrir \(path, privacy: .public)")
            db = nil
            return
        }
        migrate()
    }

    deinit { if let db { sqlite3_close(db) } }

    var isOpen: Bool { db != nil }

    // MARK: - Schema

    private func migrate() {
        guard let db else { return }
        exec("""
        CREATE TABLE IF NOT EXISTS meetings (
          id TEXT PRIMARY KEY, title TEXT, started_at TEXT, ended_at TEXT, duration_sec REAL,
          engine TEXT, model TEXT, language TEXT, transcript_path TEXT, summary_path TEXT,
          speaker_count INTEGER, transcript_text TEXT
        );
        """)
        var version: Int32 = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW {
            version = sqlite3_column_int(stmt, 0)
        }
        sqlite3_finalize(stmt)

        if version < 2 {
            let ok = exec("""
            BEGIN;
            CREATE VIRTUAL TABLE IF NOT EXISTS meetings_fts USING fts5(
              title, transcript_text, content='meetings', content_rowid='rowid'
            );
            CREATE TRIGGER IF NOT EXISTS meetings_ai AFTER INSERT ON meetings BEGIN
              INSERT INTO meetings_fts(rowid, title, transcript_text) VALUES (new.rowid, new.title, new.transcript_text);
            END;
            CREATE TRIGGER IF NOT EXISTS meetings_ad AFTER DELETE ON meetings BEGIN
              INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript_text) VALUES ('delete', old.rowid, old.title, old.transcript_text);
            END;
            CREATE TRIGGER IF NOT EXISTS meetings_au AFTER UPDATE ON meetings BEGIN
              INSERT INTO meetings_fts(meetings_fts, rowid, title, transcript_text) VALUES ('delete', old.rowid, old.title, old.transcript_text);
              INSERT INTO meetings_fts(rowid, title, transcript_text) VALUES (new.rowid, new.title, new.transcript_text);
            END;
            INSERT INTO meetings_fts(meetings_fts) VALUES ('rebuild');
            PRAGMA user_version = 2;
            COMMIT;
            """)
            if !ok {
                exec("ROLLBACK;")
                logger.error("migración a schema 2 (FTS5) falló; la búsqueda usa LIKE")
            }
        }
    }

    var schemaVersion: Int32 {
        guard let db else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            logger.error("sqlite: \(message, privacy: .public)")
            return false
        }
        return true
    }

    // MARK: - Write

    /// Replace-by-id as DELETE + INSERT so the FTS triggers see both halves.
    /// The result is explicit because post-processing must not delete the raw
    /// capture when SQLite rejected the durable history write.
    @discardableResult
    func insert(_ record: MeetingRecord) -> Bool {
        guard let db else { return false }
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE;") else { return false }
        var committed = false
        defer {
            if !committed { _ = exec("ROLLBACK;") }
        }

        var del: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM meetings WHERE id = ?;", -1, &del, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(del, 1, record.id, -1, SQLITE_TRANSIENT)
        let deleteOK = sqlite3_step(del) == SQLITE_DONE
        sqlite3_finalize(del)
        guard deleteOK else { return false }

        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO meetings (id, title, started_at, ended_at, duration_sec, engine, model, language,
          transcript_path, summary_path, speaker_count, transcript_text)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, record.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, ISO8601.string(from: record.startedAt), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, ISO8601.string(from: record.endedAt), -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, record.durationSec)
        sqlite3_bind_text(stmt, 6, record.engine, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, record.model, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, record.language, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 9, record.transcriptPath, -1, SQLITE_TRANSIENT)
        if let summary = record.summaryPath {
            sqlite3_bind_text(stmt, 10, summary, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_bind_int(stmt, 11, Int32(record.speakerCount))
        sqlite3_bind_text(stmt, 12, record.transcriptText, -1, SQLITE_TRANSIENT)
        let insertOK = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        guard insertOK, exec("COMMIT;") else { return false }
        committed = true
        return true
    }

    // MARK: - Read

    private static let summaryColumns =
        "id, title, started_at, ended_at, duration_sec, engine, model, language, transcript_path, summary_path, speaker_count"

    func recent(limit: Int) -> [MeetingSummary] {
        querySummaries("SELECT \(Self.summaryColumns) FROM meetings ORDER BY started_at DESC LIMIT \(max(1, limit));")
    }

    func summary(id: String) -> MeetingSummary? {
        querySummaries("SELECT \(Self.summaryColumns) FROM meetings WHERE id = ? LIMIT 1;", binds: [id]).first
    }

    func summary(transcriptPath: String) -> MeetingSummary? {
        querySummaries("SELECT \(Self.summaryColumns) FROM meetings WHERE transcript_path = ? ORDER BY ended_at DESC LIMIT 1;",
                       binds: [transcriptPath]).first
    }

    func record(id: String) -> MeetingRecord? {
        guard let db else { return nil }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT \(Self.summaryColumns), transcript_text FROM meetings WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let s = Self.summary(from: stmt)
        let text = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
        return MeetingRecord(id: s.id, title: s.title, startedAt: s.startedAt, endedAt: s.endedAt,
                             durationSec: s.durationSec, engine: s.engine, model: s.model, language: s.language,
                             transcriptPath: s.transcriptPath, summaryPath: s.summaryPath,
                             speakerCount: s.speakerCount, transcriptText: text)
    }

    func count() -> Int {
        guard let db else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM meetings;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// FTS5 prefix search on title + transcript, newest first, 50 rows max.
    /// Falls back to an escaped LIKE when the FTS index is unavailable.
    func search(_ queryText: String) -> [MeetingSummary] {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: 20) }
        if let match = Self.ftsQuery(trimmed) {
            let sql = """
            SELECT \(Self.summaryColumns) FROM meetings
            WHERE rowid IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)
            ORDER BY started_at DESC LIMIT 50;
            """
            if let rows = querySummariesOrNil(sql, binds: [match]) { return rows }
        }
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let sql = """
        SELECT \(Self.summaryColumns) FROM meetings
        WHERE title LIKE '%' || ? || '%' ESCAPE '\\' OR transcript_text LIKE '%' || ? || '%' ESCAPE '\\'
        ORDER BY started_at DESC LIMIT 50;
        """
        return querySummaries(sql, binds: [escaped, escaped])
    }

    /// Each whitespace token becomes a quoted FTS5 string; the last one is a prefix.
    static func ftsQuery(_ text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { index, token in
            let quoted = "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return index == tokens.count - 1 ? quoted + "*" : quoted
        }.joined(separator: " ")
    }

    private func querySummaries(_ sql: String, binds: [String] = []) -> [MeetingSummary] {
        querySummariesOrNil(sql, binds: binds) ?? []
    }

    private func querySummariesOrNil(_ sql: String, binds: [String]) -> [MeetingSummary]? {
        guard let db else { return nil }
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), value, -1, SQLITE_TRANSIENT)
        }
        var rows: [MeetingSummary] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { rows.append(Self.summary(from: stmt)); continue }
            if rc == SQLITE_DONE { return rows }
            return nil
        }
    }

    private static func summary(from stmt: OpaquePointer?) -> MeetingSummary {
        func col(_ idx: Int32) -> String {
            sqlite3_column_text(stmt, idx).map { String(cString: $0) } ?? ""
        }
        let started = ISO8601.date(from: col(2)) ?? Date()
        return MeetingSummary(
            id: col(0), title: col(1), startedAt: started,
            endedAt: ISO8601.date(from: col(3)) ?? started,
            durationSec: sqlite3_column_double(stmt, 4),
            engine: col(5), model: col(6), language: col(7), transcriptPath: col(8),
            summaryPath: sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : col(9),
            speakerCount: Int(sqlite3_column_int(stmt, 10)))
    }
}
