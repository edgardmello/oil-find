import XCTest
@testable import OilFindApp

final class FileStashTests: XCTestCase {
    func testStashPersistsUniqueReferencesAndRemovesWithoutDeletingOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Client invoice.pdf")
        let missing = directory.appendingPathComponent("Missing.pdf")
        let contents = Data("test invoice".utf8)
        try contents.write(to: file)

        let suite = "OilFindFileStash-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let stash = FileStash(preferences: preferences)
        let saved = expectation(description: "Persist one reachable file")
        stash.add([file, file, missing]) { count in
            XCTAssertEqual(count, 1)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)

        let reopened = FileStash(preferences: preferences)
        let item = try XCTUnwrap(reopened.files.first)
        XCTAssertEqual(reopened.files.count, 1)
        let resolved = expectation(description: "Resolve the original URL")
        reopened.resolve(reopened.files) { urls in
            XCTAssertEqual(urls[item.id]?.standardizedFileURL.resolvingSymlinksInPath(),
                           file.standardizedFileURL.resolvingSymlinksInPath())
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 5)

        reopened.remove([item.id])
        XCTAssertTrue(FileStash(preferences: preferences).files.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), contents)
    }

    func testStashLinksAddRemoveAndClearThroughTheSearchController() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("Plan A.txt"), second = directory.appendingPathComponent("Plan B.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)

        func link(_ query: String) throws -> StashLink { try XCTUnwrap(StashLink(try XCTUnwrap(URL(string: "oilfind://stash?" + query)))) }
        let encoded = { (url: URL) in url.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        XCTAssertEqual(try link("add=" + encoded(first) + "&add=" + encoded(second)).action, .add([first.path, second.path]))
        XCTAssertEqual(try link("clear=1").action, .clear)
        XCTAssertNil(StashLink(try XCTUnwrap(URL(string: "oilfind://stash?add=relative"))))
        XCTAssertNil(StashLink(try XCTUnwrap(URL(string: "oilfind://stash?add=%2Fa&remove=%2Fb"))))
        XCTAssertNil(StashLink(try XCTUnwrap(URL(string: "oilfind://stash"))))

        let suite = "OilFindStashLink-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        controller.applyStashLink(try link("add=" + encoded(first) + "&add=" + encoded(second)))
        let added = expectation(description: "Both files reach the stash")
        func poll() {
            if FileStash(preferences: preferences).files.count == 2 { added.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll) }
        }
        poll()
        wait(for: [added], timeout: 5)

        controller.applyStashLink(try link("remove=" + encoded(first)))
        XCTAssertEqual(FileStash(preferences: preferences).files.map(\.path), [second.path])
        controller.applyStashLink(try link("clear=1"))
        XCTAssertTrue(FileStash(preferences: preferences).files.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
