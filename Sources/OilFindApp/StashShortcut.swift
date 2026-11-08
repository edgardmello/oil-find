import AppKit
import Carbon
import OilFindCore

enum StashShortcut: String, CaseIterable {
    case add, show, paste

    struct Chord: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32

        func matches(_ event: NSEvent) -> Bool {
            UInt32(event.keyCode) == keyCode && HotKey.carbonModifiers(event.modifierFlags) == modifiers
        }

        func apply(to item: NSMenuItem) {
            item.keyEquivalent = Shortcut.keyEquivalent(keyCode)
            item.keyEquivalentModifierMask = HotKey.modifierFlags(modifiers)
        }
    }

    var defaultChord: Chord {
        switch self {
        case .add: return Chord(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey))
        case .show: return Chord(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))
        case .paste: return Chord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
        }
    }

    var settingsTitle: String {
        switch self {
        case .add: return L10n.text("settings.stashAddShortcut")
        case .show: return L10n.text("settings.stashShowShortcut")
        case .paste: return L10n.text("filePaste.title")
        }
    }

    private var preferenceKey: String { "stashShortcut." + rawValue }

    func chord(in preferences: UserDefaults) -> Chord {
        guard let values = preferences.array(forKey: preferenceKey) as? [Int], values.count == 2,
              let code = UInt32(exactly: values[0]), code <= UInt16.max,
              let modifiers = UInt32(exactly: values[1]) else { return defaultChord }
        return Chord(keyCode: code, modifiers: modifiers)
    }

    func save(_ chord: Chord, in preferences: UserDefaults) {
        preferences.set([Int(chord.keyCode), Int(chord.modifiers)], forKey: preferenceKey)
    }

    func canAssign(_ chord: Chord, in preferences: UserDefaults, global: Chord) -> Bool {
        let flags = HotKey.modifierFlags(chord.modifiers)
        guard flags.contains(.control) || (flags.contains(.command) && flags != .command),
              chord != global,
              !Self.allCases.contains(where: { $0 != self && $0.chord(in: preferences) == chord }) else { return false }

        let key = Shortcut.keyEquivalent(chord.keyCode)
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) || (0xf704...0xf717).contains(scalar.value) else { return false }

        // Reserve the shortcuts the search panel already assigns to built-in actions.
        let isDigitFilter = ("1"..."9").contains(key)
        if flags == [.control, .option], isDigitFilter { return false }
        if flags == [.command, .shift], key == "p" { return false }
        if flags.contains(.command), isDigitFilter || ["a", "c", "w"].contains(key) { return false }
        return true
    }
}
