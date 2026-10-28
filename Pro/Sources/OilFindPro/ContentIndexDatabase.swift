import Foundation
import SQLite3

public final class ContentIndexDatabase {
    private var writerDB: OpaquePointer?
    private var readerDB: OpaquePointer?
    private let writerLock = NSLock()
    private let readerLock = NSLock()
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var wHandle: OpaquePointer?
        let wFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &wHandle, wFlags, nil) == SQLITE_OK, let wHandle else {
            let msg = wHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "writer open failed"
            if let wHandle { sqlite3_close(wHandle) }
            throw NSError(domain: "OilFindPro.ContentIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        self.writerDB = wHandle
        sqlite3_busy_timeout(wHandle, 3000)

        try executeWriter("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                path TEXT NOT NULL UNIQUE,
                mtime INTEGER NOT NULL,
                size INTEGER NOT NULL,
                body TEXT NOT NULL
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
                body,
                content='files',
                content_rowid='id',
                tokenize='trigram'
            );
            CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                INSERT INTO files_fts(rowid, body) VALUES (new.id, new.body);
            END;
            CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                INSERT INTO files_fts(files_fts, rowid, body) VALUES('delete', old.id, old.body);
            END;
            CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
                INSERT INTO files_fts(files_fts, rowid, body) VALUES('delete', old.id, old.body);
                INSERT INTO files_fts(rowid, body) VALUES (new.id, new.body);
            END;
            """)

        // Open a dedicated read connection so searches never block on background indexing writes.
        var rHandle: OpaquePointer?
        let rFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(url.path, &rHandle, rFlags, nil) == SQLITE_OK, let rHandle {
            sqlite3_busy_timeout(rHandle, 500)
            self.readerDB = rHandle
        } else {
            self.readerDB = wHandle
        }
    }

    deinit {
        readerLock.lock()
        let r = readerDB
        let w = writerDB
        readerDB = nil
        readerLock.unlock()

        writerLock.lock()
        writerDB = nil
        writerLock.unlock()

        if let r, r != w { sqlite3_close_v2(r) }
        if let w { sqlite3_close_v2(w) }
    }

    private func executeWriter(_ sql: String) throws {
        guard let writerDB else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(writerDB, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            if let errMsg { sqlite3_free(errMsg) }
            throw NSError(domain: "OilFindPro.ContentIndex", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    public func loadAllMetadata() -> [String: (mtime: UInt32, size: UInt64)] {
        readerLock.lock()
        defer { readerLock.unlock() }
        guard let db = readerDB else { return [:] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT path, mtime, size FROM files;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: (mtime: UInt32, size: UInt64)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cPath = sqlite3_column_text(stmt, 0) else { continue }
            let path = String(cString: cPath)
            let mtime = UInt32(clamping: sqlite3_column_int64(stmt, 1))
            let size = UInt64(clamping: sqlite3_column_int64(stmt, 2))
            result[path] = (mtime, size)
        }
        return result
    }

    public func upsertBatch(_ records: [(path: String, mtime: UInt32, size: UInt64, body: String)]) {
        guard !records.isEmpty else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        guard let db = writerDB else { return }
        try? executeWriter("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        let sql = """
            INSERT INTO files(path, mtime, size, body) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(path) DO UPDATE SET mtime=excluded.mtime, size=excluded.size, body=excluded.body;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            try? executeWriter("ROLLBACK;")
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for record in records {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            _ = record.path.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
            sqlite3_bind_int64(stmt, 2, Int64(record.mtime))
            sqlite3_bind_int64(stmt, 3, Int64(bitPattern: record.size))
            _ = record.body.withCString { sqlite3_bind_text(stmt, 4, $0, -1, transient) }
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        try? executeWriter("COMMIT;")
    }

    public func removePaths(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        writerLock.lock()
        defer { writerLock.unlock() }
        guard let db = writerDB else { return }
        try? executeWriter("BEGIN IMMEDIATE;")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM files WHERE path = ?1;", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            try? executeWriter("ROLLBACK;")
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for path in paths {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            _ = path.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        try? executeWriter("COMMIT;")
    }

    public func clearAll() {
        writerLock.lock()
        defer { writerLock.unlock() }
        try? executeWriter("""
            DELETE FROM files;
            INSERT INTO files_fts(files_fts) VALUES('rebuild');
            VACUUM;
            """)
    }

    public func stats() -> (fileCount: Int, diskBytes: Int64) {
        readerLock.lock()
        var count = 0
        if let db = readerDB {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM files;", -1, &stmt, nil) == SQLITE_OK, let stmt {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int64(stmt, 0))
                }
                sqlite3_finalize(stmt)
            }
        }
        readerLock.unlock()
        var bytes: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: url.path + suffix)
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = values.fileSize {
                bytes += Int64(fileSize)
            }
        }
        return (count, bytes)
    }

    public func search(
        clauses: [[ContentTerm]],
        excluded: [ContentTerm],
        limit: Int = 500,
        isCancelled: () -> Bool
    ) -> [(path: String, mtime: UInt32, size: UInt64, body: String)] {
        guard !clauses.isEmpty, !isCancelled() else { return [] }
        readerLock.lock()
        defer { readerLock.unlock() }
        guard let db = readerDB else { return [] }

        let ftsExpr = Self.buildFTSExpression(clauses: clauses)
        var stmt: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        if let ftsExpr {
            let sql = """
                SELECT f.path, f.mtime, f.size, f.body
                FROM files_fts
                JOIN files f ON f.id = files_fts.rowid
                WHERE files_fts MATCH ?1
                ORDER BY f.mtime DESC
                LIMIT ?2;
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                _ = ftsExpr.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
                sqlite3_bind_int(stmt, 2, Int32(max(limit * 4, 400)))
            }
        } else if let anchor = clauses.first?.first?.text, !anchor.isEmpty {
            let sql = """
                SELECT path, mtime, size, body
                FROM files
                WHERE instr(lower(body), lower(?1)) > 0
                ORDER BY mtime DESC
                LIMIT ?2;
                """
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt {
                _ = anchor.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
                sqlite3_bind_int(stmt, 2, Int32(max(limit * 4, 400)))
            }
        }

        guard let activeStmt = stmt else { return [] }
        defer { sqlite3_finalize(activeStmt) }

        var matches: [(path: String, mtime: UInt32, size: UInt64, body: String)] = []
        matches.reserveCapacity(min(limit, 128))
        while !isCancelled(), sqlite3_step(activeStmt) == SQLITE_ROW {
            guard let cPath = sqlite3_column_text(activeStmt, 0),
                  let cBody = sqlite3_column_text(activeStmt, 3) else { continue }
            let body = String(cString: cBody)
            guard ContentExtractor.matches(body: body, clauses: clauses, excluded: excluded) else {
                continue
            }
            let path = String(cString: cPath)
            let mtime = UInt32(clamping: sqlite3_column_int64(activeStmt, 1))
            let size = UInt64(clamping: sqlite3_column_int64(activeStmt, 2))
            matches.append((path: path, mtime: mtime, size: size, body: body))
            if matches.count >= limit { break }
        }
        return matches
    }

    private static func buildFTSExpression(clauses: [[ContentTerm]]) -> String? {
        var clauseExpressions: [String] = []
        for clause in clauses {
            var altExpressions: [String] = []
            var allTrigramCapable = true
            for term in clause {
                let cleaned = term.text.replacingOccurrences(of: "\"", with: "\"\"")
                if cleaned.count < 3 || !cleaned.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                    allTrigramCapable = false
                    break
                }
                altExpressions.append("\"\(cleaned)\"")
            }
            if allTrigramCapable, !altExpressions.isEmpty {
                if altExpressions.count == 1 {
                    clauseExpressions.append(altExpressions[0])
                } else {
                    clauseExpressions.append("(" + altExpressions.joined(separator: " OR ") + ")")
                }
            }
        }
        guard !clauseExpressions.isEmpty else { return nil }
        return clauseExpressions.joined(separator: " AND ")
    }
}
