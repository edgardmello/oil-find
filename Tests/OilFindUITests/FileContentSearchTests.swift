import Foundation
import XCTest
import OilFindCore
@testable import OilFindApp

final class FileContentSearchTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("FileContentTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    func testTextExtractorPlainTextAndBinaryRejection() throws {
        let textFile = tempDir.appendingPathComponent("sample.swift")
        try "func calculateTax() -> Double { return 42.0 }".write(to: textFile, atomically: true, encoding: .utf8)

        let extracted = FileTextExtractor.extractText(from: textFile, ext: "swift")
        XCTAssertEqual(extracted, "func calculateTax() -> Double { return 42.0 }")

        // Binary with null byte should be rejected
        let binFile = tempDir.appendingPathComponent("image.fake")
        let data = Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02])
        try data.write(to: binFile)
        XCTAssertNil(FileTextExtractor.extractText(from: binFile, ext: "fake"))
    }

    func testFileContentIndexLiteralSearchAndSnippets() throws {
        let dbURL = tempDir.appendingPathComponent("test_index.sqlite")
        let index = try FileContentIndex(url: dbURL)

        try index.upsertFile(
            sourceID: "startup",
            path: "/tmp/invoice_doc.txt",
            mtime: 100,
            size: 50,
            kind: 3,
            text: "Payment invoice receipt #12345 for services rendered.",
            vector: nil
        )

        let count = try index.count()
        XCTAssertEqual(count, 1)

        let hits = try index.searchLiteral(terms: ["invoice", "receipt"])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "/tmp/invoice_doc.txt")
        XCTAssertTrue(hits[0].excerpt.contains("invoice receipt"))
        XCTAssertFalse(hits[0].highlights.isEmpty)

        // Non-matching term
        let noHits = try index.searchLiteral(terms: ["completelyMissingTerm"])
        XCTAssertTrue(noHits.isEmpty)
    }

    func testSemanticEngineVectorGenerationAndSimilarity() throws {
        let engine = FileSemanticEngine.shared
        guard engine.isAvailable else { return }

        let vec1 = engine.vector(for: "financial billing invoice contract")
        let vec2 = engine.vector(for: "payment receipt financial transaction")
        let vec3 = engine.vector(for: "astronomy galaxies telescope planets")

        guard let v1 = vec1, let v2 = vec2, let v3 = vec3 else { return }
        XCTAssertEqual(v1.count, 512)

        let quant2 = engine.quantize(v2)
        let quant3 = engine.quantize(v3)

        let simRelated = quant2.bytes.withUnsafeBufferPointer {
            engine.similarity(query: v1, quantized: $0.baseAddress!, count: $0.count, scale: quant2.scale)
        }
        let simUnrelated = quant3.bytes.withUnsafeBufferPointer {
            engine.similarity(query: v1, quantized: $0.baseAddress!, count: $0.count, scale: quant3.scale)
        }

        XCTAssertGreaterThan(simRelated, simUnrelated)
    }

    func testFileContentSearchProviderWithStoreAndPredicates() throws {
        let names = ["", "code.swift", "notes.md"]
        var buffer = ScanBuffer()
        buffer.ids = [0, 1, 2]
        buffer.parents = [0, 0, 0]
        buffer.sizes = [0, 120, 240]
        buffer.mtimes = [0, 50, 60]
        buffer.flags = [1, 128, 128]
        buffer.depths = [0, 1, 1]
        buffer.kinds = [1, 7, 3] // 7 = code, 3 = doc
        buffer.nameLens = names.map { UInt32($0.utf8.count) }
        buffer.nameBytes = Array(names.joined().utf8)

        let rootPath = tempDir.path
        let scanOut = ScanOutput(buffers: [buffer], count: 3, homeIndex: .max, elapsed: 0, finishedAt: 0)
        let store = IndexStore(scan: scanOut, config: IndexConfig(rootPath: rootPath))
        store.write { store.buildHash() }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)

        let dbURL = tempDir.appendingPathComponent("test_provider.sqlite")
        let defaults = UserDefaults(suiteName: "test.filecontent." + UUID().uuidString)!
        let manager = FileContentManager(dbURL: dbURL, preferences: defaults)

        // Seed content index
        try manager.index?.upsertFile(
            sourceID: "startup",
            path: rootPath + "/code.swift",
            mtime: 50,
            size: 120,
            kind: 7,
            text: "func authenticateUser(token: String) -> Bool { return token == \"secret\" }",
            vector: nil
        )

        let provider = FileContentSearchProvider(manager: manager)

        // Query matching content
        let query = Query.parse("authenticateUser")
        let hits = provider.prepareSearch(query, options: SearchOptions(), sources: [source], isCancelled: { false })()

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].sourceID, "startup")
        XCTAssertEqual(hits[0].entryID, 1)
        XCTAssertTrue(hits[0].detail.contains("authenticateUser"))

        // Query with ext filter matching
        let queryWithExt = Query.parse("authenticateUser ext:swift")
        let hitsWithExt = provider.prepareSearch(queryWithExt, options: SearchOptions(), sources: [source], isCancelled: { false })()
        XCTAssertEqual(hitsWithExt.count, 1)

        // Query with ext filter rejecting
        let queryRejectExt = Query.parse("authenticateUser ext:md")
        let hitsRejectExt = provider.prepareSearch(queryRejectExt, options: SearchOptions(), sources: [source], isCancelled: { false })()
        XCTAssertEqual(hitsRejectExt.count, 0)
    }

    func testCompositeSupplementarySearchProvider() throws {
        final class DummyProvider: SupplementarySearchProvider {
            var isEnabled = true
            let hitEntryID: UInt32
            init(hitEntryID: UInt32) { self.hitEntryID = hitEntryID }
            func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
                return { [self] in [.init(sourceID: "startup", entryID: hitEntryID, detail: "Hit \(hitEntryID)")] }
            }
            func sourcesDidChange(_ sources: [SearchSource]) {}
            func userActivity(visible: Bool, typing: Bool) {}
            func backgroundIndexingChanged(_ busy: Bool) {}
        }

        let p1 = DummyProvider(hitEntryID: 10)
        let p2 = DummyProvider(hitEntryID: 20)
        let composite = CompositeSupplementarySearchProvider([p1, p2])

        let hits = composite.prepareSearch(Query.parse("test"), options: SearchOptions(), sources: [], isCancelled: { false })()
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.entryID), [10, 20])
    }
}
