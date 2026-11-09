import Foundation
import OilFindCore

struct SearchLink {
    let query: String
    let kind: Int
    let folder: String?
    let volume: String?
    /// A filter from the Oil Find filter library, matched by preset ID or name.
    let filterID: String?

    init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "oilfind", parts.host?.lowercased() == "search",
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let items = parts.queryItems ?? []
        let parameters = ["q", "filter", "folder", "volume", "library"]
        guard parameters.allSatisfy({ key in items.filter { $0.name == key }.count <= 1 }) else { return nil }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let query = value("q"), !query.contains("\0") else { return nil }
        self.query = query
        let filter = value("filter")?.lowercased() ?? "all"
        let category = filter == "documents" ? "document" : filter
        guard let kind = FilterBar.names.firstIndex(of: category) ?? Query.kindValue(category).map(Int.init) else { return nil }
        self.kind = kind
        if let path = value("folder") {
            guard let normalized = ExcludedFolders.normalized(NSString(string: path).expandingTildeInPath),
                  !normalized.contains("\0") else { return nil }
            folder = normalized
        } else { folder = nil }
        volume = value("volume")
        filterID = value("library").flatMap { $0.isEmpty ? nil : $0 }
    }
}
