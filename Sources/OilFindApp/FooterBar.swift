import AppKit
import QuartzCore
import OilFindCore

private final class KeyHint: FlippedView {
    var key: String { didSet { needsLayout = true; needsDisplay = true } }
    private let label = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private let keyFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    private var capWidth: CGFloat { max(18, Theme.textWidth(key, font: keyFont) + 10) }
    var desiredWidth: CGFloat { capWidth + 5 + Theme.textWidth(label.stringValue, font: label.font!) + 4 }
    func localize(_ text: String) { label.stringValue = text; needsLayout = true }
    init(_ key: String, _ text: String) {
        self.key = key; super.init(frame: .zero); label.stringValue = text; addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); label.frame = NSRect(x: capWidth + 5, y: 1, width: desiredWidth - capWidth - 5, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: capWidth, height: 18), xRadius: 5, yRadius: 5).fill()
        let size = (key as NSString).size(withAttributes: [.font: keyFont])
        (key as NSString).draw(at: NSPoint(x: (capWidth - size.width) / 2, y: (18 - size.height) / 2), withAttributes: [.font: keyFont, .foregroundColor: NSColor.secondaryLabelColor])
    }
}

final class FooterBar: FlippedView {
    private let toast = Theme.label(11.5, .regular, .labelColor)
    private var toastTimer: Timer?
    private var toastContent: (ToastKind, String)?
    private let status = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private let hints = [KeyHint("↩", L10n.text("hint.open")), KeyHint("⌘Y", L10n.text("hint.preview"))]
    private let settings = SettingsButton()
    private let actions = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private let stash = ChromeButton("", style: .plain, size: 12, weight: .medium)
    var onActions: ((NSView) -> Void)?
    var onStash: (() -> Void)?
    var stashCount = 0 { didSet { refreshButtons() } }

    private func refreshButtons() {
        actions.title = L10n.text("panel.actions")
        stash.title = L10n.text("panel.stashCount", String(stashCount))
        actions.setAccessibilityLabel(actions.title)
        stash.setAccessibilityLabel(stash.title)
        actions.toolTip = actions.title + " (" + actionsKey + ")"
        needsLayout = true
    }
    private let inlinePreview = NSButton(frame: .zero)
    var onInlinePreview: (() -> Void)?
    var inlinePreviewVisible = false {
        didSet { updateInlinePreviewButton() }
    }
    var onSettings: (() -> Void)?
    private let syntax = KeyHint("⌘/", L10n.text("hint.syntax"))
    var fileActions = true { didSet { needsLayout = true } }
    var spacePreview = false { didSet { updatePreviewKey() } }
    private var actionsKey = "⌘K"
    private var configuredPreviewKey = "⌘Y"
    var previewKey: String { spacePreview ? L10n.text("hint.space") : configuredPreviewKey }

