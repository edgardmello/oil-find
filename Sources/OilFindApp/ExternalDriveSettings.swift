import AppKit
import SwiftUI

struct ExternalDriveSettings: View {
    @ObservedObject var catalog: ExternalDriveCatalog
    var window: () -> NSWindow?
    private func text(_ key: String, _ argument: String = "") -> String { L10n.text(key, argument) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(text("drivesEnabled"), isOn: Binding(get: { catalog.enabled }, set: catalog.setEnabled))
                .accessibilityIdentifier("external-drives.enabled")
            Text(text("drivesDescription")).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(text("settings.drives.autoNew"), isOn: Binding(get: { catalog.autoIndexNew }, set: catalog.setAutoIndexNew))
            Text(text("settings.drives.autoNewHelp")).font(.footnote).foregroundStyle(.secondary)
            if catalog.ready && catalog.rows.isEmpty {
                Text(text("drivesEmpty")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(catalog.rows) { row in
                HStack(spacing: 10) {
                    Image(nsImage: icon(row)).resizable().frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.record.name).lineLimit(1).truncationMode(.middle).help(row.record.path)
                        Text(status(row)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if row.status == .connected {
                        Button(text("settings.drives.reindex")) { catalog.reindex(row.id) }
                    }
                    Button(text("driveRemoveAction")) { catalog.confirmRemove(row, window: window()) }
                        .buttonStyle(.borderless)
                    Toggle(row.record.name, isOn: Binding(get: { row.record.enabled }, set: { catalog.setDriveEnabled(row.id, $0) }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .accessibilityIdentifier("external-drive." + row.id)
                .disabled(!catalog.enabled)
            }
        }
        .disabled(!catalog.ready)
    }
    private func icon(_ row: ExternalDriveCatalog.Row) -> NSImage {
        // Do not touch an offline path, which may now point at a different device.
        if row.status == .connected || row.status == .indexing {
            #if DEBUG
            if !catalog.snapshot { return NSWorkspace.shared.icon(forFile: row.record.path) }
            #else
            return NSWorkspace.shared.icon(forFile: row.record.path)
            #endif
        }
        return NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil) ?? NSImage()
    }
    private func status(_ row: ExternalDriveCatalog.Row) -> String {
        let locale = Locale(identifier: "en_US")
        switch row.status {
        case .connected, .indexing:
            let number = NumberFormatter(); number.locale = locale; number.numberStyle = .decimal
            return text(row.status == .connected ? "driveConnected" : "driveIndexing",
                        number.string(from: NSNumber(value: row.count)) ?? String(row.count))
        case .offline:
            let date = DateFormatter(); date.locale = locale; date.dateFormat = "MMM d"
            return text("driveOffline", date.string(from: row.record.lastConnected))
        case .disabled: return text("driveDisabled")
        }
    }
}
