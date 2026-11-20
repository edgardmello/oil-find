import Foundation
import XCTest
@testable import OilFindApp

final class LegacyCleanupTests: XCTestCase {
    func testLegacyAuthorizationCleanupRemovesOldLocalRecords() throws {
        let name = "OilFindLegacyCleanupTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        addTeardownBlock { store.removePersistentDomain(forName: name) }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("OilFind-license-\(UUID().uuidString).json")
        try Data("legacy".utf8).write(to: path)
        store.set(1.0, forKey: "trialStartedAt")
        store.set(2.0, forKey: "trialLastSeenAt")
        store.set("https://example.com", forKey: "licenseAPI")
        store.set("old-device", forKey: "deviceFallbackID")
        store.set(true, forKey: "pinyinEnabled")
        var deletedKeychain = false

        LegacyAuthorizationCleanup.run(licenseFile: path, defaults: store) { deletedKeychain = true }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNil(store.object(forKey: "trialStartedAt"))
        XCTAssertNil(store.object(forKey: "trialLastSeenAt"))
        XCTAssertNil(store.object(forKey: "licenseAPI"))
        XCTAssertNil(store.object(forKey: "deviceFallbackID"))
        XCTAssertEqual(store.object(forKey: "pinyinEnabled") as? Bool, true)
        XCTAssertTrue(deletedKeychain)
    }
}
