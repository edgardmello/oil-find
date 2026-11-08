import AppKit
import OilFindCore

private final class StashTableView: NSTableView {
    var menuForSelection: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return menuForSelection?()
    }
}

final class InlineStashTable: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private struct Metadata {
        let url: URL
        let size: Int?
        let date: Date?
    }

    private let table = StashTableView()
    private var files: [StashedFile] = []
    private var metadata: [UUID: Metadata] = [:]
    private var generation = 0
    private var loading = false
    private let queue = DispatchQueue(label: "com.oiloil.find.stashTable", qos: .utility)
    var onRemove: ((Set<UUID>) -> Void)?
    var onOpen: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    weak var menuDelegate: NSMenuDelegate?
    var desiredHeight: CGFloat { files.isEmpty ? 0 : 24 + CGFloat(min(files.count, 6)) * 22 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        table.rowHeight = 22
        table.headerView = NSTableHeaderView()
        table.intercellSpacing = .zero
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        for (key, width, minimum) in [("name", 240.0, 95.0), ("path", 240.0, 80.0), ("size", 84.0, 56.0), ("date", 160.0, 105.0)] {
            let column = NSTableColumn(identifier: .init(key))
            column.width = width
            column.minWidth = minimum
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menuForSelection = { [weak self] in self?.makeMenu() }
        documentView = table
        localize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func localize() {
        for column in table.tableColumns { column.title = L10n.text("stash.column." + column.identifier.rawValue) }
        table.reloadData()
    }

    func update(_ files: [StashedFile], visible: Bool) {
        localize()
        let next = visible ? files : []
        guard next.map(\.id) != self.files.map(\.id) else { return }
        let selected = Set(selection.map(\.id))
        generation += 1
        let token = generation
        self.files = next
        let retained = Set(next.map(\.id))
        metadata = metadata.filter { retained.contains($0.key) }
        loading = !next.isEmpty
        table.reloadData()
        table.selectRowIndexes(IndexSet(next.indices.filter { selected.contains(next[$0].id) }), byExtendingSelection: false)
        guard loading else { return }
        queue.async { [weak self] in
            var resolved: [UUID: Metadata] = [:]
            for file in next {
                guard let url = file.reachableURL() else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                resolved[file.id] = Metadata(url: url, size: values?.isDirectory == true ? nil : values?.fileSize,
                                             date: values?.contentModificationDate)
            }
            let snapshot = resolved
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.metadata = snapshot
                self.loading = false
                self.table.reloadData()
            }
        }
    }

    private var selection: [StashedFile] { table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil } }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let file = files[row]
        let details = metadata[file.id]
        let url = details?.url ?? URL(fileURLWithPath: file.path)
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingMiddle
        switch column.identifier.rawValue {
        case "path": label.stringValue = Presentation.abbreviate(path: url.deletingLastPathComponent().path, home: NSHomeDirectory())
        case "size": label.stringValue = details?.size.map { Presentation.sizeText(UInt64(max(0, $0))) } ?? "—"
        case "date": label.stringValue = details?.date.map { Presentation.dateText($0, now: Date(), calendar: .current, chinese: L10n.chinese) } ?? "—"
        default:
            label.stringValue = !loading && details == nil ? L10n.text("stash.unavailable", url.lastPathComponent) : url.lastPathComponent
        }
        label.textColor = details == nil ? .secondaryLabelColor : .labelColor
        label.toolTip = url.path
        return label
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard files.indices.contains(row), let url = metadata[files[row].id]?.url else { return nil }
        return url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        onDragging?(true)
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragging?(false)
    }

    func handleKey(_ event: NSEvent) -> Bool? {
        guard !isHidden, window?.firstResponder === table else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": performStashAction(2); return true
            case "a": table.selectAll(nil); return true
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !event.isARepeat { performStashAction(modifiers.contains(.command) ? 1 : 0) }
            return true
        }
        if event.keyCode == 51, modifiers.contains(.command) { return true }
        if modifiers.isEmpty || modifiers == .shift, [115, 116, 119, 121, 125, 126].contains(event.keyCode) { return false }
        return nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = menuDelegate
        for (index, key) in ["ctx.open", "ctx.reveal", "ctx.copyFiles", "ctx.copyPath", "ctx.copyName", "stash.remove"].enumerated() {
            if index == 2 || index == 5 { menu.addItem(.separator()) }
            let item = menu.addItem(withTitle: L10n.text(key), action: #selector(stashMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = index >= 3 || selection.allSatisfy { metadata[$0.id] != nil }
        }
        return menu
    }

    @objc private func stashMenuAction(_ item: NSMenuItem) { performStashAction(item.tag) }

    private func performStashAction(_ action: Int) {
        let files = selection
        guard !files.isEmpty else { return }
        let available = files.compactMap { metadata[$0.id]?.url }
        switch action {
        case 0:
            guard available.count == files.count else { return }
            onOpen?()
            for url in available { NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil) }
        case 1:
            guard available.count == files.count else { return }
            onOpen?()
            NSWorkspace.shared.activateFileViewerSelecting(available)
        case 2:
            guard available.count == files.count else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(available.map { $0 as NSURL })
        case 3, 4:
            let paths = files.map { metadata[$0.id]?.url.path ?? $0.path }
            let text = action == 3 ? paths : paths.map { ($0 as NSString).lastPathComponent }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text.joined(separator: "\n"), forType: .string)
        case 5: onRemove?(Set(files.map(\.id)))
        default: break
        }
    }
}
