import Foundation
import OilFindCore

struct QuickFilter: Codable, Equatable {
    struct Sort: Codable, Equatable {
        let key: String
        let ascending: Bool
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
