import Foundation

enum ResultFileTransfer {
    static func run(paths: [String], to folder: URL, move: Bool) -> Int {
        let files = FileManager.default
        let destination = folder.standardizedFileURL.resolvingSymlinksInPath()
        let sources = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let selectedPaths = Set(sources.map(\.path))
        // Move selected folders as a unit, including descendants that are also selected.
        var groups = Dictionary(grouping: sources) { source in
            guard move else { return source.path }
            var root = source
            var parent = source.deletingLastPathComponent()
            while !parent.path.isEmpty && parent.path != "/" {
                if selectedPaths.contains(parent.path),
                   let values = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                   values.isDirectory == true, values.isSymbolicLink != true {
                    root = parent
                }
                parent.deleteLastPathComponent()
            }
            return root.path
        }
        var completed = 0
        for source in sources {
            guard let selection = groups.removeValue(forKey: source.path) else { continue }
            let target = destination.appendingPathComponent(source.lastPathComponent)
            let resolvedSource = source.resolvingSymlinksInPath()
            guard target.path != source.path,
                  !destination.pathComponents.starts(with: resolvedSource.pathComponents) else { continue }
            do {
                if move { try files.moveItem(at: source, to: target) }
                else { try files.copyItem(at: source, to: target) }
                completed += selection.count
            } catch {
                // Existing destinations are left intact. Continue with the remaining selection.
            }
        }
        return completed
    }
}
