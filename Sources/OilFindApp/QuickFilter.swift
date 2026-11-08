import Foundation

struct QuickFilter: Codable {
    let name: String
    let query: String
    let kind: UInt8?
    let folder: String?
    let volume: String?
    let hiddenOnly: Bool

    private static let key = "savedQuickFilters"

    static func load(from preferences: UserDefaults) -> [QuickFilter] {
        guard let data = preferences.data(forKey: key),
              let filters = try? JSONDecoder().decode([QuickFilter].self, from: data) else { return [] }
        return filters.filter { filter in
            !filter.name.isEmpty && (filter.kind.map { (1...8).contains($0) } ?? true)
        }
    }

    static func save(_ filters: [QuickFilter], to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(filters) { preferences.set(data, forKey: key) }
    }
}
