import SwiftUI

struct FileContentSettings: View {
    let manager: FileContentManager
    @State private var enabled: Bool
    @State private var semanticEnabled: Bool
    @State private var count: Int = 0

    init(manager: FileContentManager) {
        self.manager = manager
        _enabled = State(initialValue: manager.isEnabled)
        _semanticEnabled = State(initialValue: manager.isSemanticEnabled)
    }

    private func text(_ key: String, _ value: String? = nil) -> String {
        value.map { L10n.text(key, $0) } ?? L10n.text(key)
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                Toggle(text("contentSearchEnabled"), isOn: Binding(
                    get: { enabled },
                    set: {
                        enabled = $0
                        manager.setEnabled($0)
                        refreshCount()
                    }
                ))
                Text(text("contentSearchHint"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if enabled {
                Toggle(text("contentSemanticEnabled"), isOn: Binding(
                    get: { semanticEnabled },
                    set: {
                        semanticEnabled = $0
                        manager.setSemanticEnabled($0)
                    }
                ))
                .padding(.vertical, 3)

                HStack {
                    Text(text("contentIndexedCount", String(count)))
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(text("contentReindex")) {
                        manager.reindex()
                        refreshCount()
                    }
                }
            }
        }
        .onAppear {
            refreshCount()
        }
    }

    private func refreshCount() {
        count = manager.totalIndexedCount()
    }
}
