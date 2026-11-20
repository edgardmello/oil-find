import AppKit

enum CompactFileTable {
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 28
    static let inset: CGFloat = 12
    static let iconWidth: CGFloat = 44
    static let keys = ["name", "path", "size", "date"]

    // Keep the path wider than the name and reserve room for size and date on narrow panels.
    static func widths(for width: CGFloat) -> [CGFloat] {
        let available = max(0, width - iconWidth)
        let date = min(220, floor(available * 0.27))
        let size = min(150, floor(available * 0.14))
        let name = floor((available - date - size) * 0.42)
        return [name, available - date - size - name, size, date]
    }

    static func date(_ date: Date) -> String {
        englishDate.string(from: date)
    }

    private static func formatter(locale: String, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.dateFormat = format
        return formatter
    }

    private static let englishDate = formatter(locale: "en_US_POSIX", format: "dd MMM yyyy 'at' HH:mm")
}

final class CompactFileHeader: NSTableHeaderView {
    private let isStash: Bool
    var actionsMenu: (() -> NSMenu?)?

    init(stash: Bool) {
        isStash = stash
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: CompactFileTable.headerHeight))
        setAccessibilityLabel(L10n.text(stash ? "panel.openStashWindow" : "view.compact"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let badge = NSRect(x: 20, y: 7, width: 14, height: 14)
        (isStash ? NSColor.systemPink : .secondaryLabelColor).setFill()
        NSBezierPath(ovalIn: badge).fill()
        let symbol = isStash ? "archivebox" : "line.3.horizontal.decrease"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let rect = NSRect(x: badge.midX - 4, y: badge.midY - 4, width: 8, height: 8)
            let tinted = NSImage(size: image.size, flipped: false) { frame in
                image.draw(in: frame)
                NSColor.white.setFill()
                frame.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: rect)
        }

        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        var x = CompactFileTable.iconWidth
        for (key, width) in zip(CompactFileTable.keys, CompactFileTable.widths(for: bounds.width)) {
            NSColor.separatorColor.setFill()
            NSRect(x: x, y: 6, width: 1, height: 16).fill()
            let title = L10n.text("stash.column." + key)
            (title as NSString).draw(in: NSRect(x: x + 8, y: 7, width: max(0, width - 12), height: 15), withAttributes: attributes)
            x += width
        }
    }

    // The headings describe the columns. Sorting continues to use the panel's sort controls.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x < CompactFileTable.iconWidth, let menu = actionsMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func resetCursorRects() {}
}
