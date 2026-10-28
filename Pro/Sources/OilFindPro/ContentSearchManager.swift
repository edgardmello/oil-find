import Foundation
import Combine
import CoreServices
import OilFindCore
import OilFindApp

public final class ContentSearchManager: ObservableObject, SupplementarySearchProvider {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var codeAndTextEnabled: Bool
    @Published public private(set) var documentsEnabled: Bool
    @Published public private(set) var includeNoiseAndPackages: Bool
    @Published public private(set) var indexing: Bool = false
    @Published public private(set) var indexedFileCount: Int = 0
    @Published public private(set) var diskBytes: Int64 = 0

    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled && (codeAndTextEnabled || documentsEnabled)
    }

    public var onStateChange: (() -> Void)?

    private let defaults: UserDefaults
    private let database: ContentIndexDatabase?
    private let lock = NSLock()
    private var indexedMeta: [String: (mtime: UInt32, size: UInt64)] = [:]
    private var snippetCache: [String: String] = [:]
    private var currentSources: [SearchSource] = []
    private var isPanelVisible = false
    private var isTyping = false
    private var isPrimaryBusy = false
    private var stopped = false
    private var syncGeneration = 0
    private var chinese = false

    private static let spotlightCacheLock = NSLock()
    private static var spotlightCache: [String: (timestamp: CFAbsoluteTime, paths: [String])] = [:]

    private let indexQueue = DispatchQueue(label: "com.oiloil.find.pro.content.index", qos: .utility)

    public static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Oil Find/content-index/content.sqlite")
    }

    public init(defaults: UserDefaults = .standard, databaseURL: URL? = nil) {
        self.defaults = defaults
        let url = databaseURL ?? Self.defaultDatabaseURL
        self.database = try? ContentIndexDatabase(url: url)
        self.enabled = defaults.object(forKey: "contentSearchEnabled") as? Bool ?? true
        self.codeAndTextEnabled = defaults.object(forKey: "contentSearchCodeAndText") as? Bool ?? true
        self.documentsEnabled = defaults.object(forKey: "contentSearchDocuments") as? Bool ?? true
        self.includeNoiseAndPackages = defaults.object(forKey: "contentSearchIncludeNoise") as? Bool ?? false

        if let db = self.database {
            let meta = db.loadAllMetadata()
            let currentStats = db.stats()
            self.indexedMeta = meta
            self.indexedFileCount = currentStats.fileCount
            self.diskBytes = currentStats.diskBytes
        }
    }

    public func setLanguage(chinese: Bool) {
        lock.lock()
        self.chinese = chinese
        lock.unlock()
    }

    public func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: "contentSearchEnabled")
        lock.lock()
        enabled = value
        syncGeneration += 1
        lock.unlock()
        onStateChange?()
        if value { scheduleBackgroundSync() }
    }

    public func setCodeAndTextEnabled(_ value: Bool) {
        defaults.set(value, forKey: "contentSearchCodeAndText")
        lock.lock()
        codeAndTextEnabled = value
        syncGeneration += 1
        lock.unlock()
        onStateChange?()
        if value { scheduleBackgroundSync() }
    }

    public func setDocumentsEnabled(_ value: Bool) {
        defaults.set(value, forKey: "contentSearchDocuments")
        lock.lock()
        documentsEnabled = value
        syncGeneration += 1
        lock.unlock()
        onStateChange?()
        if value { scheduleBackgroundSync() }
    }

    public func setIncludeNoiseAndPackages(_ value: Bool) {
        defaults.set(value, forKey: "contentSearchIncludeNoise")
        lock.lock()
        includeNoiseAndPackages = value
        syncGeneration += 1
        lock.unlock()
        onStateChange?()
        scheduleBackgroundSync()
    }

    public func rebuildIndex() {
        lock.lock()
        syncGeneration += 1
        indexedMeta.removeAll()
        snippetCache.removeAll()
        lock.unlock()
        indexQueue.async { [weak self] in
            guard let self else { return }
            self.database?.clearAll()
            self.refreshStatsOnMain()
            self.scheduleBackgroundSync()
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        syncGeneration += 1
        lock.unlock()
    }

    public func sourcesDidChange(_ sources: [SearchSource]) {
        lock.lock()
        let oldSignatures = currentSources.filter(\.isOnline).map { ($0.id, ObjectIdentifier($0.store)) }
        let newSignatures = sources.filter(\.isOnline).map { ($0.id, ObjectIdentifier($0.store)) }
        currentSources = sources
        let changed = oldSignatures.count != newSignatures.count
            || zip(oldSignatures, newSignatures).contains { $0.0 != $1.0 || $0.1 != $1.1 }
        lock.unlock()
        if changed {
            scheduleBackgroundSync()
        }
    }

    public func userActivity(visible: Bool, typing: Bool) {
        lock.lock()
        let wasBusy = isTyping || isPanelVisible
        isPanelVisible = visible
        isTyping = typing
        let isBusyNow = isTyping || isPanelVisible
        lock.unlock()
        if wasBusy && !isBusyNow {
            scheduleBackgroundSync()
        }
    }

    public func backgroundIndexingChanged(_ busy: Bool) {
        lock.lock()
        let wasBusy = isPrimaryBusy
        isPrimaryBusy = busy
        lock.unlock()
        if wasBusy && !busy {
            scheduleBackgroundSync()
        }
    }

    private func snippetPrefix() -> String {
        lock.lock()
        let useChinese = chinese
        lock.unlock()
        if useChinese { return "包含：" }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("pt") { return "Contém: " }
        return "Contains: "
    }

    public func prepareSearch(
        _ query: Query,
        options: SearchOptions,
        sources: [SearchSource],
        isCancelled: @escaping () -> Bool
    ) -> () -> [SupplementaryHit] {
        guard isEnabled, !query.isEmpty, options.kind != 1 else {
            return { [] }
        }

        let parsed = Self.decomposeQuery(query)
        guard !parsed.hasFoldersOnly, !parsed.contentClauses.isEmpty else {
            return { [] }
        }

        lock.lock()
        let allowCode = codeAndTextEnabled
        let allowDocs = documentsEnabled
        let allowNoise = includeNoiseAndPackages
            || parsed.hasExplicitPathFilter
            || defaults.bool(forKey: "indexPackageContents")
            || defaults.bool(forKey: "indexDependencyDirs")
        let sourceVersions: [String: UInt64] = Dictionary(
            uniqueKeysWithValues: sources.map { source in
                (source.id, source.store.read { source.store.version })
            }
        )
        lock.unlock()

        let prefix = snippetPrefix()
        let flatTerms = parsed.contentClauses.flatMap { $0 }
        // Require at least 3 characters (or non-ASCII such as CJK) before scanning file contents.
        let hasSubstantialTerm = flatTerms.contains { term in
            term.text.count >= 3 || term.text.unicodeScalars.contains(where: { $0.value >= 128 })
        }
        guard hasSubstantialTerm else {
            return { [] }
        }

        lock.lock()
        let currentlyTyping = isTyping
        lock.unlock()

        return { [weak self] in
            guard let self, self.isEnabled, !isCancelled() else { return [] }
            // Debounce intermediate keystrokes on the serial supplementQueue so fast typing never queues up Spotlight queries.
            if currentlyTyping {
                for _ in 0..<6 {
                    Thread.sleep(forTimeInterval: 0.015)
                    if isCancelled() { return [] }
                }
            }
            var hits: [SupplementaryHit] = []
            var seenEntries: [String: Set<UInt32>] = [:]

            // Phase 1: Query our lock-free SQLite FTS5 content index and macOS Spotlight (MDQuery) in parallel.
            var matchedBodiesByPath: [String: String] = [:]
            var spotlightPaths: [String] = []

            if let db = self.database {
                let dbMatches = db.search(
                    clauses: parsed.contentClauses,
                    excluded: parsed.excludedContentTerms,
                    limit: 300,
                    isCancelled: isCancelled
                )
                for match in dbMatches {
                    matchedBodiesByPath[match.path] = match.body
                }
            }
            if isCancelled() { return [] }

            if flatTerms.contains(where: { $0.text.count >= 2 }) {
                spotlightPaths = Self.querySpotlight(
                    clauses: parsed.contentClauses,
                    excluded: parsed.excludedContentTerms,
                    limit: 250,
                    isCancelled: isCancelled
                )
            }
            if isCancelled() { return [] }

            var candidatePaths: [String] = Array(matchedBodiesByPath.keys)
            var seenPathSet = Set(candidatePaths)
            for path in spotlightPaths where seenPathSet.insert(path).inserted {
                candidatePaths.append(path)
            }

            let flatAtoms = parsed.structuralClauses.flatMap { $0 }
            var clauseRanges: [Range<Int>] = []
            var cursor = 0
            for clause in parsed.structuralClauses {
                clauseRanges.append(cursor..<(cursor + clause.count))
                cursor += clause.count
            }

            // Phase 2: Resolve matched paths in each online store in O(1) and check entry predicates.
            for source in sources where source.isOnline {
                if isCancelled() { return [] }
                guard let expectedVersion = sourceVersions[source.id] else { continue }
                let store = source.store

                if !candidatePaths.isEmpty {
                    let resolvedHits: [SupplementaryHit] = Searcher.withEntryPredicates(flatAtoms, options: options, in: store, isCancelled: isCancelled) { matchAtom in
                        var localHits: [SupplementaryHit] = []
                        for path in candidatePaths {
                            if isCancelled() { return [] }
                            guard let id = Self.resolveEntry(path: path, in: store) else { continue }
                            guard Self.entryPassesFilter(
                                id: id,
                                in: store,
                                options: options,
                                allowCode: allowCode,
                                allowDocs: allowDocs,
                                allowNoise: allowNoise,
                                clauseRanges: clauseRanges,
                                matchAtom: matchAtom
                            ) != nil else { continue }

                            if seenEntries[source.id, default: []].insert(id).inserted {
                                let knownBody = matchedBodiesByPath[path]
                                localHits.append(
                                    self.makeHit(
                                        sourceID: source.id,
                                        entryID: id,
                                        sourceVersion: expectedVersion,
                                        path: path,
                                        knownBody: knownBody,
                                        flatTerms: flatTerms,
                                        prefix: prefix
                                    )
                                )
                            }
                        }
                        return localHits
                    }
                    hits.append(contentsOf: resolvedHits)
                }

                if isCancelled() { return [] }

                // Phase 3: Fast bounded on-demand scan for unindexed files (e.g. newly created files or small stores).
                let shouldScanOnDemand = store.count <= 25_000 || parsed.hasExplicitPathFilter || hits.count < 25
                if shouldScanOnDemand {
                    let onDemandCandidates = Self.collectOnDemandCandidates(
                        in: store,
                        flatAtoms: flatAtoms,
                        clauseRanges: clauseRanges,
                        options: options,
                        allowCode: allowCode,
                        allowDocs: allowDocs,
                        allowNoise: allowNoise,
                        maxCandidates: parsed.hasExplicitPathFilter ? 500 : 200,
                        isCancelled: isCancelled
                    )
                    if isCancelled() { return [] }

                    var newlyExtracted: [(path: String, mtime: UInt32, size: UInt64, body: String)] = []
                    let deadline = CFAbsoluteTimeGetCurrent() + (parsed.hasExplicitPathFilter ? 1.0 : 0.75)

                    for candidate in onDemandCandidates {
                        if isCancelled() || CFAbsoluteTimeGetCurrent() > deadline { break }
                        if seenEntries[source.id]?.contains(candidate.id) == true { continue }

                        self.lock.lock()
                        let cached = self.indexedMeta[candidate.path]
                        let cachedBody = self.snippetCache[candidate.path]
                        self.lock.unlock()
                        if let cached, cached.mtime == candidate.mtime && cached.size == candidate.size {
                            if let cachedBody, ContentExtractor.matches(body: cachedBody, clauses: parsed.contentClauses, excluded: parsed.excludedContentTerms) {
                                if seenEntries[source.id, default: []].insert(candidate.id).inserted {
                                    hits.append(
                                        SupplementaryHit(
                                            sourceID: source.id,
                                            entryID: candidate.id,
                                            thumbnail: false,
                                            sourceVersion: expectedVersion,
                                            presentation: {
                                                ContentExtractor.makePresentation(body: cachedBody, terms: flatTerms, prefix: prefix)
                                            }
                                        )
                                    )
                                }
                            }
                            continue
                        }

                        guard let body = ContentExtractor.extractText(at: candidate.path, category: candidate.category) else {
                            self.lock.lock()
                            self.indexedMeta[candidate.path] = (candidate.mtime, candidate.size)
                            self.lock.unlock()
                            continue
                        }

                        self.lock.lock()
                        self.snippetCache[candidate.path] = body
                        if self.snippetCache.count > 2000 {
                            self.snippetCache.removeAll(keepingCapacity: true)
                        }
                        self.lock.unlock()

                        newlyExtracted.append((path: candidate.path, mtime: candidate.mtime, size: candidate.size, body: body))
                        if ContentExtractor.matches(body: body, clauses: parsed.contentClauses, excluded: parsed.excludedContentTerms) {
                            if seenEntries[source.id, default: []].insert(candidate.id).inserted {
                                hits.append(
                                    SupplementaryHit(
                                        sourceID: source.id,
                                        entryID: candidate.id,
                                        thumbnail: false,
                                        sourceVersion: expectedVersion,
                                        presentation: {
                                            ContentExtractor.makePresentation(body: body, terms: flatTerms, prefix: prefix)
                                        }
                                    )
                                )
                            }
                        }
                    }

                    if !newlyExtracted.isEmpty {
                        self.cacheExtractedRecordsAsync(newlyExtracted)
                    }
                }
            }
            return hits
        }
    }

    private func makeHit(
        sourceID: String,
        entryID: UInt32,
        sourceVersion: UInt64,
        path: String,
        knownBody: String?,
        flatTerms: [ContentTerm],
        prefix: String
    ) -> SupplementaryHit {
        if let knownBody {
            return SupplementaryHit(
                sourceID: sourceID,
                entryID: entryID,
                thumbnail: false,
                sourceVersion: sourceVersion,
                presentation: {
                    ContentExtractor.makePresentation(body: knownBody, terms: flatTerms, prefix: prefix)
                }
            )
        }

        // For Spotlight matches whose body is not yet in SQLite, try extracting fast text (< 512 KB) or fall back to term highlight.
        return SupplementaryHit(
            sourceID: sourceID,
            entryID: entryID,
            thumbnail: false,
            sourceVersion: sourceVersion,
            presentation: { [weak self] in
                if let self {
                    self.lock.lock()
                    let cachedBody = self.snippetCache[path]
                    self.lock.unlock()
                    if let cachedBody {
                        return ContentExtractor.makePresentation(body: cachedBody, terms: flatTerms, prefix: prefix)
                    }
                }

                let ext = (path as NSString).pathExtension.lowercased()
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                if size > 0 && size <= 512 * 1024,
                   let category = ContentExtractor.fileCategory(name: (path as NSString).lastPathComponent, kind: ext == "pdf" ? 3 : 7, size: size),
                   let extracted = ContentExtractor.extractText(at: path, category: category),
                   ContentExtractor.matches(body: extracted, clauses: [flatTerms], excluded: []) {
                    if let self {
                        self.lock.lock()
                        self.snippetCache[path] = extracted
                        self.lock.unlock()
                    }
                    return ContentExtractor.makePresentation(body: extracted, terms: flatTerms, prefix: prefix)
                }

                // Immediate non-blocking presentation for multi-hundred-page PDFs matched via Spotlight.
                let joined = flatTerms.map(\.text).joined(separator: ", ")
                let text = prefix + "“\(joined)”"
                var highlights: [NSRange] = []
                for term in flatTerms where !term.text.isEmpty {
                    if let r = text.range(of: term.text, options: [.caseInsensitive, .diacriticInsensitive]) {
                        highlights.append(NSRange(r, in: text))
                    }
                }
                return (text, highlights)
            }
        )
    }

    private static func resolveEntry(path: String, in store: IndexStore) -> UInt32? {
        if store.hashReady {
            return store.resolve(path: path)
        }
        // Fallback parent-chain resolution if hash table is still building after startup.
        let root = store.rootPath == "/" ? "" : store.rootPath
        guard path == store.rootPath || path.hasPrefix(root + "/") else { return nil }
        if path == store.rootPath { return store.isLive(0) ? 0 : nil }
        var current: UInt32 = 0
        for component in path.dropFirst(root.count).split(separator: "/") {
            let target = String(component)
            var found: UInt32?
            for i in (Int(current) + 1)..<store.count where store.parent[i] == current && store.isLive(UInt32(i)) {
                if store.name(UInt32(i)).caseInsensitiveCompare(target) == .orderedSame {
                    found = UInt32(i)
                    break
                }
            }
            guard let next = found else { return nil }
            current = next
        }
        return current
    }

    private static func entryPassesFilter(
        id: UInt32,
        in store: IndexStore,
        options: SearchOptions,
        allowCode: Bool,
        allowDocs: Bool,
        allowNoise: Bool,
        clauseRanges: [Range<Int>],
        matchAtom: (Int, UInt32) -> Bool
    ) -> ContentExtractor.FileCategory? {
        let rawID = Int(id)
        guard rawID > 0, rawID < store.count else { return nil }
        let flags = store.flags[rawID]
        if flags & (SiftFlag.deleted | SiftFlag.dir | SiftFlag.symlink) != 0 { return nil }
        if !allowNoise && (flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) != 0) {
            return nil
        }
        let kind = store.kind[rawID]
        if let requiredKind = options.kind, kind != requiredKind { return nil }
        let size = store.size(id)
        guard size > 0 else { return nil }
        let name = store.name(id)
        guard let category = ContentExtractor.fileCategory(name: name, kind: kind, size: size) else {
            return nil
        }
        if category.isDocument && !allowDocs { return nil }
        if !category.isDocument && !allowCode { return nil }

        for range in clauseRanges {
            var matched = false
            for ordinal in range {
                if matchAtom(ordinal, id) {
                    matched = true
                    break
                }
            }
            if !matched { return nil }
        }
        return category
    }

    private static func querySpotlight(
        clauses: [[ContentTerm]],
        excluded: [ContentTerm],
        limit: Int,
        isCancelled: () -> Bool
    ) -> [String] {
        guard !clauses.isEmpty, !isCancelled() else { return [] }
        var clauseStrings: [String] = []
        for clause in clauses {
            var altStrings: [String] = []
            for term in clause {
                let escaped = term.text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "*", with: "")
                guard escaped.count >= 2 else { continue }
                let mods = term.caseSensitive ? "w" : "cdw"
                altStrings.append("kMDItemTextContent == \"\(escaped)*\"\(mods)")
            }
            guard !altStrings.isEmpty else { continue }
            if altStrings.count == 1 {
                clauseStrings.append(altStrings[0])
            } else {
                clauseStrings.append("(" + altStrings.joined(separator: " || ") + ")")
            }
        }
        guard !clauseStrings.isEmpty else { return [] }
        for neg in excluded {
            let escaped = neg.text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "")
            guard escaped.count >= 2 else { continue }
            let mods = neg.caseSensitive ? "w" : "cdw"
            clauseStrings.append("kMDItemTextContent != \"\(escaped)*\"\(mods)")
        }

        let queryKey = clauseStrings.joined(separator: " && ")
        let cacheKey = "\(limit)|\(queryKey)"
        let now = CFAbsoluteTimeGetCurrent()
        spotlightCacheLock.lock()
        if let cached = spotlightCache[cacheKey], now - cached.timestamp <= 15.0 {
            spotlightCacheLock.unlock()
            return cached.paths
        }
        spotlightCacheLock.unlock()

        let queryString = queryKey as CFString
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, queryString, [kMDItemPath] as CFArray, nil) else {
            return []
        }
        MDQuerySetMaxCount(mdQuery, limit)
        let ok = MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue))
        guard ok, !isCancelled() else { return [] }
        let count = MDQueryGetResultCount(mdQuery)
        var paths: [String] = []
        if count > 0 {
            paths.reserveCapacity(min(count, limit))
            for i in 0..<min(count, limit) {
                if isCancelled() { return [] }
                guard let rawPtr = MDQueryGetResultAtIndex(mdQuery, i) else { continue }
                let item = Unmanaged<MDItem>.fromOpaque(rawPtr).takeUnretainedValue()
                if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                    paths.append(path.precomposedStringWithCanonicalMapping)
                }
            }
        }
        spotlightCacheLock.lock()
        if spotlightCache.count >= 32 {
            spotlightCache.removeAll(keepingCapacity: true)
        }
        spotlightCache[cacheKey] = (CFAbsoluteTimeGetCurrent(), paths)
        spotlightCacheLock.unlock()
        return paths
    }

    private struct OnDemandCandidate {
        let id: UInt32
        let path: String
        let mtime: UInt32
        let size: UInt64
        let category: ContentExtractor.FileCategory
    }

    private static func collectOnDemandCandidates(
        in store: IndexStore,
        flatAtoms: [Atom],
        clauseRanges: [Range<Int>],
        options: SearchOptions,
        allowCode: Bool,
        allowDocs: Bool,
        allowNoise: Bool,
        maxCandidates: Int,
        isCancelled: @escaping () -> Bool
    ) -> [OnDemandCandidate] {
        Searcher.withEntryPredicates(flatAtoms, options: options, in: store, isCancelled: isCancelled) { matchAtom in
            guard store.count > 1 else { return [] }
            let requiredKind = options.kind
            var matchedIDs: [UInt32] = []
            matchedIDs.reserveCapacity(min(maxCandidates * 2, 1024))

            // Iterate backwards from higher IDs and check fast SoA bytes before allocating any String.
            for rawID in stride(from: store.count - 1, through: 1, by: -1) {
                if rawID & 4095 == 0 && isCancelled() { return [] }
                let flags = store.flags[rawID]
                if flags & (SiftFlag.deleted | SiftFlag.dir | SiftFlag.symlink) != 0 { continue }
                if !allowNoise {
                    if flags & SiftFlag.userArea == 0 { continue }
                    if flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) != 0 { continue }
                }
                let kind = store.kind[rawID]
                if let requiredKind, kind != requiredKind { continue }
                // Fast pre-filter by kind: 3 (doc), 7 (code), or 0 (other text files).
                if kind != 3 && kind != 7 && kind != 0 { continue }
                if store.sizeC[rawID] == 0 { continue }

                let id = UInt32(rawID)
                var passesStructure = true
                for range in clauseRanges {
                    var clauseMatched = false
                    for ordinal in range {
                        if matchAtom(ordinal, id) {
                            clauseMatched = true
                            break
                        }
                    }
                    if !clauseMatched {
                        passesStructure = false
                        break
                    }
                }
                if !passesStructure { continue }

                matchedIDs.append(id)
                if matchedIDs.count >= maxCandidates * 3 { break }
            }

            matchedIDs.sort { store.mtime[Int($0)] > store.mtime[Int($1)] }

            var results: [OnDemandCandidate] = []
            results.reserveCapacity(min(matchedIDs.count, maxCandidates))
            for id in matchedIDs {
                if isCancelled() { return [] }
                let size = store.size(id)
                let name = store.name(id)
                let kind = store.kind[Int(id)]
                guard let category = ContentExtractor.fileCategory(name: name, kind: kind, size: size) else { continue }
                if category.isDocument && !allowDocs { continue }
                if !category.isDocument && !allowCode { continue }
                results.append(
                    OnDemandCandidate(
                        id: id,
                        path: store.path(id),
                        mtime: store.mtime[Int(id)],
                        size: size,
                        category: category
                    )
                )
                if results.count >= maxCandidates { break }
            }
            return results
        }
    }

    private func cacheExtractedRecordsAsync(_ records: [(path: String, mtime: UInt32, size: UInt64, body: String)]) {
        indexQueue.async { [weak self] in
            guard let self, let db = self.database else { return }
            db.upsertBatch(records)
            self.lock.lock()
            for item in records {
                self.indexedMeta[item.path] = (item.mtime, item.size)
            }
            self.lock.unlock()
            self.refreshStatsOnMain()
        }
    }

    private struct DecomposedQuery {
        var contentClauses: [[ContentTerm]] = []
        var excludedContentTerms: [ContentTerm] = []
        var structuralClauses: [[Atom]] = []
        var hasExplicitPathFilter = false
        var hasFoldersOnly = false
    }

    private static func decomposeQuery(_ query: Query) -> DecomposedQuery {
        var out = DecomposedQuery()
        for clause in query.clauses {
            if clause.alternatives.contains(where: {
                if case .foldersOnly = $0.matcher, !$0.negated { return true }
                return false
            }) {
                out.hasFoldersOnly = true
                return out
            }

            var terms: [ContentTerm] = []
            var isPureContentClause = !clause.alternatives.isEmpty
            for atom in clause.alternatives {
                if atom.negated {
                    isPureContentClause = false
                    break
                }
                switch atom.matcher {
                case .name(let needle, let cs):
                    let str = String(decoding: needle, as: UTF8.self)
                    if str.isEmpty { isPureContentClause = false } else { terms.append(ContentTerm(text: str, caseSensitive: cs)) }
                case .fileName(let needle):
                    let str = String(decoding: needle, as: UTF8.self)
                    if str.isEmpty { isPureContentClause = false } else { terms.append(ContentTerm(text: str, caseSensitive: false)) }
                default:
                    isPureContentClause = false
                }
                if !isPureContentClause { break }
            }

            if isPureContentClause {
                out.contentClauses.append(terms)
                continue
            }

            for atom in clause.alternatives where !atom.negated {
                switch atom.matcher {
                case .path:
                    out.hasExplicitPathFilter = true
                case .glob(_, let onPath) where onPath:
                    out.hasExplicitPathFilter = true
                case .regex(_, let onPath) where onPath:
                    out.hasExplicitPathFilter = true
                default:
                    break
                }
            }

            out.structuralClauses.append(clause.alternatives)
        }
        return out
    }

    public func scheduleBackgroundSync() {
        lock.lock()
        guard !stopped, enabled, codeAndTextEnabled || documentsEnabled else {
            lock.unlock()
            DispatchQueue.main.async { self.indexing = false }
            return
        }
        syncGeneration += 1
        let generation = syncGeneration
        let sources = currentSources.filter(\.isOnline)
        let allowCode = codeAndTextEnabled
        let allowDocs = documentsEnabled
        let allowNoise = includeNoiseAndPackages
            || defaults.bool(forKey: "indexPackageContents")
            || defaults.bool(forKey: "indexDependencyDirs")
        lock.unlock()

        guard !sources.isEmpty, database != nil else { return }

        indexQueue.async { [weak self] in
            self?.runBackgroundSync(
                generation: generation,
                sources: sources,
                allowCode: allowCode,
                allowDocs: allowDocs,
                allowNoise: allowNoise
            )
        }
    }

    private func shouldAbortSync(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped || !enabled || syncGeneration != generation
    }

    private func waitWhileBusy(_ generation: Int) -> Bool {
        while true {
            lock.lock()
            let abort = stopped || !enabled || syncGeneration != generation
            let busy = isTyping || isPrimaryBusy || isPanelVisible
            lock.unlock()
            if abort { return false }
            if !busy { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func runBackgroundSync(
        generation: Int,
        sources: [SearchSource],
        allowCode: Bool,
        allowDocs: Bool,
        allowNoise: Bool
    ) {
        guard !shouldAbortSync(generation), let db = database else { return }

        var pendingWork: [(path: String, mtime: UInt32, size: UInt64, category: ContentExtractor.FileCategory)] = []

        for source in sources where source.isOnline {
            if shouldAbortSync(generation) { return }
            let store = source.store
            let candidates: [(id: UInt32, mtime: UInt32, size: UInt64, category: ContentExtractor.FileCategory)] = store.read {
                guard store.count > 1 else { return [] }
                var list: [(id: UInt32, mtime: UInt32, size: UInt64, category: ContentExtractor.FileCategory)] = []
                for rawID in 1..<store.count {
                    let flags = store.flags[rawID]
                    if flags & (SiftFlag.deleted | SiftFlag.dir | SiftFlag.symlink) != 0 { continue }
                    if !allowNoise {
                        if flags & SiftFlag.userArea == 0 { continue }
                        if flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) != 0 { continue }
                    }
                    let kind = store.kind[rawID]
                    if kind != 3 && kind != 7 && kind != 0 { continue }
                    let id = UInt32(rawID)
                    let size = store.size(id)
                    guard size > 0 else { continue }
                    let name = store.name(id)
                    guard let category = ContentExtractor.fileCategory(name: name, kind: kind, size: size) else {
                        continue
                    }
                    if category.isDocument && !allowDocs { continue }
                    if !category.isDocument && !allowCode { continue }
                    list.append((id: id, mtime: store.mtime[rawID], size: size, category: category))
                }
                return list
            }

            let sorted = candidates.sorted { $0.mtime > $1.mtime }
            for item in sorted.prefix(25_000) {
                if shouldAbortSync(generation) { return }
                let path = store.read {
                    Int(item.id) < store.count && store.isLive(item.id) ? store.path(item.id) : ""
                }
                guard !path.isEmpty else { continue }
                lock.lock()
                let existing = indexedMeta[path]
                lock.unlock()
                if let existing, existing.mtime == item.mtime && existing.size == item.size {
                    continue
                }
                pendingWork.append((path: path, mtime: item.mtime, size: item.size, category: item.category))
            }
        }

        guard !pendingWork.isEmpty else {
            refreshStatsOnMain()
            return
        }

        DispatchQueue.main.async { self.indexing = true }
        defer {
            DispatchQueue.main.async { self.indexing = false }
            refreshStatsOnMain()
        }

        var batch: [(path: String, mtime: UInt32, size: UInt64, body: String)] = []
        batch.reserveCapacity(24)

        for work in pendingWork {
            guard waitWhileBusy(generation) else { return }
            if let body = ContentExtractor.extractText(at: work.path, category: work.category) {
                batch.append((path: work.path, mtime: work.mtime, size: work.size, body: body))
            }
            lock.lock()
            indexedMeta[work.path] = (work.mtime, work.size)
            lock.unlock()

            if batch.count >= 24 {
                db.upsertBatch(batch)
                batch.removeAll(keepingCapacity: true)
                refreshStatsOnMain()
                Thread.sleep(forTimeInterval: 0.025)
            }
        }

        if !batch.isEmpty {
            db.upsertBatch(batch)
        }
    }

    private func refreshStatsOnMain() {
        guard let db = database else { return }
        let current = db.stats()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.indexedFileCount = current.fileCount
            self.diskBytes = current.diskBytes
        }
    }
}
