import AppKit
import SwiftUI
import ServiceManagement
import Carbon
import OilFindCore

final class SettingsModel: ObservableObject {
    @Published private(set) var language: AppLanguage
    @Published var launchAtLogin: Bool
    let topics: AITopicManager
    private var languageObserver: NSObjectProtocol?
    private let languageDefaults: UserDefaults
    private var coverageExplanation: CoverageExplanation?
    private let snapshot: Bool
    fileprivate let preferences: UserDefaults
    @Published var loginError: String?
    @Published var previewWithSpace: Bool
    @Published var excludedExtensionsText: String
    @Published var pinyinEnabled: Bool
    @Published var excludedPaths: [String]
    @Published private(set) var fileScripts: [FileScript]
    @Published private(set) var fileScriptError: String?
    @Published var keyCode: UInt32
    @Published var modifiers: UInt32
    @Published var indexDependencyDirs: Bool
    @Published var indexPackageContents: Bool
    @Published var indexUserLibrary: Bool
    @Published var indexSystemDirs: Bool
    @Published private(set) var stashShortcuts: [StashShortcut: StashShortcut.Chord]
    @Published var recording = false
    private(set) var recordingStashShortcut: StashShortcut?
    @Published var shortcutError: String?
    @Published var coverage = CoverageStats()
    @Published var explanation: String?
    @Published var expandedCoverage: Set<String> = []
    @Published var indexedCount = 0
    @Published var scanDate: Date?
    @Published var granted = false
    @Published var rebuilding = false
    weak var manager: IndexManager?
    var externalDrives: ExternalDriveCatalogReading?
    private var disconnectedDriveName: String?
    var additionalSources: (() -> [SearchSource])?
    private var inspectionGeneration = 0
    var onConfigChange: (() -> Void)?
    var onPinyinChange: (() -> Void)?
    var onSearchSettingsChange: ((String) -> Void)?
    var onStashShortcutsChange: (() -> Void)?
    var suspendHotKey: (() -> Void)?
    var registerHotKey: ((UInt32, UInt32) -> Bool)?
    var onContentChange: (() -> Void)?
    private let snapshotStore: IndexStore?
    private var keyMonitor: Any?
    private var timer: Timer?

