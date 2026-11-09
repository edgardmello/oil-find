import AppKit
import OilFindCore

/// Line-delimited JSON over stdin/stdout for the Raycast extension. One process per Raycast
/// command keeps the saved indexes loaded and reloads them whenever Oil Find writes new ones.
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
        var script: String?
    }

    private struct Item: Encodable {
        let path: String
        let kind: String?
        let isFolder: Bool
        let size: UInt64
        let modified: Double
        var snippet: String? = nil
        var missing: Bool? = nil
        /// Set for results from a disconnected drive's catalog.
        var offline: Bool? = nil
    }

    private struct Filter: Encodable {
        let id: String
        let name: String
        let section: String
        let symbol: String?
        /// Text a saved quick filter puts in the search field when it is opened in Oil Find.
        let query: String?
        var connected: Bool? = nil
    }

    private struct Script: Encodable {
        let path: String
        let name: String
    }

    private struct ScriptRun: Encodable {
        let status: String
        let code: Int32?
        let output: String
        let truncated: Bool
    }

    private struct IndexStatus: Encodable {
        struct Gap: Encodable {
            let reason: String
            let count: UInt64
            let examples: [String]
        }
        /// `startup`, or the drive UUID used by `drive:` filters.
        let id: String
        let name: String
        let root: String
        let items: Int
        let fileSize: UInt64
        let saved: Double?
        let connected: Bool
        let gaps: [Gap]
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
        var scripts: [Script]?
        var run: ScriptRun?
        var indexes: [IndexStatus]?
        var error: String?
    }

    static func run(contentSearch: SupplementarySearchProvider?) {
        let preferences = UserDefaults.standard
        let indexes = RaycastIndexes()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

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
                response.filters = filters(in: preferences, drives: indexes.drives)
            case "stash":
                // The app writes the stash; pick up its latest copy before reading.
                CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
                response.stash = FileStash(preferences: preferences).files.map { item(at: $0.path) }
            case "copyFiles":
                let urls = (request.paths ?? []).filter { FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) as NSURL }
                NSPasteboard.general.clearContents()
                response.copied = !urls.isEmpty && NSPasteboard.general.writeObjects(urls) ? urls.count : 0
            case "scripts":
                response.scripts = scripts(for: request.paths ?? [], in: preferences)
            case "runScript":
                response.run = runScript(request.script, paths: request.paths ?? [], in: preferences)
            case "status":
                response.indexes = status(indexes)
            default:
                let target: (path: String, offline: Bool)
                if let id = request.filter, id.hasPrefix("drive:") {
                    guard let drive = indexes.drive(String(id.dropFirst(6))) else {
                        response.error = "filterUnavailable"
                        break
                    }
                    target = (drive.url.path, !drive.isConnected)
                } else {
                    target = (AppDelegate.dbURL.path, false)
                }
                guard let store = indexes.store(at: target.path) else {
                    response.error = "indexUnavailable"
                    break
                }
                guard let found = search(request, in: store, preferences: preferences,
                                         previous: indexes.previous(at: target.path), into: &response) else { break }
                indexes.remember(found, at: target.path)
                if target.offline { response.items = response.items?.map { var item = $0; item.offline = true; return item } }
                // Content matches only exist for the startup volume.
                guard target.path == AppDelegate.dbURL.path, request.content == true,
                      let contentSearch, contentSearch.isEnabled else { break }
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

    private static func filters(in preferences: UserDefaults, drives: [RaycastIndexes.Drive]) -> [Filter] {
        let kinds = FilterBar.names.dropFirst().map { name in
            Filter(id: "kind:" + name, name: L10n.text("filter." + name), section: "kind", symbol: nil, query: nil)
        }
        let library = QuickFilter.available(in: preferences).map { filter in
            Filter(id: "library:" + filter.linkID, name: filter.name, section: filter.group?.rawValue ?? "saved",
                   symbol: filter.icon, query: filter.refinesQuery || filter.query.isEmpty ? nil : filter.query)
        }
        let volumes = drives.map { drive in
            Filter(id: "drive:" + drive.record.id, name: drive.record.name, section: "drive", symbol: "externaldrive",
                   query: nil, connected: drive.isConnected)
        }
        return kinds + library + volumes
    }

    /// Scripts from Oil Find's settings whose rules accept these files, in the app's order.
    private static func scripts(for paths: [String], in preferences: UserDefaults) -> [Script] {
        var isDirectory: ObjCBool = false
        let selection = paths.compactMap { path -> (url: URL, isDirectory: Bool)? in
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                ? (URL(fileURLWithPath: path), isDirectory.boolValue && !NSWorkspace.shared.isFilePackage(atPath: path)) : nil
        }
        guard !selection.isEmpty, selection.count == paths.count else { return [] }
        return FileScript.load(from: preferences)
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) && ($0.eligibility?.matches(selection) ?? true) }
            .map { Script(path: $0.path, name: $0.name) }
    }

    private static func runScript(_ path: String?, paths: [String], in preferences: UserDefaults) -> ScriptRun {
        // Only scripts the user added in Oil Find run, never an arbitrary path from the request.
        guard let script = FileScript.load(from: preferences).first(where: { $0.path == path }) else {
            return ScriptRun(status: "failed", code: nil, output: L10n.text("fileScripts.launchFailed"), truncated: false)
        }
        let result = FileScriptRun().execute(script, files: paths.map { URL(fileURLWithPath: $0) })
        switch result.outcome {
        case .exited(let code):
            return ScriptRun(status: "exited", code: code, output: result.output, truncated: result.truncated)
        case .signaled(let signal):
            return ScriptRun(status: "signaled", code: signal, output: result.output, truncated: result.truncated)
        case .stopped:
            return ScriptRun(status: "stopped", code: nil, output: result.output, truncated: result.truncated)
        case .failed(let key):
            let message = [L10n.text(key), result.output].filter { !$0.isEmpty }.joined(separator: "\n")
            return ScriptRun(status: "failed", code: nil, output: message, truncated: false)
        }
    }

    private static func status(_ indexes: RaycastIndexes) -> [IndexStatus] {
        func describe(id: String, name: String, path: String, connected: Bool) -> IndexStatus? {
            guard let store = indexes.store(at: path) else { return nil }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let gaps = store.read { () -> [IndexStatus.Gap] in
                CoverageReason.allCases.compactMap { reason in
                    let bucket = store.coverage[reason]
                    return bucket.count == 0 ? nil : IndexStatus.Gap(reason: reason.rawValue, count: bucket.count, examples: bucket.examples)
                }
            }
            return IndexStatus(id: id, name: name, root: store.read { store.rootPath }, items: store.read { store.count - 1 },
                               fileSize: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
                               saved: (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970,
                               connected: connected, gaps: gaps)
        }
        let startup = describe(id: "startup", name: FileManager.default.displayName(atPath: "/"), path: AppDelegate.dbURL.path, connected: true)
        let drives = indexes.drives.compactMap { describe(id: $0.record.id, name: $0.record.name, path: $0.url.path, connected: $0.isConnected) }
        return (startup.map { [$0] } ?? []) + drives
    }

    private static func search(_ request: Request, in store: IndexStore, preferences: UserDefaults,
                               previous: SearchResult?, into response: inout Response) -> SearchResult? {
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
        let limit = min(max(request.limit ?? 100, 1), 500)
        response.items = store.read { result.items.prefix(limit).filter(store.isLive).map { item($0, in: store) } }
        response.total = result.total
        return result
    }
}
