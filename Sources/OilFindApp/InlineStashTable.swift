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
    private let compactHeader = CompactFileHeader(stash: true)
    private let icons = IconProvider()
    var onClear: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    private var files: [StashedFile] = []
    private var metadata: [UUID: Metadata] = [:]
    private var generation = 0
    private var loading = false
    private let queue = DispatchQueue(label: "com.oiloil.find.stashTable", qos: .utility)
    var onRemove: ((Set<UUID>) -> Void)?
    var onOpen: (() -> Void)?
    var onDragging: ((Bool) -> Void)?
    var shortcutPreferences: UserDefaults = .standard
    weak var menuDelegate: NSMenuDelegate?
    var desiredHeight: CGFloat { files.isEmpty ? 0 : CompactFileTable.headerHeight + CGFloat(min(files.count, 6)) * CompactFileTable.rowHeight }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .controlBackgroundColor
        scrollerStyle = .overlay
        wantsLayer = true
        layer?.cornerRadius = CompactFileTable.inset
        layer?.masksToBounds = true
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = CompactFileTable.rowHeight
        table.headerView = compactHeader
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.gridColor = .separatorColor
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.autoresizingMask = [.width]
        for key in CompactFileTable.keys {
            let column = NSTableColumn(identifier: .init(key))
            column.minWidth = 0
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.menuForSelection = { [weak self] in self?.makeMenu() }
        compactHeader.actionsMenu = { [weak self] in self?.makeStashMenu() }
        documentView = table
        localize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        var widths = CompactFileTable.widths(for: contentSize.width)
        widths[0] += CompactFileTable.iconWidth
        for (column, width) in zip(table.tableColumns, widths) where column.width != width {
            column.width = width
        }
    }

    func localize() {
        compactHeader.needsDisplay = true
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

    func revealAddedFiles(_ count: Int) {
        guard count > 0, count <= files.count else { return }
        table.scrollRowToVisible(files.count - count)
    }

    private var selection: [StashedFile] { table.selectedRowIndexes.compactMap { files.indices.contains($0) ? files[$0] : nil } }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        let file = files[row]
        let details = metadata[file.id]
        let url = details?.url ?? URL(fileURLWithPath: file.path)
        let label = NSTextField(labelWithString: "")
        let key = column.identifier.rawValue
        label.font = key == "size" || key == "date" ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: key == "name" ? 12 : 11)
        label.lineBreakMode = .byTruncatingMiddle
        switch column.identifier.rawValue {
        case "path": label.stringValue = Presentation.abbreviate(path: url.deletingLastPathComponent().path, home: NSHomeDirectory())
        case "size": label.stringValue = details?.size.map { Presentation.sizeText(UInt64(max(0, $0))) } ?? "—"
        case "date": label.stringValue = details?.date.map { CompactFileTable.date($0) } ?? "—"
        default:
            label.stringValue = !loading && details == nil ? L10n.text("stash.unavailable", url.lastPathComponent) : url.lastPathComponent
        }
        label.textColor = key == "path" || (!loading && details == nil) ? .secondaryLabelColor : .labelColor
        label.toolTip = url.path
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: key == "name" ? CompactFileTable.iconWidth + 8 : 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        if key == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = icons.icon(name: url.lastPathComponent, path: url.path, flags: 0, kind: 0, resolveFileIcon: false) { _ in }
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
            ])
        }
        return cell
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

    func handleKey(_ event: NSEvent, action: StashShortcut?) -> Bool? {
        guard !isHidden, window?.firstResponder === table else { return nil }
        switch action {
        case .copyPath: performStashAction(2); return true
        case .copyName: performStashAction(9); return true
        case .selectAll: table.selectAll(nil); return true
        case .open, .reveal:
            if !event.isARepeat { performStashAction(action == .reveal ? 1 : 0) }
            return true
        case .remove:
            if !event.isARepeat { performStashAction(5) }
            return true
        case .trash: return true
        case .up, .down, .extendUp, .extendDown, .pageUp, .pageDown, .home, .end, .first, .last:
            return false
        default: return nil
        }
    }

    private func makeStashMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        menu.autoenablesItems = false
        for (tag, key) in ["panel.copyStash", "panel.openStashWindow"].enumerated() {
            let item = menu.addItem(withTitle: L10n.text(key, String(files.count)), action: #selector(stashHeaderAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
        }
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: L10n.text("stash.removeSelection"), action: #selector(stashMenuAction(_:)), keyEquivalent: "")
        remove.target = self
        remove.tag = 5
        StashShortcut.remove.chord(in: shortcutPreferences).apply(to: remove)
        remove.isEnabled = !selection.isEmpty
        let clear = menu.addItem(withTitle: L10n.text("stash.clear"), action: #selector(stashHeaderAction(_:)), keyEquivalent: "")
        clear.target = self
        clear.tag = 2
        StashShortcut.clearStash.chord(in: shortcutPreferences).apply(to: clear)
        return menu
    }

    @objc private func stashHeaderAction(_ item: NSMenuItem) {
        switch item.tag {
        case 0: onCopyAll?()
        case 1: onOpenWindow?()
        case 2: onClear?()
        default: break
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = menuDelegate
        for (index, key) in ["ctx.open", "ctx.reveal", "ctx.copyFiles", "ctx.copyPaths", "ctx.copyNames", "stash.removeSelection"].enumerated() {
            if index == 2 || index == 5 { menu.addItem(.separator()) }
            if index == 3 || index == 4 {
                FileClipboardFormat.addMenu(to: menu, titleKey: key,
                                            target: self, action: #selector(stashMenuAction(_:)),
                                            baseTag: index == 3 ? 6 : 9)
                continue
            }
            let item = menu.addItem(withTitle: L10n.text(key), action: #selector(stashMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            if index == 5 { StashShortcut.remove.chord(in: shortcutPreferences).apply(to: item) }
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
        case 5: onRemove?(Set(files.map(\.id)))
        case 6...11:
            let paths = files.map { metadata[$0.id]?.url.path ?? $0.path }
            let values = action < 9 ? paths : paths.map { ($0 as NSString).lastPathComponent }
            FileClipboardFormat(rawValue: action % 3)?.copy(values)
        default: break
        }
    }
}
