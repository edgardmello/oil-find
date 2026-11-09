import AppKit
import SwiftUI
import OilFindCore

struct SavedFilterSettings: View {
    private let preferences: UserDefaults
    private let window: () -> NSWindow?
    @AppStorage(QuickFilter.storageKey) private var storedFilters: Data?
    @State private var selection: Int?
    @State private var original: QuickFilter?
    @State private var name = ""
    @State private var query = ""
    @State private var kind: UInt8?
    @State private var folder: String?
    @State private var hiddenOnly = false
    @State private var fuzzyNames = false
    @State private var sortKey: String?
    @State private var ascending = false
    @State private var conflict = false

    init(preferences: UserDefaults, window: @escaping () -> NSWindow?) {
        self.preferences = preferences
        self.window = window
        _storedFilters = AppStorage(QuickFilter.storageKey, store: preferences)
    }

    private var filters: [QuickFilter] { QuickFilter.load(from: preferences) }
    private var validName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        filters.enumerated().contains { index, filter in
            index != selection && filter.name.caseInsensitiveCompare(validName) == .orderedSame
        }
    }

    private static let sortKeys: [SortKey] = [.relevance, .name, .modified, .size]

    private var draft: QuickFilter {
        QuickFilter(name: validName, query: query, kind: kind, folder: folder,
                    volume: original?.volume, hiddenOnly: hiddenOnly,
                    fuzzyNames: fuzzyNames ? true : original?.fuzzyNames.map { _ in false },
                    sort: sortKey.map { .init(key: $0, ascending: ascending) })
    }

    private var canSave: Bool {
        let hasSearch = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil
            || folder != nil || hiddenOnly || original?.volume != nil
        return !validName.isEmpty && !duplicateName && draft != original && (original != nil || hasSearch)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: Binding(get: { selection }, set: select)) {
                    ForEach(Array(filters.enumerated()), id: \.offset) { index, filter in
                        Label(filter.name, systemImage: "line.3.horizontal.decrease.circle")
                            .lineLimit(1)
                            .help(filter.name)
                            .tag(index)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityLabel(L10n.text("settings.page.filters"))
                Button { select(nil) } label: {
                    Label(L10n.text("settings.filters.new"), systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .padding([.leading, .bottom], 12)
            }
            .frame(width: 156)
            Divider()
            Form {
                Section(original == nil ? L10n.text("settings.filters.new") : L10n.text("settings.filters.edit")) {
                    TextField(L10n.text("quickFilter.name"), text: $name)
                    TextField(L10n.text("settings.filters.query"), text: $query)
                        .font(.system(.body, design: .monospaced))
                }
                Section(L10n.text("settings.filters.criteria")) {
                    Picker(L10n.text("settings.filters.kind"), selection: $kind) {
                        Text(L10n.text("filter.all")).tag(nil as UInt8?)
                        ForEach(Array(FilterBar.names.dropFirst().enumerated()), id: \.offset) { index, name in
                            Text(L10n.text("filter." + name)).tag(UInt8(index + 1) as UInt8?)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("settings.filters.folder"))
                        Text(folder ?? L10n.text("settings.filters.anyFolder"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(folder ?? "")
                        HStack {
                            Button(L10n.text("settings.filters.chooseFolder"), action: chooseFolder)
                            if folder != nil {
                                Button(L10n.text("settings.filters.clearFolder")) { folder = nil }
                            }
                        }
                    }
                    if let volume = original?.volume {
                        LabeledContent(L10n.text("settings.filters.volume"), value: volume)
                    }
                    Toggle(L10n.text("scope.hiddenOnly"), isOn: $hiddenOnly)
                    Toggle(L10n.text("scope.fuzzyNames"), isOn: $fuzzyNames)
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
        .onAppear { if !filters.isEmpty { select(0) } }
        .onChange(of: storedFilters) { _, _ in
            guard let selection, let original else { return }
            let current = filters
            if !current.indices.contains(selection) || current[selection] != original {
                select(nil)
                conflict = true
            }
        }
    }

    private func select(_ index: Int?) {
        let current = filters
        selection = index.flatMap { current.indices.contains($0) ? $0 : nil }
        original = selection.map { current[$0] }
        name = original?.name ?? ""
        query = original?.query ?? ""
        kind = original?.kind
        folder = original?.folder
        hiddenOnly = original?.hiddenOnly ?? false
        fuzzyNames = original?.fuzzyNames ?? false
        sortKey = original?.sort?.key
        ascending = original?.sort?.ascending ?? false
        conflict = false
    }

    private func chooseFolder() {
        guard let window = window() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = folder.map { URL(fileURLWithPath: $0, isDirectory: true) }
        panel.beginSheetModal(for: window) { response in
            if response == .OK { folder = panel.url?.path }
        }
    }

    private func save() {
        guard canSave else { return }
        var current = filters
        if let selection {
            guard current.indices.contains(selection), current[selection] == original else { conflict = true; return }
            current[selection] = draft
            QuickFilter.save(current, to: preferences)
            select(selection)
        } else {
            current.append(draft)
            QuickFilter.save(current, to: preferences)
            select(current.count - 1)
        }
    }

    private func remove() {
        var current = filters
        guard let selection, current.indices.contains(selection), current[selection] == original else { conflict = true; return }
        current.remove(at: selection)
        QuickFilter.save(current, to: preferences)
        select(current.isEmpty ? nil : min(selection, current.count - 1))
    }
}
