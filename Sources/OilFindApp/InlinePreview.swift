import AppKit
import AVKit
import OilFindCore
import Quartz
import UniformTypeIdentifiers

final class InlinePreview: FlippedView, NSTableViewDataSource, NSTableViewDelegate {
    struct Folder: Equatable {
        let store: IndexStore
        let id: UInt32
        let version: UInt64
        let query: Query

        init(item: ResultItem, query: Query) {
            let store = item.source.store
            self.store = store
            id = item.id
            version = store.read { store.version }
            self.query = query
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.store === rhs.store && lhs.id == rhs.id && lhs.version == rhs.version && lhs.query.raw == rhs.query.raw
        }
    }
    private enum Status: String {
        case select, loading, unsupported, unavailable, emptyFolder
    }

    var onClose: (() -> Void)?
    var onFolderFileSelection: (() -> Void)?
    var onOpenFolderFile: ((URL) -> Void)?

    var selectedFolderFileURL: URL? { folderFileURL(at: folderTable.selectedRow) }
    /// The Search Window shows the preview as its own rounded card beside the results card.
    var card = false { didSet { needsLayout = true; needsDisplay = true } }
    private let icon = NSImageView()
    private let headerLine = SeparatorView()
    private let metadataLine = SeparatorView()
    private let metadataLabel = Theme.label(11, .regular, .secondaryLabelColor)
    private let titleLabel = Theme.label(12.5, .semibold, .labelColor)
    private let pathLabel = Theme.label(11, .regular, .secondaryLabelColor)
    private let closeButton = NSButton()
    private let divider = SeparatorView()
    private let message = Theme.label(12, .regular, .secondaryLabelColor)
    private let folderScroll = NSScrollView()
    private let folderTable = NSTableView()
    private var folder: Folder?
    private var folderNames: [String] = []
    private var metadata = ""
    private let folderGeneration = SearchGeneration()
    private let folderQueue = DispatchQueue(label: "com.oiloil.find.folderPreview", qos: .userInitiated)
    private var isLoadingFolder = false
    private var preview: QLPreviewView?
    private var playerView: AVPlayerView?
    private var reloadingFolder = false
    private var url: URL?
    private var generation = 0
    private var status: Status = .select
    private var pendingCheck: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        message.alignment = .center
        message.maximumNumberOfLines = 2
        message.cell?.usesSingleLineMode = false
        message.cell?.wraps = true
        message.lineBreakMode = .byWordWrapping
        addSubview(divider)
        addSubview(message)
        folderTable.headerView = nil
        folderTable.rowHeight = 24
        folderTable.backgroundColor = .clear
        folderTable.style = .plain
        folderTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        folderTable.addTableColumn(column)
        folderTable.dataSource = self
        folderTable.delegate = self
        folderTable.target = self
        folderTable.doubleAction = #selector(openFolderFile)
        folderScroll.documentView = folderTable
        folderScroll.drawsBackground = false
        folderScroll.hasVerticalScroller = true
        folderScroll.autohidesScrollers = true
        folderScroll.isHidden = true
        addSubview(folderScroll)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.lineBreakMode = .byTruncatingMiddle
        closeButton.isBordered = false
        closeButton.image = Theme.symbol("xmark", size: 11, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closePreview)
        [titleLabel, pathLabel, closeButton, headerLine, metadataLine, metadataLabel, icon].forEach(addSubview)
        localize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func closePreview() { onClose?() }

    func localize() {
        message.stringValue = L10n.text("inlinePreview." + status.rawValue)
        if url == nil { titleLabel.stringValue = L10n.text("hint.preview") }
        closeButton.toolTip = L10n.text("inlinePreview.hide") + " (⇧⌘P)"
        closeButton.setAccessibilityLabel(L10n.text("inlinePreview.hide"))
        folderTable.setAccessibilityLabel(L10n.text("inlinePreview.folderFiles"))
        folderTable.setAccessibilityHelp(L10n.text("inlinePreview.folderKeys"))
        updateMetadata()
    }

    private var contentFrame: NSRect {
        NSRect(x: 12, y: 70, width: max(0, bounds.width - 24), height: max(0, bounds.height - 116))
    }

