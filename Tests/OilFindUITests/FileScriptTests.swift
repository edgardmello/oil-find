import XCTest
@testable import OilFindApp

final class FileScriptTests: XCTestCase {
    private func fixture(_ program: String) throws -> (URL, FileScript, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("test script")
        try Data(("#!/bin/sh\n" + program).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let file = directory.appendingPathComponent("invoice; $(echo unsafe) '2026'.pdf")
        try Data().write(to: file)
        return (directory, FileScript(url: executable), file)
    }

    func testScriptRulesRequireMatchingFilesAndSelectionSize() throws {
        let script = try JSONDecoder().decode(FileScript.self, from: Data(#"{"path":"/tmp/compare.sh"}"#.utf8))
        XCTAssertNil(script.eligibility)
        let rules = FileScript.Eligibility(extensions: ".PDF", minimum: 2, maximum: 2, filesOnly: true)
        let first = (URL(fileURLWithPath: "/tmp/first.pdf"), false)
        let second = (URL(fileURLWithPath: "/tmp/second.PDF"), false)
        XCTAssertTrue(rules.matches([first, second]))
        XCTAssertFalse(rules.matches([first]))
        XCTAssertFalse(rules.matches([first, second, second]))
        XCTAssertFalse(rules.matches([first, (URL(fileURLWithPath: "/tmp/folder.pdf"), true)]))
        XCTAssertFalse(rules.matches([first, (URL(fileURLWithPath: "/tmp/other.png"), false)]))
        var folders = FileScript.Eligibility()
        folders.foldersOnly = true
        XCTAssertTrue(folders.matches([(URL(fileURLWithPath: "/tmp/folder"), true)]))
        XCTAssertFalse(folders.matches([first]))
    }

    func testPassesPathsLiterallyAndReportsExitCodeAndStderr() throws {
        let (directory, script, file) = try fixture("""
        printf '%s\\n' "$#"
        printf '%s\\n' "$1"
        printf 'on stderr\\n' >&2
        exit 7
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = expectation(description: "Script completed")
        _ = FileScriptRun.start(script, files: [file]) { result in
            if case .exited(let code) = result.outcome { XCTAssertEqual(code, 7) }
            else { XCTFail("Expected the script's exit code") }
            XCTAssertEqual(result.output, "1\n" + file.path + "\non stderr\n")
            XCTAssertFalse(result.truncated)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    func testStopsARunningScript() throws {
        let (directory, script, file) = try fixture("""
        printf 'started' > "$1"
        while :; do :; done
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = expectation(description: "Script stopped")
        let run = FileScriptRun.start(script, files: [file]) { result in
            if case .stopped = result.outcome {} else { XCTFail("Expected the script to stop") }
            finished.fulfill()
        }
        defer { run.stop() }
        let deadline = Date().addingTimeInterval(2)
        while (try? String(contentsOf: file, encoding: .utf8)) != "started", Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "started")
        run.stop()
        wait(for: [finished], timeout: 5)
    }

    func testDrainsOutputPastCaptureLimit() throws {
        let (directory, script, file) = try fixture("/usr/bin/head -c 100000 /dev/zero\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        let finished = expectation(description: "Verbose script completed")
        _ = FileScriptRun.start(script, files: [file]) { result in
            if case .exited(let code) = result.outcome { XCTAssertEqual(code, 0) }
            else { XCTFail("Expected a successful exit") }
            XCTAssertEqual(result.output.utf8.count, FileScript.outputLimit)
            XCTAssertTrue(result.truncated)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
}
