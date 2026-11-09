import AppKit
import SwiftUI
import OilFindCore

struct SavedFilterSettings: View {
    private let preferences: UserDefaults
    @ObservedObject var drives: ExternalDriveCatalog
    private let window: () -> NSWindow?
    @AppStorage(QuickFilter.storageKey) private var storedFilters: Data?
    @AppStorage(QuickFilter.libraryKey) private var storedLibrary: Data?
    @State private var group: QuickFilter.Group = .quick
    @State private var symbol = QuickFilter.symbols[0]
    @State private var prepend = ""
    @State private var append = ""
    @State private var match: QuickFilter.Match = .both
    @State private var expiry = -1
    @State private var rawEditor = false
    @AppStorage(QuickFilter.expiryKey) private var globalExpiry = 0
    @State private var selection: Int?
    @State private var original: QuickFilter?
    @State private var name = ""
    @State private var query = ""
    @State private var kind: UInt8?
    @State private var folders: [String] = []
    @State private var extensions = ""
    @State private var exclusions: [String] = []
    @State private var hiddenOnly = false
    @State private var fuzzyNames = false
    @State private var sortKey: String?
    @State private var ascending = false
    @State private var conflict = false

    init(preferences: UserDefaults, drives: ExternalDriveCatalog, window: @escaping () -> NSWindow?) {
        self.preferences = preferences
        self.window = window
        self.drives = drives
        _globalExpiry = AppStorage(wrappedValue: 0, QuickFilter.expiryKey, store: preferences)
        _storedLibrary = AppStorage(QuickFilter.libraryKey, store: preferences)
        _storedFilters = AppStorage(QuickFilter.storageKey, store: preferences)
    }