    private var fileFrame: NSRect {
        let content = contentFrame
        guard selectedFolderFileURL != nil else { return content }
        let listHeight = min(floor(content.height * 0.45), CGFloat(folderNames.count) * folderTable.rowHeight + 4)
        let top = min(content.maxY, content.minY + listHeight + 8)
        return NSRect(x: content.minX, y: top, width: content.width, height: content.maxY - top)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard card else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: CompactFileTable.cardRadius, yRadius: CompactFileTable.cardRadius)
        Theme.card.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
    }

    override func layout() {
        super.layout()
        divider.isHidden = card
        icon.isHidden = !card || url == nil
        let textX: CGFloat = icon.isHidden ? 16 : 44
        icon.frame = NSRect(x: 14, y: 13, width: 24, height: 24)
        divider.frame = NSRect(x: 0, y: 0, width: Theme.pixel(self), height: bounds.height)
        titleLabel.frame = NSRect(x: textX, y: 12, width: max(0, bounds.width - textX - 46), height: 18)
        pathLabel.frame = NSRect(x: textX, y: 33, width: max(0, bounds.width - textX - 16), height: 15)
        closeButton.frame = NSRect(x: bounds.width - 38, y: 8, width: 28, height: 28)
        headerLine.frame = NSRect(x: 16, y: 58, width: max(0, bounds.width - 32), height: Theme.pixel(self))
        metadataLine.frame = NSRect(x: 16, y: max(58, bounds.height - 34), width: max(0, bounds.width - 32), height: Theme.pixel(self))
        metadataLabel.frame = NSRect(x: 16, y: max(64, bounds.height - 25), width: max(0, bounds.width - 32), height: 16)
        let content = contentFrame
        let file = fileFrame
        message.frame = NSRect(x: file.minX, y: file.midY - 18, width: file.width, height: 36)
        preview?.frame = file
        playerView?.frame = file
        let listHeight = selectedFolderFileURL == nil ? content.height : max(0, file.minY - content.minY - 8)
        folderScroll.frame = NSRect(x: content.minX, y: content.minY, width: content.width, height: listHeight)
        let width = folderScroll.contentSize.width
        if width > 0, folderTable.tableColumns[0].width != width { folderTable.tableColumns[0].width = width }
    }

    func update(url: URL?, folder: Folder? = nil, isUnavailable: Bool = false, metadata: String = "") {
        self.metadata = metadata
        if url != nil && url == self.url && self.folder == folder && !isUnavailable {
            updateMetadata()
            return
        }
        if let folder, let previous = self.folder, url == self.url, folder.id == previous.id,
           folder.store === previous.store, folder.query.raw == previous.query.raw {
            self.folder = folder
            loadFolder(folder)
            return
        }
        self.folder = folder
        _ = folderGeneration.next()
        isLoadingFolder = false
        reloadingFolder = true
        folderNames = []
        folderTable.reloadData()
        folderTable.deselectAll(nil)
        reloadingFolder = false
        folderScroll.contentView.scroll(to: .zero)
        folderScroll.reflectScrolledClipView(folderScroll.contentView)
        folderScroll.isHidden = true
        updateMetadata()
        self.url = url
        titleLabel.stringValue = url?.lastPathComponent ?? L10n.text("hint.preview")
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        needsLayout = true
        pathLabel.stringValue = url.map { Presentation.abbreviate(path: $0.deletingLastPathComponent().path, home: NSHomeDirectory()) } ?? ""
        titleLabel.toolTip = url?.lastPathComponent
        pathLabel.toolTip = url?.path
        clearFilePreview()
        message.isHidden = false

        if isUnavailable { show(.unavailable); return }
        guard let url else { show(.select); return }
        if let folder {
            isLoadingFolder = true
            show(.loading)
            loadFolder(folder)
            return
        }
        showFilePreview(url)
    }

    private func loadFolder(_ folder: Folder) {
        let generation = folderGeneration
        let token = generation.next()
        folderQueue.asyncAfter(deadline: .now() + .milliseconds(90)) { [weak self] in
            guard generation.current(token) else { return }
            let names = Searcher.folderPreviewFiles(folder.id, matching: folder.query, in: folder.store,
                                                   isCancelled: { !generation.current(token) })
            DispatchQueue.main.async { [weak self] in
                guard let self, generation.current(token) else { return }
                self.isLoadingFolder = false
                let selected = self.selectedFolderFileURL
                if self.folderNames != names {
                    self.reloadingFolder = true
                    self.folderNames = names
                    self.folderTable.reloadData()
                    self.folderTable.deselectAll(nil)
                    if let selected, let row = names.firstIndex(of: selected.lastPathComponent) {
                        self.selectFolderRow(row)
                    }
                    self.reloadingFolder = false
                }
                self.folderScroll.isHidden = names.isEmpty
                self.needsLayout = true
                if selected != self.selectedFolderFileURL || self.selectedFolderFileURL == nil {
                    self.updateFolderFilePreview()
                    if selected != nil { self.onFolderFileSelection?() }
                } else {
                    self.updateMetadata()
                }
            }
        }
    }

    private func clearFilePreview() {
        generation += 1
        pendingCheck?.cancel()
        pendingCheck = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        playerView?.player?.pause()
        playerView?.player = nil
        playerView?.removeFromSuperview()
        playerView = nil
    }

    private func showFilePreview(_ url: URL) {
        let type = UTType(filenameExtension: url.pathExtension)
        let isMedia = type.map { $0.conforms(to: .movie) || $0.conforms(to: .audio) } ?? false
        show(.loading)

        let token = generation
        // Give keyboard repeats time to settle before touching the selected file.
        let check = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.pendingCheck = nil
                    guard readable else { self.show(.unavailable); return }
                    if isMedia {
                        let playerView = AVPlayerView(frame: self.fileFrame)
                        playerView.controlsStyle = .inline
                        playerView.player = AVPlayer(url: url)
                        playerView.setAccessibilityLabel(url.lastPathComponent)
                        self.playerView = playerView
                        self.addSubview(playerView)
                    } else {
                        guard let preview = QLPreviewView(frame: self.fileFrame, style: .normal) else {
                            self.show(.unsupported); return
                        }
                        self.preview = preview
                        self.addSubview(preview)
                        preview.previewItem = url as NSURL
                    }
                    self.message.isHidden = true
                }
            }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: check)
    }

    private func updateMetadata() {
        let value = folder == nil || isLoadingFolder ? metadata
            : L10n.text("inlinePreview.fileCount", Presentation.countText(folderNames.count))
        metadataLabel.stringValue = value
        metadataLabel.toolTip = value.isEmpty ? nil : value
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folderNames.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("folderFile")
        let label = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? Theme.label(12, .regular, .labelColor)
        label.identifier = identifier
        label.lineBreakMode = .byTruncatingMiddle
        label.stringValue = folderNames[row]
        label.toolTip = folderNames[row]
        return label
    }

    private func folderFileURL(at row: Int) -> URL? {
        guard let url, folderNames.indices.contains(row) else { return nil }
        return url.appendingPathComponent(folderNames[row], isDirectory: false)
    }

    @discardableResult
    func enterFolderFiles() -> Bool {
        guard !isHidden, !folderNames.isEmpty else { return false }
        if selectedFolderFileURL == nil { selectFolderRow(0) }
        return true
    }

    func leaveFolderFiles() {
        guard selectedFolderFileURL != nil else { return }
        folderTable.deselectAll(nil)
    }

    func moveFolderFile(by delta: Int) {
        selectFolderRow(min(max(0, folderTable.selectedRow + delta), folderNames.count - 1))
    }

    private func selectFolderRow(_ row: Int) {
        guard folderNames.indices.contains(row) else { return }
        folderTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        folderTable.scrollRowToVisible(row)
    }

    func toggleFilePlayback() -> Bool {
        guard let player = playerView?.player else { return false }
        if player.rate == 0 { player.play() } else { player.pause() }
        return true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingFolder else { return }
        updateFolderFilePreview()
        onFolderFileSelection?()
    }

    private func updateFolderFilePreview() {
        clearFilePreview()
        needsLayout = true
        guard let file = selectedFolderFileURL else {
            message.isHidden = !folderNames.isEmpty
            show(.emptyFolder)
            return
        }
        message.isHidden = false
        showFilePreview(file)
    }

    @objc private func openFolderFile() {
        if let file = folderFileURL(at: folderTable.clickedRow) { onOpenFolderFile?(file) }
    }

    private func show(_ status: Status) {
        self.status = status
        localize()
    }
}
