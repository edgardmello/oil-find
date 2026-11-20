import AppKit
import OilFindCore
import Quartz
import UniformTypeIdentifiers

final class InlinePreview: FlippedView {
    private enum Status: String {
        case select, loading, unsupported, unavailable
    }

    var onClose: (() -> Void)?
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
    private var preview: QLPreviewView?
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
    }

    private var contentFrame: NSRect {
        NSRect(x: 12, y: 70, width: max(0, bounds.width - 24), height: max(0, bounds.height - 116))
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
        message.frame = NSRect(x: content.minX, y: content.midY - 18, width: content.width, height: 36)
        preview?.frame = content
    }

    func update(url: URL?, isDirectory: Bool = false, isUnavailable: Bool = false, metadata: String = "") {
        metadataLabel.stringValue = metadata
        metadataLabel.toolTip = metadata.isEmpty ? nil : metadata
        if url != nil && url == self.url && !isUnavailable { return }
        self.url = url
        titleLabel.stringValue = url?.lastPathComponent ?? L10n.text("hint.preview")
        icon.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        needsLayout = true
        pathLabel.stringValue = url.map { Presentation.abbreviate(path: $0.deletingLastPathComponent().path, home: NSHomeDirectory()) } ?? ""
        titleLabel.toolTip = url?.lastPathComponent
        pathLabel.toolTip = url?.path
        generation += 1
        pendingCheck?.cancel()
        pendingCheck = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        message.isHidden = false

        if isUnavailable { show(.unavailable); return }
        guard let url else { show(.select); return }
        guard !isDirectory, let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .text) else {
            show(.unsupported); return
        }
        show(.loading)

        let token = generation
        // Give keyboard repeats time to settle before touching the selected file.
        let check = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.pendingCheck = nil
                    guard readable, let preview = QLPreviewView(frame: self.contentFrame, style: .normal) else {
                        self.show(.unavailable); return
                    }
                    self.preview = preview
                    self.message.isHidden = true
                    self.addSubview(preview)
                    preview.previewItem = url as NSURL
                }
            }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: check)
    }

    private func show(_ status: Status) {
        self.status = status
        localize()
    }
}
