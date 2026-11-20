import AppKit
import SwiftUI
import Combine
import OilFindCore

public struct ApplicationMenuItem {
    public let title: String
    public let isVisible: Bool
    public let action: () -> Void

    public init(title: String, isVisible: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.isVisible = isVisible; self.action = action
    }
}

/// Read-only identity and catalog location for a known external drive.
public struct ExternalDriveInfo: Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let enabled: Bool
    public let isConnected: Bool
    public let catalogURL: URL

    public init(id: String, name: String, path: String, enabled: Bool, isConnected: Bool, catalogURL: URL) {
        self.id = id; self.name = name; self.path = path; self.enabled = enabled
        self.isConnected = isConnected; self.catalogURL = catalogURL
    }
}

/// Snapshots and notifications are delivered on the main thread.
public protocol ExternalDriveCatalogReading: AnyObject {
    var knownDrives: [ExternalDriveInfo] { get }
    var changes: AnyPublisher<Void, Never> { get }
}

/// Optional application integration, outside the search and indexing hot paths.
public protocol ApplicationExtension: AnyObject {
    /// An extension may finish a dedicated invocation before the app is initialized.
    func handleLaunch(arguments: [String]) -> Int32?
    #if DEBUG
    func prepareArguments(_ arguments: inout [String]) throws
    #endif
    func attachExternalDrives(_ catalog: ExternalDriveCatalogReading)
    func start(showSettings: @escaping () -> Void)
    func searchSources() -> [SearchSource]
    var supplementarySearchProvider: SupplementarySearchProvider? { get }
    var onSearchSourcesChange: (() -> Void)? { get set }
    var settingsMenuItem: ApplicationMenuItem? { get }
    var onSettingsMenuItemChange: (() -> Void)? { get set }
    func stop()
    func handle(_ url: URL)
    func settingsSection(window: @escaping () -> NSWindow?) -> AnyView
}

public extension ApplicationExtension {
    func handleLaunch(arguments: [String]) -> Int32? { nil }
    func attachExternalDrives(_ catalog: ExternalDriveCatalogReading) { }
    var settingsMenuItem: ApplicationMenuItem? { nil }
    var onSettingsMenuItemChange: (() -> Void)? { get { nil } set { } }
    var supplementarySearchProvider: SupplementarySearchProvider? { nil }
    func searchSources() -> [SearchSource] { [] }
    var onSearchSourcesChange: (() -> Void)? { get { nil } set { } }
}

#if DEBUG
public extension ApplicationExtension {
    func prepareArguments(_ arguments: inout [String]) throws { }
}
#endif