    private var filters: [QuickFilter] { QuickFilter.load(from: preferences) + QuickFilter.library(in: preferences) }
    private var validName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        filters.enumerated().contains { index, filter in
            index != selection && (filter.group ?? .quick) == group && filter.name.caseInsensitiveCompare(validName) == .orderedSame
        }
    }

    private static let sortKeys: [SortKey] = [.relevance, .name, .modified, .size]

    private var extensionList: [String] {
        extensions.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    private var validExtensions: Bool {
        extensionList.allSatisfy { (1...8).contains($0.utf8.count) && $0.utf8.allSatisfy { $0 < 128 } }
    }

    private var draft: QuickFilter {
        let criteria = Query.SavedCriteria(folders: folders.count > 1 ? folders : [],
                                           extensions: extensionList, exclusions: exclusions)
        return QuickFilter(name: validName, query: query, kind: kind, folder: folders.count == 1 ? folders.first : nil,
                    volume: original?.volume, hiddenOnly: hiddenOnly,
                    fuzzyNames: fuzzyNames ? true : original?.fuzzyNames.map { _ in false },
                    sort: sortKey.map { .init(key: $0, ascending: ascending) }, criteria: criteria.isEmpty ? nil : criteria,
                    group: original == nil || original?.group != nil ? group : nil, presetID: original?.presetID,
                    symbol: symbol == QuickFilter.symbols[0] && original?.symbol == nil ? nil : symbol,
                    prepend: prepend.isEmpty ? nil : prepend, append: append.isEmpty ? nil : append,
                    match: match == .both ? nil : match, expiresAfter: expiry < 0 ? nil : expiry)
    }

    private var canSave: Bool {
        let hasSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil
            || !prepend.isEmpty || !append.isEmpty || match != .both || draft.folder != nil || draft.criteria != nil || hiddenOnly || original?.volume != nil
        return validExtensions && !validName.isEmpty && !duplicateName && draft != original && (original != nil || hasSearch)
    }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { selection }, set: select)) {
                librarySection(.quick, overview: -1)
                librarySection(.folder, overview: -2)
                Section(L10n.text("settings.filters.other")) {
                    Label(L10n.text("settings.filters.disconnected"), systemImage: "externaldrive")
                        .tag(-3)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel(L10n.text("settings.page.filters"))
            .frame(width: 176)
            Divider()
            if let selection, selection < 0 {
                overview(selection)
            } else {
                editor
            }
        }
        .onAppear { select(-1) }
        .onChange(of: storedFilters) { _, _ in checkForExternalChange() }
        .onChange(of: storedLibrary) { _, _ in checkForExternalChange() }
    }

    private var editor: some View {
            Form {
                Section(original == nil ? group.newTitle : L10n.text("settings.filters.edit")) {
                    TextField(L10n.text("quickFilter.name"), text: $name)
                    Picker(L10n.text("settings.filters.icon"), selection: $symbol) {
                        ForEach(QuickFilter.symbols, id: \.self) { icon in
                            Image(systemName: icon).accessibilityLabel(icon).tag(icon)
                        }
                    }
                    Picker(L10n.text("settings.filters.editMode"), selection: $rawEditor) {
                        Text(L10n.text("settings.filters.structured")).tag(false)
                        Text(L10n.text("settings.filters.raw")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    if rawEditor {
                        TextField(L10n.text("settings.filters.query"), text: $query)
                            .font(.system(.body, design: .monospaced))
                        Text(L10n.text("settings.filters.rawHint")).foregroundStyle(.secondary)
                    }
                }
                if !rawEditor {
                Section(L10n.text("settings.filters.criteria")) {
                    Picker(L10n.text("settings.filters.match"), selection: $match) {
                        ForEach(QuickFilter.Match.allCases, id: \.rawValue) { value in
                            Text(L10n.text("settings.filters.match." + value.rawValue)).tag(value)
                        }
                    }
                    TextField(L10n.text("settings.filters.prepend"), text: $prepend)
                    TextField(L10n.text("settings.filters.append"), text: $append)
                    Picker(L10n.text("settings.filters.kind"), selection: $kind) {
                        Text(L10n.text("filter.all")).tag(nil as UInt8?)
                        ForEach(Array(FilterBar.names.dropFirst().enumerated()), id: \.offset) { index, name in
                            Text(L10n.text("filter." + name)).tag(UInt8(index + 1) as UInt8?)
                        }
                    }
                    pathList("settings.filters.folder", paths: $folders, allowFiles: false)
                    TextField(L10n.text("settings.filters.extensions"), text: $extensions, prompt: Text("pdf, png"))
                    if !validExtensions {
                        Text(L10n.text("settings.filters.invalidExtensions")).foregroundStyle(.secondary)
                    }
                    pathList("settings.filters.exclusions", paths: $exclusions, allowFiles: true)
                    if let volume = original?.volume {
                        LabeledContent(L10n.text("settings.filters.volume"), value: volume)
                    }
                    Toggle(L10n.text("scope.hiddenOnly"), isOn: $hiddenOnly)
                    Toggle(L10n.text("scope.fuzzyNames"), isOn: $fuzzyNames)
                }
                }
                Section(L10n.text("settings.filters.expiry")) {
                    expiryPicker(selection: $expiry, includeDefault: true)
                }
                Section(L10n.text("settings.filters.order")) {
                    Picker(L10n.text("settings.filters.order"), selection: $sortKey) {
                        Text(L10n.text("settings.filters.currentOrder")).tag(nil as String?)
                        ForEach(Self.sortKeys, id: \.rawValue) { key in
                            Text(L10n.text("sort." + key.rawValue)).tag(key.rawValue as String?)
                        }
                        if let sortKey, SortKey(rawValue: sortKey) == nil {
                            Text(sortKey).tag(sortKey as String?)
                        }
                    }
                    if sortKey != nil {
                        Toggle(L10n.text("settings.filters.ascending"), isOn: $ascending)
                    }
                }
                Section {
                    HStack {
                        if let id = original?.presetID,
                           let preset = QuickFilter.presets.first(where: { $0.presetID == id }), preset != original {
                            Button(L10n.text("settings.filters.reset")) { reset(to: preset) }
                        }
                        if original != nil {
                            Button(L10n.text("settings.filters.remove"), role: .destructive, action: remove)
                        }
                        Spacer()
                        Button(L10n.text("quickFilter.saveButton"), action: save)
                            .disabled(!canSave)
                    }
                    if duplicateName {
                        Text(L10n.text("settings.filters.duplicate")).foregroundStyle(.secondary)
                    }
                    if conflict {
                        Text(L10n.text("settings.filters.conflict")).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(L10n.text("settings.filters.hint")).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
    }

    private func librarySection(_ group: QuickFilter.Group, overview: Int) -> some View {
        Section(group.title) {
            Label(group.overviewTitle, systemImage: group == .quick ? "slider.horizontal.3" : "folder")
                .tag(overview)
            ForEach(Array(filters.enumerated()).filter { ($0.element.group ?? .quick) == group }, id: \.offset) { index, filter in
                Label {
                    Text(filter.name).lineLimit(1)
                } icon: {
                    Image(systemName: filter.icon)
                        .foregroundStyle(group == .quick ? Color.accentColor : .teal)
                }
                .help(filter.name)
                .tag(index)
            }
            Button {
                select(nil)
                self.group = group
                symbol = group == .folder ? "folder" : QuickFilter.symbols[0]
            } label: {
                Label(group.newTitle, systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func expiryPicker(selection: Binding<Int>, includeDefault: Bool) -> some View {
        Picker(L10n.text("settings.filters.expiry"), selection: selection) {
            if includeDefault { Text(L10n.text("settings.filters.expiryDefault")).tag(-1) }
            Text(L10n.text("settings.general.never")).tag(0)
            ForEach([1, 5, 15, 30], id: \.self) { minutes in
                Text(L10n.text("settings.general.minutes", String(minutes))).tag(minutes * 60)
            }
        }
    }

    private func overview(_ selection: Int) -> some View {
        Form {
            if selection == -3 {
                Section(L10n.text("settings.filters.disconnected")) {
                    let disconnected = drives.knownDrives.filter { !$0.isConnected }
                    if disconnected.isEmpty {
                        Text(L10n.text("settings.filters.noDisconnected")).foregroundStyle(.secondary)
                    }
                    ForEach(disconnected, id: \.id) { drive in
                        LabeledContent(drive.name, value: drive.path)
                    }
                }
            } else {
                let group: QuickFilter.Group = selection == -1 ? .quick : .folder
                Section(group.overviewTitle) {
                    ForEach(Array(filters.enumerated()).filter { ($0.element.group ?? .quick) == group }, id: \.offset) { index, filter in
                        Button { select(index) } label: {
                            Label(filter.name, systemImage: filter.icon)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section(L10n.text("settings.filters.expiry")) {
                    expiryPicker(selection: $globalExpiry, includeDefault: false)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func checkForExternalChange() {
        guard let selection, selection >= 0, let original else { return }
        let current = filters
        if !current.indices.contains(selection) || current[selection] != original {
            select(nil)
            conflict = true
        }
    }

    private func reset(to preset: QuickFilter) {
        guard let selection, filters.indices.contains(selection), filters[selection] == original else { return }
        var current = filters
        current[selection] = preset
        persist(current)
        select(selection)
    }

    private func select(_ index: Int?) {
        let current = filters
        selection = index
        original = index.flatMap { current.indices.contains($0) ? current[$0] : nil }
        group = original?.group ?? .quick
        symbol = original?.icon ?? QuickFilter.symbols[0]
        prepend = original?.prepend ?? ""
        append = original?.append ?? ""
        match = original?.match ?? .both
        expiry = original?.expiresAfter ?? -1
        rawEditor = !(original?.query.isEmpty ?? true)
        name = original?.name ?? ""
        query = original?.query ?? ""
        kind = original?.kind
        folders = original?.criteria?.folders ?? []
        if let folder = original?.folder, !folders.contains(folder) { folders.insert(folder, at: 0) }
        extensions = original?.criteria?.extensions.joined(separator: ", ") ?? ""
        exclusions = original?.criteria?.exclusions ?? []
        hiddenOnly = original?.hiddenOnly ?? false
        fuzzyNames = original?.fuzzyNames ?? false
        sortKey = original?.sort?.key
        ascending = original?.sort?.ascending ?? false
        conflict = false
    }

    private func pathList(_ title: String, paths: Binding<[String]>, allowFiles: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title))
            ForEach(paths.wrappedValue, id: \.self) { path in
                HStack {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).help(path)
                    Spacer()
                    Button {
                        paths.wrappedValue.removeAll { $0 == path }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.text("settings.filters.removePath", path))
                }
            }
            Button(L10n.text(allowFiles ? "settings.addFolder" : "settings.filters.chooseFolder")) {
                guard let window = window() else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = allowFiles
                panel.allowsMultipleSelection = true
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK else { return }
                    for url in panel.urls where !paths.wrappedValue.contains(url.path) {
                        paths.wrappedValue.append(url.path)
                    }
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        var current = filters
        if let selection {
            guard current.indices.contains(selection), current[selection] == original else { conflict = true; return }
            current[selection] = draft
            persist(current)
            select(selection)
        } else {
            current.append(draft)
            persist(current)
            select(current.count - 1)
        }
    }

    private func persist(_ filters: [QuickFilter]) {
        QuickFilter.save(filters.filter { $0.group == nil }, to: preferences)
        QuickFilter.saveLibrary(filters.filter { $0.group != nil }, to: preferences)
    }

    private func remove() {
        var current = filters
        guard let selection, current.indices.contains(selection), current[selection] == original else { conflict = true; return }
        current.remove(at: selection)
        persist(current)
        select(current.isEmpty ? nil : min(selection, current.count - 1))
    }
}