    func updateShortcuts(in preferences: UserDefaults) {
        actionsKey = StashShortcut.actions.symbols(in: preferences)
        configuredPreviewKey = StashShortcut.preview.symbols(in: preferences)
        hints[0].key = StashShortcut.open.symbols(in: preferences)
        syntax.key = StashShortcut.syntax.symbols(in: preferences)
        updatePreviewKey()
        refreshButtons()
    }
    private func updatePreviewKey() { hints[1].key = previewKey; needsLayout = true }
    var warning = false { didSet { status.textColor = warning ? .systemOrange : .tertiaryLabelColor; needsLayout = true } }
    var text: String { get { status.stringValue } set { status.stringValue = newValue } }
    var actionable = false { didSet { hints.forEach { $0.isHidden = !actionable }; needsLayout = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        status.wantsLayer = true; toast.wantsLayer = true; toast.alphaValue = 0
        toast.lineBreakMode = .byTruncatingMiddle
        addSubview(status); addSubview(toast); hints.forEach(addSubview); addSubview(syntax); addSubview(settings)
        inlinePreview.isBordered = false
        inlinePreview.setButtonType(.pushOnPushOff)
        inlinePreview.imagePosition = .imageOnly
        inlinePreview.target = self
        inlinePreview.action = #selector(toggleInlinePreview)
        addSubview(inlinePreview)
        addSubview(actions); addSubview(stash)
        actions.onPress = { [weak self] in
            guard let self else { return }
            self.onActions?(self.actions)
        }
        stash.onPress = { [weak self] in self?.onStash?() }
        refreshButtons()
        updateInlinePreviewButton()
        settings.onPress = { [weak self] in self?.onSettings?() }
        actionable = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func showToast(_ kind: ToastKind, value: String, snapshot: Bool = false) {
        toastContent = (kind, value)
        toastTimer?.invalidate()
        toast.stringValue = Presentation.toastText(kind, value: value, chinese: L10n.chinese)
        let wasVisible = (toast.layer?.presentation()?.opacity ?? Float(toast.alphaValue)) > 0
        Theme.Motion.opacity(status, to: 0, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn))
        Theme.Motion.opacity(toast, to: 1, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn))
        if let layer = toast.layer {
            Theme.Motion.animate(layer, "transform.translation.y", to: 0, using: snapshot ? nil : Theme.Motion.basic(Theme.Motion.toastIn, .easeOut), from: wasVisible ? nil : Theme.Motion.toastOffset)
        }
        if !snapshot {
            toastTimer = Timer.scheduledTimer(withTimeInterval: Theme.Motion.toastIn + Theme.Motion.toastStay, repeats: false) { [weak self] _ in
                guard let self else { return }
                Theme.Motion.opacity(self.toast, to: 0, using: Theme.Motion.basic(Theme.Motion.toastOut))
                Theme.Motion.opacity(self.status, to: 1, using: Theme.Motion.basic(Theme.Motion.toastOut))
            }
        }
    }
    @objc private func toggleInlinePreview() { onInlinePreview?() }
    private func updateInlinePreviewButton() {
        let title = L10n.text(inlinePreviewVisible ? "inlinePreview.hide" : "inlinePreview.show")
        inlinePreview.image = Theme.symbol("sidebar.right", size: 14, weight: .regular)
        inlinePreview.contentTintColor = inlinePreviewVisible ? .controlAccentColor : .secondaryLabelColor
        inlinePreview.state = inlinePreviewVisible ? .on : .off
        inlinePreview.toolTip = title + " (⇧⌘P)"
        inlinePreview.setAccessibilityLabel(title)
    }
    func localize() {
        refreshButtons()
        updateInlinePreviewButton()
        updatePreviewKey()
        for (hint, key) in zip(hints, ["open", "preview"]) { hint.localize(L10n.text("hint." + key)) }
        syntax.localize(L10n.text("hint.syntax")); settings.localize()
        if let (kind, value) = toastContent { toast.stringValue = Presentation.toastText(kind, value: value, chinese: L10n.chinese) }
        needsLayout = true
    }
    deinit { toastTimer?.invalidate() }
    override func layout() {
        super.layout()
        settings.frame = NSRect(x: bounds.width - 18 - settings.desiredWidth, y: 4, width: settings.desiredWidth, height: 26)
        inlinePreview.frame = NSRect(x: settings.frame.minX - 29, y: 4, width: 26, height: 26)
        var right = inlinePreview.frame.minX - 6
        for button in [actions, stash] {
            let width = ceil(Theme.textWidth(button.title, font: button.font!)) + 14
            button.frame = NSRect(x: right - width, y: 4, width: width, height: 26)
            right = button.frame.minX
        }
        actions.isEnabled = actionable
        let candidates = actionable && !warning ? Array(hints.prefix(fileActions ? 2 : 1)) + [syntax] : [syntax]
        let hintWidth = candidates.reduce(0) { $0 + $1.desiredWidth + 8 }
        let visibleHints = right - hintWidth >= 175 ? candidates : []
        for hint in hints + [syntax] { hint.isHidden = !visibleHints.contains(hint) }
        var x = right - visibleHints.reduce(0) { $0 + $1.desiredWidth + 10 }
        status.frame = NSRect(x: 22, y: 9, width: max(0, x - 38), height: 16)
        toast.frame = status.frame
        for hint in visibleHints { hint.frame = NSRect(x: x, y: 8, width: hint.desiredWidth, height: 18); x += hint.desiredWidth + 10 }
    }
}
