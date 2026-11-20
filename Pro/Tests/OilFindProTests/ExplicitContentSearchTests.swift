import AppKit
import XCTest
@testable import OilFindCore
import OilFindApp
@testable import OilFindPro

final class ExplicitContentSearchTests: XCTestCase {
    private func store(at root: URL) throws -> IndexStore {
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
        store.write {
            for i in 1..<store.count { store.flags[i] |= SiftFlag.userArea }
            store.buildHash()
        }
        return store
    }

    func testNamesAreOptInAndContentMustActuallyMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = [
            "marigold.txt": "This file has unrelated contents.",
            "notes.txt": "Confidential marigold phrase. UI design. a|b literal.",
            "reverse.txt": "phrase marigold confidential. UX design. paid.",
            "short.txt": "UX design only.",
        ]
        for (name, body) in samples { try body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let index = try store(at: root)
        let suite = UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = ContentSearchManager(defaults: preferences, databaseURL: root.appendingPathComponent("content.sqlite"))
        defer { manager.stop() }
        let source = SearchSource(id: "test", displayName: "", isOnline: true, store: index)
        func hits(_ text: String) -> Set<String> {
            let query = Query.parse(text)
            let found = manager.prepareSearch(query, options: SearchOptions(), sources: [source], isCancelled: { false })()
            return Set(found.map { hit in index.read { index.name(hit.entryID) } })
        }
        let names = try XCTUnwrap(Searcher.search(Query.parse("marigold"), in: index))
        XCTAssertEqual(names.items.map { index.name($0) }, ["marigold.txt"])
        XCTAssertEqual(hits("marigold"), [])
        XCTAssertEqual(hits("[marigold]"), ["notes.txt", "reverse.txt"])
        XCTAssertEqual(hits("content:marigold"), ["notes.txt", "reverse.txt"])
        XCTAssertEqual(hits("[\"confidential marigold phrase\"]"), ["notes.txt"])
        XCTAssertEqual(hits("content:\"confidential marigold phrase\""), ["notes.txt"])
        XCTAssertEqual(hits("notes [marigold]"), ["notes.txt"])
        XCTAssertEqual(hits("marigold [marigold]"), [])
        XCTAssertEqual(hits("[marigold] [!paid]"), ["notes.txt"])
        XCTAssertEqual(hits("[missing|\"confidential marigold phrase\"]"), ["notes.txt"])
        XCTAssertEqual(hits("[\"a|b\"]"), ["notes.txt"])
        XCTAssertEqual(hits("[UI]"), ["notes.txt"])
        XCTAssertEqual(hits("["), [])
        manager.setEnabled(false)
        XCTAssertEqual(hits("[marigold]"), [])
    }

    func testPDFWildcardAndExtensionFiltersFindBodyOnlyMatch() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in [("letter.pdf", "Fernanda and Jane approved the payment."), ("fernanda.pdf", "An unrelated document in janeiro.")] {
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try XCTUnwrap(CGContext(root.appendingPathComponent(name) as CFURL, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (text as NSString).draw(at: NSPoint(x: 40, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 18)])
            NSGraphicsContext.current = previous
            context.endPDFPage(); context.closePDF()
        }
        let index = try store(at: root)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ContentSearchManager(defaults: defaults, databaseURL: root.appendingPathComponent("content.sqlite"))
        defer { manager.stop() }
        let source = SearchSource(id: "test", displayName: "", isOnline: true, store: index)
        for input in ["*.pdf [fernanda]", "ext:pdf [fernanda]", "kind:doc [fernanda]", "ext:pdf [\"jane\"]", "ext:pdf content:\"jane\""] {
            let hits = manager.prepareSearch(Query.parse(input), options: SearchOptions(), sources: [source], isCancelled: { false })()
            XCTAssertEqual(hits.map { index.name($0.entryID) }, ["letter.pdf"], input)
        }
    }

