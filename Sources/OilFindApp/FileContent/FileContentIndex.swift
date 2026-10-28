import Foundation
import SQLite3
import Compression
import Darwin

enum FileContentError: Error {
    case database(String)
}

final class FileContentSQL {
    let db: OpaquePointer
    init(_ url: URL, readOnly: Bool = false) throws {
        var handle: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open file content database"
            if let handle { sqlite3_close(handle) }
            throw FileContentError.database(msg)
        }
        db = handle
        sqlite3_busy_timeout(db, readOnly ? 100 : 2000)
    }
    deinit { sqlite3_close(db) }

    func run(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    func error() -> FileContentError { .database(String(cString: sqlite3_errmsg(db))) }
    func prepare(_ sql: String) throws -> FileContentStatement { try FileContentStatement(self, sql) }
}

final class FileContentStatement {
    private let database: FileContentSQL
    let handle: OpaquePointer

    init(_ database: FileContentSQL, _ sql: String) throws {
        self.database = database
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database.db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw database.error()
        }
        handle = stmt
    }
    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [String]) {
        for (i, value) in values.enumerated() {
            _ = value.withCString {
                sqlite3_bind_text(handle, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
    }
    func next() throws -> Bool {
        let status = sqlite3_step(handle)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw database.error() }
        return status == SQLITE_ROW
    }
    func text(_ col: Int32) -> String { sqlite3_column_text(handle, col).map { String(cString: $0) } ?? "" }
    func int(_ col: Int32) -> Int64 { sqlite3_column_int64(handle, col) }
    func double(_ col: Int32) -> Double { sqlite3_column_double(handle, col) }
}

public final class FileContentIndex {
    let sql: FileContentSQL
    private let readOnly: Bool
    private var statements: [String: FileContentStatement] = [:]

    public init(url: URL, readOnly: Bool = false) throws {
        self.readOnly = readOnly
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        sql = try FileContentSQL(url, readOnly: readOnly)
        if !readOnly {
            try sql.run("""
                PRAGMA journal_mode=WAL;
                PRAGMA foreign_keys=ON;
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS files(
                    pk INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    mtime INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    kind INTEGER NOT NULL,
                    indexed_at REAL NOT NULL,
                    UNIQUE(source_id, path)
                );
                CREATE INDEX IF NOT EXISTS files_lookup ON files(source_id, path);
                CREATE TABLE IF NOT EXISTS file_docs(
                    file_pk INTEGER PRIMARY KEY REFERENCES files(pk) ON DELETE CASCADE,
                    folded BLOB NOT NULL,
                    bytes INTEGER NOT NULL,
                    raw_doc BLOB NOT NULL
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(
                    grams, content='', contentless_delete=1, detail=none
                );
                CREATE TRIGGER IF NOT EXISTS file_doc_delete AFTER DELETE ON files BEGIN
                    DELETE FROM file_fts WHERE rowid=old.pk;
                END;
                CREATE TABLE IF NOT EXISTS file_vectors(
                    file_pk INTEGER PRIMARY KEY REFERENCES files(pk) ON DELETE CASCADE,
                    dims INTEGER NOT NULL,
                    scale REAL NOT NULL,
                    quantized BLOB NOT NULL
                );
                COMMIT;
            """)
        }
    }

    private func statement(_ query: String) throws -> FileContentStatement {
        if let s = statements[query] {
            sqlite3_reset(s.handle)
            sqlite3_clear_bindings(s.handle)
            return s
        }
        let s = try sql.prepare(query)
        statements[query] = s
        return s
    }

    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func grams(_ text: String, query: Bool = false) -> String {
        let scalars = text.unicodeScalars
        let count = scalars.count
        let shortQuery = query && count < 3
        let asciiQuery = query && scalars.allSatisfy { $0.value < 128 }
        var values = Set<UInt64>()
        var previous: UInt32?, beforePrevious: UInt32?

        for scalar in scalars {
            let value = scalar.value
            if !query || count == 1 { values.insert(UInt64(value)) }
            if let previous, !query || shortQuery || !asciiQuery {
                values.insert((1 << 42) | UInt64(previous) << 21 | UInt64(value))
            }
            if let previous, let beforePrevious, previous < 128 && beforePrevious < 128 && value < 128 {
                values.insert((1 << 63) | UInt64(beforePrevious) << 42 | UInt64(previous) << 21 | UInt64(value))
            }
            beforePrevious = previous; previous = value
        }

        let separator = query ? " AND " : " "
        var result = ""; result.reserveCapacity(values.count * 18)
        for value in values.sorted() {
            if !result.isEmpty { result += separator }
            result += "x"
            result += String(value, radix: 16)
        }
        return result
    }

    private static func pack(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0]) }
        var compressed = Data(count: data.count)
        let count = compressed.withUnsafeMutableBytes { outBuf in
            data.withUnsafeBytes { inBuf in
                compression_encode_buffer(outBuf.bindMemory(to: UInt8.self).baseAddress!, outBuf.count,
                                          inBuf.bindMemory(to: UInt8.self).baseAddress!, inBuf.count, nil, COMPRESSION_LZFSE)
            }
        }
        if count > 0 && count < data.count {
            compressed.count = count
            var result = Data([1])
            result.append(compressed)
            return result
        }
        var result = Data([0])
        result.append(data)
        return result
    }

    private static func unpack(_ data: Data, length: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        let header = data[0]
        let payload = data.dropFirst()
        if header == 0 { return Data(payload) }
        guard header == 1 else { return nil }
        var output = Data(count: length)
        let decoded = output.withUnsafeMutableBytes { outBuf in
            payload.withUnsafeBytes { inBuf in
                compression_decode_buffer(outBuf.bindMemory(to: UInt8.self).baseAddress!, length,
                                          inBuf.bindMemory(to: UInt8.self).baseAddress!, inBuf.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == length else { return nil }
        return output
    }

    func fileInfo(sourceID: String, path: String) throws -> (pk: Int64, mtime: Int64, size: Int64)? {
        let s = try statement("SELECT pk, mtime, size FROM files WHERE source_id=? AND path=?")
        s.bind([sourceID, path])
        defer { sqlite3_reset(s.handle) }
        guard try s.next() else { return nil }
        return (pk: s.int(0), mtime: s.int(1), size: s.int(2))
    }

    func upsertFile(sourceID: String, path: String, mtime: Int64, size: Int64, kind: Int, text: String,
                    vector: (dims: Int, scale: Float, bytes: [Int8])?) throws {
        try sql.run("BEGIN IMMEDIATE")
        do {
            let filesStmt = try statement("""
                INSERT INTO files(source_id, path, mtime, size, kind, indexed_at)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, path) DO UPDATE SET
                    mtime=excluded.mtime, size=excluded.size, kind=excluded.kind, indexed_at=excluded.indexed_at
            """)
            filesStmt.bind([sourceID, path, String(mtime), String(size), String(kind), String(Date().timeIntervalSince1970)])
            _ = try filesStmt.next()
            sqlite3_reset(filesStmt.handle)

            let pkStmt = try statement("SELECT pk FROM files WHERE source_id=? AND path=?")
            pkStmt.bind([sourceID, path])
            guard try pkStmt.next() else { throw FileContentError.database("Failed to resolve pk") }
            let pk = pkStmt.int(0)
            sqlite3_reset(pkStmt.handle)

            // Folded and raw text documents
            let foldedText = Self.fold(text)
            let foldedData = Self.pack(Data(foldedText.utf8))
            let rawData = Self.pack(Data(text.utf8))

            let docsStmt = try statement("""
                INSERT INTO file_docs(file_pk, folded, bytes, raw_doc)
                VALUES(?, ?, ?, ?)
                ON CONFLICT(file_pk) DO UPDATE SET
                    folded=excluded.folded, bytes=excluded.bytes, raw_doc=excluded.raw_doc
            """)
            sqlite3_bind_int64(docsStmt.handle, 1, pk)
            _ = foldedData.withUnsafeBytes { sqlite3_bind_blob(docsStmt.handle, 2, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_bind_int64(docsStmt.handle, 3, Int64(foldedText.utf8.count))
            _ = rawData.withUnsafeBytes { sqlite3_bind_blob(docsStmt.handle, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            _ = try docsStmt.next()
            sqlite3_reset(docsStmt.handle)

            // FTS index
            let ftsDelete = try statement("DELETE FROM file_fts WHERE rowid=?")
            sqlite3_bind_int64(ftsDelete.handle, 1, pk)
            _ = try ftsDelete.next()
            sqlite3_reset(ftsDelete.handle)

            let grams = Self.grams(foldedText)
            let ftsInsert = try statement("INSERT INTO file_fts(rowid, grams) VALUES(?, ?)")
            sqlite3_bind_int64(ftsInsert.handle, 1, pk)
            _ = grams.withCString { sqlite3_bind_text(ftsInsert.handle, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            _ = try ftsInsert.next()
            sqlite3_reset(ftsInsert.handle)

            // Vectors
            if let vector {
                let vecStmt = try statement("""
                    INSERT INTO file_vectors(file_pk, dims, scale, quantized)
                    VALUES(?, ?, ?, ?)
                    ON CONFLICT(file_pk) DO UPDATE SET
                        dims=excluded.dims, scale=excluded.scale, quantized=excluded.quantized
                """)
                sqlite3_bind_int64(vecStmt.handle, 1, pk)
                sqlite3_bind_int64(vecStmt.handle, 2, Int64(vector.dims))
                sqlite3_bind_double(vecStmt.handle, 3, Double(vector.scale))
                _ = vector.bytes.withUnsafeBytes { sqlite3_bind_blob(vecStmt.handle, 4, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                _ = try vecStmt.next()
                sqlite3_reset(vecStmt.handle)
            }

            try sql.run("COMMIT")
        } catch {
            try? sql.run("ROLLBACK")
            throw error
        }
    }

    func removeFiles(sourceID: String, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try sql.run("BEGIN IMMEDIATE")
        do {
            let stmt = try statement("DELETE FROM files WHERE source_id=? AND path=?")
            for path in paths {
                stmt.bind([sourceID, path])
                _ = try stmt.next()
                sqlite3_reset(stmt.handle)
            }
            try sql.run("COMMIT")
        } catch {
            try? sql.run("ROLLBACK")
            throw error
        }
    }

    func count() throws -> Int {
        let s = try statement("SELECT count(*) FROM files")
        defer { sqlite3_reset(s.handle) }
        guard try s.next() else { return 0 }
        return Int(s.int(0))
    }

    func clear() throws {
        try sql.run("DELETE FROM files; PRAGMA wal_checkpoint(TRUNCATE);")
    }

    /// Literal search over FTS5 postings with full literal verification and snippet extraction.
    func searchLiteral(terms: [String], limit: Int = 100, isCancelled: @escaping () -> Bool = { false }) throws -> [(sourceID: String, path: String, excerpt: String, highlights: [NSRange])] {
        guard !terms.isEmpty, !isCancelled() else { return [] }
        let foldedTerms = terms.map(Self.fold).filter { !$0.isEmpty }
        guard !foldedTerms.isEmpty else { return [] }

        var ftsConditions: [String] = []
        var bindings: [String] = []
        for term in foldedTerms {
            let g = Self.grams(term, query: true)
            ftsConditions.append("f.pk IN (SELECT rowid FROM file_fts WHERE file_fts MATCH ?)")
            bindings.append(g)
        }

        let sqlQuery = """
            SELECT f.pk, f.source_id, f.path, d.folded, d.bytes, d.raw_doc
            FROM files f
            JOIN file_docs d ON d.file_pk = f.pk
            WHERE \(ftsConditions.joined(separator: " AND "))
            ORDER BY f.mtime DESC
            LIMIT ?
        """

        let stmt = try statement(sqlQuery)
        for (i, b) in bindings.enumerated() {
            _ = b.withCString { sqlite3_bind_text(stmt.handle, Int32(i + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        sqlite3_bind_int64(stmt.handle, Int32(bindings.count + 1), Int64(limit * 2))
        defer { sqlite3_reset(stmt.handle) }

        var hits: [(sourceID: String, path: String, excerpt: String, highlights: [NSRange])] = []

        while try stmt.next() {
            if isCancelled() { return [] }
            let sourceID = stmt.text(1)
            let path = stmt.text(2)
            let byteCount = Int(stmt.int(4))

            guard let foldedBlob = sqlite3_column_blob(stmt.handle, 3) else { continue }
            let foldedBlobSize = Int(sqlite3_column_bytes(stmt.handle, 3))
            let foldedData = Data(bytes: foldedBlob, count: foldedBlobSize)

            guard let unpackedFolded = Self.unpack(foldedData, length: byteCount),
                  let foldedStr = String(data: unpackedFolded, encoding: .utf8) else { continue }

            // Literal check: must contain all folded terms
            var matchesAll = true
            for term in foldedTerms {
                if !foldedStr.localizedStandardContains(term) {
                    matchesAll = false
                    break
                }
            }
            guard matchesAll else { continue }

            // Extract raw snippet
            var snippet = ""
            var highlights: [NSRange] = []

            guard let rawBlob = sqlite3_column_blob(stmt.handle, 5) else { continue }
            let rawBlobSize = Int(sqlite3_column_bytes(stmt.handle, 5))
            let rawData = Data(bytes: rawBlob, count: rawBlobSize)

            if let unpackedRaw = Self.unpack(rawData, length: byteCount),
               let rawStr = String(data: unpackedRaw, encoding: .utf8) {
                let (snip, hls) = Self.makeExcerpt(raw: rawStr, queryTerm: terms.first ?? "")
                snippet = snip
                highlights = hls
            }

            hits.append((sourceID: sourceID, path: path, excerpt: snippet, highlights: highlights))
            if hits.count >= limit { break }
        }

        return hits
    }

    /// Semantic search computing cosine similarity against quantized Int8 vectors.
    func searchSemantic(queryVector: [Float], limit: Int = 50, minScore: Float = 0.55, isCancelled: @escaping () -> Bool = { false }) throws -> [(sourceID: String, path: String, excerpt: String, score: Float)] {
        guard !queryVector.isEmpty, !isCancelled() else { return [] }

        let stmt = try statement("""
            SELECT f.source_id, f.path, d.bytes, d.raw_doc, v.dims, v.scale, v.quantized
            FROM files f
            JOIN file_docs d ON d.file_pk = f.pk
            JOIN file_vectors v ON v.file_pk = f.pk
            ORDER BY f.mtime DESC
        """)
        defer { sqlite3_reset(stmt.handle) }

        var matches: [(sourceID: String, path: String, excerpt: String, score: Float)] = []

        while try stmt.next() {
            if isCancelled() { return [] }
            let dims = Int(stmt.int(4))
            guard dims == queryVector.count else { continue }
            let scale = Float(stmt.double(5))
            guard let blob = sqlite3_column_blob(stmt.handle, 6) else { continue }
            let blobCount = Int(sqlite3_column_bytes(stmt.handle, 6))
            guard blobCount == dims else { continue }

            let quantizedPtr = blob.bindMemory(to: Int8.self, capacity: dims)
            let sim = FileSemanticEngine.shared.similarity(query: queryVector, quantized: quantizedPtr, count: dims, scale: scale)

            if sim >= minScore {
                let sourceID = stmt.text(0)
                let path = stmt.text(1)
                let byteCount = Int(stmt.int(2))
                var snippet = ""

                if let rawBlob = sqlite3_column_blob(stmt.handle, 3) {
                    let rawBlobSize = Int(sqlite3_column_bytes(stmt.handle, 3))
                    let rawData = Data(bytes: rawBlob, count: rawBlobSize)
                    if let unpacked = Self.unpack(rawData, length: byteCount),
                       let text = String(data: unpacked, encoding: .utf8) {
                        snippet = String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
                    }
                }
                matches.append((sourceID: sourceID, path: path, excerpt: snippet, score: sim))
            }
        }

        matches.sort { $0.score > $1.score }
        if matches.count > limit {
            matches = Array(matches.prefix(limit))
        }
        return matches
    }

    static func makeExcerpt(raw: String, queryTerm: String) -> (String, [NSRange]) {
        guard let range = raw.range(of: queryTerm, options: .caseInsensitive) else {
            let prefix = String(raw.prefix(200)).replacingOccurrences(of: "\n", with: " ")
            return (prefix, [])
        }

        let start = raw.index(range.lowerBound, offsetBy: -50, limitedBy: raw.startIndex) ?? raw.startIndex
        let end = raw.index(range.upperBound, offsetBy: 150, limitedBy: raw.endIndex) ?? raw.endIndex
        let rawSnippet = String(raw[start..<end])

        let cleanSnippet = (start > raw.startIndex ? "… " : "") + rawSnippet.replacingOccurrences(of: "\n", with: " ") + (end < raw.endIndex ? " …" : "")

        var highlights: [NSRange] = []
        if let match = cleanSnippet.range(of: queryTerm, options: .caseInsensitive) {
            let nsRange = NSRange(match, in: cleanSnippet)
            highlights.append(nsRange)
        }
        return (cleanSnippet, highlights)
    }
}
