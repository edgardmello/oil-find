import AppKit
import Carbon
import XCTest
import OilFindCore
@testable import OilFindApp

final class StashShortcutTests: XCTestCase {
    func testCustomChordReachesPanelAndRejectsConflicts() throws {
        _ = NSApplication.shared
        let suite = "OilFindStashShortcut-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        let add = StashShortcut.add
        let global = StashShortcut.Chord(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers)
        let custom = StashShortcut.Chord(keyCode: UInt32(kVK_F6), modifiers: UInt32(controlKey))
        XCTAssertEqual(add.chord(in: preferences), add.defaultChord)
        XCTAssertTrue(add.canAssign(custom, in: preferences, global: global))
        XCTAssertFalse(add.canAssign(global, in: preferences, global: global))
        XCTAssertFalse(add.canAssign(StashShortcut.show.defaultChord, in: preferences, global: global))
        XCTAssertFalse(add.canAssign(.init(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey)),
                                     in: preferences, global: global))

        add.save(custom, in: preferences)
        XCTAssertEqual(add.chord(in: preferences), custom)
        let controller = SearchViewController(snapshot: true, preferences: preferences)
        _ = controller.view
        func event(_ chord: StashShortcut.Chord, key: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: HotKey.modifierFlags(chord.modifiers),
                                          timestamp: 0, windowNumber: 0, context: nil, characters: key,
                                          charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(chord.keyCode)))
        }
        XCTAssertTrue(controller.handleKey(try event(custom, key: Shortcut.keyEquivalent(custom.keyCode))))
        XCTAssertFalse(controller.handleKey(try event(add.defaultChord, key: "s")))
    }
}