    init(snapshotStore: IndexStore? = nil, snapshot: Bool = false, languageDefaults: UserDefaults = .standard, preferences: UserDefaults = .standard, topics: AITopicManager? = nil) {
        self.topics = topics ?? AITopicManager(defaults: preferences)
        self.snapshot = snapshot
        self.preferences = preferences
        fileScripts = snapshot ? [] : FileScript.load(from: preferences)
        stashShortcuts = Dictionary(uniqueKeysWithValues: StashShortcut.allCases.map {
            ($0, snapshot ? $0.defaultChord : $0.chord(in: preferences))
        })
        self.languageDefaults = languageDefaults
        self.language = L10n.language
        launchAtLogin = snapshot ? false : SMAppService.mainApp.status == .enabled
        if !snapshot { SettingsPreferences.register() }
        let defaults = UserDefaults.standard
        indexDependencyDirs = !snapshot && defaults.bool(forKey: "indexDependencyDirs")
        indexPackageContents = !snapshot && defaults.bool(forKey: "indexPackageContents")
        indexUserLibrary = !snapshot && defaults.bool(forKey: "indexUserLibrary")
        indexSystemDirs = !snapshot && defaults.bool(forKey: "indexSystemDirs")
        previewWithSpace = snapshot ? true : (preferences.object(forKey: "previewWithSpace") as? Bool ?? true)
        excludedExtensionsText = snapshot ? "" : (preferences.stringArray(forKey: "excludedExtensions") ?? []).joined(separator: " ")
        pinyinEnabled = snapshot ? true : defaults.bool(forKey: "pinyinEnabled")
        excludedPaths = snapshot ? [] : ExcludedFolders.adding(defaults.stringArray(forKey: "userExcludedPaths") ?? [], to: [])
        keyCode = snapshot ? Shortcut.defaultKeyCode : UInt32(clamping: defaults.integer(forKey: "hotKeyCode"))
        modifiers = snapshot ? Shortcut.defaultModifiers : UInt32(clamping: defaults.integer(forKey: "hotKeyModifiers"))
        self.snapshotStore = snapshotStore
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.language = L10n.language
            self.shortcutError = L10n.relocalized(self.shortcutError)
            self.fileScriptError = L10n.relocalized(self.fileScriptError)
            if let name = self.disconnectedDriveName { self.explanation = L10n.text("explain.disconnectedDrive", name) }
            else if let answer = self.coverageExplanation { self.explanation = L10n.explanation(answer) }
            self.onContentChange?()
        }
        refresh()
    }
    func startRefreshing() {
        refresh(); timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopRefreshing() { timer?.invalidate(); timer = nil; cancelRecording() }
    func refresh() {
        let wasGranted = granted
        if !snapshot {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            let paths = ExcludedFolders.adding(preferences.stringArray(forKey: "userExcludedPaths") ?? [], to: [])
            if excludedPaths != paths { excludedPaths = paths; onContentChange?() }
        }
        granted = snapshot ? false : Permissions.hasFullDiskAccess()
        rebuilding = manager?.isRescanning == true || manager?.state == .scanning || manager?.state == .loading
        var stats = CoverageStats()
        if let store = snapshotStore ?? manager?.store {
            let values = store.read { (store.liveCount, store.scanFinishedAt, store.coverage) }
            stats = values.2
            indexedCount = values.0
            scanDate = values.1 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(values.1))
        } else { indexedCount = 0; scanDate = nil }
        for source in additionalSources?() ?? [] {
            var excludedTypes = CoverageStats()
            excludedTypes.buckets[.fileType] = source.store.read { source.store.coverage[.fileType] }
            stats.merge(excludedTypes)
        }
        if !snapshot { stats.refreshVolumes(excluding: Set((additionalSources?() ?? []).filter(\.isOnline).map { $0.store.rootPath })) }
        if coverage != stats { coverage = stats }
        if wasGranted != granted { onContentChange?() }
    }
    func checkFile(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let path = panel.url?.path else { return }
            self.check(path: path)
        }
    }
    func check(path: String) {
        // Capture extension state on the main thread before inspecting the filesystem.
        let allSources = additionalSources?() ?? []
        let sources = allSources, manager = manager
        let disconnected = externalDrives?.knownDrives.first { drive in
            !drive.isConnected && !allSources.contains { $0.id == drive.id }
                && (path == drive.path || path.hasPrefix(drive.path + "/"))
        }
        inspectionGeneration += 1
        let generation = inspectionGeneration
        DispatchQueue.global(qos: .utility).async {
            let answer = sources.lazy.compactMap { $0.explain(path: path) }.first ?? manager?.explain(path: path) ?? .pending
            DispatchQueue.main.async {
                guard generation == self.inspectionGeneration else { return }
                self.disconnectedDriveName = disconnected?.name
                self.coverageExplanation = answer
                self.explanation = disconnected.map { L10n.text("explain.disconnectedDrive", $0.name) } ?? L10n.explanation(answer)
            }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        onContentChange?()
    }
    func setPreviewWithSpace(_ enabled: Bool) {
        previewWithSpace = enabled
        preferences.set(enabled, forKey: "previewWithSpace")
    }
    func commitExcludedExtensions() {
        excludedExtensionsText = SettingsPreferences.setExcludedExtensions(excludedExtensionsText, in: preferences)
    }
    func setPinyin(_ enabled: Bool) {
        pinyinEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "pinyinEnabled")
        onPinyinChange?()
    }
    func setLanguage(_ value: AppLanguage) { L10n.setLanguage(value, in: languageDefaults) }
    func setScope(_ key: String, _ enabled: Bool) {
        switch key {
        case "indexDependencyDirs": indexDependencyDirs = enabled
        case "indexPackageContents": indexPackageContents = enabled
        case "indexUserLibrary": indexUserLibrary = enabled
        case "indexSystemDirs": indexSystemDirs = enabled
        default: preconditionFailure("Unknown scope key")
        }
        UserDefaults.standard.set(enabled, forKey: key)
        onConfigChange?(); refresh()
    }
    func addFolders(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK else { return }
            self.setExcluded(ExcludedFolders.adding(panel.urls.map(\.path), to: self.excludedPaths))
        }
    }
    func removeFolder(_ path: String) { setExcluded(excludedPaths.filter { $0 != path }) }
    private func setExcluded(_ paths: [String]) {
        guard paths != excludedPaths else { return }
        excludedPaths = paths; SettingsPreferences.setExcludedPaths(paths, in: preferences)
        onContentChange?()
    }
    func addFileScript(in window: NSWindow?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let isExecutable = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && FileManager.default.isExecutableFile(atPath: url.path)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard isExecutable else { self.fileScriptError = L10n.text("fileScripts.notExecutable"); return }
                    self.fileScriptError = nil
                    let script = FileScript(url: url)
                    if !self.fileScripts.contains(script) {
                        self.fileScripts.append(script)
                        FileScript.save(self.fileScripts, to: self.preferences)
                    }
                }
            }
        }
    }

    func removeFileScript(_ script: FileScript) {
        fileScripts.removeAll { $0 == script }
        FileScript.save(fileScripts, to: preferences)
    }

    func rebuild() { manager?.rescan(); rebuilding = manager != nil }
    func beginRecording(in window: NSWindow?, stashShortcut: StashShortcut? = nil) {
        guard !recording, let window else { return }
        recordingStashShortcut = stashShortcut
        shortcutError = nil; recording = true; suspendHotKey?(); onContentChange?()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self, self.recording, let window, event.window === window else { return event }
            self.record(event); return nil
        }
    }
    private func endRecording() {
        recordingStashShortcut = nil
        recording = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onContentChange?()
    }
    func cancelRecording() {
        guard recording else { return }
        shortcutError = registerHotKey?(keyCode, modifiers) == true ? nil : L10n.text("settings.shortcutConflict")
        endRecording()
    }
    private func record(_ event: NSEvent) {
        let recordedModifiers = HotKey.carbonModifiers(event.modifierFlags)
        if recordedModifiers == 0, event.keyCode == UInt16(kVK_Escape) { cancelRecording(); return }
        let reset = recordedModifiers == 0 && (event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete))
        let fallback = recordingStashShortcut?.defaultChord ?? .init(keyCode: Shortcut.defaultKeyCode, modifiers: Shortcut.defaultModifiers)
        let code = reset ? fallback.keyCode : UInt32(event.keyCode)
        let mask = reset ? fallback.modifiers : recordedModifiers
        let key = Shortcut.keyEquivalent(code)
        let functionKey = key.unicodeScalars.first.map { (0xf704...0xf717).contains($0.value) } ?? false
        guard recordingStashShortcut != nil || functionKey || mask & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            shortcutError = L10n.text("settings.shortcutModifier"); onContentChange?(); return
        }
        let chord = StashShortcut.Chord(keyCode: code, modifiers: mask)
        if let target = recordingStashShortcut {
            let global = StashShortcut.Chord(keyCode: keyCode, modifiers: modifiers)
            guard target.canAssign(chord, in: preferences, global: global) else {
                shortcutError = L10n.text("settings.stashShortcutUnavailable"); onContentChange?(); return
            }
            target.save(chord, in: preferences)
            stashShortcuts[target] = chord
            onStashShortcutsChange?()
            cancelRecording()
            return
        }
        if stashShortcuts.values.contains(chord) {
            shortcutError = L10n.text("settings.stashShortcutUnavailable"); onContentChange?(); return
        }
        if registerHotKey?(code, mask) == true {
            keyCode = code; modifiers = mask
            UserDefaults.standard.set(Int(code), forKey: "hotKeyCode")
            UserDefaults.standard.set(Int(mask), forKey: "hotKeyModifiers")
            onStashShortcutsChange?()
            shortcutError = nil
        } else {
            _ = registerHotKey?(keyCode, modifiers)
            shortcutError = L10n.text("settings.shortcutConflict")
        }
        endRecording()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}

