import AppKit
import OilFindCore

final class FilterBar: FlippedView, NSMenuDelegate {
    static let toolbarHeight: CGFloat = 66
    var preferredHeight: CGFloat { compactToolbar ? 36 : Self.toolbarHeight }
    var compactToolbar = false {
        didSet {
            guard compactToolbar != oldValue else { return }
            updateCategoryVisibility()
            needsLayout = true
        }
    }
    static let names = ["all", "folder", "app", "document", "image", "video", "audio", "code", "archive"]
    private var buttons: [ChromeButton] = []
    private var buttonWidths: [CGFloat] = []
    private let capsule = TintPlate(radius: 13) { view in
        NSColor.controlAccentColor.withAlphaComponent(Theme.dark(view) ? 0.26 : 0.15)
    }
    var tintStrength: CGFloat = 1 {
        didSet {
            capsule.alphaValue = tintStrength
            refreshScope()
        }
    }
    private var laidOut = false
    private(set) var additionalSelected = false
    var additionalTitle: String? {
        didSet {
            guard additionalTitle != oldValue else { return }
            if additionalTitle == nil { additionalSelected = false }
            buttons.last?.title = additionalTitle ?? ""
            updateCategoryVisibility()
            if let button = buttons.last { buttonWidths[buttons.count - 1] = Theme.textWidth(button.title, font: button.font!) + 22 }
            refresh(); needsLayout = true
        }
    }
    private let scopeButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    var scopeActive = false { didSet { refreshScope() } }
    var scopeMenu: (() -> NSMenu)?
    var searchOptionsMenu: (() -> NSMenu)?
    var savedMenu: (() -> NSMenu)?
    var viewMenu: (() -> NSMenu)?
    var searchOptionsActive = false { didSet { refreshScope() } }
    private let searchOptionsButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private let savedButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private let viewButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private let categoryButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    private var toolbarButtons: [ChromeButton] { [scopeButton, searchOptionsButton, savedButton, viewButton, sortButton] }
    private let sortButton = ChromeButton("", style: .plain, size: 12, weight: .medium)
    var onChange: (() -> Void)?
    var onMenuTracking: ((Bool) -> Void)?
    var onSortChange: (() -> Void)?
    var options = SearchOptions() { didSet { refresh() } }
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.4; (buttons + toolbarButtons + [categoryButton]).forEach { $0.isEnabled = isEnabled } }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(capsule)
        for (i, name) in Self.names.enumerated() {
            let button = ChromeButton(L10n.text("filter." + name), style: .filter, size: 12.5, weight: .medium)
            button.onPress = { [weak self] in self?.select(i) }
            buttons.append(button); buttonWidths.append(Theme.textWidth(button.title, font: button.font!) + 22); addSubview(button)
        }
        let additional = ChromeButton("", style: .filter, size: 12.5, weight: .medium)
        additional.isHidden = true; additional.onPress = { [weak self] in self?.select(Self.names.count) }
        buttons.append(additional); buttonWidths.append(0); addSubview(additional)
        sortButton.trailingSymbol = Theme.symbol("arrow.up.arrow.down", size: 10, weight: .medium)
        sortButton.onPress = { [weak self] in self?.showSortMenu() }
        for (button, menu) in [(scopeButton, \FilterBar.scopeMenu), (searchOptionsButton, \FilterBar.searchOptionsMenu),
                               (savedButton, \FilterBar.savedMenu), (viewButton, \FilterBar.viewMenu)] {
            button.trailingSymbol = Theme.symbol("chevron.down", size: 10, weight: .medium)
            button.onPress = { [weak self, weak button] in
                guard let self, let button, let menu = self[keyPath: menu]?() else { return }
                self.show(menu, under: button)
            }
            addSubview(button)
        }
        categoryButton.trailingSymbol = Theme.symbol("chevron.down", size: 10, weight: .medium)
        categoryButton.onPress = { [weak self] in self?.showCategories() }
        addSubview(categoryButton)
        addSubview(sortButton)
        updateCategoryVisibility()
        refresh(); refreshScope()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func sortName(_ key: SortKey) -> String {
        switch key { case .relevance: return "relevance"; case .name: return "name"; case .modified: return "modified"; case .size: return "size" }
    }
    private var activeTint: NSColor {
        NSColor.secondaryLabelColor.blended(withFraction: tintStrength, of: .controlAccentColor) ?? .controlAccentColor
    }
    private func refreshScope() {
        scopeButton.title = L10n.text("scope.menu")
        searchOptionsButton.title = L10n.text("scope.options")
        savedButton.title = L10n.text("scope.saved")
        viewButton.title = L10n.text("scope.view")
        searchOptionsButton.textTint = searchOptionsActive ? activeTint : nil
        searchOptionsButton.needsDisplay = true
        scopeButton.textTint = scopeActive ? activeTint : nil
        scopeButton.needsDisplay = true
        categoryButton.textTint = selectedCategory == 0 ? nil : activeTint
        categoryButton.needsDisplay = true
        needsLayout = true
    }
    func localize() {
        refreshScope()
        for (i, button) in buttons.prefix(Self.names.count).enumerated() {
            button.title = L10n.text("filter." + Self.names[i])
            buttonWidths[i] = Theme.textWidth(button.title, font: button.font!) + 22
        }
        refresh(); needsLayout = true
    }
    private var selectedCategory: Int { additionalSelected ? Self.names.count : Int(options.kind ?? 0) }

    private func updateCategoryVisibility() {
        for (index, button) in buttons.enumerated() {
            button.isHidden = compactToolbar || (index == Self.names.count && additionalTitle == nil)
        }
        capsule.isHidden = compactToolbar
        categoryButton.isHidden = !compactToolbar
    }

    private func showCategories() {
        let menu = NSMenu()
        for (index, button) in buttons.enumerated() where index < Self.names.count || additionalTitle != nil {
            let item = menu.addItem(withTitle: button.title, action: #selector(selectCategory(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = selectedCategory == index ? .on : .off
        }
        show(menu, under: categoryButton)
    }

    @objc private func selectCategory(_ item: NSMenuItem) { select(item.tag) }

    private func refresh() {
        for (index, button) in buttons.enumerated() { button.active = index == selectedCategory }
        categoryButton.title = buttons[selectedCategory].title
        categoryButton.textTint = selectedCategory == 0 ? nil : activeTint
        categoryButton.setAccessibilityLabel(L10n.text("settings.interface.fileType", categoryButton.title))
        categoryButton.needsDisplay = true
        if compactToolbar { needsLayout = true }
        let sortTitle = L10n.text("sort." + Self.sortName(options.sort))
        let changedSort = sortButton.title != sortTitle
        sortButton.title = sortTitle; sortButton.needsDisplay = true
        if laidOut && !compactToolbar { moveCapsule(animated: window?.isVisible == true) }
        if changedSort || sortButton.frame.isEmpty { needsLayout = true }
    }
    override func layout() {
        super.layout()
        if !compactToolbar { layoutCategoryChips() }
        let controls = compactToolbar ? [categoryButton] + toolbarButtons : toolbarButtons
        let leftCount = controls.count - 2
        let widths = controls.map { ceil(Theme.textWidth($0.title, font: $0.font!)) + 24 }
        let available = max(0, bounds.width - 36 - CGFloat(controls.count - 1) * 4)
        let fitting = min(1, available / widths.reduce(0, +))
        var left: CGFloat = 18
        for index in 0..<leftCount {
            let width = floor(widths[index] * fitting)
            controls[index].frame = NSRect(x: left, y: 5, width: width, height: 26)
            left += width + 4
        }
        var right = bounds.width - 18
        for index in controls.indices.suffix(2).reversed() {
            let width = floor(widths[index] * fitting)
            right -= width
            controls[index].frame = NSRect(x: right, y: 5, width: width, height: 26)
            right -= 4
        }
        laidOut = true
        if !compactToolbar { moveCapsule(animated: false) }
    }

    private func layoutCategoryChips() {
        var x: CGFloat = 18
        let visibleCount = Self.names.count + (additionalTitle == nil ? 0 : 1)
        let available = max(0, bounds.width - 36 - CGFloat(visibleCount - 1) * 2)
        let natural = buttonWidths.prefix(visibleCount).reduce(0, +)
        let reduction = max(0, (natural - available) / CGFloat(visibleCount))
        for (i, button) in buttons.prefix(visibleCount).enumerated() {
            let width = max(20, buttonWidths[i] - reduction)
            button.frame = NSRect(x: x, y: 36, width: width, height: 26)
            x += width + 2
        }

    }
    private func moveCapsule(animated: Bool) {
        let target = buttons[additionalSelected ? Self.names.count : Int(options.kind ?? 0)].frame
        guard capsule.frame != target else { return }
        Theme.Motion.frame(capsule, to: target, using: animated && !Theme.Motion.reduced ? Theme.Motion.chip : nil)
    }
    func select(_ index: Int, notify: Bool = true) {
        guard !isHidden, isEnabled, index >= 0, index < Self.names.count + (additionalTitle == nil ? 0 : 1) else { return }
        additionalSelected = index == Self.names.count
        options.kind = index == 0 || additionalSelected ? nil : UInt8(index)
        if notify { onChange?() }
    }
    func cycle(_ delta: Int) {
        let count = Self.names.count + (additionalTitle == nil ? 0 : 1)
        select(((additionalSelected ? Self.names.count : Int(options.kind ?? 0)) + delta + count) % count)
    }
    private func showSortMenu() {
        guard isEnabled else { return }
        let menu = NSMenu(); menu.delegate = self
        for (i, key) in [SortKey.relevance, .name, .modified, .size].enumerated() {
            if i == 0 && options.sortsRecentResults { continue }
            let item = NSMenuItem(title: L10n.text("sort." + Self.sortName(key)), action: #selector(sortSelected(_:)), keyEquivalent: "")
            item.tag = i; item.target = self; item.state = options.sort == key ? .on : .off
            menu.addItem(item)
        }
        show(menu, under: sortButton)
    }

    private func show(_ menu: NSMenu, under button: ChromeButton) {
        menu.delegate = self
        menu.popUp(positioning: nil, at: NSPoint(x: button.frame.minX, y: button.frame.maxY), in: self)
    }
    @objc private func sortSelected(_ item: NSMenuItem) {
        let key = [SortKey.relevance, .name, .modified, .size][item.tag]
        options.ascending = options.sort == key && key != .relevance ? !options.ascending : key == .name
        options.sort = key; onSortChange?(); onChange?()
    }
    func menuWillOpen(_ menu: NSMenu) { onMenuTracking?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenuTracking?(false) }
}
