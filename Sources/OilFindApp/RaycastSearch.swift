import Foundation
import OilFindCore

/// Line-delimited JSON over stdin/stdout for the Raycast extension. One process per Raycast
/// command keeps the saved index loaded and reloads it whenever Oil Find writes a new one.
/// Bump `OilFindRaycastProtocol` in Info.plist when the messages change shape.
enum RaycastSearch {
    private struct Request: Decodable {
        let id: Int
        var type: String?
        var query: String?
        var filter: String?
        var limit: Int?
    }

    private struct Item: Encodable {
        let path: String
        let kind: String?
        let isFolder: Bool
        let size: UInt64
        let modified: Double
    }

    private struct Filter: Encodable {
        let id: String
        let name: String
        let section: String
        let symbol: String?
        /// Text a saved quick filter puts in the search field when it is opened in Oil Find.
        let query: String?
    }

    private struct Response: Encodable {
        let id: Int
        var items: [Item]?
        var total: Int?
        var filters: [Filter]?
        var error: String?
    }

    static func run() {
        let preferences = UserDefaults.standard
        let path = AppDelegate.dbURL.path
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var store: IndexStore?
        var indexVersion: [String] = []
        var previous: SearchResult?

        while let line = readLine() {
            guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else { continue }
            var response = Response(id: request.id)
            if request.type == "filters" {
                response.filters = filters(in: preferences)
            } else {
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let version = [FileAttributeKey.systemFileNumber, .modificationDate, .size].map {
                    attributes?[$0].map { String(describing: $0) } ?? ""
                }
                if store == nil || version != indexVersion {
                    previous = nil
                    store = attributes == nil ? nil : IndexStore.load(from: path)
                    indexVersion = version
                }
                if let store {
                    search(request, in: store, preferences: preferences, previous: &previous, into: &response)
                } else {
                    response.error = "indexUnavailable"
                }
            }
            if let data = try? encoder.encode(response) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }

    private static func filters(in preferences: UserDefaults) -> [Filter] {
        let kinds = FilterBar.names.dropFirst().map { name in
            Filter(id: "kind:" + name, name: L10n.text("filter." + name), section: "kind", symbol: nil, query: nil)
        }
        let library = QuickFilter.available(in: preferences).map { filter in
            Filter(id: "library:" + filter.linkID, name: filter.name, section: filter.group?.rawValue ?? "saved",
                   symbol: filter.icon, query: filter.refinesQuery || filter.query.isEmpty ? nil : filter.query)
        }
        return kinds + library
    }

    private static func search(_ request: Request, in store: IndexStore, preferences: UserDefaults,
                               previous: inout SearchResult?, into response: inout Response) {
        let typed = request.query ?? ""
        var filter: QuickFilter?
        var kind: UInt8?
        if let id = request.filter, id.hasPrefix("kind:") {
            kind = FilterBar.names.firstIndex(of: String(id.dropFirst(5))).flatMap { $0 > 0 ? UInt8($0) : nil }
        } else if let id = request.filter, id.hasPrefix("library:") {
            filter = QuickFilter.linked(String(id.dropFirst(8)), in: preferences)
            if filter == nil { response.error = "filterUnavailable"; return }
        }

        let text = filter.map { !$0.refinesQuery && !$0.query.isEmpty ? $0.query + " " + typed : typed } ?? typed
        var query = Query.parse(text, store: store, fuzzyNames: filter?.fuzzyNames ?? preferences.bool(forKey: "fuzzyNames"))
        var options = SettingsPreferences.searchOptions(in: preferences, recent: text.trimmingCharacters(in: .whitespaces).isEmpty)
        options.kind = kind
        if let filter {
            if filter.refinesQuery { query = filter.appendingFields(to: query, store: store) }
            if let folder = filter.folder { query = query.restricted(toFolder: folder) }
            if let criteria = filter.criteria { query = query.applying(criteria) }
            if filter.hiddenOnly { query = query.showingOnlyHiddenFiles() }
            options.kind = filter.kind
            if let sort = filter.sort, let key = SortKey(rawValue: sort.key) {
                options.sort = key
                options.ascending = sort.ascending
            }
        }

        if let diagnostic = query.diagnostics.first {
            response.error = "invalidQuery:" + diagnostic.kind.rawValue
            return
        }
        guard let result = Searcher.search(query, options: options, in: store, previous: previous) else {
            response.items = []
            response.total = 0
            return
        }
        previous = result
        let limit = min(max(request.limit ?? 100, 1), 500)
        response.items = store.read {
            result.items.prefix(limit).filter(store.isLive).map { index in
                let flags = store.flags[Int(index)], code = Int(store.kind[Int(index)])
                return Item(path: store.path(index),
                            kind: (1...Query.kindNames.count).contains(code) ? Query.kindNames[code - 1] : nil,
                            isFolder: flags & SiftFlag.dir != 0 && flags & SiftFlag.package == 0,
                            size: store.size(index), modified: store.modified(index).timeIntervalSince1970)
            }
        }
        response.total = result.total
    }
}
