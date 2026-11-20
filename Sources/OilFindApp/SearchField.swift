import AppKit
import QuartzCore

final class SearchEditor: NSTextView {
    var handleKey: ((NSEvent) -> Bool)?
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

final class SearchField: FlippedView, NSTextFieldDelegate {
    let input = NSTextField()
    let editor = SearchEditor()
    private let glass = NSImageView()
    private let clear = NSButton()
    private let expand = NSButton()
    var onExpand: (() -> Void)?
    var showExpand = false { didSet { expand.isHidden = !showExpand; updateAccessory(); needsLayout = true } }
    var textScale: CGFloat = 1 {
        didSet {
            input.font = .systemFont(ofSize: 21 * textScale)
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
        glass.frame = NSRect(x: 24, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let textHeight = ceil(29 * textScale)
        input.frame = NSRect(x: 58, y: (bounds.height - textHeight) / 2, width: max(0, bounds.width - (showExpand ? 136 : 112)), height: textHeight)
        expand.frame = NSRect(x: bounds.width - 42, y: (bounds.height - 24) / 2, width: 24, height: 24)
        clear.frame = NSRect(x: bounds.width - (showExpand ? 78 : 48), y: (bounds.height - 28) / 2, width: 28, height: 28)
        progress.frame = NSRect(x: bounds.width - (showExpand ? 68 : 44), y: (bounds.height - 16) / 2, width: 16, height: 16)
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
