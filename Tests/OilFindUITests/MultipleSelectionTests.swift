import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class MultipleSelectionTests: XCTestCase {
    private func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = [], _ characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func testShiftArrowsAndSelectAllBuildAMultipleSelectionThatDragsAsMove() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindMulti-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<6 { try Data().write(to: root.appendingPathComponent("row\(index).txt")) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.close() }
        try controller.prepareSnapshot(state: "results", query: "row", options: .init(sort: .name), store: store, selection: 1)
        controller.view.layoutSubtreeIfNeeded()
        let results = controller.results
        let table = try XCTUnwrap(results.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
        XCTAssertTrue(table.allowsMultipleSelection)
        XCTAssertTrue(table.draggingSourceOperationMask(forLocal: false).contains(.move))

        XCTAssertTrue(controller.handleKey(key(125, .shift)))
        XCTAssertTrue(controller.handleKey(key(125, .shift)))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(1...3))
        XCTAssertEqual(results.selectedRow, 3)
        XCTAssertEqual(results.selectedItems.map(\.name), ["row3.txt", "row1.txt", "row2.txt"])
        XCTAssertEqual(controller.footer.text, L10n.text("footer.selected", "3"))

        // Shrinking returns toward the anchor; a plain arrow collapses from the cursor.
        XCTAssertTrue(controller.handleKey(key(126, .shift)))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(1...2))
        XCTAssertTrue(controller.handleKey(key(125)))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 3))

        results.selectAll()
        XCTAssertEqual(results.selectionCount, 6)
        XCTAssertEqual(results.selectedRow, 3)
    }
}
