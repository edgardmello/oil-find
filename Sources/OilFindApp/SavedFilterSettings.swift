import SwiftUI

struct SavedFilterSettings: View {
    private let preferences: UserDefaults
    @AppStorage(QuickFilter.storageKey) private var storedFilters: Data?
    @State private var selection: Int?
    @State private var original: QuickFilter?
    @State private var name = ""
    @State private var query = ""
    @State private var conflict = false

    init(preferences: UserDefaults) {
        self.preferences = preferences
        _storedFilters = AppStorage(QuickFilter.storageKey, store: preferences)
    }

    private var filters: [QuickFilter] { QuickFilter.load(from: preferences) }
    private var validName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicateName: Bool {
        filters.enumerated().contains { index, filter in
            index != selection && filter.name.caseInsensitiveCompare(validName) == .orderedSame
        }
    }

    private var changed: Bool { original?.name != validName || original?.query != query }

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
                Section {
                    HStack {
                        if original != nil {
                            Button(L10n.text("settings.filters.remove"), role: .destructive, action: remove)
                        }
                        Spacer()
                        Button(L10n.text("quickFilter.saveButton"), action: save)
                            .disabled(validName.isEmpty || duplicateName || !changed || (original == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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
        conflict = false
    }

    private func save() {
        guard !validName.isEmpty, !duplicateName else { return }
        var current = filters
        if let selection, var filter = original {
            guard current.indices.contains(selection), current[selection] == filter else { conflict = true; return }
            filter.name = validName
            filter.query = query
            current[selection] = filter
            QuickFilter.save(current, to: preferences)
            select(selection)
        } else {
            current.append(QuickFilter(name: validName, query: query, kind: nil, folder: nil, volume: nil, hiddenOnly: false))
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
