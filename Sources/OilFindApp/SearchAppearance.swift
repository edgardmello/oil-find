import AppKit

enum SearchInterface: String, CaseIterable {
    case window, bar
    static let key = "searchInterface"

    var title: String { L10n.text("settings.interface." + rawValue) }
}

enum SearchMaterial: String, CaseIterable {
    case glassy, vibrant, opaque
    static let key = "searchWindowMaterial"

    var title: String { L10n.text("settings.material." + rawValue) }
}

enum StatusItem: String, CaseIterable {
    case results, duration, open, preview, syntax, stash, actions, sidePreview

    var title: String { L10n.text("settings.status." + rawValue) }

    static func key(for interface: SearchInterface) -> String {
        "hiddenStatusItems." + interface.rawValue
    }

    static func hidden(in preferences: UserDefaults, interface: SearchInterface) -> Set<Self> {
        Set((preferences.stringArray(forKey: key(for: interface)) ?? []).compactMap(Self.init(rawValue:)))
    }
}
