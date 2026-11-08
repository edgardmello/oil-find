import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchEditingTests: XCTestCase {
    private func event(_ character: String, code: UInt16, in window: NSWindow,
                       modifiers: NSEvent.ModifierFlags = .command) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: code)!
    }

    func testInlinePreviewShortcutTogglesAndResetsOnHide() {
        _ = NSApplication.shared
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        let controller = panel.searchController
        let shortcut = event("P", code: 35, in: panel, modifiers: [.command, .shift])

        XCTAssertFalse(controller.inlinePreviewVisible)
        XCTAssertTrue(panel.performKeyEquivalent(with: shortcut))
        XCTAssertTrue(controller.inlinePreviewVisible)
        XCTAssertTrue(panel.performKeyEquivalent(with: shortcut))
        XCTAssertFalse(controller.inlinePreviewVisible)
        XCTAssertTrue(panel.performKeyEquivalent(with: shortcut))
        panel.hide()
        XCTAssertFalse(controller.inlinePreviewVisible)
    }

    func testSpaceTypesIntoSearchAfterNavigatingWithSidePreview() throws {
        _ = NSApplication.shared
        let suite = "OilFindSidePreview-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: "previewWithSpace")
        let controller = SearchViewController(snapshot: true, preferences: preferences)
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize),
                             styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controller
        panel.delegate = controller
        defer { panel.close() }
        let field = controller.searchField
        field.text = "two"
        field.focus()
        let editor = try XCTUnwrap(field.input.currentEditor() as? SearchEditor)
        editor.setSelectedRange(NSRange(location: 3, length: 0))

        let down = event("\u{F701}", code: 125, in: panel, modifiers: [])
        let space = event(" ", code: 49, in: panel, modifiers: [])
        controller.setInlinePreviewVisible(true)
        XCTAssertTrue(controller.handleKey(down))
        XCTAssertTrue(controller.browsingResults)
        XCTAssertEqual(controller.footer.previewKey, "⌘Y")
        XCTAssertFalse(controller.handleKey(space))
        editor.keyDown(with: space)
        XCTAssertEqual(editor.string, "two ")
    }

    func testTextEditingShortcutsWorkWithoutAnApplicationMenu() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        pasteboard.clearContents(); pasteboard.setString("unchanged", forType: .string)
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        let field = panel.searchController.searchField
        panel.contentView?.layoutSubtreeIfNeeded()
        field.text = "自媒体 html"
        field.focus()
        let editor = try XCTUnwrap(field.input.currentEditor() as? SearchEditor)
        XCTAssertTrue(panel.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))

        XCTAssertTrue(panel.performKeyEquivalent(with: event("a", code: 0, in: panel)))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(panel.performKeyEquivalent(with: event("c", code: 8, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), "自媒体 html")

        pasteboard.clearContents(); pasteboard.setString("新查询", forType: .string)
        XCTAssertTrue(panel.performKeyEquivalent(with: event("v", code: 9, in: panel)))
        XCTAssertEqual(field.text, "新查询")
        editor.setSelectedRange(NSRange(location: 0, length: 1))
        XCTAssertTrue(panel.performKeyEquivalent(with: event("x", code: 7, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), "新")
        XCTAssertEqual(field.text, "查询")

        XCTAssertFalse(panel.searchController.handleKey(event("a", code: 0, in: panel, modifiers: .control)))
        XCTAssertFalse(panel.searchController.handleKey(event("a", code: 0, in: panel, modifiers: [.command, .control])))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindEditing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("自媒体教程.html")
        try Data().write(to: file)
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        try panel.searchController.prepareSnapshot(state: "results", query: "html", options: .init(), store: store, selection: 0)
        field.focus()
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(panel.performKeyEquivalent(with: event("c", code: 8, in: panel)))
        XCTAssertEqual(pasteboard.string(forType: .string), file.path)
        XCTAssertNotNil(pasteboard.string(forType: .fileURL))
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(panel.performKeyEquivalent(with: event("c", code: 8, in: panel, modifiers: [.command, .option])))
        XCTAssertEqual(pasteboard.string(forType: .string), file.lastPathComponent)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 4))
    }
}
