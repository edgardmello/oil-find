import Foundation
import XCTest
@testable import OilFindApp

final class EncryptedShareImageTests: XCTestCase {
    func testCreatesPasswordProtectedImageWithoutOverwritingDestination() throws {
        guard ProcessInfo.processInfo.environment["OILFIND_TEST_DISK_IMAGES"] == "1" else {
            throw XCTSkip("Requires access to the macOS disk image service")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let first = directory.appendingPathComponent("example.txt")
        let destination = directory.appendingPathComponent("Share.dmg")
        try Data("fixture".utf8).write(to: first)
        let password = try EncryptedShareImage.password()
        try EncryptedShareImage.create(from: [first], at: destination, password: password)

        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["isencrypted", destination.path]
        task.standardOutput = output
        try task.run()
        let status = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0)
        XCTAssertTrue(String(decoding: status, as: UTF8.self).contains("encrypted: YES"))
        let mount = directory.appendingPathComponent("Mounted")
        try manager.createDirectory(at: mount, withIntermediateDirectories: false)
        let attach = Process()
        let input = Pipe()
        attach.executableURL = task.executableURL
        attach.arguments = ["attach", "-quiet", "-nobrowse", "-readonly", "-stdinpass", "-mountpoint", mount.path, destination.path]
        attach.standardInput = input
        try attach.run()
        try input.fileHandleForWriting.write(contentsOf: Data(password.utf8) + Data([0]))
        try input.fileHandleForWriting.close()
        attach.waitUntilExit()
        XCTAssertEqual(attach.terminationStatus, 0)
        if attach.terminationStatus == 0 {
            defer { _ = try? Process.run(attach.executableURL!, arguments: ["detach", "-quiet", mount.path]).waitUntilExit() }
            XCTAssertEqual(try Data(contentsOf: mount.appendingPathComponent(first.lastPathComponent)), Data("fixture".utf8))
        }

        let original = try Data(contentsOf: destination)
        XCTAssertThrowsError(try EncryptedShareImage.create(from: [first], at: destination, password: password))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }
}
