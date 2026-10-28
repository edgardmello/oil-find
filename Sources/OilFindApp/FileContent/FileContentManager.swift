import Foundation
import OilFindCore
import AppKit

public final class FileContentManager {
    public static let shared = FileContentManager()

    private let dbURL: URL
    private let preferences: UserDefaults
    private let budget = AITopicWorkBudget(fraction: 0.25)
    private let syncQueue = DispatchQueue(label: "com.oiloil.find.filecontent.sync", qos: .utility)
    private var isRunning = false
    private var isBusy = false
    private var isUserTyping = false
    private var currentSources: [SearchSource] = []
    private let lock = NSLock()
    private var syncPending = false
    private var syncGeneration = 0

    public var index: FileContentIndex?

    public init(dbURL: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.dbURL = dbURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Oil Find/file-content/index.sqlite")
        try? self.index = FileContentIndex(url: self.dbURL)
    }

    public var isEnabled: Bool {
        preferences.object(forKey: "contentSearchEnabled") as? Bool ?? true
    }

    public func setEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: "contentSearchEnabled")
        if enabled {
            triggerSync()
        }
    }

    public var isSemanticEnabled: Bool {
        preferences.object(forKey: "contentSemanticEnabled") as? Bool ?? true
    }

    public func setSemanticEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: "contentSemanticEnabled")
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true
        if isEnabled {
            triggerSyncLocked()
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        isRunning = false
        syncGeneration += 1
    }

    public func sourcesDidChange(_ sources: [SearchSource]) {
        lock.lock()
        defer { lock.unlock() }
        currentSources = sources
        if isRunning && isEnabled {
            triggerSyncLocked()
        }
    }

    public func backgroundIndexingChanged(_ busy: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isBusy = busy
    }

    public func userActivity(visible: Bool, typing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        isUserTyping = typing
    }

    public func reindex() {
        syncQueue.async { [weak self] in
            guard let self else { return }
            try? self.index?.clear()
            self.triggerSync()
        }
    }

    public func totalIndexedCount() -> Int {
        (try? index?.count()) ?? 0
    }

    private func triggerSync() {
        lock.lock()
        defer { lock.unlock() }
        triggerSyncLocked()
    }

    private func triggerSyncLocked() {
        guard !syncPending else { return }
        syncPending = true
        syncGeneration += 1
        let gen = syncGeneration

        syncQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.performSync(generation: gen)
        }
    }

    private func performSync(generation: Int) {
        lock.lock()
        syncPending = false
        let sources = currentSources
        let enabled = isEnabled && isRunning
        lock.unlock()

        guard enabled, !sources.isEmpty else { return }

        for source in sources {
            if generation != self.syncGeneration { return }
            syncSource(source, generation: generation)
        }
    }

    private func syncSource(_ source: SearchSource, generation: Int) {
        let store = source.store
        var candidates: [(id: UInt32, mtime: Int64, size: Int64, kind: Int)] = []

        store.read {
            candidates.reserveCapacity(min(store.count, 50_000))
            for i in 1..<store.count {
                let id = UInt32(i)
                let flags = store.flags[i]
                guard flags & SiftFlag.deleted == 0,
                      flags & SiftFlag.dir == 0,
                      flags & SiftFlag.userArea != 0,
                      flags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.hidden) == 0 else { continue }
                let kind = Int(store.kind[i])
                // kind 3 = document, kind 7 = code
                guard kind == 3 || kind == 7 else { continue }

                let size = Int64(store.size(id))
                guard size > 0 && size <= Int64(FileTextExtractor.maxPDFFileSize) else { continue }
                let mtime = Int64(store.mtime[i])
                candidates.append((id: id, mtime: mtime, size: size, kind: kind))
            }
        }

        for item in candidates {
            if generation != self.syncGeneration { return }

            // Yield to main scanning or typing
            while isBusy || isUserTyping {
                Thread.sleep(forTimeInterval: 0.1)
                if generation != self.syncGeneration { return }
            }

            let path: String = store.read {
                store.path(item.id)
            }
            guard !path.isEmpty else { continue }

            if let existing = try? index?.fileInfo(sourceID: source.id, path: path) {
                if existing.mtime == item.mtime && existing.size == item.size {
                    continue
                }
            }

            let fileURL = URL(fileURLWithPath: path)
            let ext = fileURL.pathExtension

            guard let text = FileTextExtractor.extractText(from: fileURL, ext: ext, isCancelled: { [weak self] in
                guard let self else { return true }
                return generation != self.syncGeneration || self.isBusy
            }) else { continue }

            let semanticActive = isSemanticEnabled
            var vectorData: (dims: Int, scale: Float, bytes: [Int8])? = nil
            if semanticActive {
                if let vec = FileSemanticEngine.shared.vector(for: text, isCancelled: { [weak self] in
                    guard let self else { return true }
                    return generation != self.syncGeneration || self.isBusy
                }) {
                    vectorData = FileSemanticEngine.shared.quantize(vec)
                }
            }

            try? index?.upsertFile(
                sourceID: source.id,
                path: path,
                mtime: item.mtime,
                size: item.size,
                kind: item.kind,
                text: text,
                vector: vectorData
            )

            budget.checkpoint { [weak self] in
                guard let self else { return true }
                return generation != self.syncGeneration
            }
        }
    }
}