private struct LanguagePicker: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    final class Coordinator: NSObject {
        let model: SettingsModel
        init(_ model: SettingsModel) { self.model = model }
        @objc func selected(_ button: NSPopUpButton) {
            guard AppLanguage.allCases.indices.contains(button.indexOfSelectedItem) else { return }
            model.setLanguage(AppLanguage.allCases[button.indexOfSelectedItem])
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small; button.font = .systemFont(ofSize: 12.5)
        button.target = context.coordinator; button.action = #selector(Coordinator.selected(_:))
        button.setAccessibilityIdentifier("settings.language")
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let titles = AppLanguage.allCases.map(\.title)
        if button.itemTitles != titles { button.removeAllItems(); button.addItems(withTitles: titles) }
        button.selectItem(at: AppLanguage.allCases.firstIndex(of: model.language)!)
        button.setAccessibilityLabel(L10n.text("settings.language"))
    }
}

enum SettingsPage: String, Identifiable {
    case general, style, actionBar, search, filters, index, drives, exclusions, shortcuts, scripts, topics, extensions

    var id: Self { self }
    var title: String { L10n.text(presentation.title) }
    var icon: String { presentation.icon }

    private var presentation: (title: String, icon: String) {
        switch self {
        case .general: return ("settings.general", "gearshape")
        case .style: return ("settings.page.style", "paintbrush")
        case .actionBar: return ("settings.page.actionBar", "rectangle.bottomthird.inset.filled")
        case .filters: return ("settings.page.filters", "line.3.horizontal.decrease.circle")
        case .search: return ("settings.page.search", "magnifyingglass")
        case .index: return ("settings.index", "internaldrive")
        case .drives: return ("drivesTitle", "externaldrive")
        case .exclusions: return ("settings.page.exclusions", "minus.circle")
        case .shortcuts: return ("settings.page.shortcuts", "keyboard")
        case .scripts: return ("fileScripts.title", "terminal")
        case .topics: return ("topicsTitle", "text.bubble")
        case .extensions: return ("settings.page.extensions", "puzzlepiece.extension")
        }
    }
}

