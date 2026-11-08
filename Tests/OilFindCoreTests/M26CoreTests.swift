import XCTest
import CoreServices
@testable import OilFindCore

final class M26CoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OilFindM26Core-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func contains(_ name: String, root: URL, store: IndexStore) -> Bool { store.read { store.containsPath(root.appendingPathComponent(name).path) } }
    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testExactFolderScopeAndIndependentRecentSort() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        func makeSource(_ name: String, files: [String]) throws -> SearchSource {
            let directory = root.appendingPathComponent(name)
            for path in files {
                let file = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: file)
            }
            let config = IndexConfig(rootPath: directory.path)
            let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
            store.write {
                for i in 1..<store.count { store.flags[i] |= SiftFlag.userArea }
            }
            return SearchSource(id: name, displayName: name, isOnline: true, store: store)
        }
        let first = try makeSource("First", files: ["Work/Invoice A.pdf", "Work/Invoice A.png", "Other/Work/Invoice B.pdf"])
        let second = try makeSource("Second", files: ["Work/Invoice C.pdf"])
        let query = Query.parse("invoice").restricted(toFolder: root.appendingPathComponent("First/Work").path)
        let filtered = try XCTUnwrap(MultiSearcher.search(query, options: .init(kind: Query.kindValue("doc")), in: [first, second]))
        XCTAssertEqual(filtered.items.count, 1)
        let hit = try XCTUnwrap(filtered.items.first)
        let store = filtered.sources[hit.sourceIndex].store
        XCTAssertEqual(store.read { store.name(hit.entryID) }, "Invoice A.pdf")

        var options = SearchOptions(sort: .name, ascending: false)
        options.sortsRecentResults = true
        let recent = try XCTUnwrap(MultiSearcher.search(.parse(""), options: options, in: [first, second]))
        let names = recent.items.map { hit in
            let store = recent.sources[hit.sourceIndex].store
            return store.read { store.name(hit.entryID) }
        }
        XCTAssertEqual(names, ["Invoice C.pdf", "Invoice B.pdf", "Invoice A.png", "Invoice A.pdf"])
        XCTAssertEqual(Coverage.explain(path: root.appendingPathComponent("First/missing.pdf").path,
                                        config: .init(rootPath: first.store.rootPath), store: first.store), .missing)
    }

    func testHiddenSearchUsesIndexedFlagsAndSeparateCacheEntries() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in [".secret.txt", "visible-secret.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let query = Query.parse("secret")
        let all = try XCTUnwrap(Searcher.search(query, in: store))
        XCTAssertEqual(all.items.count, 2)
        let cache = SearchCache()
        cache.insert(all)
        let hidden = query.showingOnlyHiddenFiles()
        XCTAssertNil(cache.lookup(query: hidden, options: .init(), store: store))
        let filtered = try XCTUnwrap(Searcher.search(hidden, in: store, previous: all))
        XCTAssertEqual(filtered.items.map { id in store.read { store.name(id) } }, [".secret.txt"])
        let hiddenWithNoText = try XCTUnwrap(Searcher.search(Query.parse("").showingOnlyHiddenFiles(), in: store))
        XCTAssertEqual(hiddenWithNoText.items, filtered.items)
    }

    func testScanExtensionRulesAndCoverage() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.log", "b.LOG", "many.parts.Js", "plain", "last.", "a.log.txt", "long.longextension", "bundle.pages"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        for name in ["folder.log", "App.app", "Document.pages"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        let config = IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: [".LOG", "js", "app", "pages", "longextension"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 2).run()), config: config)
        for name in ["a.log", "b.LOG", "many.parts.Js", "long.longextension", "bundle.pages"] { XCTAssertFalse(contains(name, root: root, store: store), name) }
        for name in ["plain", "last.", "a.log.txt", "folder.log", "App.app", "Document.pages"] { XCTAssertTrue(contains(name, root: root, store: store), name) }
        XCTAssertEqual(store.coverage[.fileType].count, 5)
        XCTAssertEqual(Coverage.explain(path: root.appendingPathComponent("a.log").path, config: config, store: store), .fileType("log"))
        XCTAssertEqual(Coverage.explain(path: root.appendingPathComponent("folder.log").path, config: config, store: store), .indexed)
        XCTAssertNotEqual(config.fingerprint, IndexConfig(rootPath: root.path).fingerprint)
        XCTAssertEqual(config.fingerprint, IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: ["js", "log", "app", "pages", "longextension"]).fingerprint)
        let db = root.appendingPathComponent("catalog")
        try store.save(to: db.path)
        let loaded = try XCTUnwrap(IndexStore.load(from: db.path))
        XCTAssertEqual(loaded.scopeFingerprint, config.scopeFingerprint)
        XCTAssertEqual(loaded.coverage[.fileType], store.coverage[.fileType])
        XCTAssertEqual(store.read { store.compacted().scopeFingerprint }, config.scopeFingerprint)
    }
    func testDirectAndSubtreeEventsRespectFileTypes() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("rename.txt"))
        let config = IndexConfig(rootPath: root.path, indexPackageContents: true, excludedExtensions: ["log", "js", "app"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let updater = IndexUpdater(config: config)
        try FileManager.default.moveItem(at: root.appendingPathComponent("rename.txt"), to: root.appendingPathComponent("rename.LOG"))
        try Data().write(to: root.appendingPathComponent("new.Js"))
        try Data().write(to: root.appendingPathComponent("new.txt"))
        _ = updater.apply(["rename.txt", "rename.LOG", "new.Js", "new.txt"].map { FSChange(path: root.appendingPathComponent($0).path) }, to: store)
        XCTAssertFalse(contains("rename.txt", root: root, store: store))
        XCTAssertFalse(contains("rename.LOG", root: root, store: store))
        XCTAssertFalse(contains("new.Js", root: root, store: store))
        XCTAssertTrue(contains("new.txt", root: root, store: store))
        XCTAssertEqual(store.coverage[.fileType].count, 2)
        for name in ["folder.log", "App.app"] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("skip.LOG"))
            try Data().write(to: dir.appendingPathComponent("keep.txt"))
        }
        _ = updater.apply([FSChange(path: root.path, flags: UInt32(kFSEventStreamEventFlagMustScanSubDirs))], to: store)
        for name in ["folder.log", "App.app"] {
            XCTAssertTrue(contains(name, root: root, store: store))
            XCTAssertTrue(contains(name + "/keep.txt", root: root, store: store))
            XCTAssertFalse(contains(name + "/skip.LOG", root: root, store: store))
        }
    }
    func testSharedSettingsRebuildEveryOnlineSource() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OilFindM26-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let managers = try ["one", "two"].map { name -> IndexManager in
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent("keep.txt"))
            try Data().write(to: dir.appendingPathComponent("skip.LOG"))
            let manager = IndexManager(config: IndexConfig(rootPath: dir.path), dbURL: root.appendingPathComponent(name + ".index"), settingsDefaults: defaults)
            manager.start(); return manager
        }
        defer { managers.forEach { $0.stop() } }
        wait { managers.allSatisfy { $0.state == .ready } }
        let oldStores = managers.compactMap(\.store)
        let normalized = SettingsPreferences.setExcludedExtensions(" .LOG, log  .Js , css ", in: defaults)
        XCTAssertEqual(normalized, "log js css")
        wait { managers.enumerated().allSatisfy { $0.element.store !== oldStores[$0.offset] && $0.element.state == .ready && !$0.element.isRescanning } }
        for (index, manager) in managers.enumerated() {
            let store = try XCTUnwrap(manager.store)
            XCTAssertNotEqual(store.configFingerprint, oldStores[index].configFingerprint)
            XCTAssertFalse(store.read { store.containsPath(store.rootPath + "/skip.LOG") })
            XCTAssertEqual(manager.explain(path: store.rootPath + "/skip.LOG"), .fileType("log"))
        }
        let selected = root.appendingPathComponent("one/keep.txt").path
        SettingsPreferences.setExcludedPaths([selected], in: defaults)
        wait { managers[0].store.map { store in store.read { !store.containsPath(selected) } } == true }
        XCTAssertEqual(managers[0].explain(path: selected), .userExcluded(selected))
        XCTAssertTrue(contains("keep.txt", root: root.appendingPathComponent("two"), store: try XCTUnwrap(managers[1].store)))
    }
    func testOfflineFilteringIsReversibleAndNeverOverwritesCatalog() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("skip.log"))
        try Data().write(to: root.appendingPathComponent("keep.txt"))
        let config = IndexConfig(rootPath: root.path)
        let initial = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let db = root.appendingPathComponent("catalog")
        try initial.save(to: db.path)
        let original = try Data(contentsOf: db)
        let suite = "OilFindM26Offline-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        _ = SettingsPreferences.setExcludedExtensions("log", in: defaults)
        let manager = IndexManager(config: config, dbURL: db, settingsDefaults: defaults)
        defer { manager.stop() }
        manager.startOffline()
        wait { manager.state == .ready }
        XCTAssertFalse(contains("skip.log", root: root, store: try XCTUnwrap(manager.store)))
        XCTAssertTrue(contains("keep.txt", root: root, store: try XCTUnwrap(manager.store)))
        XCTAssertFalse(manager.isRescanning)
        _ = SettingsPreferences.setExcludedExtensions("", in: defaults)
        wait { manager.state == .ready && manager.store?.read { manager.store!.containsPath(root.appendingPathComponent("skip.log").path) } == true }
        let path = root.appendingPathComponent("keep.txt").path
        let beforePathExclusion = try XCTUnwrap(manager.store)
        SettingsPreferences.setExcludedPaths([path], in: defaults)
        wait { manager.state == .ready && manager.store !== beforePathExclusion }
        XCTAssertFalse(contains("keep.txt", root: root, store: try XCTUnwrap(manager.store)))
        XCTAssertEqual(manager.explain(path: path), .userExcluded(path))
        let excludedStore = try XCTUnwrap(manager.store)
        SettingsPreferences.setExcludedPaths([], in: defaults)
        wait { manager.state == .ready && manager.store !== excludedStore }
        XCTAssertTrue(contains("keep.txt", root: root, store: try XCTUnwrap(manager.store)))
        manager.stop()
        XCTAssertEqual(try Data(contentsOf: db), original)
    }
}

extension M26CoreTests {
    func testUnicodeExtensionCaseAndNormalizationMatchScanningAndEvents() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let names = ["one.É", "two.e\u{301}", "three.Ö", "four.İ", "five.ẞ", "six.longextension", "seven.J\u{030C}", "eight.ǰ", "nine.SS"]
        for name in names { try Data().write(to: root.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path, excludedExtensions: ["é", "ö", "i\u{307}", "ß", "longextension", "ǰ"])
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        XCTAssertEqual(store.liveCount, 1)
        XCTAssertEqual(store.coverage[.fileType].count, UInt64(names.count))
        for name in ["direct.É", "direct.e\u{301}", "direct.Ö"] {
            try Data().write(to: root.appendingPathComponent(name))
            _ = IndexUpdater(config: config).apply([FSChange(path: root.appendingPathComponent(name).path)], to: store)
        }
        let dir = root.appendingPathComponent("dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data().write(to: dir.appendingPathComponent(name)) }
        _ = IndexUpdater(config: config).apply([FSChange(path: dir.path)], to: store)
        XCTAssertEqual(store.liveCount, 2)
    }
}
