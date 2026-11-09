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
        XCTAssertEqual(controller.filters.preferredHeight, FilterBar.toolbarHeight)
        XCTAssertEqual(controller.filters.options.kind, 3)
        XCTAssertEqual(controller.searchField.text, "report")
    }

    func testClassicRestoresOriginalLayoutWithoutOverwritingTablePreference() throws {
        _ = NSApplication.shared
        let suite = "OilFindClassic-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(SearchInterface.classic.rawValue, forKey: SearchInterface.key)
        preferences.set(true, forKey: "compactResults")
        let controller = SearchViewController(snapshot: false, preferences: preferences)
        _ = controller.view

        XCTAssertEqual(controller.searchInterface, .classic)
        XCTAssertEqual(controller.filters.preferredHeight, 40)
        XCTAssertFalse(controller.results.compact)
        XCTAssertTrue(preferences.bool(forKey: "compactResults"))

        preferences.set(SearchInterface.window.rawValue, forKey: SearchInterface.key)
        controller.applySearchSetting(SearchInterface.key)
        XCTAssertTrue(controller.results.compact)
        XCTAssertEqual(controller.filters.preferredHeight, FilterBar.toolbarHeight)
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
