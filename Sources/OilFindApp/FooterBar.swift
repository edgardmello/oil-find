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

enum PinnedFileAction: String, CaseIterable {
    case open, reveal, preview, copy

    static let preferenceKey = "pinnedFileActions"
    var title: String {
        switch self {
        case .open: return L10n.text("hint.open")
        case .reveal: return L10n.text("ctx.reveal")
        case .preview: return L10n.text("hint.preview")
        case .copy: return L10n.text("ctx.copyFiles")
        }
    }

    static func selected(in preferences: UserDefaults) -> [Self] {
        let keys = preferences.stringArray(forKey: preferenceKey) ?? []
        return allCases.filter { keys.contains($0.rawValue) }
    }
}

final class FooterBar: FlippedView {
    struct Application {
        let url: URL
        let name: String
        let icon: NSImage
    }

    private let appChooser = NSButton()
    private let appScroll = NSScrollView()
    private let appStrip = NSView()
    private var applicationButtons: [NSButton] = []
    private var applications: [Application] = []
    var onChooseApplication: (() -> Void)?
    var onOpenApplication: ((URL) -> Void)?
    private var showsApplicationRow = false
    var hiddenStatusItems: Set<StatusItem> = [] { didSet { needsLayout = true } }
    var backgroundOpacity: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(backgroundOpacity).setFill()
        bounds.fill()
    }

    var showActionsMenu = true { didSet { needsLayout = true } }
    var showActionDividers = false { didSet { needsLayout = true } }
    private let actionDivider = SeparatorView()

    var showActionHints = true { didSet { needsLayout = true } }
    var desiredHeight: CGFloat { showsApplicationRow ? 62 : 34 }

    private let toast = Theme.label(11.5, .regular, .labelColor)
    private var toastTimer: Timer?
    private var toastContent: (ToastKind, String)?
    private let status = Theme.label(11.5, .regular, .tertiaryLabelColor)
    private let hints = [KeyHint("↩", L10n.text("hint.open")), KeyHint("⌘Y", L10n.text("hint.preview"))]
    private let classicReveal = KeyHint("⌘↩", L10n.text("hint.reveal"))
    private let classicCopy = KeyHint("⌘C", L10n.text("hint.copy"))
    var classicLayout = false { didSet { needsLayout = true } }
    private let settings = SettingsButton()
    private let actions = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private let stash = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private var pinnedButtons: [(PinnedFileAction, ChromeButton)] = []
    var onPinnedAction: ((PinnedFileAction) -> Void)?

    func setPinnedActions(_ actions: [PinnedFileAction]) {
        guard actions != pinnedButtons.map({ $0.0 }) else { return }
        pinnedButtons.forEach { $0.1.removeFromSuperview() }
        pinnedButtons = actions.map { action in
            let button = ChromeButton(action.title, style: .plain, size: 12, weight: .medium)
            button.onPress = { [weak self] in self?.onPinnedAction?(action) }
            addSubview(button)
            return (action, button)
        }
        needsLayout = true
    }

    var onActions: ((NSView) -> Void)?
    var onStash: (() -> Void)?
    var stashCount = 0 { didSet { refreshButtons() } }

    private func refreshButtons() {
        actions.title = L10n.text("panel.actions")
        stash.title = L10n.text("panel.stashCount", String(stashCount))
        actions.setAccessibilityLabel(actions.title)
        stash.setAccessibilityLabel(stash.title)
        stash.toolTip = L10n.text("stash.toggleHint") + " (" + stashKey + ")"
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
    var fileActions = true {
        didSet {
            classicCopy.localize(L10n.text(fileActions ? "hint.copy" : "hint.copyResult"))
            needsLayout = true
        }
    }
    var spacePreview = false { didSet { updatePreviewKey() } }
    private var actionsKey = "⌘K"
    private var stashKey = "⇧⌘S"
    private var configuredPreviewKey = "⌘Y"
    var previewKey: String { spacePreview ? L10n.text("hint.space") : configuredPreviewKey }

    func updateShortcuts(in preferences: UserDefaults) {
        actionsKey = StashShortcut.actions.symbols(in: preferences)
        stashKey = StashShortcut.show.symbols(in: preferences)
        configuredPreviewKey = StashShortcut.preview.symbols(in: preferences)
        hints[0].key = StashShortcut.open.symbols(in: preferences)
        syntax.key = StashShortcut.syntax.symbols(in: preferences)
        classicReveal.key = StashShortcut.reveal.symbols(in: preferences)
        classicCopy.key = StashShortcut.copyPath.symbols(in: preferences)
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
        addSubview(status); addSubview(toast); (hints + [classicReveal, classicCopy]).forEach(addSubview); addSubview(syntax); addSubview(settings)
        inlinePreview.isBordered = false
        inlinePreview.setButtonType(.pushOnPushOff)
        inlinePreview.imagePosition = .imageOnly
        inlinePreview.target = self
        inlinePreview.action = #selector(toggleInlinePreview)
        addSubview(inlinePreview)
        addSubview(actionDivider)
        addSubview(actions); addSubview(stash)
        appChooser.bezelStyle = .recessed
        appChooser.font = .systemFont(ofSize: 11, weight: .medium)
        appChooser.title = L10n.text("footer.openWith")
        appChooser.target = self
        appChooser.action = #selector(chooseApplication)
        appScroll.drawsBackground = false
        appScroll.hasHorizontalScroller = true
        appScroll.autohidesScrollers = true
        appScroll.scrollerStyle = .overlay
        appScroll.documentView = appStrip
        appChooser.isHidden = true
        appScroll.isHidden = true
        addSubview(appChooser)
        addSubview(appScroll)
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
    func setApplications(_ apps: [Application], pending: Bool = false) {
        applications = apps
        showsApplicationRow = pending || !apps.isEmpty
        appChooser.isHidden = !showsApplicationRow
        appScroll.isHidden = apps.isEmpty
        applicationButtons.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        applicationButtons = apps.enumerated().map { index, app in
            let button = NSButton(title: app.name, image: app.icon, target: self, action: #selector(openApplication(_:)))
            button.bezelStyle = .recessed
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 11)
            button.toolTip = app.name
            button.tag = index
            let width = min(200, ceil(button.fittingSize.width) + 4)
            button.frame = NSRect(x: x, y: 1, width: width, height: 22)
            x += width + 4
            appStrip.addSubview(button)
            return button
        }
        appStrip.frame = NSRect(x: 0, y: 0, width: x, height: 24)
        appScroll.contentView.scroll(to: .zero)
        appScroll.reflectScrolledClipView(appScroll.contentView)
        needsLayout = true
    }

    @objc private func chooseApplication() { onChooseApplication?() }

    @objc private func openApplication(_ button: NSButton) {
        guard applications.indices.contains(button.tag) else { return }
        onOpenApplication?(applications[button.tag].url)
    }

    func showToast(_ kind: ToastKind, value: String, snapshot: Bool = false) {
        toastContent = (kind, value)
        toastTimer?.invalidate()
        toast.stringValue = Presentation.toastText(kind, value: value)
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
        pinnedButtons.forEach { $0.1.title = $0.0.title }
        appChooser.title = L10n.text("footer.openWith")
        refreshButtons()
        updateInlinePreviewButton()
        updatePreviewKey()
        for (hint, key) in zip(hints, ["open", "preview"]) { hint.localize(L10n.text("hint." + key)) }
        classicReveal.localize(L10n.text("hint.reveal"))
        classicCopy.localize(L10n.text(fileActions ? "hint.copy" : "hint.copyResult"))
        syntax.localize(L10n.text("hint.syntax")); settings.localize()
        if let (kind, value) = toastContent { toast.stringValue = Presentation.toastText(kind, value: value) }
        needsLayout = true
    }
    deinit { toastTimer?.invalidate() }
    override func layout() {
        super.layout()
        if showsApplicationRow {
            let width = ceil(appChooser.fittingSize.width) + 4
            appChooser.frame = NSRect(x: 18, y: 34, width: width, height: 22)
            appScroll.frame = NSRect(x: appChooser.frame.maxX + 6, y: 33,
                                     width: max(0, bounds.width - appChooser.frame.maxX - 24), height: 24)
        }
        settings.frame = NSRect(x: bounds.width - 18 - settings.desiredWidth, y: 4, width: settings.desiredWidth, height: 26)
        inlinePreview.isHidden = classicLayout || hiddenStatusItems.contains(.sidePreview)
        inlinePreview.frame = NSRect(x: settings.frame.minX - 29, y: 4, width: 26, height: 26)
        var right = (inlinePreview.isHidden ? settings.frame.minX : inlinePreview.frame.minX) - 6
        for (button, item) in [(actions, StatusItem.actions), (stash, .stash)] {
            button.isHidden = classicLayout || hiddenStatusItems.contains(item) || (item == .actions && !showActionsMenu)
            if button.isHidden { continue }
            let width = ceil(Theme.textWidth(button.title, font: button.font!)) + 14
            button.frame = NSRect(x: right - width, y: 4, width: width, height: 26)
            right = button.frame.minX
        }
        actions.isEnabled = actionable
        actionDivider.isHidden = true
        let dividerX = right
        if showActionDividers && !pinnedButtons.isEmpty { right -= 8 }
        for (_, button) in pinnedButtons.reversed() {
            let width = ceil(Theme.textWidth(button.title, font: button.font!)) + 16
            button.isHidden = !actionable || !fileActions || right - width < 120
            if !button.isHidden {
                right -= width
                button.frame = NSRect(x: right, y: 4, width: width, height: 26)
            }
        }
        if showActionDividers && pinnedButtons.contains(where: { !$0.1.isHidden }) {
            actionDivider.frame = NSRect(x: dividerX - 4, y: 10, width: Theme.pixel(self), height: 14)
            actionDivider.isHidden = false
        }
        var candidates: [KeyHint] = []
        if pinnedButtons.isEmpty && showActionHints && actionable && !warning {
            if !hiddenStatusItems.contains(.open) { candidates.append(hints[0]) }
            if classicLayout && fileActions { candidates.append(classicReveal) }
            if fileActions && !hiddenStatusItems.contains(.preview) { candidates.append(hints[1]) }
            if classicLayout { candidates.append(classicCopy) }
        }
        if !hiddenStatusItems.contains(.syntax) { candidates.append(syntax) }
        let hintWidth = candidates.reduce(0) { $0 + $1.desiredWidth + 8 }
        let visibleHints = right - hintWidth >= 175 ? candidates : []
        for hint in hints + [syntax, classicReveal, classicCopy] { hint.isHidden = !visibleHints.contains(hint) }
        var x = right - visibleHints.reduce(0) { $0 + $1.desiredWidth + 10 }
        status.frame = NSRect(x: 22, y: 9, width: max(0, x - 38), height: 16)
        toast.frame = status.frame
        for hint in visibleHints { hint.frame = NSRect(x: x, y: 8, width: hint.desiredWidth, height: 18); x += hint.desiredWidth + 10 }
    }
}