private struct SettingsForm: View {
    @ObservedObject var model: SettingsModel
    var appExtension: ApplicationExtension?
    var externalDrives: ExternalDriveCatalog
    var window: () -> NSWindow?
    @State var page: SettingsPage
    @State private var shortcutQuery = ""
    @State private var selectedScript: FileScript?

    private func preference(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { model.preferences.object(forKey: key) as? Bool ?? fallback }, set: { value in
            model.objectWillChange.send()
            model.preferences.set(value, forKey: key)
            model.onSearchSettingsChange?(key)
        })
    }

    private func option(_ title: String, help: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text(title))
                hint(L10n.text(help))
            }
        }
    }

    private func previewChoice<Preview: View>(_ title: String, example: String, selected: Bool, action: @escaping () -> Void, @ViewBuilder preview: () -> Preview) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview()
                    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                Text(L10n.text(title)).font(.headline)
                hint(L10n.text(example))
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func resultExample(table: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if table {
                HStack {
                    Text(L10n.text("stash.column.name"))
                    Spacer()
                    Text(L10n.text("stash.column.size"))
                }.foregroundStyle(.secondary)
                Divider()
            }
            ForEach(["Report.pdf", "Notes.txt"], id: \.self) { file in
                HStack {
                    Label(file, systemImage: "doc")
                    Spacer()
                    if table { Text(file == "Report.pdf" ? "128 KB" : "4 KB").foregroundStyle(.secondary) }
                }
                if !table { Text("~/Documents").foregroundStyle(.secondary).padding(.leading, 18) }
            }
        }
        .font(.caption)
    }

    private func matchingExample(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(query, systemImage: "magnifyingglass").font(.system(.caption, design: .monospaced))
            Divider()
            Label("CHANGELOG.md", systemImage: "doc.text").font(.caption)
        }
    }

    private func sidebarGroup(_ title: String, pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(pages) { destination in
                Button {
                    guard destination != page else { return }
                    window()?.makeFirstResponder(nil)
                    model.cancelRecording()
                    page = destination
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination.icon)
                            .frame(width: 18)
                            .foregroundStyle(page == destination ? Color.white : .accentColor)
                            .accessibilityHidden(true)
                        Text(destination == .shortcuts ? L10n.text("settings.sidebar.shortcuts") : destination.title)
                            .fontWeight(page == destination ? .semibold : .regular)
                            .foregroundStyle(page == destination ? Color.white : .primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if page == destination {
                            RoundedRectangle(cornerRadius: 7).fill(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(page == destination ? .isSelected : [])
                .accessibilityIdentifier("settings.page." + destination.rawValue)
            }
        }
    }

    private var shortcutRows: [(action: StashShortcut, title: String)] {
        StashShortcut.allCases.compactMap { action in
            if StashShortcut.scripts.contains(action) {
                guard model.fileScripts.indices.contains(action.slot) else { return nil }
                return (action, model.fileScripts[action.slot].name)
            }
            return (action, action.settingsTitle)
        }
    }

    private func matchesShortcut(_ title: String, chord: StashShortcut.Chord) -> Bool {
        let query = shortcutQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let symbols = Shortcut.symbols(keyCode: chord.keyCode, modifiers: chord.modifiers)
        return query.isEmpty || title.localizedStandardContains(query) || symbols.localizedStandardContains(query)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sidebarGroup("settings.group.app", pages: [.general, .style, .actionBar])
                    sidebarGroup("settings.group.indexing", pages: [.search, .filters, .index, .drives, .exclusions])
                    sidebarGroup("settings.group.actions", pages: [.shortcuts, .scripts])
                    sidebarGroup("settings.group.integrations", pages: appExtension == nil ? [.topics] : [.topics, .extensions])
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 20)
            }
            .frame(width: 192)
            .background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 8)
                if page == .shortcuts {
                    TextField(L10n.text("settings.filterShortcuts"), text: $shortcutQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                }
                if page == .filters {
                    SavedFilterSettings(preferences: model.preferences)
                } else {
                    Form { pageContent }
                    .formStyle(.grouped)
                    .toggleStyle(.switch)
                    .id(page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general:
            Section {
                HStack {
                    Text(L10n.text("settings.language")); Spacer()
                    LanguagePicker(model: model).frame(width: 140, height: 24)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Toggle(L10n.text("settings.login"), isOn: Binding(get: { model.launchAtLogin }, set: model.setLogin))
                    if let error = model.loginError { hint(error).foregroundStyle(.red) }
                }
            }
            Section {
                HStack {
                    Text(L10n.text("settings.shortcut"))
                    Spacer()
                    ShortcutRecorder(model: model).frame(width: 120, height: 24)
                }
                if let error = model.shortcutError { hint(error).foregroundStyle(.red) }
            } header: {
                Text(L10n.text("settings.page.shortcuts"))
            } footer: {
                hint(L10n.text("settings.version", UpdateManager.current.version.text))
            }
        case .style:
            let compact = preference("compactResults")
            Section(L10n.text("view.results")) {
                HStack(alignment: .top, spacing: 12) {
                    previewChoice("view.original", example: "settings.style.listHint", selected: !compact.wrappedValue) {
                        compact.wrappedValue = false
                    } preview: {
                        resultExample(table: false)
                    }
                    previewChoice("view.compact", example: "settings.style.tableHint", selected: compact.wrappedValue) {
                        compact.wrappedValue = true
                    } preview: {
                        resultExample(table: true)
                    }
                }
                option("settings.style.preview", help: "settings.style.previewHint", value: preference("defaultSidePreview"))
            }
        case .actionBar:
            Section(L10n.text("settings.actionBar.rows")) {
                option("settings.actionBar.hints", help: "settings.actionBar.hintsHelp", value: preference("showActionHints", default: true))
                option("footer.openWith", help: "settings.actionBar.appsHelp", value: preference("showOpenWithRow", default: true))
            }
            Section(L10n.text("settings.actionBar.preview")) {
                HStack(spacing: 12) {
                    if preference("showActionHints", default: true).wrappedValue {
                        Label(L10n.text("hint.open"), systemImage: "return")
                        Label(L10n.text("hint.preview"), systemImage: "eye")
                    }
                    Label(L10n.text("panel.actions"), systemImage: "ellipsis.circle")
                    Spacer()
                }.foregroundStyle(.secondary)
                if preference("compactResults").wrappedValue && preference("showOpenWithRow", default: true).wrappedValue {
                    Label(L10n.text("footer.openWith"), systemImage: "app")
                        .foregroundStyle(.secondary)
                }
            }
        case .search:
            let fuzzy = preference("fuzzyNames")
            Section(L10n.text("settings.search.matching")) {
                HStack(alignment: .top, spacing: 12) {
                    previewChoice("settings.search.literal", example: "settings.search.literalHint", selected: !fuzzy.wrappedValue) {
                        fuzzy.wrappedValue = false
                    } preview: {
                        matchingExample("changelog")
                    }
                    previewChoice("scope.fuzzyNames", example: "settings.search.fuzzyHint", selected: fuzzy.wrappedValue) {
                        fuzzy.wrappedValue = true
                    } preview: {
                        matchingExample("clgmd")
                    }
                }
                option("settings.pinyin", help: "settings.pinyinHint",
                       value: Binding(get: { model.pinyinEnabled }, set: model.setPinyin))
            }
            Section(L10n.text("hint.preview")) {
                option("settings.previewSpace", help: "settings.previewSpaceHint",
                       value: Binding(get: { model.previewWithSpace }, set: model.setPreviewWithSpace))
            }
        case .filters:
            EmptyView()
        case .shortcuts:
            let matches = shortcutRows.filter { row in
                matchesShortcut(row.title, chord: model.stashShortcuts[row.action] ?? row.action.defaultChord)
            }
            let global = matchesShortcut(L10n.text("settings.shortcut"),
                                         chord: .init(keyCode: model.keyCode, modifiers: model.modifiers))
            Section {
                if global {
                    HStack {
                        Text(L10n.text("settings.shortcut")); Spacer()
                        ShortcutRecorder(model: model).frame(width: 120, height: 24)
                    }
                }
                ForEach(matches, id: \.action) { row in
                    HStack {
                        Text(row.title)
                        Spacer()
                        ShortcutRecorder(model: model, stashShortcut: row.action).frame(width: 120, height: 24)
                    }
                }
                if matches.isEmpty && !global {
                    Text(L10n.text("settings.noShortcutMatches")).foregroundStyle(.secondary)
                }
            } header: {
                hint(L10n.text("settings.stashShortcutHint"))
                if let error = model.shortcutError { hint(error).foregroundStyle(.red) }
            }
        case .index:
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(L10n.text("settings.indexed")); Spacer()
                        Text(L10n.text("settings.items", Presentation.countText(model.indexedCount)))
                    }
                    if let date = model.scanDate {
                        hint(L10n.text("settings.scanDate", Presentation.dateText(date, now: Date(), calendar: .current, chinese: L10n.chinese)))
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("coverage.title")).font(.subheadline).foregroundStyle(.secondary)
                    coverageRow("noAccess", bucket: model.coverage[.noAccess])
                    if model.coverage.scopeCount > 0 {
                        DisclosureGroup(isExpanded: coverageBinding("scope")) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(CoverageReason.allCases.filter { $0.scopeKey != nil && model.coverage[$0].count > 0 }, id: \.self) { reason in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L10n.text("settings.scope." + reason.scopeKey!) + " · " + String(model.coverage[reason].count))
                                            .font(.footnote).foregroundStyle(.secondary)
                                        examples(model.coverage[reason])
                                    }
                                }
                            }
                            .padding(.top, 4).padding(.leading, 12).frame(maxWidth: .infinity, alignment: .leading)
                        } label: { Text(L10n.text("coverage.scope", String(model.coverage.scopeCount))).fixedSize(horizontal: false, vertical: true) }
                    }
                    coverageRow("userExcluded", bucket: model.coverage[.userExcluded])
                    coverageRow("fileType", bucket: model.coverage[.fileType])
                    coverageRow("cloud", bucket: model.coverage[.cloud])
                    coverageRow("volumes", bucket: model.coverage[.volumes])
                    Button(L10n.text("coverage.check")) { model.checkFile(in: window()) }
                    if let explanation = model.explanation { hint(explanation) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(L10n.text("settings.permission")); Spacer()
                        Circle().fill(Color(nsColor: model.granted ? .systemGreen : .systemOrange)).frame(width: 8, height: 8)
                        Text(L10n.text(model.granted ? "settings.granted" : "settings.notGranted"))
                    }
                    if !model.granted { Button(L10n.text("settings.openPermissions"), action: Permissions.openSettings) }
                }
                Button(L10n.text(model.rebuilding ? "settings.rebuilding" : "settings.rebuild"), action: model.rebuild)
                    .disabled(model.rebuilding || model.manager == nil)
            }
            Section {
                scopeRow("dependency", key: "indexDependencyDirs", enabled: model.indexDependencyDirs)
                scopeRow("packages", key: "indexPackageContents", enabled: model.indexPackageContents)
                scopeRow("library", key: "indexUserLibrary", enabled: model.indexUserLibrary)
                scopeRow("system", key: "indexSystemDirs", enabled: model.indexSystemDirs)
            } header: { Text(L10n.text("settings.scope")) }
              footer: { hint(L10n.text("settings.scopeHint")) }
        case .drives:
            Section {
                ExternalDriveSettings(catalog: externalDrives, chinese: L10n.chinese, window: window)
            }
        case .topics:
            Section {
                AITopicSettings(manager: model.topics)
            }
        case .scripts:
            Section {
                if model.fileScripts.isEmpty { hint(L10n.text("settings.scripts.empty")) }
                ForEach(model.fileScripts) { script in
                    Button {
                        model.cancelRecording()
                        selectedScript = script
                    } label: {
                        HStack {
                            Label(script.name, systemImage: "doc.text")
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if activeScript == script { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activeScript == script ? .isSelected : [])
                }
                Button(L10n.text("fileScripts.add")) { model.addFileScript(in: window()) }
                if let error = model.fileScriptError { hint(error).foregroundStyle(.red) }
            } footer: { hint(L10n.text("fileScripts.hint")) }
            if let script = activeScript, let index = model.fileScripts.firstIndex(of: script) {
                Section(script.name) {
                    Text(script.path).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    if StashShortcut.scripts.indices.contains(index) {
                        HStack {
                            Text(L10n.text("settings.sidebar.shortcuts"))
                            Spacer()
                            ShortcutRecorder(model: model, stashShortcut: StashShortcut.scripts[index]).frame(width: 120, height: 24)
                        }
                        if let error = model.shortcutError { hint(error).foregroundStyle(.red) }
                    }
                    HStack {
                        Button(L10n.text("ctx.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([script.url]) }
                        Spacer()
                        Button(L10n.text("fileScripts.remove", script.name), role: .destructive) {
                            model.cancelRecording()
                            model.removeFileScript(script)
                            selectedScript = nil
                        }
                    }
                }.id(script.id)
            }
        case .extensions:
            if let appExtension { appExtension.settingsSection(window: window) }
        case .exclusions:
            Section {
                if model.excludedPaths.isEmpty { Text(L10n.text("settings.noExcluded")).foregroundStyle(.secondary) }
                ForEach(model.excludedPaths, id: \.self) { path in
                    HStack {
                        Text(Presentation.abbreviate(path: path, home: NSHomeDirectory())).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { model.removeFolder(path) } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
                Button(L10n.text("settings.addFolder")) { model.addFolders(in: window()) }
            } header: { Text(L10n.text("settings.excluded")) }
              footer: { hint(L10n.text("settings.excludedHint")) }
            Section {
                ExcludedExtensionsInput(model: model).frame(height: 24)
            } header: { Text(L10n.text("settings.excludedTypes")) }
              footer: { hint(L10n.text("settings.excludedTypesHint")) }
        }
    }
    private var activeScript: FileScript? {
        selectedScript.flatMap { model.fileScripts.contains($0) ? $0 : nil } ?? model.fileScripts.first
    }

    private func coverageBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expandedCoverage.contains(key) }, set: { if $0 { model.expandedCoverage.insert(key) } else { model.expandedCoverage.remove(key) } })
    }
    @ViewBuilder private func coverageRow(_ key: String, bucket: CoverageBucket) -> some View {
        if bucket.count > 0 {
            DisclosureGroup(isExpanded: coverageBinding(key)) { examples(bucket).padding(.top, 4).padding(.leading, 12) }
                label: { Text(L10n.text("coverage." + key, String(bucket.count))).fixedSize(horizontal: false, vertical: true) }
        }
    }
    // Left-aligned, one line each; long paths truncate in the middle and show in full on hover.
    private func examples(_ bucket: CoverageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(bucket.examples, id: \.self) { path in
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func scopeRow(_ name: String, key: String, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(L10n.text("settings.scope." + name), isOn: Binding(get: { enabled }, set: { model.setScope(key, $0) }))
            hint(L10n.text("settings.scope." + name + "Hint"))
        }
    }
    private func hint(_ text: String) -> some View { Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: SettingsModel
    var stashShortcut: StashShortcut? = nil
    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.onBegin = { [weak model, weak button] in model?.beginRecording(in: button?.window, stashShortcut: stashShortcut) }
        button.onCancel = { [weak model] in model?.cancelRecording() }
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        let chord = stashShortcut.map { model.stashShortcuts[$0] ?? $0.defaultChord }
            ?? .init(keyCode: model.keyCode, modifiers: model.modifiers)
        button.recording = model.recording && model.recordingStashShortcut == stashShortcut
        button.title = button.recording ? L10n.text("settings.record") : Shortcut.symbols(keyCode: chord.keyCode, modifiers: chord.modifiers)
        button.needsDisplay = true
    }
}

private final class RecorderButton: NSButton {
    var recording = false
    var onBegin: (() -> Void)?, onCancel: (() -> Void)?
    init() {
        super.init(frame: .zero); isBordered = false
        font = .systemFont(ofSize: 12.5, weight: .medium)
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(begin)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    @objc private func begin() { window?.makeFirstResponder(self); onBegin?() }
    override func mouseDown(with event: NSEvent) { begin() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 49 || event.keyCode == 36 { begin() } else { super.keyDown(with: event) } }
    override func resignFirstResponder() -> Bool { onCancel?(); return super.resignFirstResponder() }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.labelColor.withAlphaComponent(0.07).setFill(); path.fill()
        if recording {
            let pixel = 1 / (window?.backingScaleFactor ?? 2)
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: 6, yRadius: 6)
            border.lineWidth = pixel; border.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: NSColor.labelColor]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

final class SettingsWindow: NSWindow {
    weak var settingsModel: SettingsModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The accessory app has no Edit menu to dispatch field-editor commands.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers == .command || modifiers == [.command, .shift],
           let editor = firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText() {
            if modifiers.contains(.shift) { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            return true
        }
        if modifiers == .command,
           let editor = firstResponder as? NSTextView, editor.isFieldEditor, !editor.hasMarkedText() {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": editor.selectAll(nil); return true
            case "c": editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    init(model: SettingsModel, appExtension: ApplicationExtension? = nil, externalDrives: ExternalDriveCatalog = ExternalDriveCatalog(), initialPage: SettingsPage = .general) {
        self.model = model
        model.externalDrives = externalDrives
        model.additionalSources = { [weak appExtension, weak externalDrives] in
            (externalDrives?.searchSources() ?? []) + (appExtension?.searchSources() ?? [])
        }
        let initialSize = NSSize(width: 780, height: 560)
        let window = SettingsWindow(contentRect: NSRect(origin: .zero, size: initialSize), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentMinSize = NSSize(width: 680, height: 440)
        window.settingsModel = model
        window.title = L10n.text("settings.title"); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let settings = SettingsForm(model: model, appExtension: appExtension, externalDrives: externalDrives,
                                    window: { [weak window] in window }, page: initialPage)
        let hosting = NSHostingController(rootView: settings)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(initialSize)
        model.onContentChange = { [weak self] in self?.refreshTitle() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() {
        guard let window else { return }
        if !window.isVisible { model.startRefreshing(); refreshTitle(); window.center() }
        window.makeKeyAndOrderFront(nil)
    }
    private func refreshTitle() {
        window?.title = L10n.text("settings.title")
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? ExcludedExtensionsField)?.editor
    }
    func windowWillClose(_ notification: Notification) { model.stopRefreshing() }
    func windowDidResignKey(_ notification: Notification) { model.cancelRecording() }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}
