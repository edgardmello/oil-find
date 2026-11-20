import XCTest
@testable import OilFindCore

final class ExplicitContentQueryTests: XCTestCase {
    private func contents(_ text: String) -> [[String]] {
        Query.parse(text).clauses.map { clause in
            clause.alternatives.compactMap { if case .content(let value) = $0.matcher { return value }; return nil }
        }
    }

    func testExplicitWordPhraseAndQuotedAlternatives() {
        XCTAssertFalse(Query.parse("client").hasContentTerms)
        XCTAssertEqual(contents("[client]"), [["client"]])
        XCTAssertEqual(contents("[\"paid invoice\"]"), [["paid invoice"]])
        XCTAssertEqual(contents("content:\"paid invoice\""), [["paid invoice"]])
        XCTAssertEqual(contents("[client|\"paid invoice\"]"), [["client", "paid invoice"]])
        XCTAssertEqual(contents("[\"a|b\"]"), [["a|b"]])
        XCTAssertEqual(contents("[ui] [ux]"), [["ui"], ["ux"]])
    }

    func testQuotedContentRetainsWholeWordIntentPerAlternative() {
        for input in ["[\"jane\"]", "content:\"jane\"", "[!\"jane\"]"] {
            XCTAssertTrue(Query.parse(input).clauses[0].alternatives[0].contentWholeWords, input)
        }
        let atoms = Query.parse("[jane|\"paid invoice\"]").clauses[0].alternatives
        XCTAssertFalse(atoms[0].contentWholeWords)
        XCTAssertTrue(atoms[1].contentWholeWords)
        XCTAssertFalse(Query.parse("[jane]").clauses[0].alternatives[0].contentWholeWords)
    }

    func testIncompleteContentQueryNeverBecomesFilenameOrRecents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("nothing".utf8).write(to: root.appendingPathComponent("client.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
        for input in ["[client]", "[", "[]", "content:", "[!client]", "![client]", "client [client]"] {
            let query = Query.parse(input)
            XCTAssertTrue(query.hasContentTerms, input)
            XCTAssertFalse(query.isEmpty, input)
            let result = try XCTUnwrap(Searcher.search(query, in: store))
            XCTAssertEqual(result.total, 0, input)
        }
        let literal = Query.parse("\"[client].txt\"")
        XCTAssertFalse(literal.hasContentTerms)
    }

    func testNegatedContentIsSeparateFromFilenameExclusion() {
        let query = Query.parse("[invoice] [!paid]")
        XCTAssertEqual(query.clauses.count, 2)
        XCTAssertFalse(query.clauses[0].alternatives[0].negated)
        XCTAssertTrue(query.clauses[1].alternatives[0].negated)
        XCTAssertFalse(query.clauses[1].alternatives[0].excludesAncestors)
        XCTAssertEqual(contents("![\"paid invoice\"]"), [["paid invoice"]])
    }
}
