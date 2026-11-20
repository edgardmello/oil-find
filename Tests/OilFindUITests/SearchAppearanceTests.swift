import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchAppearanceTests: XCTestCase {
    func testSearchBarOpensCollapsedAndDownArrowExpandsIt() throws {
        _ = NSApplication.shared
        let suite = "OilFindAppearance-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(SearchInterface.bar.rawValue, forKey: SearchInterface.key)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view

        controller.preparePanelAppearance()
        XCTAssertTrue(controller.barCollapsed)
        XCTAssertTrue(controller.panelBody.isHidden)
        XCTAssertFalse(controller.searchField.isHidden)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                  timestamp: 0, windowNumber: 0, context: nil, characters: "",
                                                  charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        XCTAssertTrue(controller.handleKey(down))
        XCTAssertFalse(controller.barCollapsed)
        XCTAssertFalse(controller.panelBody.isHidden)
        controller.preparePanelAppearance()
        XCTAssertTrue(controller.barCollapsed)
        XCTAssertTrue(controller.panelBody.isHidden)
        XCTAssertFalse(controller.searchField.isHidden)

        controller.searchField.text = "report"
        controller.startSearch()
        XCTAssertFalse(controller.barCollapsed)
        XCTAssertFalse(controller.panelBody.isHidden)
    }

    func testExpandedBarKeepsCompactToolbarAndFileTypeSelection() throws {
        _ = NSApplication.shared
        let suite = "OilFindCompactToolbar-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(SearchInterface.bar.rawValue, forKey: SearchInterface.key)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view
        controller.searchField.text = "report"
        controller.startSearch()
        XCTAssertFalse(controller.barCollapsed)
        XCTAssertEqual(controller.filters.preferredHeight, 36)
        controller.filters.select(3)
        XCTAssertEqual(controller.filters.options.kind, 3)

        preferences.set(SearchInterface.window.rawValue, forKey: SearchInterface.key)
        controller.applySearchSetting(SearchInterface.key)
        // Search Window moves the categories to its filter tiles; the selection carries over.
        XCTAssertTrue(controller.filters.tileMode)
        XCTAssertEqual(controller.filters.preferredHeight, 0)
        XCTAssertEqual(controller.filters.options.kind, 3)
        XCTAssertEqual(controller.searchField.text, "report")
    }

    func testEachInterfaceOwnsItsResultsLayout() throws {
        _ = NSApplication.shared
        let suite = "OilFindInterfaceLayout-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(SearchInterface.classic.rawValue, forKey: SearchInterface.key)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view

        XCTAssertEqual(controller.searchInterface, .classic)
        XCTAssertEqual(controller.filters.preferredHeight, 40)
        XCTAssertFalse(controller.results.compact)

        preferences.set(SearchInterface.window.rawValue, forKey: SearchInterface.key)
        controller.applySearchSetting(SearchInterface.key)
        XCTAssertTrue(controller.results.compact)
        XCTAssertTrue(controller.filters.tileMode)
        XCTAssertTrue(controller.searchField.boxed)
        XCTAssertEqual(controller.filters.preferredHeight, 0)

        preferences.set(SearchInterface.bar.rawValue, forKey: SearchInterface.key)
        controller.applySearchSetting(SearchInterface.key)
        XCTAssertFalse(controller.results.compact)
        XCTAssertFalse(controller.searchField.boxed)
        XCTAssertEqual(controller.filters.preferredHeight, 36)
    }

    func testSearchWindowTilesApplyLibraryFiltersFromOptionLetters() throws {
        _ = NSApplication.shared
        let suite = "OilFindTiles-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(SearchInterface.window.rawValue, forKey: SearchInterface.key)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view
        func option(_ key: String, shift: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.option, .shift] : .option,
                                          timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                          charactersIgnoringModifiers: key, isARepeat: false, keyCode: 3))
        }
        XCTAssertTrue(controller.handleKey(try option("f")))
        XCTAssertEqual(controller.filters.options.kind, 1)
        XCTAssertTrue(controller.handleKey(try option("f")))
        XCTAssertNil(controller.filters.options.kind, "Choosing the active tile again clears it")
        // ⌃⌥S stays the stash shortcut instead of the System tile.
        let stash = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .option],
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "s",
                                                   charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        _ = controller.handleKey(stash)
        XCTAssertNil(controller.filters.options.kind)
    }

    func testDraggedSearchWindowKeepsItsCornerUntilReset() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        panel.resizeForInlinePreview(display: false)
        let centred = panel.frame
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.minX + 20, y: area.maxY - 20 - centred.height))
        panel.rememberPosition()
        let corner = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.searchController.setInlinePreviewVisible(true, resize: false)
        panel.resizeForInlinePreview(display: false)
        XCTAssertEqual(panel.frame.minX, corner.x)
        XCTAssertEqual(panel.frame.maxY, corner.y)
        XCTAssertGreaterThan(panel.frame.width, centred.width, "The preview widens the window to the right of the kept corner")
        panel.forgetPosition()
        XCTAssertNil(panel.customTopLeft)
        XCTAssertEqual(panel.frame.midX, area.midX, accuracy: 1)
    }

    func testResultsMenuNoLongerOffersLayoutChoices() throws {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        let menu = try XCTUnwrap(controller.filters.viewMenu?())
        XCTAssertNil(menu.items.first { $0.title == L10n.text("view.compact") })
        XCTAssertNotNil(menu.items.first { $0.title == L10n.text("inlinePreview.show") })
    }

    func testMinimumQueryLengthClearsPreviousResultsWhileTyping() throws {
        _ = NSApplication.shared
        let suite = "OilFindMinQuery-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("report.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        controller.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        try controller.prepareSnapshot(state: "results", query: "report", options: .init(), store: store, selection: 0)
        XCTAssertEqual(controller.results.result?.count, 1)

        preferences.set(3, forKey: "minimumSearchLength")
        controller.searchField.text = "re"
        controller.startSearch()
        XCTAssertNil(controller.results.result)
        XCTAssertNil(controller.results.selectedItem)
    }

    func testStatusVisibilityIsIndependentForWindowAndSearchBar() throws {
        _ = NSApplication.shared
        let suite = "OilFindStatus-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(["stash"], forKey: StatusItem.key(for: .window))
        preferences.set(["actions", "duration"], forKey: StatusItem.key(for: .bar))
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view
        let footer = try XCTUnwrap(controller.panelBody.subviews.compactMap { $0 as? FooterBar }.first)
        XCTAssertEqual(footer.hiddenStatusItems, [.stash])

        preferences.set(SearchInterface.bar.rawValue, forKey: SearchInterface.key)
        controller.applySearchSetting(SearchInterface.key)
        XCTAssertEqual(footer.hiddenStatusItems, [.actions, .duration])
    }
}
