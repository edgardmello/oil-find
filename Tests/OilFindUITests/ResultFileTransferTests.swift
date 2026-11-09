import Foundation
import XCTest
@testable import OilFindApp

final class ResultFileTransferTests: XCTestCase {
    func testCopyKeepsAnExistingDestinationAndContinuesWithOtherFiles() throws {
        try withFolders { source, destination in
            let first = source.appendingPathComponent("first.txt")
            let second = source.appendingPathComponent("second.txt")
            let existing = destination.appendingPathComponent(first.lastPathComponent)
            try Data("source".utf8).write(to: first)
            try Data("second".utf8).write(to: second)
            try Data("existing".utf8).write(to: existing)

            XCTAssertEqual(ResultFileTransfer.run(paths: [first.path, second.path], to: destination, move: false), 1)
            XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "source")
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent(second.lastPathComponent), encoding: .utf8), "second")
        }
    }

    func testMovingSelectedFolderAndChildPreservesTheirHierarchy() throws {
        try withFolders { source, destination in
            let folder = source.appendingPathComponent("Folder", isDirectory: true)
            let child = folder.appendingPathComponent("child.txt")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("child".utf8).write(to: child)

            XCTAssertEqual(ResultFileTransfer.run(paths: [child.path, folder.path], to: destination, move: true), 2)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Folder/child.txt"), encoding: .utf8), "child")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        }
    }

    private func withFolders(_ body: (URL, URL) throws -> Void) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)
        try body(source, destination)
    }
}
