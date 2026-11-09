import Foundation
import OilFindCore

struct QuickFilter: Codable, Equatable {
    struct Sort: Codable, Equatable {
        let key: String
        let ascending: Bool
    }

    enum Group: String, Codable, CaseIterable {
        case quick, folder

        var title: String { L10n.text("settings.filters.group." + rawValue) }
        var newTitle: String { L10n.text("settings.filters.new." + rawValue) }
        var overviewTitle: String { L10n.text("settings.filters.all." + rawValue) }
    }

    var name: String
    var query: String
    let kind: UInt8?
    let folder: String?
    let volume: String?
    let hiddenOnly: Bool
    var fuzzyNames: Bool? = nil
    var sort: Sort? = nil
    var criteria: Query.SavedCriteria? = nil

    var group: Group? = nil
    var presetID: String? = nil
    var symbol: String? = nil
    var prepend: String? = nil
    var append: String? = nil
    var match: Match? = nil
    var expiresAfter: Int? = nil
    static let expiryKey = "savedFilterExpiry"

    enum Match: String, Codable, CaseIterable {
        case both, files, folders
    }

    var icon: String { symbol ?? (group == .folder ? "folder" : "line.3.horizontal.decrease.circle") }
    static let libraryKey = "filterLibrary"
    static let symbols = ["line.3.horizontal.decrease.circle", "folder", "app", "photo", "film", "waveform",
                          "doc.text", "archivebox", "chevron.left.forwardslash.chevron.right",
                          "gearshape", "doc.richtext", "hammer", "house", "icloud", "externaldrive", "desktopcomputer"]

    static func library(in preferences: UserDefaults) -> [QuickFilter] {
        guard let data = preferences.data(forKey: libraryKey),
              let filters = try? JSONDecoder().decode([QuickFilter].self, from: data) else { return presets }
        return filters.filter { $0.group != nil && !$0.name.isEmpty && ($0.kind.map { (1...8).contains($0) } ?? true) }
    }

    static func saveLibrary(_ filters: [QuickFilter], to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(filters) { preferences.set(data, forKey: libraryKey) }
    }

    static var presets: [QuickFilter] {
        let home = NSHomeDirectory()
        func preset(_ id: String, name: String, group: Group = .quick, symbol: String,
                    kind: UInt8? = nil, folders: [String] = [], extensions: [String] = []) -> QuickFilter {
            let criteria = Query.SavedCriteria(folders: folders.count > 1 ? folders : [],
                                               extensions: extensions, exclusions: [])
            return QuickFilter(name: L10n.text(name), query: "", kind: kind, folder: folders.count == 1 ? folders.first : nil,
                               volume: nil, hiddenOnly: false, criteria: criteria.isEmpty ? nil : criteria,
                               group: group, presetID: id, symbol: symbol)
        }
        return [
            preset("apps", name: "filter.app", symbol: "app", kind: 2),
            preset("folders", name: "filter.folder", symbol: "folder", kind: 1),
            preset("images", name: "filter.image", symbol: "photo", kind: 4),
            preset("videos", name: "filter.video", symbol: "film", kind: 5),
            preset("audio", name: "filter.audio", symbol: "waveform", kind: 6),
            preset("documents", name: "filter.document", symbol: "doc.text", kind: 3),
            preset("archives", name: "filter.archive", symbol: "archivebox", kind: 8),
            preset("code", name: "filter.code", symbol: "chevron.left.forwardslash.chevron.right", kind: 7),
            preset("config", name: "settings.filters.preset.config", symbol: "gearshape",
                   extensions: ["json", "yaml", "yml", "toml", "ini", "plist", "conf", "cfg"]),
            preset("pdf", name: "settings.filters.preset.pdf", symbol: "doc.richtext", extensions: ["pdf"]),
            QuickFilter(name: L10n.text("settings.filters.preset.xcode"), query: "*.xcodeproj | *.xcworkspace",
                        kind: nil, folder: nil, volume: nil, hiddenOnly: false,
                        group: .quick, presetID: "xcode", symbol: "hammer"),
            preset("applications", name: "settings.filters.preset.applications", group: .folder, symbol: "app",
                   folders: ["/Applications", "/System/Applications", home + "/Applications"]),
            preset("home", name: "settings.filters.preset.home", group: .folder, symbol: "house", folders: [home]),
            preset("home-documents", name: "filter.document", group: .folder, symbol: "doc.text", folders: [home + "/Documents"]),
            preset("icloud", name: "settings.filters.preset.icloud", group: .folder, symbol: "icloud",
                   folders: [home + "/Library/Mobile Documents"]),
            preset("cloud", name: "settings.filters.preset.cloud", group: .folder, symbol: "icloud",
                   folders: [home + "/Library/CloudStorage"]),
            preset("system", name: "settings.filters.preset.system", group: .folder, symbol: "desktopcomputer",
                   folders: ["/System", "/Library"])
        ]
    }

    static let storageKey = "savedQuickFilters"

    static func load(from preferences: UserDefaults) -> [QuickFilter] {
        guard let data = preferences.data(forKey: storageKey),
              let filters = try? JSONDecoder().decode([QuickFilter].self, from: data) else { return [] }
        return filters.filter { filter in
            !filter.name.isEmpty && (filter.kind.map { (1...8).contains($0) } ?? true)
        }
    }

    static func save(_ filters: [QuickFilter], to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(filters) { preferences.set(data, forKey: storageKey) }
    }
}
