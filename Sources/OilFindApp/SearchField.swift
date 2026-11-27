import AppKit
import QuartzCore

final class SearchEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
    var onPointerSelection: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPointerSelection?()
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), handleKey?(event) == true { return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !hasMarkedText(), handleKey?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PassiveProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A borderless symbol button for the tools inside the Search Window's field.
final class FieldToolButton: NSButton {
    var onPress: ((NSView) -> Void)?
    var active = false { didSet { contentTintColor = active ? .controlAccentColor : .secondaryLabelColor } }
    init(symbol: String) {
        super.init(frame: .zero)
        isBordered = false; imagePosition = .imageOnly
        image = Theme.symbol(symbol, size: 13, weight: .regular)
        contentTintColor = .secondaryLabelColor
        target = self; action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    @objc private func pressed() { onPress?(self) }
}

final class SearchField: FlippedView, NSTextFieldDelegate {
    let input = NSTextField()
    let editor = SearchEditor()
    private let glass = NSImageView()
    private let clear = NSButton()
    private let expand = NSButton()
    var onExpand: (() -> Void)?
    var showExpand = false { didSet { expand.isHidden = !showExpand; updateAccessory(); needsLayout = true } }
    /// The Search Window draws the query inside a rounded field with its tools on the trailing edge.
    var boxed = false {
        didSet {
            guard boxed != oldValue else { return }
            glass.image = Theme.symbol("magnifyingglass", size: boxed ? 14 : 19, weight: .medium)
            trailingTools.forEach { $0.isHidden = !boxed }
            applyFont(); needsLayout = true; needsDisplay = true
        }
    }
    var trailingTools: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            trailingTools.forEach { $0.isHidden = !boxed; addSubview($0) }
            needsLayout = true
        }
    }
    private var fontSize: CGFloat { (boxed ? 14 : 21) * textScale }
    private func applyFont() {
        input.font = .systemFont(ofSize: fontSize)
        (input.currentEditor() as? NSTextView)?.font = input.font
        localize()
    }
    var boxRect: NSRect { NSRect(x: 46, y: (bounds.height - 32) / 2, width: max(0, bounds.width - 62), height: 32) }
    override func draw(_ dirtyRect: NSRect) {
        guard boxed else { return }
        let path = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.labelColor.withAlphaComponent(Theme.dark(self) ? 0.08 : 0.04).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(Theme.dark(self) ? 0.08 : 0.1).setStroke(); path.lineWidth = 1; path.stroke()
    }
    var textScale: CGFloat = 1 {
        didSet {
            input.font = .systemFont(ofSize: fontSize)
            (input.currentEditor() as? NSTextView)?.font = input.font
            localize()
            needsLayout = true
        }
    }
    private let progress = PassiveProgressIndicator()
    var placeholder: String? { didSet { if placeholder != oldValue { localize() } } }
    private var selectionObserver: NSObjectProtocol?
    private var clearVisible = false, progressVisible = false
    var onSelectionChange: (() -> Void)?
    var onChange: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var indexing = false { didSet { updateAccessory() } }
    var text: String {
        get { input.stringValue }
        set { input.stringValue = newValue; updateAccessory() }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.image = Theme.symbol("magnifyingglass", size: 19, weight: .medium)
        glass.contentTintColor = .secondaryLabelColor
        input.font = .systemFont(ofSize: 21); input.textColor = .labelColor
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.cell?.isScrollable = true; input.cell?.usesSingleLineMode = true
        input.lineBreakMode = .byClipping
        input.placeholderAttributedString = NSAttributedString(string: placeholder ?? L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
        input.delegate = self
        editor.isFieldEditor = true
        selectionObserver = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: editor, queue: .main) { [weak self] _ in self?.onSelectionChange?() }
        editor.handleKey = { [weak self] event in self?.onKey?(event) ?? false }
        clear.isBordered = false; clear.image = Theme.symbol("xmark.circle.fill", size: 15, weight: .regular)
        clear.contentTintColor = .tertiaryLabelColor; clear.target = self; clear.action = #selector(clearText)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        [clear, progress].forEach { $0.wantsLayer = true; $0.alphaValue = 0 }
        expand.isBordered = false
        expand.image = Theme.symbol("chevron.down", size: 14, weight: .medium)
        expand.target = self
        expand.action = #selector(expandPressed)
        expand.isHidden = true
        [glass, input, clear, progress, expand].forEach(addSubview)
        localize()
        updateAccessory()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func expandPressed() { onExpand?() }
    func localize() {
        clear.toolTip = L10n.text("search.clear")
        clear.setAccessibilityLabel(L10n.text("search.clear"))
        input.setAccessibilityLabel(L10n.text("placeholder"))
        expand.toolTip = L10n.text("settings.interface.expand")
        expand.setAccessibilityLabel(expand.toolTip)
        input.placeholderAttributedString = NSAttributedString(string: placeholder ?? L10n.text("placeholder"), attributes: [.font: input.font!, .foregroundColor: NSColor.placeholderTextColor])
    }
    override func layout() {
        super.layout()
        if boxed {
            let box = boxRect
            glass.frame = NSRect(x: 18, y: (bounds.height - 18) / 2, width: 18, height: 18)
            var right = box.maxX - 8
            for tool in trailingTools.reversed() {
                tool.frame = NSRect(x: right - 22, y: box.midY - 11, width: 22, height: 22)
                right -= 24
            }
            clear.frame = NSRect(x: right - 22, y: box.midY - 11, width: 22, height: 22)
            progress.frame = NSRect(x: right - 19, y: box.midY - 8, width: 16, height: 16)
            let textHeight = ceil(20 * textScale)
            setInputFrame(NSRect(x: box.minX + 10, y: box.midY - textHeight / 2, width: max(0, right - 26 - box.minX - 10), height: textHeight))
            expand.frame = .zero
            return
        }
        glass.frame = NSRect(x: 24, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let textHeight = ceil(29 * textScale)
        setInputFrame(NSRect(x: 58, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - (showExpand ? 136 : 112)), height: textHeight))
        expand.frame = NSRect(x: bounds.width - 42, y: (bounds.height - 24) / 2, width: 24, height: 24)
        clear.frame = NSRect(x: bounds.width - (showExpand ? 78 : 48), y: (bounds.height - 28) / 2, width: 28, height: 28)
        progress.frame = NSRect(x: bounds.width - (showExpand ? 68 : 44), y: (bounds.height - 16) / 2, width: 16, height: 16)
    }
    /// Resizing an NSTextField while it is being edited selects all of its text; keep the caret where it was.
    private func setInputFrame(_ frame: NSRect) {
        guard input.frame != frame else { return }
        let editing = input.currentEditor() as? NSTextView
        let selection = editing?.selectedRange()
        input.frame = frame
        if let editing, let selection, editing.selectedRange() != selection { editing.setSelectedRange(selection) }
    }
    func focus(selectAll: Bool = false) {
        window?.makeFirstResponder(input)
        if selectAll { input.selectText(nil) }
    }
    deinit { if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) } }
    func controlTextDidEndEditing(_ obj: Notification) { onSelectionChange?() }
    func controlTextDidChange(_ obj: Notification) { updateAccessory(); onChange?() }
    @objc private func clearText() { text = ""; focus(); onChange?() }
    private func accessory(_ view: NSView, visible: Bool) {
        let animate = window?.isVisible == true
        view.isHidden = false
        Theme.Motion.opacity(view, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        if let layer = view.layer {
            let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
            Theme.Motion.animate(layer, "transform.scale", to: visible ? 1 : Theme.Motion.accessoryScale, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
        }
    }
    private func updateAccessory() {
        let showClear = !text.isEmpty
        let showProgress = indexing && text.isEmpty
        if clearVisible != showClear { clearVisible = showClear; accessory(clear, visible: showClear) }
        clear.isEnabled = showClear
        if progressVisible != showProgress {
            progressVisible = showProgress
            if showProgress { progress.startAnimation(nil) }
            accessory(progress, visible: showProgress)
            if !showProgress {
                DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self] in
                    if self?.progressVisible == false { self?.progress.stopAnimation(nil) }
                }
            }
        }
    }
}
