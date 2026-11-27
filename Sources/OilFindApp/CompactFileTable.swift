import AppKit

enum CompactFileTable {
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 28
    static let inset: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let iconWidth: CGFloat = 44
    static let keys = ["name", "path", "size", "date"]

    // Keep the path wider than the name and reserve room for size and date on narrow panels.
    static func widths(for width: CGFloat, proportions: [CGFloat]? = nil) -> [CGFloat] {
        let available = max(0, width - iconWidth)
        if let proportions { return proportions.map { $0 * available } }
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
    var onResize: (([CGFloat]) -> Void)?
    var onFinishResize: (() -> Void)?
    var proportions: [CGFloat]? { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }

    private var columnWidths: [CGFloat] { CompactFileTable.widths(for: bounds.width, proportions: proportions) }
    private var drag: (index: Int, x: CGFloat, widths: [CGFloat])?

    private func dividerRects() -> [NSRect] {
        var x = CompactFileTable.iconWidth
        return columnWidths.dropLast().map { width in
            x += width
            return NSRect(x: x - 4, y: 0, width: 8, height: bounds.height)
        }
    }

    init(stash: Bool) {
        isStash = stash
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: CompactFileTable.headerHeight))
        setAccessibilityLabel(L10n.text(stash ? "panel.openStashWindow" : "view.compact"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.card.setFill()
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
        for (key, width) in zip(CompactFileTable.keys, columnWidths) {
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
        if onResize != nil, let divider = dividerRects().firstIndex(where: { $0.contains(point) }) {
            drag = (divider, point.x, columnWidths)
            return
        }
        guard point.x < CompactFileTable.iconWidth, let menu = actionsMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        var widths = drag.widths
        let left = widths[drag.index], right = widths[drag.index + 1]
        let delta = convert(event.locationInWindow, from: nil).x - drag.x
        let change = min(max(delta, min(64, left) - left), right - min(64, right))
        widths[drag.index] += change
        widths[drag.index + 1] -= change
        let total = widths.reduce(0, +)
        if total > 0 { onResize?(widths.map { $0 / total }) }
    }

    override func mouseUp(with event: NSEvent) {
        if drag != nil { onFinishResize?() }
        drag = nil
    }

    override func resetCursorRects() {
        guard onResize != nil else { return }
        for rect in dividerRects() { addCursorRect(rect, cursor: .resizeLeftRight) }
    }
}
