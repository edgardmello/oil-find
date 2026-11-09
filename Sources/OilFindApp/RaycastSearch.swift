import AppKit
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
        var content: Bool?
        var paths: [String]?
    }

    private struct Item: Encodable {
        let path: String
        let kind: String?
        let isFolder: Bool
        let size: UInt64
        let modified: Double
        var snippet: String? = nil
        var missing: Bool? = nil
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
        /// Set on a search answer when a second line with content matches follows.
        var contentPending: Bool?
        var contentItems: [Item]?
        var stash: [Item]?
        var copied: Int?
        var error: String?
    }

    static func run(contentSearch: SupplementarySearchProvider?) {
        let preferences = UserDefaults.standard
        let path = AppDelegate.dbURL.path
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        var store: IndexStore?
        var indexVersion: [String] = []
        var previous: SearchResult?

        func send(_ response: Response) {
            if let data = try? encoder.encode(response) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }

        while let line = readLine() {
            guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else { continue }
            var response = Response(id: request.id)
            switch request.type {
            case "filters":
                response.filters = filters(in: preferences)
            case "stash":
                // The app writes the stash; pick up its latest copy before reading.
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
                response.stash = FileStash(preferences: preferences).files.map { item(at: $0.path) }
            case "copyFiles":
                let urls = (request.paths ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) as NSURL }
                NSPasteboard.general.clearContents()
                response.copied = !urls.isEmpty && NSPasteboard.general.writeObjects(urls) ? urls.count : 0
            default:
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let version = [FileAttributeKey.systemFileNumber, .modificationDate, .size].map {
                    attributes?[$0].map { String(describing: $0) } ?? ""
                }
                if store == nil || version != indexVersion {
                    previous = nil
                    store = attributes == nil ? nil : IndexStore.load(from: path)
                    indexVersion = version
                }
                guard let store else {
                    response.error = "indexUnavailable"
                    break
                }
                guard let found = search(request, in: store, preferences: preferences, previous: &previous, into: &response),
                      request.content == true, let contentSearch, contentSearch.isEnabled else { break }
                response.contentPending = true
                send(response)
                // A newer request on stdin supersedes this one, so stop scanning contents as soon as it arrives.
                let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
                let hits = contentSearch.prepareSearch(found.query, options: found.options, sources: [source],
                                                       isCancelled: inputWaiting)()
                if inputWaiting() { continue }
                let shown = Set(response.items?.map(\.path) ?? [])
                var content = Response(id: request.id)
                content.contentItems = store.read {
                    hits.filter { $0.sourceID == source.id && store.isLive($0.entryID) }.prefix(50).compactMap { hit in
                        var entry = item(hit.entryID, in: store)
                        guard !shown.contains(entry.path) else { return nil }
                        entry.snippet = hit.detail
                        return entry
                    }
                }
                response = content
            }
            send(response)
        }
    }

    private static func inputWaiting() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0
    }

    private static func item(_ index: UInt32, in store: IndexStore) -> Item {
        let flags = store.flags[Int(index)], code = Int(store.kind[Int(index)])
        return Item(path: store.path(index),
                    kind: (1...Query.kindNames.count).contains(code) ? Query.kindNames[code - 1] : nil,
                    isFolder: flags & SiftFlag.dir != 0 && flags & SiftFlag.package == 0,
                    size: store.size(index), modified: store.modified(index).timeIntervalSince1970)
    }

    private static func item(at path: String) -> Item {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return Item(path: path, kind: nil, isFolder: false, size: 0, modified: 0, missing: true)
        }
        let isFolder = attributes[.type] as? FileAttributeType == .typeDirectory
            && !NSWorkspace.shared.isFilePackage(atPath: path)
        return Item(path: path, kind: isFolder ? "folder" : nil, isFolder: isFolder,
                    size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                    modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
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

    @discardableResult
    private static func search(_ request: Request, in store: IndexStore, preferences: UserDefaults,
                               previous: inout SearchResult?, into response: inout Response) -> SearchResult? {
        let typed = request.query ?? ""
        var filter: QuickFilter?
        var kind: UInt8?
        if let id = request.filter, id.hasPrefix("kind:") {
            kind = FilterBar.names.firstIndex(of: String(id.dropFirst(5))).flatMap { $0 > 0 ? UInt8($0) : nil }
        } else if let id = request.filter, id.hasPrefix("library:") {
            filter = QuickFilter.linked(String(id.dropFirst(8)), in: preferences)
            if filter == nil { response.error = "filterUnavailable"; return nil }
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
            return nil
        }
        guard let result = Searcher.search(query, options: options, in: store, previous: previous) else {
            response.items = []
            response.total = 0
            return nil
        }
        previous = result
        let limit = min(max(request.limit ?? 100, 1), 500)
        response.items = store.read { result.items.prefix(limit).filter(store.isLive).map { item($0, in: store) } }
        response.total = result.total
        return result
    }
}
