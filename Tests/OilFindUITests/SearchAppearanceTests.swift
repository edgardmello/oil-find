import AppKit
import XCTest
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
