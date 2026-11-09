import AppKit
import SwiftUI
import Combine
import OilFindCore
import OilFindApp

public final class OilFindProExtension: ApplicationExtension {
    public let contentManager: ContentSearchManager
    public var onSearchSourcesChange: (() -> Void)?
    public var onSettingsMenuItemChange: (() -> Void)?

    private var chinese = false
    private var showSettingsAction: (() -> Void)?
    private var driveCatalog: ExternalDriveCatalogReading?
    private var driveSubscription: AnyCancellable?
    private var offlineManagers: [String: (info: ExternalDriveInfo, manager: IndexManager)] = [:]
    private let offlineLock = NSLock()

    public init(contentManager: ContentSearchManager = ContentSearchManager()) {
        self.contentManager = contentManager
        self.contentManager.onStateChange = { [weak self] in
            self?.onSearchSourcesChange?()
        }
    }

    public var supplementarySearchProvider: SupplementarySearchProvider? {
        contentManager
    }

    public var settingsMenuItem: ApplicationMenuItem? {
        nil
    }

    public func attachExternalDrives(_ catalog: ExternalDriveCatalogReading) {
        self.driveCatalog = catalog
        driveSubscription = catalog.changes.sink { [weak self] in
            self?.syncOfflineDrives()
        }
        syncOfflineDrives()
    }

    private func syncOfflineDrives() {
        guard let catalog = driveCatalog else { return }
        let desired = catalog.knownDrives.filter {
            $0.enabled && !$0.isConnected && FileManager.default.fileExists(atPath: $0.catalogURL.path)
        }
        let desiredIDs = Set(desired.map(\.id))
        var changed = false

        offlineLock.lock()
        for (id, entry) in offlineManagers where !desiredIDs.contains(id) {
            entry.manager.stop()
            offlineManagers.removeValue(forKey: id)
            changed = true
        }

        for drive in desired {
            if let existing = offlineManagers[drive.id] {
                if existing.info != drive {
                    offlineManagers[drive.id] = (drive, existing.manager)
                    changed = true
                }
            } else {
                let standard = IndexConfig.standard()
                let config = IndexConfig(rootPath: drive.path, excludedNames: standard.excludedNames)
                let manager = IndexManager(config: config, dbURL: drive.catalogURL, volumeUUID: drive.id)
                manager.onIndexChange = { [weak self] in
                    DispatchQueue.main.async { self?.onSearchSourcesChange?() }
                }
                manager.onStateChange = { [weak self] state in
                    if state == .ready || state == .idle {
                        DispatchQueue.main.async { self?.onSearchSourcesChange?() }
                    }
                }
                offlineManagers[drive.id] = (drive, manager)
                manager.startOffline()
                changed = true
            }
        }
        offlineLock.unlock()

        if changed {
            onSearchSourcesChange?()
        }
    }

    public func start(chinese: Bool, showSettings: @escaping () -> Void) {
        self.chinese = chinese
        self.showSettingsAction = showSettings
        contentManager.setLanguage(chinese: chinese)
        syncOfflineDrives()
    }

    public func searchSources() -> [SearchSource] {
        offlineLock.lock()
        defer { offlineLock.unlock() }
        var result: [SearchSource] = []
        for (_, entry) in offlineManagers.sorted(by: { $0.key < $1.key }) {
            guard let store = entry.manager.store else { continue }
            result.append(
                SearchSource(
                    id: entry.info.id,
                    displayName: entry.info.name,
                    isOnline: false,
                    store: store,
                    explainPath: entry.manager.explain(path:)
                )
            )
        }
        return result
    }

    public func stop() {
        driveSubscription?.cancel()
        driveSubscription = nil
        offlineLock.lock()
        let managers = offlineManagers.values.map(\.manager)
        offlineManagers.removeAll()
        offlineLock.unlock()
        for manager in managers {
            manager.stop()
        }
        contentManager.stop()
    }

    public func languageDidChange(chinese: Bool) {
        self.chinese = chinese
        contentManager.setLanguage(chinese: chinese)
        onSettingsMenuItemChange?()
    }

