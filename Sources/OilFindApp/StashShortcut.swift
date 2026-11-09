import AppKit
import Carbon
import OilFindCore

enum StashShortcut: String, CaseIterable {
    case add, show, paste, remove, clearStash
    case syntax, actions, preview, inlinePreview, open
    case reveal, copyPath, copyName, trash, settings
    case close, selectAll, up, down, extendUp
    case extendDown, first, last, pageUp, pageDown
    case nextFilter, previousFilter, home, end, escape
    case copyTo, moveTo, terminal, duplicate

    case category1, category2, category3, category4, category5, category6, category7, category8, category9

    case quick1, quick2, quick3, quick4, quick5, quick6, quick7, quick8, quick9

    case script1, script2, script3, script4, script5, script6, script7, script8, script9

    struct Chord: Hashable {
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
        case .clearStash: return Chord(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey | shiftKey | optionKey))
        case .remove: return Chord(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey | shiftKey))
        case .paste: return Chord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey))
        case .syntax: return Chord(keyCode: UInt32(kVK_ANSI_Slash), modifiers: UInt32(cmdKey))
        case .actions: return Chord(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey))
        case .preview: return Chord(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(cmdKey))
        case .inlinePreview: return Chord(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey))
        case .open: return Chord(keyCode: UInt32(kVK_Return), modifiers: UInt32(0))
        case .reveal: return Chord(keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))
        case .copyPath: return Chord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey))
        case .copyName: return Chord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey))
        case .trash: return Chord(keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey))
        case .settings: return Chord(keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey))
        case .close: return Chord(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey))
        case .selectAll: return Chord(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))
        case .up: return Chord(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(0))
        case .down: return Chord(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(0))
        case .extendUp: return Chord(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(shiftKey))
        case .extendDown: return Chord(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(shiftKey))
        case .first: return Chord(keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(cmdKey))
        case .last: return Chord(keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(cmdKey))
        case .pageUp: return Chord(keyCode: UInt32(kVK_PageUp), modifiers: UInt32(0))
        case .pageDown: return Chord(keyCode: UInt32(kVK_PageDown), modifiers: UInt32(0))
        case .nextFilter: return Chord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(0))
        case .previousFilter: return Chord(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey))
        case .home: return Chord(keyCode: UInt32(kVK_Home), modifiers: UInt32(0))
        case .end: return Chord(keyCode: UInt32(kVK_End), modifiers: UInt32(0))
        case .escape: return Chord(keyCode: UInt32(kVK_Escape), modifiers: UInt32(0))
        case .copyTo: return Chord(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | controlKey))
        case .moveTo: return Chord(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(cmdKey | controlKey))
        case .terminal: return Chord(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | controlKey))
        case .duplicate: return Chord(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey))
        case .category1, .category2, .category3, .category4, .category5, .category6, .category7, .category8, .category9:
            return Chord(keyCode: FileScript.shortcutKeys[slot], modifiers: UInt32(cmdKey))
        case .quick1, .quick2, .quick3, .quick4, .quick5, .quick6, .quick7, .quick8, .quick9:
            return Chord(keyCode: FileScript.shortcutKeys[slot], modifiers: UInt32(controlKey | optionKey))
        case .script1, .script2, .script3, .script4, .script5, .script6, .script7, .script8, .script9:
            return Chord(keyCode: FileScript.shortcutKeys[slot], modifiers: UInt32(controlKey | shiftKey))
        }
    }

    var settingsTitle: String {
        switch self {
        case .add: return L10n.text("settings.stashAddShortcut")
        case .show: return L10n.text("settings.stashShowShortcut")
        case .clearStash: return L10n.text("stash.clear")
        case .remove: return L10n.text("stash.removeSelection")
        case .paste: return L10n.text("filePaste.title")
        case .syntax: return L10n.text("hint.syntax")
        case .actions: return L10n.text("panel.actions")
        case .preview: return L10n.text("hint.preview")
        case .inlinePreview: return L10n.text("inlinePreview.show")
        case .open: return L10n.text("ctx.open")
        case .reveal: return L10n.text("ctx.reveal")
        case .copyPath: return L10n.text("ctx.copyPaths")
        case .copyName: return L10n.text("ctx.copyNames")
        case .trash: return L10n.text("ctx.trash")
        case .settings: return L10n.text("settings.title")
        case .close: return L10n.text("shortcut.close")
        case .selectAll: return L10n.text("shortcut.selectAll")
        case .up: return L10n.text("shortcut.up")
        case .down: return L10n.text("shortcut.down")
        case .extendUp: return L10n.text("shortcut.extendUp")
        case .extendDown: return L10n.text("shortcut.extendDown")
        case .first: return L10n.text("shortcut.first")
        case .last: return L10n.text("shortcut.last")
        case .pageUp: return L10n.text("shortcut.pageUp")
        case .pageDown: return L10n.text("shortcut.pageDown")
        case .nextFilter: return L10n.text("shortcut.nextFilter")
        case .previousFilter: return L10n.text("shortcut.previousFilter")
        case .home: return L10n.text("shortcut.first")
        case .end: return L10n.text("shortcut.last")
        case .escape: return L10n.text("shortcut.escape")
        case .copyTo: return L10n.text("ctx.copyTo")
        case .moveTo: return L10n.text("ctx.moveTo")
        case .terminal: return L10n.text("ctx.terminal")
        case .duplicate: return L10n.text("ctx.duplicate")
        case .category1, .category2, .category3, .category4, .category5, .category6, .category7, .category8, .category9:
            return L10n.text("shortcut.category", String(slot + 1))
        case .quick1, .quick2, .quick3, .quick4, .quick5, .quick6, .quick7, .quick8, .quick9:
            return L10n.text("shortcut.quick", String(slot + 1))
        case .script1, .script2, .script3, .script4, .script5, .script6, .script7, .script8, .script9:
            return L10n.text("shortcut.script", String(slot + 1))
        }
    }

    static let categories = allCases.filter { $0.rawValue.hasPrefix("category") }
    static let quickFilters = allCases.filter { $0.rawValue.hasPrefix("quick") }
    static let scripts = allCases.filter { $0.rawValue.hasPrefix("script") }
    var slot: Int { (rawValue.last?.wholeNumberValue ?? 1) - 1 }

    var symbols: String { symbols(in: .standard) }

    func symbols(in preferences: UserDefaults) -> String {
        let chord = chord(in: preferences)
        return Shortcut.symbols(keyCode: chord.keyCode, modifiers: chord.modifiers)
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
        let key = Shortcut.keyEquivalent(chord.keyCode)
        guard !key.isEmpty, chord != global,
              !Self.allCases.contains(where: { $0 != self && $0.chord(in: preferences) == chord }) else { return false }
        if chord == defaultChord { return true }

        let hasCommandModifier = !flags.intersection([.command, .control, .option]).isEmpty
        let functionKey = key.unicodeScalars.first.map { (0xf704...0xf717).contains($0.value) } ?? false
        guard hasCommandModifier || functionKey else { return false }
        if flags == .command, ["a", "c", "x", "v", "z", "q"].contains(key) { return false }
        return true
    }
}
