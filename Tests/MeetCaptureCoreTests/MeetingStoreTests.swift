import XCTest
import SQLite3
@testable import MeetCaptureCore

final class MeetingStoreTests: XCTestCase {
    private func record(id: String, title: String, text: String, at: TimeInterval = 0) -> MeetingRecord {
        let start = TestSupport.fixedDate.addingTimeInterval(at)
        return MeetingRecord(id: id, title: title, startedAt: start, endedAt: start.addingTimeInterval(60), durationSec: 60,
                             engine: "whisper", model: "m", language: "es", transcriptPath: "/t/\(id).txt",
                             summaryPath: nil, speakerCount: 2, transcriptText: text)
    }

    func testInsertRecentRecordAndReplaceById() throws {
        let dir = TestSupport.makeTempDir(self, "store")
        let store = MeetingStore(path: dir + "/meetcapture.db")
        XCTAssertTrue(store.isOpen)
        XCTAssertEqual(store.schemaVersion, MeetingStore.currentSchemaVersion)
        store.insert(record(id: "meet-1", title: "Primera", text: "hablamos de presupuesto"))
        store.insert(record(id: "meet-2", title: "Segunda", text: "hablamos de contratos", at: 100))
        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(store.recent(limit: 10).map(\.id), ["meet-2", "meet-1"])
        XCTAssertEqual(store.record(id: "meet-1")?.transcriptText, "hablamos de presupuesto")
        store.insert(record(id: "meet-1", title: "Primera bis", text: "otro texto"))
        XCTAssertEqual(store.count(), 2, "same id replaces the row instead of duplicating")
        XCTAssertEqual(store.record(id: "meet-1")?.title, "Primera bis")
    }

    func testFTSSearchMatchesTranscriptAndTitle() throws {
        let dir = TestSupport.makeTempDir(self, "fts")
        let path = dir + "/meetcapture.db"
        let store = MeetingStore(path: path)
        store.insert(record(id: "meet-1", title: "Kickoff", text: "definimos el presupuesto anual"))
        store.insert(record(id: "meet-2", title: "Cierre", text: "firmamos el contrato"))
        XCTAssertEqual(store.search("presup").map(\.id), ["meet-1"], "prefix match on the last token")
        XCTAssertEqual(store.search("Cierre").map(\.id), ["meet-2"])
        XCTAssertEqual(store.search("contrato anual").map(\.id), [], "all tokens must match")
        XCTAssertEqual(store.search("   ").count, 2, "blank query lists recent")
        // Punctuation-heavy queries fall back to LIKE instead of raising an FTS syntax error.
        XCTAssertEqual(store.search("presupuesto\"").map(\.id), ["meet-1"])

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM meetings_fts", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 2, "FTS index stays in sync via triggers")
        sqlite3_finalize(stmt)
    }

    func testFTSQueryQuotesTokens() {
        XCTAssertEqual(MeetingStore.ftsQuery("hola mundo"), "\"hola\" \"mundo\"*")
        XCTAssertNil(MeetingStore.ftsQuery("  "))
        XCTAssertEqual(MeetingStore.ftsQuery("a\"b"), "\"a\"\"b\"*", "embedded quotes are doubled (FTS5 escaping)")
    }
}
