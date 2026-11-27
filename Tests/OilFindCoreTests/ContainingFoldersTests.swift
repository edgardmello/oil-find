import Foundation
import XCTest
@testable import OilFindCore

final class ContainingFoldersTests: XCTestCase {
    private let files = FileManager.default

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Oil Find " + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        try body(root)
    }

    private func write(_ path: String, under root: URL) throws {
        let file = root.appendingPathComponent(path)
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    private func scan(_ config: IndexConfig) throws -> IndexStore {
        IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
    }

    func testContainingFoldersUseImmediateIndexedParentsAndFilterTheirNames() throws {
        try fixture { root in
            for path in ["Projects With Space.v1/root.pdf",
                         "Projects With Space.v1/Orçamento/a.PDF",
                         "Projects With Space.v1/Orçamento/b.pdf",
                         "Projects With Space.v1/Orçamento/Takes/clip.MOV",
                         "Projects With Space.v1/Orçamento/Takes/c.pdf",
                         "Projects With Space.v1/Other/Deep/Takes/d.pdf",
                         "Projects With Space.v1/Other/Deep/Takes/image.PNG",
                         "Projects With Space.v1/Custom/data.UNLISTEDLONG",
                         "Projects With Space.v1/Unicode/data.RÉSUMÉ",
                         "Projects With Space.v1/Numeric/data.123",
                         "Projects With Space.v1/Sources/main.SWIFT",
                         "Projects With Space.v1/Video/clip.MKV",
                         "Projects With Space.v1/Folder With Extension/fake.pdf/placeholder",
                         "Projects With Space.v1/Orçamento In File/orçamento.txt",
                         "Projects With Space.v1/Unrelated/orçamento.pdf",
                         "Projects With Space.v1/Excluded/hidden.pdf",
                         "Projects With Space.v1/Custom/excluded.ignore",
                         "Projects With Space.v1 Backup/Outside/e.pdf"] {
                try write(path, under: root)
            }
            let scope = root.appendingPathComponent("Projects With Space.v1")
            let config = IndexConfig(rootPath: root.path, userExcludedPaths: [scope.appendingPathComponent("Excluded").path],
                                     excludedExtensions: ["ignore"])
            let store = try scan(config)

            func expect(_ terms: String, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) throws {
                let query = Query.parse("in:\"\(scope.path)\" \(terms)", store: store)
                let result = try XCTUnwrap(Searcher.search(query, in: store), file: file, line: line)
                XCTAssertEqual(result.items.map { store.path($0) }.sorted(),
                               expected.map { scope.appendingPathComponent($0).path }.sorted(), file: file, line: line)
                XCTAssertEqual(result.total, expected.count, file: file, line: line)
            }

            try expect("contains:ext:pdf", ["Orçamento", "Orçamento/Takes", "Other/Deep/Takes", "Unrelated"])
            try expect("contains:ext:pdf orçamento", ["Orçamento"])
            try expect("contains:kind:video", ["Orçamento/Takes", "Video"])
            try expect("contains:kind:image", ["Other/Deep/Takes"])
            try expect("contains:kind:code", ["Sources"])
            try expect("contains:ext:MP4;mov;MKV", ["Orçamento/Takes", "Video"])
            try expect("contains:ext:unlistedlong;résumé;123", ["Custom", "Unicode", "Numeric"])
            try expect("contains:ext:123", ["Numeric"])
            try expect("contains:ext:ignore", [])
            try expect("contains:kind:unknown", [])
            try expect("ext:pdf", ["root.pdf", "Orçamento/a.PDF", "Orçamento/b.pdf", "Orçamento/Takes/c.pdf",
                                   "Other/Deep/Takes/d.pdf", "Unrelated/orçamento.pdf", "Folder With Extension/fake.pdf"])
            try expect("kind:video", ["Orçamento/Takes/clip.MOV", "Video/clip.MKV"])
            try expect("ext:unlistedlong;résumé", ["Custom/data.UNLISTEDLONG", "Unicode/data.RÉSUMÉ"])

            let query = Query.parse("in:\"\(scope.path)\" contains:ext:pdf")
                .restricted(toFolder: root.path).restricted(toFolder: scope.appendingPathComponent("Orçamento").path)
            let combined = try XCTUnwrap(Searcher.search(query, in: store))
            XCTAssertEqual(combined.items.map { store.path($0) }, [scope.appendingPathComponent("Orçamento/Takes").path])

            let localStore = try scan(IndexConfig(rootPath: scope.path, userExcludedPaths: config.userExcludedPaths))
            let anotherRoot = root.appendingPathComponent("Projects With Space.v1 Backup")
            let otherStore = try scan(IndexConfig(rootPath: anotherRoot.path))
            let sources = [SearchSource(id: "projects", displayName: "Projects", isOnline: true, store: localStore),
                           SearchSource(id: "backup", displayName: "Backup", isOnline: true, store: otherStore)]
            let scopedQuery = Query.parse("in:\"\(scope.path)\" contains:ext:pdf")
            let multi = try XCTUnwrap(MultiSearcher.search(scopedQuery, in: sources))
            XCTAssertEqual(multi.items.map(\.sourceIndex), Array(repeating: 0, count: 4))
        }
    }

    func testFolderPreviewListsOnlyDirectFilesMatchingTheContainsFilter() throws {
        try fixture { root in
            for path in ["Shots/clip10.mov", "Shots/clip2.MP4", "Shots/Notes.pdf", "Shots/Deep/clip1.mkv"] {
                try write(path, under: root)
            }
            let config = IndexConfig(rootPath: root.path)
            let store = try scan(config)
            let id = try XCTUnwrap(store.read { store.indexedID(forPath: root.path + "/Shots") })
            XCTAssertEqual(Searcher.folderPreviewFiles(id, matching: Query.parse("contains:kind:video Shots"), in: store),
                           ["clip2.MP4", "clip10.mov"])
            XCTAssertEqual(Searcher.folderPreviewFiles(id, matching: Query.parse("contains:ext:PDF;MKV"), in: store), ["Notes.pdf"])
            XCTAssertEqual(Searcher.folderPreviewFiles(id, matching: Query.parse("Shots"), in: store),
                           ["clip2.MP4", "clip10.mov", "Notes.pdf"])
            XCTAssertTrue(Searcher.folderPreviewFiles(id, matching: Query.parse("contains:kind:video"), in: store,
                                                       isCancelled: { true }).isEmpty)
            let old = root.appendingPathComponent("Shots/clip2.MP4")
            try files.removeItem(at: old)
            _ = IndexUpdater(config: config).apply([FSChange(path: old.path)], to: store)
            XCTAssertEqual(Searcher.folderPreviewFiles(id, matching: Query.parse("contains:kind:video"), in: store),
                           ["clip10.mov"])
        }
    }

    func testContainingFoldersTrackAddsMovesRenamesAndLastRemoval() throws {
        try fixture { root in
            try write("A/first.PDF", under: root)
            try write("A/second.pdf", under: root)
            try write("B/keep.txt", under: root)
            let config = IndexConfig(rootPath: root.path)
            let store = try scan(config)
            let updater = IndexUpdater(config: config)
            let query = Query.parse("in:\"\(root.path)\" contains:ext:pdf")
            let options = SearchOptions()
            let cache = SearchCache()
            var previous: SearchResult?

            func expect(_ folders: [String], changes: [String] = [], line: UInt = #line) throws {
                if !changes.isEmpty {
                    _ = updater.apply(changes.map { FSChange(path: root.appendingPathComponent($0).path) }, to: store)
                    XCTAssertNil(cache.lookup(query: query, options: options, store: store), line: line)
                }
                let result = try XCTUnwrap(Searcher.search(query, options: options, in: store, previous: previous))
                XCTAssertEqual(result.items.map { store.path($0) }.sorted(),
                               folders.map { root.appendingPathComponent($0).path }.sorted(), line: line)
                cache.insert(result)
                previous = result
            }

            try expect(["A"])
            try files.removeItem(at: root.appendingPathComponent("A/first.PDF"))
            try expect(["A"], changes: ["A/first.PDF"])
            try files.moveItem(at: root.appendingPathComponent("A/second.pdf"), to: root.appendingPathComponent("B/moved.pdf"))
            try expect(["B"], changes: ["A/second.pdf", "B/moved.pdf"])
            try files.moveItem(at: root.appendingPathComponent("B/moved.pdf"), to: root.appendingPathComponent("B/renamed.txt"))
            try expect([], changes: ["B/moved.pdf", "B/renamed.txt"])
            try write("B/final.PDF", under: root)
            try expect(["B"], changes: ["B/final.PDF"])
            try files.removeItem(at: root.appendingPathComponent("B/final.PDF"))
            try expect([], changes: ["B/final.PDF"])
        }
    }
}