    public func handle(_ url: URL) {
        showSettingsAction?()
    }

    public func settingsSection(window: @escaping () -> NSWindow?) -> AnyView {
        AnyView(ContentSearchSettingsSection(manager: contentManager, chinese: chinese))
    }
}

private struct ContentSearchSettingsSection: View {
    @ObservedObject var manager: ContentSearchManager
    let chinese: Bool

    private var isPortuguese: Bool {
        guard !chinese else { return false }
        return (Locale.preferredLanguages.first?.lowercased() ?? "").hasPrefix("pt")
    }

    private func tr(zh: String, pt: String, en: String) -> String {
        if chinese { return zh }
        if isPortuguese { return pt }
        return en
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(
                    tr(
                        zh: "搜索文件内容（递归）",
                        pt: "Buscar recursivamente dentro dos arquivos",
                        en: "Search Inside File Contents (Recursive)"
                    ),
                    isOn: Binding(get: { manager.enabled }, set: manager.setEnabled)
                )
                Text(
                    tr(
                        zh: "在文件名搜索的同时，实时检索代码、文本、PDF、文档与图片里的内容，全部在本机完成。",
                        pt: "Pesquisa dentro de códigos, textos, Markdown, PDFs, documentos Office e imagens localmente em paralelo à busca por nome.",
                        en: "Searches inside code, plain text, Markdown, PDFs, Office documents and images locally alongside filename search."
                    )
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(
                tr(
                    zh: "代码、纯文本与配置文件 (.swift, .py, .js, .md, .txt, .json…)",
                    pt: "Código, texto puro e configurações (.swift, .py, .js, .md, .txt, .json…)",
                    en: "Code, plain text and config files (.swift, .py, .js, .md, .txt, .json…)"
                ),
                isOn: Binding(get: { manager.codeAndTextEnabled }, set: manager.setCodeAndTextEnabled)
            )
            .disabled(!manager.enabled)

            Toggle(
                tr(
                    zh: "PDF、Office、富文本文档与图片 (.pdf, .docx, .rtf, .jpg, .png…)",
                    pt: "Documentos PDF, Office, RTF e imagens (.pdf, .docx, .rtf, .jpg, .png…)",
                    en: "PDF, Office and Rich Text documents, and images (.pdf, .docx, .rtf, .jpg, .png…)"
                ),
                isOn: Binding(get: { manager.documentsEnabled }, set: manager.setDocumentsEnabled)
            )
            .disabled(!manager.enabled)

            Toggle(
                tr(
                    zh: "包含隐藏目录、包内部与依赖目录中的文件",
                    pt: "Incluir arquivos em pastas ocultas, pacotes e dependências",
                    en: "Include files inside hidden folders, packages and dependencies"
                ),
                isOn: Binding(get: { manager.includeNoiseAndPackages }, set: manager.setIncludeNoiseAndPackages)
            )
            .disabled(!manager.enabled)

            HStack {
                if manager.indexing {
                    Text(
                        tr(
                            zh: "正在后台建立内容索引… 已索引 \(manager.indexedFileCount) 个文件",
                            pt: "Indexando conteúdo em segundo plano… \(manager.indexedFileCount) arquivos",
                            en: "Indexing file contents in background… \(manager.indexedFileCount) files"
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    let sizeText = ByteCountFormatter.string(fromByteCount: manager.diskBytes, countStyle: .file)
                    Text(
                        tr(
                            zh: "已缓存 \(manager.indexedFileCount) 个文件 · 占用 \(sizeText)",
                            pt: "\(manager.indexedFileCount) arquivos indexados · \(sizeText)",
                            en: "\(manager.indexedFileCount) files indexed · \(sizeText)"
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(
                    tr(zh: "重建内容索引", pt: "Reindexar Conteúdo", en: "Rebuild Content Index"),
                    action: manager.rebuildIndex
                )
                .disabled(!manager.enabled || manager.indexing)
            }
        } header: {
            Text(tr(zh: "文件内容搜索", pt: "Busca no Conteúdo dos Arquivos", en: "File Content Search"))
        }
    }
}
