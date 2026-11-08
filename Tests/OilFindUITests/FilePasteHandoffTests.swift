import ApplicationServices
import Carbon
import XCTest
@testable import OilFindApp

final class FilePasteHandoffTests: XCTestCase {
    func testDestinationRequiresSameProcessWindowAndElement() {
        let element = AXUIElementCreateApplication(100)
        let sameElement = AXUIElementCreateApplication(100)
        let differentElement = AXUIElementCreateApplication(101)
        let window = AXUIElementCreateApplication(102)
        let original = FilePasteHandoff.Focus(pid: 100, element: element, window: window)

        XCTAssertEqual(original, .init(pid: 100, element: sameElement, window: window))
        XCTAssertNotEqual(original, .init(pid: 101, element: element, window: window))
        XCTAssertNotEqual(original, .init(pid: 100, element: differentElement, window: window))
        XCTAssertNotEqual(original, .init(pid: 100, element: element, window: nil))
    }

    func testPasteHasSeparateConfigurableShortcut() throws {
        let suite = "OilFindFilePasteShortcut-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let paste = StashShortcut.paste
        let fallback = paste.chord(in: preferences)
        XCTAssertNotEqual(fallback, StashShortcut.add.defaultChord)
        XCTAssertNotEqual(fallback, StashShortcut.show.defaultChord)
        let custom = StashShortcut.Chord(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey))
        paste.save(custom, in: preferences)
        XCTAssertEqual(paste.chord(in: preferences), custom)
        XCTAssertEqual(StashShortcut.add.chord(in: preferences), StashShortcut.add.defaultChord)
    }
}
