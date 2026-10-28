import XCTest
import Combine
@testable import OilFindCore
import OilFindApp
@testable import OilFindPro

final class OilFindProTests: XCTestCase {
    func testRecursiveContentSearchAcrossNestedDirectories() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oilfind-pro-test-" + UUID().uuidString)
        let nestedDir = tempRoot.appendingPathComponent("project/src/deep/module")
        let docsDir = tempRoot.appendingPathComponent("project/docs")
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let codeFile = nestedDir.appendingPathComponent("Engine.swift")
        try """
        import Foundation
        // Recursive secret token inside nested Swift file
        public func computeQuantumFluxValue() -> Int {
            return 42
        }
        """.write(to: codeFile, atomically: true, encoding: .utf8)

        let noteFile = docsDir.appendingPathComponent("notes.md")
        try """
        # Architecture Notes
        This document explains the hyperdrive calibration procedure for personal MacBooks.
        """.write(to: noteFile, atomically: true, encoding: .utf8)

        let config = IndexConfig(rootPath: tempRoot.path)
        let scan = try XCTUnwrap(Scanner(config: config).run())
        let store = IndexStore(scan: scan, config: config)
        store.write {
            for i in 1..<store.count {
                store.flags[i] |= SiftFlag.userArea
            }
            store.buildHash()
        }

