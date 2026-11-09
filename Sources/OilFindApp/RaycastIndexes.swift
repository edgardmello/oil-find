import Foundation
import OilFindCore

/// Saved indexes the Raycast bridge searches: the startup volume and each known external drive.
/// Each one is loaded on first use and reloaded when Oil Find replaces its file.
final class RaycastIndexes {
    struct Drive {
        let record: ExternalDriveRecord
        let url: URL
        var isConnected: Bool { FileManager.default.fileExists(atPath: record.path) }
    }

    private struct Loaded {
        let store: IndexStore
        let version: [String]
        var previous: SearchResult?
    }

    private let persistence = ExternalDrivePersistence(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Oil Find/external-drives", isDirectory: true))
    private var loaded: [String: Loaded] = [:]

    var drives: [Drive] {
        let preferences = persistence.load()
        guard preferences.enabled else { return [] }
        return preferences.drives.filter(\.enabled).map { Drive(record: $0, url: persistence.indexURL($0.id)) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func drive(_ id: String) -> Drive? { drives.first { $0.record.id == id.uppercased() } }

    static func version(of path: String) -> [String]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return [FileAttributeKey.systemFileNumber, .modificationDate, .size].map {
            attributes[$0].map { String(describing: $0) } ?? ""
        }
    }

    func store(at path: String) -> IndexStore? {
        guard let version = Self.version(of: path) else { loaded[path] = nil; return nil }
        if let current = loaded[path], current.version == version { return current.store }
        guard let store = IndexStore.load(from: path) else { loaded[path] = nil; return nil }
        loaded[path] = Loaded(store: store, version: version)
        return store
    }

    /// The last result for this index, so a longer query can narrow it instead of scanning again.
    func previous(at path: String) -> SearchResult? { loaded[path]?.previous }
    func remember(_ result: SearchResult, at path: String) { loaded[path]?.previous = result }
}