    func testQuotedWordsAndPhrasesRequireUnicodeWordBoundaries() throws {
        let exact = ContentTerm(text: "jane", caseSensitive: false, wholeWords: true)
        for body in ["Jane", "(JANE),", "Olá, Jane!", "jane-smith", "jané.", "janeiro, then Jane."] {
            XCTAssertTrue(ContentExtractor.matches(body: body, clauses: [[exact]], excluded: []), body)
        }
        for body in ["janeiro", "MaryJane", "jane2", "jane_smith", "éjane", "janeé"] {
            XCTAssertFalse(ContentExtractor.matches(body: body, clauses: [[exact]], excluded: []), body)
        }
        let partial = ContentTerm(text: "jane", caseSensitive: false)
        XCTAssertTrue(ContentExtractor.matches(body: "janeiro", clauses: [[partial]], excluded: []))
        XCTAssertTrue(ContentExtractor.matches(body: "paid in janeiro", clauses: [[ContentTerm(text: "paid", caseSensitive: false)]], excluded: [exact]))
        XCTAssertFalse(ContentExtractor.matches(body: "paid by Jane", clauses: [[ContentTerm(text: "paid", caseSensitive: false)]], excluded: [exact]))
        let phrase = ContentTerm(text: "paid invoice", caseSensitive: false, wholeWords: true)
        XCTAssertTrue(ContentExtractor.matches(body: "A paid invoice.", clauses: [[phrase]], excluded: []))
        XCTAssertFalse(ContentExtractor.matches(body: "unpaid invoices", clauses: [[phrase]], excluded: []))
        let presentation = ContentExtractor.makePresentation(body: "janeiro, then Jane.", terms: [exact], prefix: "")
        XCTAssertEqual(presentation.highlights.map { (presentation.text as NSString).substring(with: $0) }, ["Jane"])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ContentIndexDatabase(url: root.appendingPathComponent("content.sqlite"))
        database.upsertBatch([(path: "/partial", mtime: 1, size: 1, body: "janeiro"),
                              (path: "/exact", mtime: 1, size: 1, body: "Jane.")])
        XCTAssertEqual(database.search(clauses: [[exact]], excluded: [], isCancelled: { false }).map(\.path), ["/exact"])
    }

    func testContentHitsUseCurrentVersionAfterUnrelatedIndexChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "Fernanda approved this document.".write(to: root.appendingPathComponent("letter.txt"), atomically: true, encoding: .utf8)
        let index = try store(at: root)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ContentSearchManager(defaults: defaults, databaseURL: root.appendingPathComponent("content.sqlite"))
        defer { manager.stop() }
        let source = SearchSource(id: "test", displayName: "", isOnline: true, store: index)
        let work = manager.prepareSearch(Query.parse("[fernanda]"), options: SearchOptions(), sources: [source], isCancelled: { false })
        index.write { index.version += 1 }
        let hits = work()
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sourceVersion, index.version)
    }

    func testIndexedShortAlternativesUseEveryBranchAndVerifyPhraseOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try ContentIndexDatabase(url: root.appendingPathComponent("content.sqlite"))
        database.upsertBatch([
            (path: "/a", mtime: 1, size: 1, body: "UI design paid invoice"),
            (path: "/b", mtime: 1, size: 1, body: "UX design invoice paid"),
            (path: "/c", mtime: 1, size: 1, body: "unrelated"),
        ])
        let alternatives = [[ContentTerm(text: "UI", caseSensitive: false), ContentTerm(text: "UX", caseSensitive: false)]]
        XCTAssertEqual(Set(database.search(clauses: alternatives, excluded: [], isCancelled: { false }).map(\.path)), ["/a", "/b"])
        let phrase = [[ContentTerm(text: "paid invoice", caseSensitive: false)]]
        XCTAssertEqual(database.search(clauses: phrase, excluded: [], isCancelled: { false }).map(\.path), ["/a"])
        XCTAssertTrue(database.search(clauses: alternatives, excluded: [], isCancelled: { true }).isEmpty)
    }

    func testImageTextIsRecognizedAndSearchableWithoutFilenameMatch() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 1400, height: 300))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1400, height: 300).fill()
        ("QUANTUM MAPLE" as NSString).draw(at: NSPoint(x: 60, y: 120), withAttributes: [
            .font: NSFont.systemFont(ofSize: 90, weight: .medium), .foregroundColor: NSColor.black
        ])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let url = root.appendingPathComponent("capture.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let index = try store(at: root)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ContentSearchManager(defaults: defaults, databaseURL: root.appendingPathComponent("content.sqlite"))
        defer { manager.stop() }
        let source = SearchSource(id: "test", displayName: "", isOnline: true, store: index)
        let query = Query.parse("[\"quantum maple\"]")
        let hits = manager.prepareSearch(query, options: SearchOptions(kind: 4), sources: [source], isCancelled: { false })()
        XCTAssertEqual(hits.map { index.name($0.entryID) }, ["capture.png"])
        XCTAssertTrue(hits.first?.detail.localizedCaseInsensitiveContains("quantum maple") == true)
        XCTAssertTrue(hits.first?.highlights.isEmpty == false)
    }
}
