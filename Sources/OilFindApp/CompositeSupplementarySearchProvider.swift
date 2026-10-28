import Foundation
import OilFindCore

/// Composes multiple supplementary search providers into a single provider.
/// Work from each provider is executed and collected concurrently.
final class CompositeSupplementarySearchProvider: SupplementarySearchProvider {
    private let providers: [SupplementarySearchProvider]

    init(_ providers: [SupplementarySearchProvider?]) {
        self.providers = providers.compactMap { $0 }
    }

    var isEnabled: Bool {
        providers.contains { $0.isEnabled }
    }

    func prepareSearch(_ query: Query, options: SearchOptions, sources: [SearchSource], isCancelled: @escaping () -> Bool) -> () -> [SupplementaryHit] {
        let active = providers.filter(\.isEnabled)
        guard !active.isEmpty else { return { [] } }
        let runners = active.map { $0.prepareSearch(query, options: options, sources: sources, isCancelled: isCancelled) }
        return {
            var hits: [SupplementaryHit] = []
            for run in runners {
                if isCancelled() { return [] }
                hits.append(contentsOf: run())
            }
            return hits
        }
    }

    func sourcesDidChange(_ sources: [SearchSource]) {
        providers.forEach { $0.sourcesDidChange(sources) }
    }

    func userActivity(visible: Bool, typing: Bool) {
        providers.forEach { $0.userActivity(visible: visible, typing: typing) }
    }

    func backgroundIndexingChanged(_ busy: Bool) {
        providers.forEach { $0.backgroundIndexingChanged(busy) }
    }
}
