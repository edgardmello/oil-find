import AppKit
import XCTest
@testable import OilFindApp

final class InlineStashTableTests: XCTestCase {
    func testExpandedStashKeepsEveryRowInAScrollableTable() throws {
        _ = NSApplication.shared
        let tableView = InlineStashTable(frame: NSRect(x: 0, y: 0, width: 760, height: 156))
        let files = (1...9).map { StashedFile(url: URL(fileURLWithPath: "/missing/stashed-file-\($0)")) }
        tableView.update(files, visible: true)
        let table = try XCTUnwrap(tableView.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 9)
        XCTAssertEqual(table.tableColumns.map { $0.identifier.rawValue }, ["name", "path", "size", "date"])
        XCTAssertTrue(table.allowsMultipleSelection)
        XCTAssertTrue(tableView.hasVerticalScroller)
        XCTAssertEqual(tableView.desiredHeight, 156)
        tableView.update(files, visible: false)
        XCTAssertEqual(tableView.desiredHeight, 0)
    }
}
