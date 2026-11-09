import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchAccessoryTests: XCTestCase {
    func testStashOpensOnAddAndSupportsToggleAndRemovalShortcuts() throws {
        let app = NSApplication.shared
        let suite = "OilFindStashExpansion-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("stash-example.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        controller.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        let window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 800, height: 560),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFrontRegardless()
        defer { window.close() }
        try controller.prepareSnapshot(state: "results", query: "stash-example", options: .init(), store: store, selection: 0)
        let bar = try XCTUnwrap(controller.panelBody.subviews.compactMap { $0 as? SearchAccessoryBar }.first)
        XCTAssertEqual(bar.desiredHeight, 0)

        XCTAssertTrue(app.sendAction(NSSelectorFromString("stashSelection"), to: controller, from: nil))
        let deadline = Date().addingTimeInterval(2)
        while bar.desiredHeight == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let stash = try XCTUnwrap(bar.subviews.compactMap { $0 as? InlineStashTable }.first)
        XCTAssertFalse(stash.isHidden)
        let table = try XCTUnwrap(stash.documentView as? NSTableView)
        XCTAssertEqual(table.numberOfRows, 1)

        func key(_ action: StashShortcut) throws -> NSEvent {
            let chord = action.chord(in: preferences)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                   modifierFlags: HotKey.modifierFlags(chord.modifiers),
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                                                   keyCode: UInt16(chord.keyCode)))
        }
        XCTAssertTrue(controller.handleKey(try key(.show)))
        XCTAssertTrue(stash.isHidden)
        XCTAssertTrue(controller.handleKey(try key(.show)))
        XCTAssertFalse(stash.isHidden)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertTrue(controller.handleKey(try key(.remove)))
        XCTAssertTrue(stash.isHidden)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stash-example.txt").path))

        XCTAssertTrue(app.sendAction(NSSelectorFromString("stashSelection"), to: controller, from: nil))
        let addedAgain = Date().addingTimeInterval(2)
        while stash.isHidden && Date() < addedAgain {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(controller.handleKey(try key(.show)))
        XCTAssertTrue(stash.isHidden)
        XCTAssertTrue(controller.handleKey(try key(.clearStash)))
        XCTAssertTrue(controller.handleKey(try key(.show)))
        XCTAssertTrue(stash.isHidden)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stash-example.txt").path))
    }

    func testQuickFilterRestoresSavedFilenameModeAndSortAndReadsLegacyFilters() throws {
        let app = NSApplication.shared
        let suite = "OilFindQuickFilterMode-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        QuickFilter.save([
            .init(name: "Approximate", query: "rdm", kind: nil, folder: nil, volume: nil, hiddenOnly: false, fuzzyNames: true,
                  sort: .init(key: "size", ascending: true)),
            .init(name: "Legacy", query: "readme", kind: nil, folder: nil, volume: nil, hiddenOnly: false)
        ], to: preferences)

        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view
        func restore(_ title: String) throws {
            let quick = try XCTUnwrap(controller.filters.savedMenu?())
            let item = try XCTUnwrap(quick.items.first { $0.title == title })
            XCTAssertTrue(app.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        func fuzzyMenuState() throws -> NSControl.StateValue {
            let menu = try XCTUnwrap(controller.filters.searchOptionsMenu?())
            return try XCTUnwrap(menu.items.first { $0.title == L10n.text("scope.fuzzyNames") }).state
        }

        try restore("Approximate")
        XCTAssertEqual(controller.searchField.text, "rdm")
        XCTAssertEqual(try fuzzyMenuState(), .on)
        XCTAssertEqual(controller.filters.options.sort, .size)
        XCTAssertTrue(controller.filters.options.ascending)
        XCTAssertNil(preferences.string(forKey: "sortKey"))
        XCTAssertFalse(preferences.bool(forKey: "fuzzyNames"))
        try restore("Legacy")
        XCTAssertEqual(controller.searchField.text, "readme")
        XCTAssertEqual(try fuzzyMenuState(), .off)
    }

    func testApplyingQuickFilterPreservesQueryAndDisplaysRemovableScopes() throws {
        let app = NSApplication.shared
        let suite = "OilFindAccessory-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        QuickFilter.save([.init(name: "Receipts", query: "saved text", kind: Query.kindValue("doc"),
                                folder: "/Clients", volume: nil, hiddenOnly: true)], to: preferences)

        let controller = SearchViewController(snapshot: true, preferences: preferences)
        _ = controller.view
        controller.searchField.text = "keep this text"
        let quick = try XCTUnwrap(controller.filters.savedMenu?())
        let apply = try XCTUnwrap(quick.items.first { $0.title == L10n.text("quickFilter.refine") }?.submenu?.items.first)
        XCTAssertTrue(app.sendAction(try XCTUnwrap(apply.action), to: apply.target, from: apply))
        XCTAssertEqual(controller.searchField.text, "keep this text")
        XCTAssertEqual(controller.filters.options.kind, Query.kindValue("doc"))

        let bar = try XCTUnwrap(controller.panelBody.subviews.compactMap { $0 as? SearchAccessoryBar }.first)
        XCTAssertEqual(bar.desiredHeight, 32)
        let clear = try XCTUnwrap(bar.subviews.compactMap { $0 as? ChromeButton }.first {
            $0.title == L10n.text("panel.clearFilters")
        })
        clear.onPress?()
        XCTAssertEqual(bar.desiredHeight, 0)
        XCTAssertNil(controller.filters.options.kind)
        XCTAssertEqual(controller.searchField.text, "keep this text")
    }
    func testFilterLibraryPresetsCanBeEditedAndAppliedWithoutReplacingSearchText() throws {
        let app = NSApplication.shared
        let suite = "OilFindFilterLibrary-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        var library = QuickFilter.library(in: preferences)
        XCTAssertEqual(library.filter { $0.group == .quick }.count, 11)
        XCTAssertEqual(library.filter { $0.group == .folder }.count, 6)
        let index = try XCTUnwrap(library.firstIndex { $0.presetID == "pdf" })
        library[index].name = "My PDFs"
        library[index].expiresAfter = 300
        QuickFilter.saveLibrary(library, to: preferences)
        XCTAssertEqual(QuickFilter.library(in: preferences), library)

        let controller = SearchViewController(snapshot: true, preferences: preferences)
        _ = controller.view
        controller.searchField.text = "invoice 2026"
        let menu = try XCTUnwrap(controller.filters.savedMenu?())
        let group = try XCTUnwrap(menu.items.first { $0.title == QuickFilter.Group.quick.title }?.submenu)
        let preset = try XCTUnwrap(group.items.first { $0.title == "My PDFs" })
        let action = try XCTUnwrap(preset.action)
        let bar = try XCTUnwrap(controller.panelBody.subviews.compactMap { $0 as? SearchAccessoryBar }.first)
        XCTAssertTrue(app.sendAction(action, to: preset.target, from: preset))
        XCTAssertEqual(controller.searchField.text, "invoice 2026")
        XCTAssertEqual(bar.desiredHeight, 32)
        XCTAssertTrue(app.sendAction(action, to: preset.target, from: preset))
        XCTAssertEqual(bar.desiredHeight, 0)
    }

}
