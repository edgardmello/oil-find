import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class M17UITests: XCTestCase {
    func testSyntaxShortcutEscapeAndExamplePreserveSearchInput() {
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        func event(_ key: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: key == 44 ? "/" : "", charactersIgnoringModifiers: key == 44 ? "/" : "", isARepeat: false, keyCode: key)!
        }
        controller.searchField.text = "original"
        XCTAssertTrue(controller.handleKey(event(44, .command)))
        XCTAssertTrue(controller.syntaxVisible)
        XCTAssertTrue(controller.handleKey(event(53)))
        XCTAssertFalse(controller.syntaxVisible)
        XCTAssertEqual(controller.searchField.text, "original")
        controller.toggleSyntax(true)
        controller.view.frame = NSRect(origin: .zero, size: Theme.panelSize)
        controller.view.layoutSubtreeIfNeeded()
        let button = controller.syntax.subviews.compactMap { $0 as? NSButton }[3]
        for label in button.subviews.compactMap({ $0 as? NSTextField }) {
            let point = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: controller.syntax.superview)
            XCTAssertTrue(controller.syntax.hitTest(point) === button)
        }
        button.performClick(nil)
        XCTAssertFalse(controller.syntaxVisible)
        XCTAssertEqual(controller.searchField.text, "~/Desktop/ png")
    }
    func testRemappedSyntaxShortcutUsesTheNewKey() throws {
        let app = NSApplication.shared
        let suite = "OilFindSyntaxShortcut-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chord = StashShortcut.Chord(keyCode: 97, modifiers: 0)
        StashShortcut.syntax.save(chord, in: defaults)
        let controller = SearchViewController(snapshot: true, preferences: defaults)
        _ = controller.view
        let old = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: 0, windowNumber: 0, context: nil, characters: "/", charactersIgnoringModifiers: "/", isARepeat: false, keyCode: 44))
        let custom = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(chord.keyCode)))
        XCTAssertFalse(controller.handleKey(old))
        XCTAssertTrue(controller.handleKey(custom))
        XCTAssertTrue(controller.syntaxVisible)
        _ = app
    }

    func testLocalizationUsesExactDiagnosticAndCoverageCopy() {
        XCTAssertEqual(L10n.text("coverage.title"), "Not Covered")
        XCTAssertEqual(L10n.text("coverage.volumes", "2"), "External and network volumes: 2 (not indexed)")
        XCTAssertEqual(L10n.explanation(.volume), "It's on an external or network volume, which isn't indexed.")
        XCTAssertEqual(L10n.text("empty.noAccess"), "Some folders aren't accessible, so files in them can't be found.")
        XCTAssertEqual(L10n.diagnostic(QueryDiagnostic(kind: .size)), "Write size: as size:>10mb or size:1mb..5mb")
        XCTAssertEqual(L10n.diagnostic(QueryDiagnostic(kind: .date)), "Write dm: as dm:today, dm:week or dm:2026-10-01")
        XCTAssertEqual(L10n.explanation(.cloud), "It's in a folder that's only in the cloud. Download it to this Mac to search it.")
    }
}
