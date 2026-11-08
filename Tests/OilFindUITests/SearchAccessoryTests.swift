import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class SearchAccessoryTests: XCTestCase {
    func testApplyingQuickFilterPreservesQueryAndDisplaysRemovableScopes() throws {
        let app = NSApplication.shared
        let suite = "OilFindAccessory-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        QuickFilter.save([.init(name: "Receipts", query: "saved text", kind: Query.kindValue("doc"),
                                folder: "/Clients", volume: nil, hiddenOnly: true)], to: preferences)

        let controller = SearchViewController(snapshot: true, preferences: preferences)
        let view = controller.view
        controller.searchField.text = "keep this text"
        let menu = try XCTUnwrap(controller.filters.scopeMenu?())
        let quick = try XCTUnwrap(menu.items.first { $0.title == L10n.text("quickFilter.title") }?.submenu)
        let apply = try XCTUnwrap(quick.items.first { $0.title == L10n.text("quickFilter.refine") }?.submenu?.items.first)
        XCTAssertTrue(app.sendAction(try XCTUnwrap(apply.action), to: apply.target, from: apply))
        XCTAssertEqual(controller.searchField.text, "keep this text")
        XCTAssertEqual(controller.filters.options.kind, Query.kindValue("doc"))

        let bar = try XCTUnwrap(view.subviews.compactMap { $0 as? SearchAccessoryBar }.first)
        XCTAssertEqual(bar.desiredHeight, 32)
        let clear = try XCTUnwrap(bar.subviews.compactMap { $0 as? ChromeButton }.first {
            $0.title == L10n.text("panel.clearFilters")
        })
        clear.onPress?()
        XCTAssertEqual(bar.desiredHeight, 0)
        XCTAssertNil(controller.filters.options.kind)
        XCTAssertEqual(controller.searchField.text, "keep this text")
    }
}
