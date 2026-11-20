import AppKit

/// The Search Window's filter strip: library filters as tiles, file-type filters on the left
/// ("Search only") and folder filters on the right ("Search inside").
final class FilterTileBar: FlippedView {
    static let height: CGFloat = 92
    private static let pitch: CGFloat = 85

    struct Tile {
        let filter: QuickFilter
        let key: Character?
        let modifiers: NSEvent.ModifierFlags
    }

    var onSelect: ((QuickFilter) -> Void)?
    var activeID: String? { didSet { if activeID != oldValue { views.forEach { $0.active = $0.tile.filter.linkID == activeID } } } }
    private(set) var tiles: [Tile] = []
    private var views: [FilterTileView] = []
    private let onlyTitle = FilterTileBar.sectionLabel()
    private let insideTitle = FilterTileBar.sectionLabel()
    private let onlyScroll = FilterTileBar.strip()
    private let insideScroll = FilterTileBar.strip()
    private let divider = SeparatorView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        [onlyTitle, insideTitle, onlyScroll, insideScroll, divider].forEach(addSubview)
        localize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func sectionLabel() -> NSTextField {
        let label = Theme.label(9.5, .semibold, .tertiaryLabelColor)
        return label
    }

    private static func strip() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.documentView = FlippedView()
        return scroll
    }

    func localize() {
        func caps(_ key: String) -> NSAttributedString {
            NSAttributedString(string: L10n.text(key).uppercased(), attributes: [.kern: 0.6, .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        onlyTitle.attributedStringValue = caps("tiles.searchOnly")
        insideTitle.attributedStringValue = caps("tiles.searchInside")
    }

    /// Rebuilds the tiles from the filter library; letters follow each filter's name, as in a menu,
    /// skipping any letter a panel shortcut already owns with the same modifiers.
    func setFilters(_ filters: [QuickFilter], reserved: (Character, NSEvent.ModifierFlags) -> Bool = { _, _ in false }) {
        var built: [Tile] = []
        for (group, modifiers) in [(QuickFilter.Group.quick, NSEvent.ModifierFlags.option), (.folder, [.shift, .option])] {
            var used = Set<Character>()
            for filter in filters where filter.group == group {
                let key = filter.name.lowercased().first { $0.isLetter && $0.isASCII && !used.contains($0) && !reserved($0, modifiers) }
                if let key { used.insert(key) }
                built.append(Tile(filter: filter, key: key, modifiers: modifiers))
            }
        }
        guard built.map(\.key) != tiles.map(\.key) || built.map(\.filter) != tiles.map(\.filter) else { return }
        tiles = built
        views.forEach { $0.removeFromSuperview() }
        views = tiles.map { tile in
            let view = FilterTileView(tile: tile)
            view.active = tile.filter.linkID == activeID
            view.onPress = { [weak self] in self?.onSelect?(tile.filter) }
            return view
        }
        needsLayout = true
    }

    /// ⌥ + letter picks a "Search only" tile, ⇧⌥ + letter a "Search inside" tile.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags == .option || flags == [.shift, .option],
              let typed = event.charactersIgnoringModifiers?.lowercased().first,
              let tile = tiles.first(where: { $0.key == typed && $0.modifiers == flags }) else { return false }
        onSelect?(tile.filter)
        return true
    }

    override func layout() {
        super.layout()
        let quick = views.filter { $0.tile.filter.group == .quick }
        let folder = views.filter { $0.tile.filter.group != .quick }
        let insideWidth = folder.isEmpty ? 0 : min(CGFloat(folder.count) * Self.pitch + 12, floor(bounds.width * 0.3))
        let onlyWidth = bounds.width - 16 - insideWidth - (folder.isEmpty ? 16 : 0)
        func place(_ tiles: [FilterTileView], in scroll: NSScrollView, title: NSTextField, x: CGFloat, width: CGFloat) {
            title.frame = NSRect(x: x + 6, y: 2, width: max(0, width - 12), height: 13)
            scroll.frame = NSRect(x: x, y: 18, width: max(0, width), height: bounds.height - 18)
            guard let document = scroll.documentView else { return }
            for (index, tile) in tiles.enumerated() {
                if tile.superview !== document { document.addSubview(tile) }
                tile.frame = NSRect(x: CGFloat(index) * Self.pitch, y: 0, width: Self.pitch, height: bounds.height - 22)
            }
            document.frame = NSRect(x: 0, y: 0, width: max(scroll.frame.width, CGFloat(tiles.count) * Self.pitch), height: scroll.frame.height)
        }
        place(quick, in: onlyScroll, title: onlyTitle, x: 16, width: onlyWidth)
        insideScroll.isHidden = folder.isEmpty; insideTitle.isHidden = folder.isEmpty; divider.isHidden = folder.isEmpty
        if !folder.isEmpty {
            divider.frame = NSRect(x: 16 + onlyWidth, y: 4, width: Theme.pixel(self), height: bounds.height - 12)
            place(folder, in: insideScroll, title: insideTitle, x: 16 + onlyWidth + 8, width: insideWidth - 8)
        }
    }
}

private final class FilterTileView: NSView {
    let tile: FilterTileBar.Tile
    var onPress: (() -> Void)?
    var active = false { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    init(tile: FilterTileBar.Tile) {
        self.tile = tile
        super.init(frame: .zero)
        toolTip = tile.filter.name + (keyText.isEmpty ? "" : " (" + keyText + ")")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tile.filter.name)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var keyText: String {
        guard let key = tile.key else { return "" }
        return "⌥" + (tile.modifiers.contains(.shift) ? "⇧" : "") + String(key).uppercased()
    }

    /// Each preset keeps its own hue; custom filters get a stable one from their name.
    private var tint: NSColor {
        let colors: [String: NSColor] = [
            "apps": .systemPink, "folders": .systemGreen, "images": .systemOrange, "videos": .systemBlue,
            "audio": .systemGreen, "documents": .systemOrange, "archives": .systemYellow, "code": .systemTeal,
            "config": .systemYellow, "pdf": .systemRed, "xcode": .systemBlue, "applications": .systemTeal,
            "home": .systemBlue, "home-documents": .systemRed, "icloud": .systemCyan, "cloud": .systemIndigo,
            "system": .systemGray
        ]
        if let id = tile.filter.presetID, let color = colors[id] { return color }
        let palette: [NSColor] = [.systemPink, .systemGreen, .systemOrange, .systemBlue, .systemTeal, .systemPurple, .systemYellow, .systemRed]
        let hash = tile.filter.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[hash % palette.count]
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.dark(self)
        let color = tint
        let square = NSRect(x: (bounds.width - 40) / 2, y: 6, width: 40, height: 40)
        let path = NSBezierPath(roundedRect: square, xRadius: 10, yRadius: 10)
        color.withAlphaComponent(active ? 0.45 : (hovered ? 0.3 : (dark ? 0.2 : 0.16))).setFill(); path.fill()
        (active ? NSColor.controlAccentColor : color.withAlphaComponent(dark ? 0.45 : 0.35)).setStroke()
        path.lineWidth = active ? 1.5 : 1; path.stroke()
        if let image = NSImage(systemSymbolName: tile.filter.icon, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .regular)) {
            let size = image.size
            let rect = NSRect(x: square.midX - size.width / 2, y: square.midY - size.height / 2, width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { frame in
                image.draw(in: frame); color.setFill(); frame.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: rect)
        }
        if !keyText.isEmpty {
            let font = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
            let width = Theme.textWidth(keyText, font: font) + 6
            let cap = NSRect(x: square.maxX - width + 8, y: 0, width: width, height: 13)
            (dark ? NSColor(white: 0.18, alpha: 0.95) : NSColor(white: 0.93, alpha: 0.95)).setFill()
            NSBezierPath(roundedRect: cap, xRadius: 3.5, yRadius: 3.5).fill()
            (keyText as NSString).draw(at: NSPoint(x: cap.minX + 3, y: cap.minY + 1), withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let title = NSAttributedString(string: tile.filter.name.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .kern: 0.5, .paragraphStyle: paragraph,
            .foregroundColor: active ? NSColor.controlAccentColor : (hovered ? NSColor.labelColor : NSColor.secondaryLabelColor)
        ])
        title.draw(in: NSRect(x: 2, y: square.maxY + 9, width: bounds.width - 4, height: 13))
    }
}
