import AppKit
import AVKit
import OilFindCore
import XCTest
@testable import OilFindApp

final class ContainingFoldersUITests: XCTestCase {
    func testFolderRowsSupportKeyboardSelectionAndContextScope() throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Oil Find Folders " + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        for folder in ["First", "Second"] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try files.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent(folder + ".PDF"))
            try Data().write(to: url.appendingPathComponent(folder + ".MOV"))
        }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
        let suite = "OilFindContainingFolders-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let controller = SearchViewController(snapshot: true, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        controller.additionalSources = { [SearchSource(id: "fixture", displayName: "", isOnline: true, store: store)] }

        let query = "in:\"\(root.path)\" contains:ext:pdf"
        try controller.prepareSnapshot(state: "results", query: query, options: SearchOptions(sort: .name, ascending: true, kind: 1),
                                       store: store, selection: 0)
        func key(_ character: String, code: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                           characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: code))
        }

        XCTAssertEqual(controller.results.selectedItem?.name, "First")
        XCTAssertTrue(controller.handleKey(try key("\u{F701}", code: 125)))
        let second = root.appendingPathComponent("Second").path
        XCTAssertEqual(controller.results.selectedItem?.path, second)
        XCTAssertEqual(controller.results.selectedItem?.parentPath, root.path)
        XCTAssertTrue(controller.handleKey(try key("\u{F700}", code: 126)))
        XCTAssertEqual(controller.results.selectedItem?.name, "First")
        XCTAssertTrue(controller.handleKey(try key("\u{F701}", code: 125)))

        func previewTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.accessibilityLabel() == L10n.text("inlinePreview.folderFiles") { return table }
            return view.subviews.lazy.compactMap { previewTable(in: $0) }.first
        }
        func waitForPreview(_ name: String, table: NSTableView, file: StaticString = #filePath, line: UInt = #line) {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if table.numberOfRows == 1,
                   (table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField)?.stringValue == name { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTFail("The sidebar should show only \(name)", file: file, line: line)
        }
        controller.setInlinePreviewVisible(true, resize: false)
        controller.view.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(previewTable(in: controller.view))
        waitForPreview("Second.PDF", table: preview)
        XCTAssertTrue(controller.handleKey(try key("\u{F700}", code: 126)))
        waitForPreview("First.PDF", table: preview)
        XCTAssertTrue(controller.handleKey(try key("\u{F701}", code: 125)))
        waitForPreview("Second.PDF", table: preview)

        let menu = try XCTUnwrap(controller.results.onContextMenu?(controller.results.selectedRow))
        XCTAssertEqual(menu.item(withTitle: "Show in Finder")?.isEnabled, true)
        let scope = try XCTUnwrap(menu.item(withTitle: "Search in This Folder"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(scope.action), to: scope.target, from: scope))
        XCTAssertTrue(controller.filters.scopeActive)
        XCTAssertNil(controller.filters.options.kind)
        XCTAssertEqual(controller.searchField.text, "")
        controller.searchField.text = "ext:pdf"
        controller.searchField.onChange?()
        let deadline = Date().addingTimeInterval(3)
        while controller.results.result?.query.raw != "ext:pdf" && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(controller.results.result?.query.folderScope, second)
        XCTAssertEqual(controller.results.result?.total, 1)
        XCTAssertEqual(controller.results.selectedItem?.path, second + "/Second.PDF")
    }

    func testFolderFileSelectionUpdatesMoviePreviewAndLeftReturnsToResults() throws {
        _ = NSApplication.shared
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Oil Find Preview " + UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let folder = root.appendingPathComponent("Clips", isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["First.mp4", "Second.mov"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config).run()), config: config)
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        let controller = panel.searchController
        try controller.prepareSnapshot(state: "results", query: "contains:kind:video", options: SearchOptions(), store: store, selection: 0)
        controller.setInlinePreviewVisible(true, resize: false)
        controller.view.layoutSubtreeIfNeeded()

        func descendant<T: NSView>(_ type: T.Type, in view: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
            if let view = view as? T, matching(view) { return view }
            for child in view.subviews {
                if let found = descendant(type, in: child, matching: matching) { return found }
            }
            return nil
        }
        func waitUntil(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(predicate())
        }
        func press(_ code: UInt16, _ character: String) throws -> Bool {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: panel.windowNumber, context: nil, characters: character,
                                                      charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            return panel.performKeyEquivalent(with: event)
        }
        func previewName() -> String? {
            let player = descendant(AVPlayerView.self, in: controller.view)?.player
            return (player?.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
        }

        let table = try XCTUnwrap(descendant(NSTableView.self, in: controller.view) {
            $0.accessibilityLabel() == L10n.text("inlinePreview.folderFiles")
        })
        waitUntil { table.numberOfRows == 2 }
        XCTAssertTrue(try press(125, "\u{F701}"))
        XCTAssertTrue(try press(124, "\u{F703}"))
        XCTAssertEqual(table.selectedRow, 0)
        waitUntil { previewName() == "First.mp4" }
        XCTAssertTrue(try press(125, "\u{F701}"))
        XCTAssertEqual(table.selectedRow, 1)
        waitUntil { previewName() == "Second.mov" }
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        waitUntil { previewName() == "First.mp4" }
        XCTAssertTrue(try press(123, "\u{F702}"))
        XCTAssertEqual(table.selectedRow, -1)
        XCTAssertNil(previewName())
        XCTAssertEqual(controller.results.selectedItem?.name, "Clips")
    }

}