        let dbURL = tempRoot.appendingPathComponent("content.sqlite")
        let suiteName = "com.oiloil.find.pro.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ContentSearchManager(defaults: defaults, databaseURL: dbURL)
        defer { manager.stop() }

        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)

        // 1. Search for content inside nested Swift file where filename does NOT match query.
        let query1 = Query.parse("computeQuantumFluxValue", store: store)
        let work1 = manager.prepareSearch(query1, options: SearchOptions(), sources: [source], isCancelled: { false })
        let hits1 = work1()
        XCTAssertEqual(hits1.count, 1)
        let matchedID1 = try XCTUnwrap(hits1.first?.entryID)
        XCTAssertEqual(store.read { store.name(matchedID1) }, "Engine.swift")
        XCTAssertTrue(hits1[0].detail.contains("computeQuantumFluxValue"))
        XCTAssertFalse(hits1[0].highlights.isEmpty)

        // 2. Search with extension filter + content term.
        let query2 = Query.parse("ext:md hyperdrive calibration", store: store)
        let work2 = manager.prepareSearch(query2, options: SearchOptions(), sources: [source], isCancelled: { false })
        let hits2 = work2()
        XCTAssertEqual(hits2.count, 1)
        let matchedID2 = try XCTUnwrap(hits2.first?.entryID)
        XCTAssertEqual(store.read { store.name(matchedID2) }, "notes.md")
        XCTAssertTrue(hits2[0].detail.contains("hyperdrive"))

        // 3. Extension mismatch should filter out the file.
        let query3 = Query.parse("ext:py computeQuantumFluxValue", store: store)
        let work3 = manager.prepareSearch(query3, options: SearchOptions(), sources: [source], isCancelled: { false })
        XCTAssertTrue(work3().isEmpty)
    }

    func testExtensionProvidesSupplementaryProvider() {
        let ext = OilFindProExtension()
        defer { ext.stop() }
        XCTAssertNotNil(ext.supplementarySearchProvider)
        XCTAssertTrue(ext.supplementarySearchProvider?.isEnabled == true)
    }

    func testUnpluggedDrivesStaySearchableAndIndicateDrive() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oilfind-unplugged-test-" + UUID().uuidString)
        let volumeDir = tempRoot.appendingPathComponent("Volumes/T7 Shield")
        let expensesDir = volumeDir.appendingPathComponent("Expenses")
        try FileManager.default.createDirectory(at: expensesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let invoiceFile = expensesDir.appendingPathComponent("invoice-september.pdf")
        try Data("invoice data".utf8).write(to: invoiceFile)

        let standard = IndexConfig.standard()
        let config = IndexConfig(rootPath: volumeDir.path, excludedNames: standard.excludedNames)
        let scan = try XCTUnwrap(Scanner(config: config).run())
        let store = IndexStore(scan: scan, config: config)
        let uuid = UUID().uuidString.uppercased()
        store.configFingerprint = config.fingerprint(volumeUUID: uuid)
        let catalogURL = tempRoot.appendingPathComponent(uuid + ".oilfind")
        try store.save(to: catalogURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))

        let driveInfo = ExternalDriveInfo(
            id: uuid,
            name: "T7 Shield",
            path: volumeDir.path,
            enabled: true,
            isConnected: false,
            catalogURL: catalogURL
        )

        final class MockCatalog: ExternalDriveCatalogReading {
            var knownDrives: [ExternalDriveInfo]
            private let subject = PassthroughSubject<Void, Never>()
            var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
            init(drives: [ExternalDriveInfo]) { self.knownDrives = drives }
            func sendUpdate(drives: [ExternalDriveInfo]) {
                self.knownDrives = drives
                subject.send()
            }
        }

        let mockCatalog = MockCatalog(drives: [driveInfo])
        let ext = OilFindProExtension()
        defer { ext.stop() }

        let initialExpectation = self.expectation(description: "Offline search sources change")
        initialExpectation.assertForOverFulfill = false
        ext.onSearchSourcesChange = {
            if !ext.searchSources().isEmpty {
                initialExpectation.fulfill()
            }
        }
        ext.attachExternalDrives(mockCatalog)

        wait(for: [initialExpectation], timeout: 5.0)

        let offlineSources = ext.searchSources()
        XCTAssertEqual(offlineSources.count, 1)
        let source = try XCTUnwrap(offlineSources.first)
        XCTAssertEqual(source.id, uuid)
        XCTAssertEqual(source.displayName, "T7 Shield")
        XCTAssertFalse(source.isOnline)

        let query = Query.parse("invoice-september", store: source.store)
        let found = try XCTUnwrap(MultiSearcher.search(query, in: [source]))
        XCTAssertEqual(found.items.count, 1)
        let hit = found.items[0]
        let matchedSource = found.sources[hit.sourceIndex]
        XCTAssertEqual(matchedSource.id, uuid)
        XCTAssertEqual(matchedSource.displayName, "T7 Shield")
        XCTAssertFalse(matchedSource.isOnline)

        let storeRef = matchedSource.store
        let hitName = storeRef.read { storeRef.name(hit.entryID) }
        let hitParent = storeRef.read { storeRef.parentPath(hit.entryID) }
        XCTAssertEqual(hitName, "invoice-september.pdf")
        XCTAssertEqual(hitParent, expensesDir.path)

        // Verify the formatted path shows the drive location and disconnected status
        let displayedPath = Presentation.abbreviate(path: hitParent, home: NSHomeDirectory()) + " · Not connected"
        XCTAssertEqual(displayedPath, "\(expensesDir.path) · Not connected")

        // Reconnecting the drive removes the offline search source
        let connectedDriveInfo = ExternalDriveInfo(
            id: uuid,
            name: "T7 Shield",
            path: volumeDir.path,
            enabled: true,
            isConnected: true,
            catalogURL: catalogURL
        )
        let reconnectedExpectation = self.expectation(description: "Offline source removed on reconnect")
        reconnectedExpectation.assertForOverFulfill = false
        ext.onSearchSourcesChange = {
            if ext.searchSources().isEmpty {
                reconnectedExpectation.fulfill()
            }
        }
        mockCatalog.sendUpdate(drives: [connectedDriveInfo])
        wait(for: [reconnectedExpectation], timeout: 5.0)
        XCTAssertTrue(ext.searchSources().isEmpty)
    }

    func testRealIndexFindsSupracitadoInPDFs() throws {
        let indexPath = NSHomeDirectory() + "/Library/Application Support/Oil Find/index.oilfind"
        guard FileManager.default.fileExists(atPath: indexPath),
              let store = IndexStore.load(from: indexPath) else {
            return
        }
        store.write { store.buildHash() }
        let manager = ContentSearchManager()
        defer { manager.stop() }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        let query = Query.parse("supracitado", store: store)
        let started = CFAbsoluteTimeGetCurrent()
        let hits = manager.prepareSearch(query, options: SearchOptions(), sources: [source], isCancelled: { false })()
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let matchedPaths = hits.map { hit in store.read { store.path(hit.entryID) } }
        print("Matched paths for 'supracitado' (\(hits.count) hits in \(String(format: "%.1f", elapsedMs)) ms):", matchedPaths)
        XCTAssertFalse(hits.isEmpty, "Expected PDF and Markdown matches for 'supracitado'")
        XCTAssertTrue(matchedPaths.contains(where: { $0.hasSuffix(".pdf") }), "Expected at least one PDF match for 'supracitado'")
    }

    func testTagSearchParsesAndExecutes() throws {
        let query = Query.parse("tag:iptu", store: nil)
        guard case .tag(let tagVal)? = query.clauses.first?.alternatives.first?.matcher else {
            XCTFail("Expected tag matcher")
            return
        }
        XCTAssertEqual(tagVal, "iptu")
    }

    func testRealIndexFindsTaggedFiles() throws {
        let indexPath = NSHomeDirectory() + "/Library/Application Support/Oil Find/index.oilfind"
        guard FileManager.default.fileExists(atPath: indexPath),
              let store = IndexStore.load(from: indexPath) else {
            return
        }
        store.write { store.buildHash() }
        let manager = ContentSearchManager()
        defer { manager.stop() }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        let query = Query.parse("tag:iptu", store: store)
        let hits = manager.prepareSearch(query, options: SearchOptions(), sources: [source], isCancelled: { false })()
        XCTAssertFalse(hits.isEmpty, "Expected tag hits for 'tag:iptu'")
        if let first = hits.first {
            XCTAssertTrue(first.detail.contains("🏷️ iptu"))
        }
    }
}
