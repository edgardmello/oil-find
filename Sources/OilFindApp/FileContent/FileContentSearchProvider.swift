import Foundation
import OilFindCore
import COilFind

public final class FileContentSearchProvider: SupplementarySearchProvider {
    private let manager: FileContentManager

    public init(manager: FileContentManager = .shared) {
        self.manager = manager
    }

    public var isEnabled: Bool {
        manager.isEnabled
    }

    public func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        guard isEnabled, !query.isEmpty, !sources.isEmpty else { return { [] } }

        var terms: [String] = []
        var filterAtoms: [Atom] = []

        for clause in query.clauses {
            for alt in clause.alternatives {
                if !alt.negated, case .name(let needle, _) = alt.matcher {
                    let term = String(decoding: needle, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !term.isEmpty { terms.append(term) }
                } else {
                    filterAtoms.append(alt)
                }
            }
        }

        guard !terms.isEmpty else { return { [] } }
        let rawQuery = query.raw
        let sourcesMap = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })

        return { [weak self] in
            guard let self, self.isEnabled, !isCancelled() else { return [] }
            guard let index = self.manager.index else { return [] }

            // 1. Literal Search
            var rawHits = (try? index.searchLiteral(terms: terms, limit: 100, isCancelled: isCancelled)) ?? []
            if isCancelled() { return [] }

            // 2. Semantic Search (as fallback or addition when query has multiple terms or few literal hits)
            if self.manager.isSemanticEnabled && (terms.count >= 2 || rawHits.count < 10) {
                if let queryVector = FileSemanticEngine.shared.vector(for: rawQuery, isCancelled: isCancelled) {
                    if let semanticMatches = try? index.searchSemantic(queryVector: queryVector, limit: 25, minScore: 0.65, isCancelled: isCancelled) {
                        let existingPaths = Set(rawHits.map(\.path))
                        for match in semanticMatches where !existingPaths.contains(match.path) {
                            rawHits.append((sourceID: match.sourceID, path: match.path, excerpt: match.excerpt, highlights: []))
                        }
                    }
                }
            }

            if isCancelled() || rawHits.isEmpty { return [] }

            // 3. Map paths to entryIDs and evaluate remaining filter atoms
            var hits: [SupplementaryHit] = []
            hits.reserveCapacity(rawHits.count)

            for hit in rawHits {
                if isCancelled() { return [] }
                guard let source = sourcesMap[hit.sourceID] else { continue }

                let matchedHit: SupplementaryHit? = source.store.read {
                    guard let entryID = Self.resolve(path: hit.path, in: source.store),
                          source.store.isLive(entryID) else { return nil }

                    if !filterAtoms.isEmpty {
                        let passes = Searcher.withEntryPredicates(filterAtoms, options: options, in: source.store, isCancelled: isCancelled) { predicate in
                            for i in 0..<filterAtoms.count {
                                if !predicate(i, entryID) { return false }
                            }
                            return true
                        }
                        guard passes else { return nil }
                    }

                    let version = source.store.version
                    let excerpt = hit.excerpt
                    let hls = hit.highlights
                    return SupplementaryHit(sourceID: source.id, entryID: entryID, thumbnail: false, sourceVersion: version) {
                        (text: excerpt, highlights: hls)
                    }
                }

                if let matchedHit {
                    hits.append(matchedHit)
                }
            }

            return hits
        }
    }

    public func sourcesDidChange(_ sources: [SearchSource]) {
        manager.sourcesDidChange(sources)
    }

    public func userActivity(visible: Bool, typing: Bool) {
        manager.userActivity(visible: visible, typing: typing)
    }

    public func backgroundIndexingChanged(_ busy: Bool) {
        manager.backgroundIndexingChanged(busy)
    }

    private static func resolve(path: String, in store: IndexStore) -> UInt32? {
        if store.hashReady {
            return store.resolve(path: path)
        }
        let root = store.rootPath == "/" ? "" : store.rootPath
        guard path == store.rootPath || path.hasPrefix(root + "/") else { return nil }
        if path == store.rootPath { return store.isLive(0) ? 0 : nil }
        var current: UInt32 = 0
        for component in path.dropFirst(root.count).split(separator: "/") {
            let bytes = Array(component.utf8)
            var found: UInt32?
            bytes.withUnsafeBufferPointer { name in
                for i in (Int(current) + 1)..<store.count where store.parent[i] == current && store.isLive(UInt32(i)) {
                    let candidate = store.nameBytes(UInt32(i))
                    if sift_name_equal(candidate.baseAddress, candidate.count, name.baseAddress, name.count, store.caseSensitiveNames ? 1 : 0) != 0 {
                        found = UInt32(i)
                        break
                    }
                }
            }
            guard let id = found else { return nil }
            current = id
        }
        return current
    }
}
