import Foundation

struct StashedFile: Codable {
    let id: UUID
    let path: String
    let bookmark: Data?

    init(url: URL) {
        id = UUID()
        path = url.path
        bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func reachableURL() -> URL? {
        let url: URL
        if let bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            url = resolved
        } else {
            url = URL(fileURLWithPath: path)
        }
        return (try? url.checkResourceIsReachable()) == true ? url : nil
    }
}

final class FileStash {
    private static let key = "stashedFiles"
    private let preferences: UserDefaults
    private let queue = DispatchQueue(label: "com.oiloil.find.fileStash", qos: .utility)
    private(set) var files: [StashedFile]
    var onChange: (() -> Void)?

    init(preferences: UserDefaults) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([StashedFile].self, from: data) {
            files = saved
        } else { files = [] }
    }

    // Bookmark and file metadata access can block on a slow volume.
    func add(_ urls: [URL], completion: @escaping (Int) -> Void) {
        let urls = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        queue.async { [weak self] in
            var seen = Set<String>()
            let candidates = urls.compactMap { url -> StashedFile? in
                guard seen.insert(url.path).inserted, (try? url.checkResourceIsReachable()) == true else { return nil }
                return StashedFile(url: url)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var paths = Set(self.files.map(\.path))
                let added = candidates.filter { paths.insert($0.path).inserted }
                if !added.isEmpty { self.files.append(contentsOf: added); self.persist() }
                completion(added.count)
            }
        }
    }

    func remove(_ ids: Set<UUID>) {
        let remaining = files.filter { !ids.contains($0.id) }
        guard remaining.count != files.count else { return }
        files = remaining
        persist()
    }

    func resolve(_ files: [StashedFile], completion: @escaping ([UUID: URL]) -> Void) {
        queue.async {
            let urls = Dictionary(uniqueKeysWithValues: files.compactMap { item in
                item.reachableURL().map { (item.id, $0) }
            })
            DispatchQueue.main.async { completion(urls) }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(files) { preferences.set(data, forKey: Self.key) }
        onChange?()
    }
}
