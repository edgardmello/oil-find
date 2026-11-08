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
}
