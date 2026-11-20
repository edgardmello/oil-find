import AppKit

/// The Search Window's top strip: window buttons on the left, Pin and Quit on the right.
final class WindowTitleBar: FlippedView {
    static let height: CGFloat = 30
    var onClose: (() -> Void)?
    var onMinimize: (() -> Void)?
    var onZoom: (() -> Void)?
    var onPin: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Dragging the strip moves the window; a double-click puts it back in its default place.
    var onDragEnded: (() -> Void)?
    var onResetPosition: (() -> Void)?
    var pinned = false { didSet { pin.active = pinned } }
    private let lights = TrafficLights()
    private let pin = TitleTextButton(symbol: "pin", title: "")
    private let quit = TitleTextButton(symbol: "power", title: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        lights.onPress = { [weak self] index in
            switch index {
            case 0: self?.onClose?()
            case 1: self?.onMinimize?()
            default: self?.onZoom?()
            }
        }
        pin.onPress = { [weak self] in self?.onPin?() }
        quit.onPress = { [weak self] in self?.onQuit?() }
        [lights, pin, quit].forEach(addSubview)
        localize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 { onResetPosition?(); return }
        let start = NSEvent.mouseLocation, origin = window.frame.origin
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let now = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + now.x - start.x, y: origin.y + now.y - start.y))
            moved = true
        }
        if moved { onDragEnded?() }
    }

    func localize() {
        toolTip = L10n.text("titlebar.moveHelp")
        pin.title = L10n.text("titlebar.pin"); pin.toolTip = L10n.text("titlebar.pinHelp")
        quit.title = L10n.text("titlebar.quit"); quit.toolTip = L10n.text("titlebar.quitHelp")
        lights.titles = [L10n.text("titlebar.close"), L10n.text("titlebar.minimize"), L10n.text("titlebar.zoom")]
        needsLayout = true
    }

    override func layout() {
        super.layout()
        lights.frame = NSRect(x: 12, y: 8, width: 58, height: 14)
        var right = bounds.width - 12
        for button in [quit, pin] {
            let width = button.desiredWidth
            button.frame = NSRect(x: right - width, y: 7, width: width, height: 16)
            right -= width + 10
        }
    }
}

/// Close, minimize and zoom: grey at rest and coloured with glyphs on hover, like a window's own buttons.
private final class TrafficLights: NSView {
    var onPress: ((Int) -> Void)?
    var titles: [String] = [] { didSet { toolTip = nil; updateAccessibility() } }
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }

    private func rect(_ index: Int) -> NSRect { NSRect(x: 1 + CGFloat(index) * 20, y: 1, width: 12, height: 12) }

    private func updateAccessibility() {
        setAccessibilityElement(false)
        setAccessibilityChildren(titles.enumerated().map { index, title in
            let element = NSAccessibilityElement.element(withRole: .button, frame: rect(index), label: title, parent: self) as AnyObject
            return element
        })
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    // Keep the press here so the title bar does not start a window drag.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = (0..<3).first(where: { rect($0).insetBy(dx: -3, dy: -3).contains(point) }) { onPress?(index) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                                 NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                                 NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)]
        let glyphs = ["xmark", "minus", "arrow.up.left.and.arrow.down.right"]
        for index in 0..<3 {
            let circle = NSBezierPath(ovalIn: rect(index))
            (hovered ? colors[index] : NSColor.labelColor.withAlphaComponent(Theme.dark(self) ? 0.22 : 0.16)).setFill()
            circle.fill()
            guard hovered, let glyph = NSImage(systemSymbolName: glyphs[index], accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 7, weight: .bold)) else { continue }
            let size = glyph.size, box = rect(index)
            let tinted = NSImage(size: size, flipped: false) { frame in
                glyph.draw(in: frame); NSColor.black.withAlphaComponent(0.55).setFill(); frame.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

private final class TitleTextButton: NSButton {
    var onPress: (() -> Void)?
    var active = false { didSet { refresh() } }
    private let symbolName: String
    override var title: String { didSet { refresh() } }
    var desiredWidth: CGFloat { 14 + Theme.textWidth(title, font: font ?? .systemFont(ofSize: 11)) + 2 }

    init(symbol: String, title: String) {
        symbolName = symbol
        super.init(frame: .zero)
        isBordered = false; imagePosition = .imageLeading; imageHugsTitle = true
        font = .systemFont(ofSize: 11)
        target = self; action = #selector(pressed)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?() }
    private func refresh() {
        let color: NSColor = active ? .controlAccentColor : .tertiaryLabelColor
        image = Theme.symbol(active ? symbolName + ".fill" : symbolName, size: 9.5, weight: .regular)
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 11), .foregroundColor: color])
        setAccessibilityLabel(title)
        setAccessibilityValue(active ? 1 : 0)
    }
}
