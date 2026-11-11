import AppKit
import OilFindCore

final class StashWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let stash: FileStash
    private let preferences: UserDefaults
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let copy = NSButton()
    private let remove = NSButton()
    private let clear = NSButton()
    private var displayedFiles: [StashedFile] = []
    private var urls: [UUID: URL] = [:]
    private var generation = 0
    private var resolving = false
    private var copying = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(stash: FileStash, preferences: UserDefaults = .standard) {
        self.stash = stash
        self.preferences = preferences
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.minSize = NSSize(width: 350, height: 220)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.autoresizingMask = [.width]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for (button, action) in [(copy, #selector(copyFiles)), (remove, #selector(removeFiles)), (clear, #selector(clearFiles))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
        }
        copy.keyEquivalent = "c"
        copy.keyEquivalentModifierMask = .command
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [status, clear, remove, copy])
        footer.spacing = 8
        footer.alignment = .centerY
        let content = NSView()
        panel.contentView = content
        for view in [scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])

        stash.onChange = { [weak self] in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append((workspace, workspace.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.window?.isVisible == true else { return }
                self.refresh()
            }))
        }
        localize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { observers.forEach { center, token in center.removeObserver(token) } }

    func present() {
        localize()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if !resolving { refresh() }
    }

    private func localize() {
        window?.title = L10n.text("stash.title")
        copy.title = L10n.text("stash.copy")
        clear.title = L10n.text("stash.clear")
        let clearChord = StashShortcut.clearStash.chord(in: preferences)
        clear.keyEquivalent = Shortcut.keyEquivalent(clearChord.keyCode)
        clear.keyEquivalentModifierMask = HotKey.modifierFlags(clearChord.modifiers)
        remove.title = L10n.text("stash.remove")
        let chord = StashShortcut.remove.chord(in: preferences)
        remove.keyEquivalent = Shortcut.keyEquivalent(chord.keyCode)
        remove.keyEquivalentModifierMask = HotKey.modifierFlags(chord.modifiers)
        remove.toolTip = L10n.text("stash.removeSelection") + " (" + StashShortcut.remove.symbols(in: preferences) + ")"
        updateButtons()
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }

    private func refresh() {
        generation += 1
        let token = generation
        let selected = Set(selectedFiles.map(\.id))
        let files = stash.files
        displayedFiles = files
        urls = [:]
        resolving = !files.isEmpty
        table.reloadData()
        table.selectRowIndexes(IndexSet(files.indices.filter { selected.contains(files[$0].id) }), byExtendingSelection: false)
        updateButtons()
        guard resolving else { return }
        stash.resolve(files) { [weak self] urls in
            guard let self, self.generation == token else { return }
            self.urls = urls
            self.resolving = false
            self.table.reloadData()
            self.updateButtons()
        }
    }

    private var selectedFiles: [StashedFile] {
        table.selectedRowIndexes.compactMap { displayedFiles.indices.contains($0) ? displayedFiles[$0] : nil }
    }

    private var filesToCopy: [StashedFile] {
        let selected = selectedFiles
        return selected.isEmpty ? displayedFiles : selected
    }

    private func updateButtons() {
        copy.isEnabled = !resolving && !copying && filesToCopy.contains { urls[$0.id] != nil }
        remove.isEnabled = !selectedFiles.isEmpty
        clear.isEnabled = !stash.files.isEmpty
        if stash.files.isEmpty { status.stringValue = L10n.text("stash.empty") }
        else if resolving { status.stringValue = L10n.text("stash.checking") }
        else if urls.count < stash.files.count {
            status.stringValue = L10n.text("stash.someUnavailable", String(stash.files.count - urls.count))
        } else { status.stringValue = "" }
    }

    @objc private func copyFiles() {
        guard copy.isEnabled else { return }
        let files = filesToCopy
        copying = true
        updateButtons()
        stash.resolve(files) { [weak self] urls in
            guard let self else { return }
            self.copying = false
            let current = Set(self.stash.files.map(\.id))
            let available = files.compactMap { current.contains($0.id) ? urls[$0.id] : nil }
            self.updateButtons()
            guard !available.isEmpty else { self.refresh(); return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.writeObjects(available.map { $0 as NSURL }) {
                self.status.stringValue = L10n.text("stash.copied", String(available.count))
            }
        }
    }

    @objc private func clearFiles() { stash.clear() }

    @objc private func removeFiles() {
        stash.remove(Set(selectedFiles.map(\.id)))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedFiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("stashPath")
        let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        let file = displayedFiles[row]
        let path = urls[file.id]?.path ?? file.path
        let unavailable = !resolving && urls[file.id] == nil
        label.identifier = identifier
        label.stringValue = unavailable ? L10n.text("stash.unavailable", path) : path
        label.toolTip = path
        label.textColor = unavailable ? .secondaryLabelColor : .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard displayedFiles.indices.contains(row), let url = urls[displayedFiles[row].id] else { return nil }
        return url as NSURL
    }
}
