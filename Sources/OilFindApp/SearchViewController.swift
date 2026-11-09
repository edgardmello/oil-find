import AppKit
import Quartz
import Darwin
import OilFindCore

private final class SupplementarySearchBox { var hits: [SupplementaryHit] = [] }
private final class AdditionalSearchBox { var items: [AdditionalSearchItem] = []; var failed = false; var elapsedMs: Double = 0 }

private final class SearchGeneration {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return value == token }
}

final class SearchViewController: NSViewController, NSWindowDelegate, NSMenuDelegate {
    let searchField = SearchField(frame: .zero)
    let filters = FilterBar(frame: .zero)
    let results = ResultsView(frame: .zero)
    let footer = FooterBar(frame: .zero)
    let quickLook = QuickLook()
    private let inlinePreview = InlinePreview(frame: .zero)
    private(set) var inlinePreviewVisible = false
    private var quickLookDismissTime: CFAbsoluteTime = 0
    private let topLine = SeparatorView(), bottomLine = SeparatorView()
    private let empty = StateView(.empty), indexing = StateView(.indexing)
    let syntax = SyntaxReference(frame: .zero)
    private let syntaxScroll = NSScrollView()
    private(set) var syntaxVisible = false
    private var diagnostics: [QueryDiagnostic] = []
    private var snapshotNoAccess = false
    private var coverageExplanation: CoverageExplanation?
    private let snapshot: Bool
    private let preferences: UserDefaults
    private let filePaste = FilePasteHandoff()
    private lazy var fileStash = FileStash(preferences: preferences)
    private lazy var scriptWindow = FileScriptWindow()
    private let accessories = SearchAccessoryBar(frame: .zero)
    private var stashExpanded = false
    private var copyingStash = false
    private lazy var stashWindow = StashWindow(stash: fileStash)
    private let queue = DispatchQueue(label: "com.oiloil.find.search", qos: .userInteractive)
    private let fileTransferQueue = DispatchQueue(label: "com.oiloil.find.fileTransfer", qos: .userInitiated)
    private let coverageQueue = DispatchQueue(label: "com.oiloil.find.searchCoverage", qos: .utility)
    private let generation = SearchGeneration(), cache = SearchCache()
    private var timer: Timer?
    private var stateView: NSView?
    private var languageObserver: NSObjectProtocol?
    private var menuTracking = false, dragging = false, footerShowsSelection = false
    private var trashing: Set<URL> = []
    private var selectionAnchor: (sourceID: String, store: IndexStore, id: UInt32, path: String)?
    private var additionalSearchFailed = false
    private var additionalPending = false
    private var pendingNewSearch: Bool?
    private(set) var browsingResults = false
    var previewWithSpace: Bool { preferences.object(forKey: "previewWithSpace") as? Bool ?? true }
    private var spaceOpensQuickLook: Bool { browsingResults && previewWithSpace && !inlinePreviewVisible }
    private func setBrowsing(_ browsing: Bool) {
        browsingResults = browsing
        footer.spacePreview = spaceOpensQuickLook
    }
    var manager: IndexManager?
    var supplementaryProvider: SupplementarySearchProvider?
    var additionalSearchProvider: AdditionalSearchProvider? {
        didSet {
            oldValue?.onChange = nil; oldValue?.visibilityChanged(false)
            additionalSearchProvider?.onChange = { [weak self] in self?.additionalChanged() }
            if isViewLoaded { additionalChanged() }
        }
    }
    private func refreshAdditionalFilter() {
        guard isViewLoaded else { return }
        filters.additionalTitle = additionalSearchProvider?.isEnabled == true ? additionalSearchProvider?.title : nil
        searchField.placeholder = filters.additionalSelected ? additionalSearchProvider?.placeholder : nil
    }
    private func additionalChanged() {
        refreshAdditionalFilter()
        if additionalSearchProvider?.isEnabled != true { additionalPending = false }
        if let provider = additionalSearchProvider, let result = results.result,
           let filtered = result.removingUnavailableAdditionalItems(using: provider, options: filters.options) {
            results.refresh(filtered, applyingAvailabilityImmediately: true)
            resultDidChange(filtered)
        }
        if view.window?.isVisible == true { refreshSearch() }
    }
    func panelDidHide() {
        setInlinePreviewVisible(false, resize: false)
        additionalSearchProvider?.visibilityChanged(false)
        supplementaryProvider?.userActivity(visible: false, typing: false)
    }
    private let additionalQueue = DispatchQueue(label: "com.oiloil.find.additional", qos: .userInitiated)
    private let supplementQueue = DispatchQueue(label: "com.oiloil.find.supplement", qos: .userInteractive)
    var additionalSources: (() -> [SearchSource])?
    private var sourceCaches: [String: SearchCache] = [:]
    private var sourceCacheStores: [String: ObjectIdentifier] = [:]
    private var folderScope: String?
    private var volumeScope: String?
    private lazy var fuzzyNames = !snapshot && preferences.bool(forKey: "fuzzyNames")
    private var hiddenOnly = false
    private var sortingRecent: Bool { !hiddenOnly && folderScope == nil && searchField.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var scopedSources: [SearchSource] {
        guard let volumeScope else { return searchSources }
        let sources = searchSources
        if let source = sources.first(where: { $0.id == volumeScope }) { return [source] }
        return Array(sources.filter { $0.displayName == volumeScope }.prefix(1))
    }
    private var searchSources: [SearchSource] {
        let primary = manager?.store.map { SearchSource(id: "startup", displayName: "", isOnline: true, store: $0) }
        return primary.map { [$0] + (additionalSources?() ?? []) } ?? (additionalSources?() ?? [])
    }
    func sourcesChanged() {
        refreshAdditionalFilter()
        refreshProgress()
        supplementaryProvider?.sourcesDidChange(searchSources)
        results.cancelPendingRefresh(); results.cancelPress()
        if supplementaryProvider?.isEnabled != true, let result = results.result, result.hasSupplements {
            let base = result.withoutSupplements()
            let row = results.selectedItem.flatMap { base.index(sourceID: $0.source.id, store: $0.source.store, id: $0.id, path: $0.path) } ?? 0
            present(base, selection: row, resetScroll: false)
        }
        // Invalidate displayed actions immediately, including while the panel is hidden.
        if results.selectedItem?.source.isOnline != true { quickLook.close() }
        if let presented = results.result, let multi = presented.multiple {
            let current = Set(searchSources.map(\.id))
            if multi.sources.contains(where: { !current.contains($0.id) }) && current.isEmpty {
                results.clear(preservingViewport: true); setState(.empty)
                footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
            }
        }
        results.localize()
        refreshInlinePreview()
        if view.window?.isVisible == true || snapshot {
            refreshSearch()
        }
    }
    var hidePanel: (() -> Void)?
    var onSettings: (() -> Void)?
    init(snapshot: Bool, preferences: UserDefaults = .standard) {
        self.snapshot = snapshot
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = PanelSurface(snapshot: snapshot) }
    override func viewDidLoad() {
        super.viewDidLoad()
        [searchField, topLine, filters, results, empty, indexing, bottomLine, footer, inlinePreview, accessories, syntaxScroll].forEach(view.addSubview)
        syntaxScroll.drawsBackground = false
        syntaxScroll.hasVerticalScroller = true
        syntaxScroll.autohidesScrollers = true
        syntaxScroll.documentView = syntax
        syntaxScroll.isHidden = true
        inlinePreview.isHidden = true
        syntax.shortcutPreferences = preferences
        refreshShortcuts()
        syntax.onExample = { [weak self] example in
            guard let self else { return }; self.setBrowsing(false); self.searchField.text = example; self.toggleSyntax(false); self.searchField.focus(); self.startSearch()
        }
        searchField.onSelectionChange = { [weak self] in self?.refreshDiagnostics() }
        searchField.onChange = { [weak self] in self?.setBrowsing(false); self?.startSearch() }
        searchField.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        filters.onChange = { [weak self] in self?.scopeChanged(resetAdditional: false) }
        results.setCompact(preferences.bool(forKey: "compactResults"))
        filters.scopeMenu = { [weak self] in self?.makeScopeMenu() ?? NSMenu() }
        filters.onSortChange = { [weak self] in
            guard let self, !self.snapshot else { return }
            let recent = self.filters.options.sortsRecentResults
            self.preferences.set(FilterBar.sortName(self.filters.options.sort), forKey: recent ? "recentSortKey" : "sortKey")
            self.preferences.set(self.filters.options.ascending, forKey: recent ? "recentSortAscending" : "sortAscending")
        }
        filters.onMenuTracking = { [weak self] tracking in
            self?.menuTracking = tracking
            if !tracking { self?.hideIfInactive() }
        }
        if !snapshot { results.currentSource = { [weak self] id in self?.searchSources.first { $0.id == id } } }
        results.onPointerSelection = { [weak self] in self?.setBrowsing(true) }
        results.onOpen = { [weak self] in self?.openSelected() }
        results.onSelection = { [weak self] in
            self?.quickLook.refresh()
            self?.refreshInlinePreview()
            self?.footer.fileActions = self?.results.selectedAdditional == nil
            if let self, let item = self.results.selectedItem {
                self.selectionAnchor = (item.source.id, item.source.store, item.id, item.path)
            }
            if let self, let result = self.results.result {
                let multiple = self.multipleSelected
                if multiple || self.footerShowsSelection { self.updateFooter(result) }
                self.footerShowsSelection = multiple
            }
        }
        results.onContextMenu = { [weak self] _ in self?.contextMenu() }
        results.onRefreshApplied = { [weak self] result in self?.resultDidChange(result) }
        results.onDragging = { [weak self] active in
            self?.dragging = active
            if !active { self?.hideIfInactive() }
        }
        quickLook.selectedURL = { [weak self] in
            guard let self, self.results.selectedItem?.source.isOnline == true else { return nil }
            return self.selectedURL
        }
        quickLook.onWillOpen = { [weak self] in self?.rememberFocus() }
        quickLook.onReclaimFocus = { [weak self] in self?.restoreFocus() }
        quickLook.onWillClose = { [weak self] in
            self?.quickLookDismissTime = CFAbsoluteTimeGetCurrent()
        }
        quickLook.onDidClose = { [weak self] in
            guard let self, let window = self.view.window, window.isVisible else { return }
            self.quickLookDismissTime = CFAbsoluteTimeGetCurrent()
            self.restoreFocus()
        }
        quickLook.onKey = { [weak self] event in self?.forwardPreviewKey(event) ?? false }
        footer.onInlinePreview = { [weak self] in self?.toggleInlinePreview() }
        footer.onActions = { [weak self] anchor in self?.showActions(anchoredTo: anchor) }
        footer.onStash = { [weak self] in self?.toggleStash() }
        footer.onSettings = { [weak self] in self?.onSettings?() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.localize() }
        setState(.indexing)
        if !snapshot {
            filters.options = SettingsPreferences.searchOptions(in: preferences, recent: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshProgress() }
        }
        localize()
        refreshAdditionalFilter()
    }
    deinit {
        timer?.invalidate()
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
    }
    private func localize() {
        footer.spacePreview = spaceOpensQuickLook
        filters.localize(); footer.localize(); empty.localize(); indexing.localize(); syntax.localize(); results.localize()
        searchField.localize(); inlinePreview.localize()
        refreshAccessories()
        refreshAdditionalFilter()
        if let result = results.result { updateFooter(result) }
        else if stateView === indexing { footer.text = L10n.text("footer.indexing", Presentation.countText(indexing.count)) }
        refreshProgress()
        view.needsLayout = true
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height, px = Theme.pixel(view)
        searchField.frame = NSRect(x: 0, y: 0, width: w, height: 64)
        topLine.frame = NSRect(x: 0, y: 64, width: w, height: px)
        filters.frame = NSRect(x: 0, y: 64 + px, width: w, height: 40)
        let accessoryHeight = syntaxVisible ? 0 : accessories.desiredHeight
        accessories.isHidden = syntaxVisible || accessoryHeight == 0
        accessories.frame = NSRect(x: 0, y: 104 + px, width: w, height: accessoryHeight)
        let top: CGFloat = 104 + px + accessoryHeight
        let region = NSRect(x: 0, y: top, width: w, height: max(0, h - top - 34 - px))
        let previewWidth = inlinePreviewVisible && !syntaxVisible ? min(400, floor(region.width * 0.36)) : 0
        let list = NSRect(x: 0, y: top, width: w - previewWidth, height: region.height)
        [results, empty, indexing].forEach { $0.frame = list }
        syntaxScroll.frame = region
        syntax.frame = NSRect(origin: .zero, size: NSSize(width: syntaxScroll.contentSize.width,
                                                           height: max(region.height, syntax.contentHeight)))
        inlinePreview.frame = NSRect(x: list.maxX, y: top, width: previewWidth, height: region.height)
        bottomLine.frame = NSRect(x: 0, y: h - 34 - px, width: w, height: px)
        footer.frame = NSRect(x: 0, y: h - 34, width: w, height: 34)
    }
    func setState(_ state: StateView.State?) {
        _ = view
        let previous: NSView = stateView ?? (results as NSView)
        stateView = state == .empty ? empty : state == .indexing ? indexing : nil
        refreshInlinePreview()
        let target: NSView = stateView ?? (results as NSView)
        footer.actionable = !syntaxVisible && stateView == nil && (results.result?.total ?? 0) > 0
        guard previous !== target else { return }
        let animate = !snapshot && view.window?.isVisible == true && previous !== target
        for item in [results, empty, indexing] as [NSView] {
            let visible = item === target
            if visible { item.isHidden = false }
            Theme.Motion.opacity(item, to: visible ? 1 : 0, using: animate ? Theme.Motion.basic(Theme.Motion.crossfade) : nil)
            if !visible {
                if animate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.crossfade) { [weak self, weak item] in
                        guard let self, let item else { return }
                        let current: NSView = self.stateView ?? (self.results as NSView)
                        if item !== current { item.isHidden = true }
                    }
                } else { item.isHidden = true }
            }
        }
    }
    func applySearchLink(_ link: SearchLink) {
        _ = view
        searchField.text = link.query
        folderScope = link.folder
        hiddenOnly = false
        volumeScope = link.volume.map { value in
            searchSources.first { $0.id == value || $0.displayName == value }?.id ?? value
        }
        filters.select(link.kind, notify: false)
        scopeChanged()
    }

    private func makeScopeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sourceID: String?, checked: Bool) {
            let item = NSMenuItem(title: title, action: #selector(selectVolume(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = sourceID; item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add(L10n.text("scope.allVolumes"), nil, checked: volumeScope == nil)
        for source in searchSources {
            add(source.id == "startup" ? L10n.text("scope.startup") : source.displayName,
                source.id, checked: volumeScope != nil && scopedSources.first?.id == source.id)
        }
        if let folderScope {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: L10n.text("scope.clearFolder", (folderScope as NSString).lastPathComponent),
                                   action: #selector(clearFolderScope), keyEquivalent: "")
            clear.target = self
            clear.toolTip = folderScope
            menu.addItem(clear)
        }
        menu.addItem(.separator())
        let hidden = menu.addItem(withTitle: L10n.text("scope.hiddenOnly"), action: #selector(toggleHiddenOnly), keyEquivalent: "")
        hidden.target = self
        hidden.state = hiddenOnly ? .on : .off
        let fuzzy = menu.addItem(withTitle: L10n.text("scope.fuzzyNames"), action: #selector(toggleFuzzyNames), keyEquivalent: "")
        fuzzy.target = self
        fuzzy.state = fuzzyNames ? .on : .off
        let quick = menu.addItem(withTitle: L10n.text("quickFilter.title"), action: nil, keyEquivalent: "")
        quick.submenu = makeQuickFilterMenu()
        menu.addItem(.separator())
        let viewStyle = menu.addItem(withTitle: L10n.text("view.results"), action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for (tag, key) in ["view.original", "view.compact"].enumerated() {
            let item = styles.addItem(withTitle: L10n.text(key), action: #selector(selectResultsView(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            item.state = (tag == 1) == results.compact ? .on : .off
        }
        viewStyle.submenu = styles
        return menu
    }

    @objc private func selectResultsView(_ item: NSMenuItem) {
        let compact = item.tag == 1
        results.setCompact(compact)
        if !snapshot { preferences.set(compact, forKey: "compactResults") }
    }

    private func makeQuickFilterMenu() -> NSMenu {
        let menu = NSMenu()
        let saved = QuickFilter.load(from: preferences)
        let remove = NSMenu()
        let refine = NSMenu()
        if !saved.isEmpty { menu.addItem(.sectionHeader(title: L10n.text("quickFilter.restore"))) }
        for (index, filter) in saved.enumerated() {
            let item = menu.addItem(withTitle: filter.name, action: #selector(applyQuickFilterItem(_:)), keyEquivalent: "")
            if StashShortcut.quickFilters.indices.contains(index) { StashShortcut.quickFilters[index].chord(in: preferences).apply(to: item) }
            item.target = self; item.tag = index
            let refinement = refine.addItem(withTitle: filter.name, action: #selector(refineQuickFilterItem(_:)), keyEquivalent: "")
            refinement.target = self; refinement.tag = index
            let deletion = remove.addItem(withTitle: filter.name, action: #selector(removeQuickFilter(_:)), keyEquivalent: "")
            deletion.target = self; deletion.tag = index
        }
        if !saved.isEmpty {
            let item = menu.addItem(withTitle: L10n.text("quickFilter.refine"), action: nil, keyEquivalent: "")
            item.submenu = refine
            menu.addItem(.separator())
        }
        let save = menu.addItem(withTitle: L10n.text("quickFilter.save"), action: #selector(saveQuickFilter), keyEquivalent: "")
        save.target = self
        if !saved.isEmpty {
            let item = menu.addItem(withTitle: L10n.text("quickFilter.remove"), action: nil, keyEquivalent: "")
            item.submenu = remove
        }
        return menu
    }

    @objc private func toggleFuzzyNames() {
        fuzzyNames.toggle()
        if !snapshot { preferences.set(fuzzyNames, forKey: "fuzzyNames") }
        scopeChanged()
    }

    @objc private func toggleHiddenOnly() {
        hiddenOnly.toggle()
        scopeChanged()
    }

    @objc private func applyQuickFilterItem(_ item: NSMenuItem) {
        _ = applyQuickFilter(at: item.tag)
    }

    @objc private func refineQuickFilterItem(_ item: NSMenuItem) {
        _ = applyQuickFilter(at: item.tag, restoreQuery: false)
    }

    private func applyQuickFilter(at index: Int, restoreQuery: Bool = true) -> Bool {
        let saved = QuickFilter.load(from: preferences)
        guard saved.indices.contains(index) else { return false }
        let filter = saved[index]
        if restoreQuery { searchField.text = filter.query }
        folderScope = filter.folder
        volumeScope = filter.volume
        hiddenOnly = filter.hiddenOnly
        fuzzyNames = filter.fuzzyNames ?? false
        filters.select(Int(filter.kind ?? 0), notify: false)
        scopeChanged()
        return true
    }

    @objc private func removeQuickFilter(_ item: NSMenuItem) {
        var saved = QuickFilter.load(from: preferences)
        guard saved.indices.contains(item.tag) else { return }
        saved.remove(at: item.tag)
        QuickFilter.save(saved, to: preferences)
    }

    @objc private func saveQuickFilter() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window?.isVisible == true else { return }
            self.rememberFocus()
            self.menuTracking = true
            defer { self.menuTracking = false; self.restoreFocus() }
            let alert = NSAlert()
            alert.messageText = L10n.text("quickFilter.saveTitle")
            alert.addButton(withTitle: L10n.text("quickFilter.saveButton"))
            alert.addButton(withTitle: L10n.text("quickFilter.cancel"))
            let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            name.placeholderString = L10n.text("quickFilter.name")
            name.setAccessibilityLabel(L10n.text("quickFilter.name"))
            alert.accessoryView = name
            alert.window.initialFirstResponder = name
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            let filter = QuickFilter(name: title, query: self.searchField.text, kind: self.filters.options.kind,
                                     folder: self.folderScope, volume: self.volumeScope, hiddenOnly: self.hiddenOnly,
                                     fuzzyNames: self.fuzzyNames && !self.filters.additionalSelected)
            var saved = QuickFilter.load(from: self.preferences)
            if let index = saved.firstIndex(where: { $0.name.caseInsensitiveCompare(title) == .orderedSame }) { saved[index] = filter }
            else { saved.append(filter) }
            QuickFilter.save(saved, to: self.preferences)
        }
    }

    @objc private func selectVolume(_ item: NSMenuItem) {
        volumeScope = item.representedObject as? String
        scopeChanged()
    }

    @objc private func clearFolderScope() {
        folderScope = nil
        scopeChanged()
    }

    @objc private func scopeToSelection() {
        guard let item = results.selectedItem, !multipleSelected else { return }
        folderScope = item.flags & SiftFlag.dir != 0 ? item.path : item.parentPath
        searchField.text = ""
        scopeChanged()
    }

    private func scopeChanged(resetAdditional: Bool = true) {
        filters.scopeActive = folderScope != nil || volumeScope != nil || hiddenOnly || fuzzyNames
        if resetAdditional && filters.additionalSelected { filters.select(0, notify: false) }
        refreshAdditionalFilter()
        refreshAccessories()
        setBrowsing(false)
        searchField.focus()
        startSearch()
    }

    private func refreshAccessories() {
        var chips: [(String, () -> Void)] = []
        if let kind = filters.options.kind, FilterBar.names.indices.contains(Int(kind)) {
            chips.append((L10n.text("filter." + FilterBar.names[Int(kind)]) + " ×", { [weak self] in self?.filters.select(0) }))
        }
        if let volumeScope {
            let title = scopedSources.first.map { $0.id == "startup" ? L10n.text("scope.startup") : $0.displayName } ?? volumeScope
            chips.append((title + " ×", { [weak self] in self?.volumeScope = nil; self?.scopeChanged() }))
        }
        if let folderScope {
            chips.append(((folderScope as NSString).lastPathComponent + " ×", { [weak self] in self?.clearFolderScope() }))
        }
        if hiddenOnly {
            chips.append((L10n.text("scope.hiddenOnly") + " ×", { [weak self] in self?.toggleHiddenOnly() }))
        }
        if chips.count > 1 {
            chips.append((L10n.text("panel.clearFilters"), { [weak self] in
                guard let self else { return }
                self.volumeScope = nil; self.folderScope = nil; self.hiddenOnly = false
                self.filters.select(0, notify: false)
                self.scopeChanged()
            }))
        }
        if fuzzyNames && !filters.additionalSelected {
            chips.append((L10n.text("scope.fuzzyNames") + " ×", { [weak self] in self?.toggleFuzzyNames() }))
        }
        accessories.setFilters(chips)
        let files = snapshot ? [] : fileStash.files
        footer.stashCount = files.count
        accessories.setStash(files: files, expanded: stashExpanded,
                             copy: { [weak self] in self?.copyStash() }, open: { [weak self] in self?.showStash() },
                             dragging: { [weak self] active in
                                 self?.dragging = active
                                 if !active { self?.hideIfInactive() }
                             },
                             leaveSearch: { [weak self] in self?.hidePanel?() },
                             remove: { [weak self] ids in self?.fileStash.remove(ids); self?.refreshAccessories() },
                             menuDelegate: self)
        accessories.needsLayout = true
        view.needsLayout = true
    }

    private func toggleStash() {
        if syntaxVisible { toggleSyntax(false) }
        stashExpanded.toggle()
        refreshAccessories()
        restoreFocus()
    }

    private func copyStash() {
        guard !copyingStash else { return }
        let files = fileStash.files
        guard !files.isEmpty else { return }
        copyingStash = true
        fileStash.resolve(files) { [weak self] urls in
            guard let self else { return }
            self.copyingStash = false
            guard self.view.window?.isVisible == true else { return }
            let ids = Set(self.fileStash.files.map(\.id))
            let available = files.compactMap { ids.contains($0.id) ? urls[$0.id] : nil }
            guard !available.isEmpty else {
                self.footer.text = L10n.text("panel.stashUnavailable")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.writeObjects(available.map { $0 as NSURL }) {
                self.footer.text = L10n.text("panel.stashCopied", String(available.count), String(files.count))
            }
        }
    }

    func panelWillShow() {
        filters.scopeActive = folderScope != nil || volumeScope != nil || hiddenOnly || fuzzyNames
        refreshAccessories()
        additionalSearchProvider?.visibilityChanged(true)
        setBrowsing(false)
        supplementaryProvider?.userActivity(visible: true, typing: false)
        let sources = scopedSources
        let currentQuery = editingQuery(store: sources.first?.store)
        if additionalSearchProvider?.isEnabled != true { additionalPending = false }
        if additionalSearchProvider?.isEnabled != true, let result = results.result, result.isCurrent(sources),
           (result.single != nil || result.multiple != nil || sources.isEmpty),
           result.query.raw == currentQuery.raw, result.query.folderScope == currentQuery.folderScope,
           result.query.hiddenOnly == currentQuery.hiddenOnly, result.query.fuzzyNames == currentQuery.fuzzyNames, !currentQuery.isTimeDependent,
           Date().timeIntervalSince(result.createdAt) <= 600 { return }
        startSearch(preserveSelection: true)
    }
    func indexChanged() {
        refreshProgress()
        supplementaryProvider?.sourcesDidChange(searchSources)
        if view.window?.isVisible == true { refreshSearch() }
    }
    func managerStateChanged(_ state: IndexManager.State) {
        refreshProgress()
        if manager?.store == nil && !filters.additionalSelected && results.result?.hasAdditional != true && results.result?.hasSupplements != true { setState(.indexing) }
    }
    private func refreshProgress() {
        if let result = results.result, result.query.isEmpty { updateFooter(result) }
        searchField.indexing = additionalPending
        guard let manager else { return }
        supplementaryProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        additionalSearchProvider?.backgroundIndexingChanged(manager.state == .loading || manager.state == .scanning || manager.isRescanning)
        searchField.indexing = additionalPending || !filters.additionalSelected && (manager.state == .scanning || manager.isRescanning)
        if manager.store == nil && !filters.additionalSelected {
            let count = manager.scannedCount
            indexing.updateCount(count); footer.text = L10n.text("footer.indexing", Presentation.countText(count))
        }
    }
    func startSearch(preserveSelection: Bool = false) {
        pendingNewSearch = preserveSelection
        results.cancelPendingRefresh()
        search(refresh: false, preserveSelection: preserveSelection)
    }
    private func refreshSearch() {
        // Index notifications must not turn an uncommitted user query into a refresh.
        if let preserveSelection = pendingNewSearch {
            search(refresh: false, preserveSelection: preserveSelection)
        } else if results.result == nil {
            startSearch()
        } else {
            search(refresh: true, preserveSelection: false)
        }
    }
    private func search(refresh: Bool, preserveSelection: Bool) {
        supplementaryProvider?.userActivity(visible: view.window?.isVisible == true, typing: !refresh && !preserveSelection)
        let token = generation.next()
        let additionalOnly = filters.additionalSelected
        let sources = additionalOnly ? [] : scopedSources
        if !snapshot && filters.options.sortsRecentResults != sortingRecent {
            var options = SettingsPreferences.searchOptions(in: preferences, recent: sortingRecent)
            options.kind = filters.options.kind
            filters.options = options
        }
        let store = sources.first?.store
        var options = filters.options
        if !snapshot { options.pinyin = UserDefaults.standard.bool(forKey: "pinyinEnabled") }
        let query = editingQuery(store: store), previous = results.result
        let cancelled = { [generation] in !generation.current(token) }
        let supplementary = additionalOnly ? nil : supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: cancelled)
        let additional = additionalSearchProvider.flatMap { provider in
            provider.isEnabled && (additionalOnly || options.kind == nil && folderScope == nil && volumeScope == nil && !hiddenOnly) ? provider.prepareSearch(query, isCancelled: cancelled) : nil
        }
        additionalSearchFailed = false
        additionalPending = !refresh && additional != nil
        if sources.isEmpty && additional == nil {
            pendingNewSearch = nil
            results.clear(preservingViewport: true)
            setState(manager != nil && manager?.store == nil ? .indexing : .empty)
            if let volumeScope {
                footer.warning = true
                footer.text = L10n.text("scope.unavailable", volumeScope)
            } else {
                footer.warning = false
                footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(0))
            }
            refreshProgress(); return
        }
        refreshProgress()
        let additionalBox = AdditionalSearchBox()
        let group = DispatchGroup()
        let box = SupplementarySearchBox()
        if let supplementary {
            group.enter()
            supplementQueue.async { box.hits = supplementary(); group.leave() }
        }
        if let additional {
            group.enter()
            additionalQueue.async {
                let began = CFAbsoluteTimeGetCurrent()
                do { additionalBox.items = try additional() } catch { additionalBox.failed = true }
                additionalBox.elapsedMs = (CFAbsoluteTimeGetCurrent() - began) * 1000
                group.leave()
            }
        }
        let anchor = refresh || preserveSelection ? selectionAnchor : nil
        queue.async { [weak self] in
            guard let self, self.generation.current(token) else { return }
            let found: SearchPresentation
            if sources.isEmpty { found = SearchPresentation(query: query) }
            else if sources.count == 1 && sources[0].id == "startup", let store {
                if !self.sourceCaches.isEmpty { self.sourceCaches.removeAll(); self.sourceCacheStores.removeAll() }
                if previous?.single?.store !== store { self.cache.removeAll() }
                guard let result = self.cache.lookup(query: query, options: options, store: store)
                    ?? Searcher.search(query, options: options, in: store, previous: previous?.single, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                self.cache.insert(result); found = SearchPresentation(result)
            } else {
                if previous?.single != nil { self.cache.removeAll() }
                self.sourceCaches = self.sourceCaches.filter { key, _ in sources.contains { $0.id == key } }
                self.sourceCacheStores = self.sourceCacheStores.filter { key, _ in sources.contains { $0.id == key } }
                for source in sources {
                    let identity = ObjectIdentifier(source.store)
                    if self.sourceCacheStores[source.id] != identity {
                        self.sourceCaches[source.id] = SearchCache(); self.sourceCacheStores[source.id] = identity
                    }
                }
                guard let result = MultiSearcher.search(query, options: options, in: sources, previous: previous?.multiple, caches: self.sourceCaches, isCancelled: { !self.generation.current(token) }), self.generation.current(token) else { return }
                found = SearchPresentation(result)
            }
            let anchoredRow = anchor.flatMap { found.index(sourceID: $0.sourceID, store: $0.store, id: $0.id, path: $0.path) }
            let row = anchoredRow ?? 0
            let deferNames = sources.isEmpty && additional != nil || previous?.query.raw == query.raw && ((refresh || preserveSelection) && (previous?.hasAdditional == true || previous?.hasSupplements == true) || anchor != nil && anchoredRow == nil && supplementary != nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation.current(token) else { return }
                self.diagnostics = query.diagnostics
                if deferNames { return }
                if refresh {
                    self.results.refresh(found)
                } else {
                    self.pendingNewSearch = nil
                    if preserveSelection, self.results.result != nil { self.results.refresh(found) }
                    else { self.present(found, selection: row, resetScroll: !preserveSelection) }
                }
            }
            if supplementary != nil || additional != nil {
                group.notify(queue: self.queue) { [weak self] in
                    guard let self, self.generation.current(token) else { return }
                    if additional == nil && box.hits.isEmpty && !deferNames { return }
                    let files = box.hits.isEmpty ? found : found.supplement(box.hits, options: options)
                    let combined = files.including(additionalBox.items, options: options, elapsedMs: additionalBox.elapsedMs)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation.current(token) else { return }
                        self.pendingNewSearch = nil; self.additionalPending = false; self.additionalSearchFailed = additionalBox.failed
                        self.refreshProgress()
                        guard combined.isCurrent(self.searchSources) else { return }
                        if additionalBox.failed, previous?.query.raw == query.raw, previous?.hasAdditional == true {
                            self.footer.warning = true; self.footer.text = self.additionalSearchProvider?.status ?? L10n.text("search.failed")
                            return
                        }
                        if sources.isEmpty && !refresh && !preserveSelection { self.present(combined) }
                        else { self.results.refresh(combined) }
                        if additionalBox.failed { self.footer.warning = true; self.footer.text = L10n.text("search.failed") }
                    }
                }
            }
        }
    }
    func present(_ result: SearchResult, selection: Int = 0, resetScroll: Bool = true) { present(SearchPresentation(result), selection: selection, resetScroll: resetScroll) }
    func present(_ result: SearchPresentation, selection: Int = 0, resetScroll: Bool = true) {
        results.show(result, selection: selection, resetScroll: resetScroll)
        resultDidChange(result)
    }
    private func editingQuery(store: IndexStore?) -> Query {
        var query = Query.parse(searchField.text, store: store, editingRange: searchField.input.currentEditor() == nil ? nil : searchField.editor.selectedRange(), isComposing: searchField.editor.hasMarkedText(), fuzzyNames: fuzzyNames && !filters.additionalSelected, pathExists: { [self] path in
            if searchSources.contains(where: { source in source.store.read { source.store.containsPath(path) } }) { return true }
            var info = stat(); return path.withCString { stat($0, &info) == 0 }
        })
        if !filters.additionalSelected {
            if let folderScope { query = query.restricted(toFolder: folderScope) }
            if hiddenOnly { query = query.showingOnlyHiddenFiles() }
        }
        return query
    }
    private func refreshDiagnostics() {
        let query = editingQuery(store: manager?.store ?? results.result?.store)
        guard let result = results.result, result.query.raw == query.raw else { return }
        diagnostics = query.diagnostics
        configureEmpty(result); updateFooter(result)
    }
    private func configureEmpty(_ result: SearchPresentation) {
        empty.configure(diagnostic: diagnostics.first, hasNoAccess: snapshotNoAccess || (!Permissions.hasFullDiskAccess() && result.sources.contains { source in source.store.read { source.store.coverage[.noAccess].count > 0 } }),
                        explanation: coverageExplanation)
    }
    func toggleSyntax(_ show: Bool? = nil) {
        let visible = show ?? !syntaxVisible
        syntaxVisible = visible
        refreshInlinePreview()
        view.needsLayout = true
        footer.actionable = !visible && stateView == nil && (results.result?.total ?? 0) > 0
        syntaxScroll.isHidden = false
        Theme.Motion.opacity(syntaxScroll, to: visible ? 1 : 0, using: snapshot ? nil : Theme.Motion.chip)
        if let layer = syntaxScroll.layer { Theme.Motion.animate(layer, "transform.translation.y", to: visible ? 0 : 8, using: snapshot ? nil : Theme.Motion.chip) }
        if !visible {
            if snapshot { syntaxScroll.isHidden = true }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + Theme.Motion.chip.settlingDuration) { [weak self] in if self?.syntaxVisible == false { self?.syntaxScroll.isHidden = true } } }
        }
    }
    private func resultDidChange(_ result: SearchPresentation) {
        coverageExplanation = nil
        configureEmpty(result)
        explainEmptyResult(result)
        setState(result.total == 0 ? .empty : nil)
        updateFooter(result)
        refreshProgress()
    }
    private var explicitPath: String? {
        let text = searchField.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unquoted = text.count >= 2 && (text.first == "'" || text.first == "\u{22}") && text.last == text.first
            ? String(text.dropFirst().dropLast()) : text
        let path: String
        if unquoted.lowercased().hasPrefix("file:") {
            guard let url = URL(string: unquoted), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        } else {
            // Preserve literal names first; paste normalization also accepts escaped paths.
            let normalized = text.hasPrefix("/") || text.hasPrefix("~/") ? text : Query.normalizePaste(text)
            path = NSString(string: normalized).expandingTildeInPath
        }
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return nil }
        return path
    }

    private func explainEmptyResult(_ result: SearchPresentation) {
        guard !snapshot, result.total == 0, diagnostics.isEmpty, !filters.additionalSelected,
              folderScope == nil, volumeScope == nil, !hiddenOnly, let path = explicitPath else { return }
        let sources = searchSources.filter { $0.id != "startup" }
        let manager = manager
        coverageQueue.async { [weak self, weak result] in
            guard result != nil else { return }
            let answer = sources.lazy.compactMap { $0.explain(path: path) }.first ?? manager?.explain(path: path)
            DispatchQueue.main.async { [weak self, weak result] in
                guard let self, let result, self.results.result === result, self.explicitPath == path else { return }
                self.coverageExplanation = answer
                self.configureEmpty(result)
            }
        }
    }

    private func updateFooter(_ result: SearchPresentation) {
        footer.warning = !diagnostics.isEmpty
        if let diagnostic = diagnostics.first { footer.text = L10n.diagnostic(diagnostic); return }
        if additionalSearchFailed { footer.warning = true; footer.text = L10n.text("search.failed"); return }
        if filters.additionalSelected {
            footer.text = L10n.text("footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
            if let status = additionalSearchProvider?.status { footer.text = status }
        } else if result.query.isEmpty {
            let count = Presentation.countText(result.sources.reduce(0) { count, source in count + source.store.read { source.store.liveCount } })
            footer.text = L10n.text("footer.recent", count)
        } else {
            footer.text = L10n.text(result.sortedCount < result.total ? "footer.partial" : "footer.results", Presentation.countText(result.total), Presentation.elapsedText(result.elapsedMs))
        }
        if multipleSelected { footer.text = L10n.text("footer.selected", Presentation.countText(results.selectionCount)) }
    }
    func prepareSnapshot(state: String, query: String, options: SearchOptions, store: IndexStore?, selection: Int, additionalSources: [SearchSource] = [], additionalOnly: Bool = false) throws {
        _ = view
        searchField.text = state == "recent" ? "" : query; filters.options = options
        refreshAccessories()
        if state == "indexing" {
            setState(.indexing); indexing.updateCount(1_234_567); searchField.indexing = true
            footer.text = L10n.text("footer.indexing", Presentation.countText(1_234_567)); return
        }
        if additionalOnly || additionalSearchProvider?.isEnabled == true {
            if additionalOnly { filters.select(FilterBar.names.count, notify: false); refreshAdditionalFilter() }
            _ = generation.next(); pendingNewSearch = nil
            let query = Query.parse(searchField.text, store: store)
            let sources = additionalOnly ? [] : store.map { [SearchSource(id: "startup", displayName: "", isOnline: true, store: $0)] + additionalSources } ?? additionalSources
            let files: SearchPresentation
            if sources.isEmpty { files = SearchPresentation(query: query) }
            else if let found = MultiSearcher.search(query, options: options, in: sources) {
                let hits = supplementaryProvider?.prepareSearch(query, options: options, sources: sources, isCancelled: { false })() ?? []
                files = hits.isEmpty ? SearchPresentation(found) : SearchPresentation(found).supplement(hits, options: options)
            } else { throw SnapshotError.failed("Cannot search snapshot index") }
            let began = CFAbsoluteTimeGetCurrent()
            let items = additionalOnly || options.kind == nil ? try additionalSearchProvider?.prepareSearch(query, isCancelled: { false })() ?? [] : []
            diagnostics = query.diagnostics; present(files.including(items, options: options, elapsedMs: (CFAbsoluteTimeGetCurrent() - began) * 1000), selection: selection); return
        }
        if let store, let supplementaryProvider {
            let sources = [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources
            let query = Query.parse(searchField.text, store: store)
            let hits = supplementaryProvider.prepareSearch(query, options: options, sources: sources, isCancelled: { false })()
            guard let found = MultiSearcher.search(query, options: options, in: sources) else { throw SnapshotError.failed("Cannot search snapshot index") }
            diagnostics = query.diagnostics; present(SearchPresentation(found).supplement(hits, options: options), selection: selection); return
        }
        if let store, !additionalSources.isEmpty, let found = MultiSearcher.search(Query.parse(searchField.text, store: store), options: options, in: [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] + additionalSources) {
            diagnostics = found.query.diagnostics; present(SearchPresentation(found), selection: selection); return
        }
        guard let store, let found = Searcher.search(Query.parse(searchField.text, store: store), options: options, in: store) else { throw SnapshotError.failed("Cannot search snapshot index") }
        diagnostics = Query.parse(searchField.text, store: store).diagnostics
        snapshotNoAccess = state == "no-access"
        present(found, selection: selection)
        if state == "syntax" { toggleSyntax(true) }
        if state == "toast", let item = results.selectedItem { footer.showToast(.copiedPath, value: item.path, snapshot: true) }
        if state == "empty" {
            setState(.empty)
            footer.text = L10n.text("footer.results", Presentation.countText(0), Presentation.elapsedText(found.elapsedMs))
        }
    }
    #if DEBUG
    func prepareStashSnapshot() {
        let files = (0..<6).compactMap { results.item(at: $0) }.map { StashedFile(url: URL(fileURLWithPath: $0.path)) }
        footer.stashCount = files.count
        accessories.setStash(files: files, expanded: true, copy: {}, open: {}, dragging: { _ in },
                             leaveSearch: {}, remove: { _ in }, menuDelegate: self)
        view.needsLayout = true
    }
    #endif

    private var selectedURL: URL? {
        guard stateView == nil else { return nil }
        return results.selectedItem.map { URL(fileURLWithPath: $0.path) }
    }
    /// File results of the whole selection whose source is still online, focused row first.
    private var selectedOnlineItems: [ResultItem] {
        guard stateView == nil else { return [] }
        return results.selectedItems.filter { item in
            item.source.isOnline && (snapshot || searchSources.first { $0.id == item.source.id }.map { $0.isOnline && $0.store === item.source.store } == true)
        }
    }
    private lazy var panelShortcuts = makePanelShortcuts()

    private func makePanelShortcuts() -> [StashShortcut.Chord: StashShortcut] {
        Dictionary(StashShortcut.allCases.map { ($0.chord(in: preferences), $0) }, uniquingKeysWith: { first, _ in first })
    }

    func refreshShortcuts() {
        panelShortcuts = makePanelShortcuts()
        footer.updateShortcuts(in: preferences)
        syntax.localize()
    }

    private var multipleSelected: Bool { results.selectionCount > 1 && results.selectedAdditional == nil }
    func handleKey(_ event: NSEvent) -> Bool {
        if (view.window as? SearchPanel)?.hiding == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if searchField.editor.hasMarkedText() { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A nonactivating panel has no Edit menu to dispatch text shortcuts.
        if flags.intersection([.command, .control, .option, .shift]) == .command,
           let editor = searchField.input.currentEditor() {
            switch key {
            case "a" where !browsingResults: editor.selectAll(nil); return true
            case "c" where editor.selectedRange.length > 0: editor.copy(nil); return true
            case "x": editor.cut(nil); return true
            case "v": editor.paste(nil); return true
            default: break
            }
        }
        let chord = StashShortcut.Chord(keyCode: UInt32(event.keyCode), modifiers: HotKey.carbonModifiers(flags))
        let action: StashShortcut?
        if event.keyCode == 76, chord.modifiers == StashShortcut.open.defaultChord.modifiers,
           StashShortcut.open.chord(in: preferences) == StashShortcut.open.defaultChord {
            action = .open
        } else if event.keyCode == 76, chord.modifiers == StashShortcut.reveal.defaultChord.modifiers,
                  StashShortcut.reveal.chord(in: preferences) == StashShortcut.reveal.defaultChord {
            action = .reveal
        } else {
            action = panelShortcuts[chord]
        }

        if let handled = accessories.handleStashKey(event, action: action) { return handled }
        if action == .syntax {
            if !event.isARepeat { toggleSyntax() }
            return true
        }
        if action == .escape {
            if syntaxVisible { toggleSyntax(false) }
            else if quickLook.isVisible { quickLook.close() }
            else { hidePanel?() }
            return true
        }
        if syntaxVisible { return false }
        if event.keyCode == 49 && chord.modifiers == 0 && (quickLook.isVisible || spaceOpensQuickLook) {
            if !event.isARepeat { previewSelected() }
            return true
        }
        guard let action else { return false }
        switch action {
        case .up, .down, .extendUp, .extendDown, .first, .last, .pageUp, .pageDown, .home, .end:
            setBrowsing(true)
            switch action {
            case .up: results.move(-1, repeatKey: event.isARepeat)
            case .down: results.move(1, repeatKey: event.isARepeat)
            case .extendUp: results.extend(-1, repeatKey: event.isARepeat)
            case .extendDown: results.extend(1, repeatKey: event.isARepeat)
            case .first, .home: results.select(0, repeatKey: event.isARepeat)
            case .last, .end: results.select((results.result?.count ?? 1) - 1, repeatKey: event.isARepeat)
            case .pageUp: results.page(-1, repeatKey: event.isARepeat)
            case .pageDown: results.page(1, repeatKey: event.isARepeat)
            default: break
            }
            return true
        case .selectAll:
            guard browsingResults else { return false }
            results.selectAll(); return true
        default: break
        }
        if event.isARepeat { return true }
        switch action {
        case .add: stashSelection()
        case .show: toggleStash()
        case .paste: pasteSelectionInPreviousApp()
        case .actions: showActions(anchoredTo: footer)
        case .preview: previewSelected()
        case .inlinePreview: toggleInlinePreview()
        case .open:
            if !browsingResults, !filters.additionalSelected, let path = explicitPath { openExplicitPath(path) }
            else { openSelected() }
        case .reveal: revealSelected()
        case .copyPath: copyPath()
        case .copyName: copyName()
        case .trash: trashSelected()
        case .settings: onSettings?()
        case .close: hidePanel?()
        case .nextFilter: filters.cycle(1)
        case .previousFilter: filters.cycle(-1)
        case .terminal: openSelectedInTerminal()
        case .duplicate: duplicateSelectedFiles()
        case .copyTo: transferSelectedFiles(move: false)
        case .moveTo: transferSelectedFiles(move: true)
        default:
            if StashShortcut.categories.contains(action) { filters.select(action.slot) }
            else if StashShortcut.quickFilters.contains(action) { return applyQuickFilter(at: action.slot) }
            else if StashShortcut.scripts.contains(action) {
                let scripts = FileScript.load(from: preferences)
                guard scripts.indices.contains(action.slot) else { return false }
                runFileScript(scripts[action.slot])
            } else { return false }
        }
        return true
    }
    private func openExplicitPath(_ path: String) {
        let text = searchField.text
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let alternate = NSString(string: Query.normalizePaste(text)).expandingTildeInPath
            let target = [path, alternate].first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchField.text == text, self.view.window?.isVisible == true,
                      (self.view.window as? SearchPanel)?.hiding != true else { return }
                guard let target else {
                    self.footer.warning = true
                    self.footer.text = L10n.text("path.unavailable")
                    return
                }
                NSWorkspace.shared.open(URL(fileURLWithPath: target), configuration: .init()) { [weak self] _, error in
                    DispatchQueue.main.async {
                        guard let self, self.searchField.text == text else { return }
                        if error == nil { self.hidePanel?() }
                        else { self.footer.warning = true; self.footer.text = L10n.text("path.unavailable") }
                    }
                }
            }
        }
    }

    private func openSelected() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .open); return }
        if multipleSelected { openMultiple(); return }
        guard stateView == nil, (view.window as? SearchPanel)?.hiding != true, let url = selectedURL else { return }
        guard allowOnlineAction() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { NSSound.beep(); return }
        results.pressOpen { [weak self] in
            guard self?.allowOnlineAction() == true else { return }
            guard NSWorkspace.shared.open(url) else { NSSound.beep(); return }
            self?.hidePanel?()
        }
    }
    private func openMultiple() {
        guard (view.window as? SearchPanel)?.hiding != true else { return }
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        results.pressOpen { [weak self] in
            var opened = false
            for url in urls { opened = NSWorkspace.shared.open(url) || opened }
            if opened { self?.hidePanel?() } else { NSSound.beep() }
        }
    }
    private func revealSelected() {
        if multipleSelected {
            let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
            guard !urls.isEmpty else { NSSound.beep(); return }
            NSWorkspace.shared.activateFileViewerSelecting(urls); hidePanel?(); return
        }
        guard stateView == nil, let url = selectedURL, allowOnlineAction() else { return }; NSWorkspace.shared.activateFileViewerSelecting([url]); hidePanel?()
    }
    @discardableResult
    private func allowOnlineAction() -> Bool {
        guard let item = results.selectedItem else { return false }
        // Check the live provider as well as the submitted snapshot during an in-flight refresh.
        let current = searchSources.first { $0.id == item.source.id }
        guard item.source.isOnline && (snapshot || current?.isOnline == true) else {
            footer.warning = true; footer.actionable = false
            footer.text = L10n.text("source.unavailable", item.source.displayName)
            return false
        }
        return snapshot || current?.store === item.source.store
    }
    private func toggleInlinePreview() {
        if syntaxVisible { toggleSyntax(false) }
        setInlinePreviewVisible(!inlinePreviewVisible)
        restoreFocus()
    }

    func setInlinePreviewVisible(_ visible: Bool, resize: Bool = true) {
        guard visible != inlinePreviewVisible else { return }
        inlinePreviewVisible = visible
        footer.inlinePreviewVisible = visible
        footer.spacePreview = spaceOpensQuickLook
        refreshInlinePreview()
        if resize { (view.window as? SearchPanel)?.resizeForInlinePreview() }
        view.needsLayout = true
    }

    private func refreshInlinePreview() {
        let visible = inlinePreviewVisible && !syntaxVisible
        inlinePreview.isHidden = !visible
        guard visible, stateView == nil, let item = results.selectedItem else {
            inlinePreview.update(url: nil)
            return
        }
        let online = item.source.isOnline && (snapshot || searchSources.contains {
            $0.id == item.source.id && $0.isOnline && $0.store === item.source.store
        })
        inlinePreview.update(url: online ? URL(fileURLWithPath: item.path) : nil,
                             isDirectory: item.flags & SiftFlag.dir != 0, isUnavailable: !online)
    }

    private func previewSelected() {
        if quickLook.isVisible { quickLook.close() } else if allowOnlineAction() { quickLook.open() }
    }
    /// Selection in the search field before the preview opened, restored when it closes.
    private var focusSelection: NSRange?
    private func rememberFocus() {
        guard let window = view.window else { return }
        focusSelection = window.firstResponder === searchField.editor ? searchField.editor.selectedRange : nil
    }
    /// Gives key status back to the search panel and puts the caret back where it was,
    /// without selecting the whole query (which made the next keystroke replace it).
    private func restoreFocus() {
        guard let window = view.window, window.isVisible, (window as? SearchPanel)?.hiding != true else { return }
        if !window.isKeyWindow { window.makeKey() }
        if window.firstResponder === searchField.editor { focusSelection = nil; return }
        let length = (searchField.text as NSString).length
        let range = focusSelection ?? NSRange(location: length, length: 0)
        focusSelection = nil
        searchField.focus()
        let location = min(range.location, length)
        searchField.editor.selectedRange = NSRange(location: location, length: min(range.length, length - location))
    }
    /// Keys that reach the preview panel while it is key: take focus back and replay them
    /// through the search panel, so navigation keeps working and typed text lands in the field.
    private func forwardPreviewKey(_ event: NSEvent) -> Bool {
        restoreFocus()
        if handleKey(event) { return true }
        guard view.window?.firstResponder === searchField.editor else { return false }
        let flags = event.modifierFlags.intersection([.command, .control])
        guard flags.isEmpty else { return false }
        searchField.editor.keyDown(with: event)
        return true
    }
    private func copyPath() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .copy); return }
        if multipleSelected {
            let urls = results.selectedItems.map { URL(fileURLWithPath: $0.path) }
            guard stateView == nil, !urls.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
            NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            footer.showToast(.copiedPath, value: L10n.text("selection.items", Presentation.countText(urls.count))); return
        }
        guard stateView == nil, let url = selectedURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([url as NSURL]); NSPasteboard.general.setString(url.path, forType: .string)
        footer.showToast(.copiedPath, value: url.path)
    }
    private func copyName() {
        if let item = results.selectedAdditional { performAdditional(item, kind: .copyName); return }
        if multipleSelected {
            let names = results.selectedItems.map(\.name)
            guard stateView == nil, !names.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
            footer.showToast(.copiedName, value: L10n.text("selection.items", Presentation.countText(names.count))); return
        }
        guard stateView == nil, let item = results.selectedItem else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.name, forType: .string)
        footer.showToast(.copiedName, value: item.name)
    }
    private func trashSelected() {
        if multipleSelected { trashMultiple(); return }
        guard stateView == nil, let url = selectedURL, let item = results.selectedItem else { return }
        guard allowOnlineAction(), FileManager.default.fileExists(atPath: url.path), trashing.insert(url).inserted else { return }
        NSWorkspace.shared.recycle([url]) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.trashing.remove(url)
                if error != nil { NSSound.beep() }
                else { self?.footer.showToast(.trashed, value: item.name) }
            }
        }
    }
    private func trashMultiple() {
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
            .filter { FileManager.default.fileExists(atPath: $0.path) && !trashing.contains($0) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        trashing.formUnion(urls)
        NSWorkspace.shared.recycle(urls) { [weak self] moved, error in
            DispatchQueue.main.async {
                self?.trashing.subtract(urls)
                if error != nil { NSSound.beep() }
                if !moved.isEmpty { self?.footer.showToast(.trashed, value: L10n.text("selection.items", Presentation.countText(moved.count))) }
            }
        }
    }
    private func performAdditional(_ item: AdditionalSearchItem, kind: AdditionalSearchAction.Kind) {
        guard pendingNewSearch == nil, stateView == nil, results.result?.query.raw == searchField.text, additionalSearchProvider?.isEnabled == true,
              let action = item.actions.first(where: { $0.kind == kind }) else { return }
        let perform = { [weak self] in
            guard let self, self.results.selectedAdditional?.id == item.id, self.additionalSearchProvider?.isEnabled == true else { return }
            self.runAdditional(action)
        }
        if kind == .open { results.pressOpen(perform) } else { perform() }
    }
    private func runAdditional(_ action: AdditionalSearchAction) {
        guard additionalSearchProvider?.isEnabled == true, pendingNewSearch == nil else { return }
        action.perform { [weak self] success in
            guard let self else { return }
            if success { if action.kind == .open { self.hidePanel?() } }
            else { self.footer.warning = true; self.footer.text = L10n.text("search.actionFailed") }
        }
    }
    @objc private func additionalContextAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? AdditionalSearchAction else { return }; runAdditional(action)
    }
    private func showActions(anchoredTo anchor: NSView) {
        guard stateView == nil, !syntaxVisible, results.selectedItem != nil || results.selectedAdditional != nil else { return }
        let menu = contextMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.midX, y: 0), in: anchor)
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        if let selected = results.selectedAdditional {
            for action in selected.actions {
                let item = NSMenuItem(title: action.title, action: #selector(additionalContextAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = action; menu.addItem(item)
            }
            return menu
        }
        let selected = results.selectedItems
        let onlineCount = selectedOnlineItems.count
        let allOnline = onlineCount == selected.count
        @discardableResult
        func action(_ key: String, _ selector: Selector, enabled: Bool = true, tag: Int = 0) -> NSMenuItem {
            let item = menu.addItem(withTitle: L10n.text(key), action: selector, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.tag = tag
            return item
        }
        menu.autoenablesItems = false
        guard !selected.isEmpty else { return menu }

        StashShortcut.open.chord(in: preferences).apply(to: action("ctx.open", #selector(contextAction(_:)), enabled: onlineCount > 0))
        StashShortcut.reveal.chord(in: preferences).apply(to: action("ctx.reveal", #selector(contextAction(_:)), enabled: onlineCount > 0, tag: 1))
        StashShortcut.preview.chord(in: preferences).apply(to: action("ctx.preview", #selector(contextAction(_:)), enabled: selected.first?.source.isOnline == true, tag: 2))
        if !multipleSelected {
            menu.addItem(.separator())
            action("ctx.openWith", #selector(chooseApplication), enabled: allOnline)
            StashShortcut.terminal.chord(in: preferences).apply(to: action("ctx.terminal", #selector(openSelectedInTerminal), enabled: allOnline))
            action("scope.inFolder", #selector(scopeToSelection))
        }
        menu.addItem(.separator())
        StashShortcut.duplicate.chord(in: preferences).apply(to: action("ctx.duplicate", #selector(duplicateSelectedFiles), enabled: allOnline))
        menu.addItem(.separator())
        action("ctx.copyFiles", #selector(copySelectedFiles), enabled: allOnline)
        FileClipboardFormat.addMenu(to: menu, titleKey: "ctx.copyPaths", target: self,
                                    action: #selector(copySelectionText(_:)), baseTag: 0)
        FileClipboardFormat.addMenu(to: menu, titleKey: "ctx.copyNames", target: self,
                                    action: #selector(copySelectionText(_:)), baseTag: 3)
        let paste = action("filePaste.title", #selector(pasteSelectionInPreviousApp), enabled: onlineCount > 0)
        StashShortcut.paste.chord(in: preferences).apply(to: paste)

        menu.addItem(.separator())
        StashShortcut.copyTo.chord(in: preferences).apply(to: action("ctx.copyTo", #selector(transferSelectedFiles(_:)), enabled: allOnline))
        StashShortcut.moveTo.chord(in: preferences).apply(to: action("ctx.moveTo", #selector(transferSelectedFiles(_:)), enabled: allOnline, tag: 1))

        menu.addItem(.separator())
        let stash = action("stash.add", #selector(stashSelection), enabled: onlineCount > 0)
        StashShortcut.add.chord(in: preferences).apply(to: stash)
        if let scripts = fileScriptsMenu() {
            let item = menu.addItem(withTitle: L10n.text("fileScripts.run"), action: nil, keyEquivalent: "")
            item.submenu = scripts
            item.isEnabled = allOnline
        }
        menu.addItem(.separator())
        StashShortcut.trash.chord(in: preferences).apply(to: action("ctx.trash", #selector(contextAction(_:)), enabled: onlineCount > 0, tag: 7))
        action("ctx.exclude", #selector(excludeSelected))
        return menu
    }
    @objc private func openSelectedInTerminal() {
        guard let item = results.selectedItem, allowOnlineAction(),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        let directory = item.flags & SiftFlag.dir != 0 ? item.path : item.parentPath
        NSWorkspace.shared.open([URL(fileURLWithPath: directory)], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                if error == nil { self?.hidePanel?() }
                else { NSSound.beep() }
            }
        }
    }

    @objc private func copySelectionText(_ sender: NSMenuItem) {
        let values = results.selectedItems.map { sender.tag < 3 ? $0.path : $0.name }
        FileClipboardFormat(rawValue: sender.tag % 3)?.copy(values)
    }

    @objc private func transferSelectedFiles(_ sender: NSMenuItem) {
        transferSelectedFiles(move: sender.tag == 1)
    }

    private func transferSelectedFiles(move: Bool) {
        let paths = selectedOnlineItems.map(\.path)
        guard !snapshot, !paths.isEmpty, paths.count == results.selectedItems.count else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window?.isVisible == true else { return }
            self.rememberFocus()
            self.menuTracking = true
            defer { self.menuTracking = false; self.restoreFocus() }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = L10n.text(move ? "ctx.moveButton" : "ctx.copyButton")
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            self.footer.warning = false
            self.footer.text = L10n.text(move ? "ctx.moving" : "ctx.copying")
            self.fileTransferQueue.async { [weak self] in
                let completed = ResultFileTransfer.run(paths: paths, to: folder, move: move)
                DispatchQueue.main.async { [weak self] in
                    self?.footer.warning = completed != paths.count
                    self?.footer.text = L10n.text(move ? "ctx.movedCount" : "ctx.copiedCount", String(completed), String(paths.count))
                }
            }
        }
    }

    @objc private func copySelectedFiles() {
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty, urls.count == results.selectedItems.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }

    @objc private func duplicateSelectedFiles() {
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
        guard !snapshot, !urls.isEmpty, urls.count == results.selectedItems.count else { return }
        NSWorkspace.shared.duplicate(urls) { [weak self] copies, error in
            DispatchQueue.main.async {
                self?.footer.warning = error != nil
                self?.footer.text = error == nil
                    ? L10n.text("ctx.duplicated", String(copies.count))
                    : L10n.text("ctx.duplicateFailed", String(copies.count), String(urls.count))
            }
        }
    }

    private func fileScriptsMenu() -> NSMenu? {
        let scripts = FileScript.load(from: preferences)
        guard !scripts.isEmpty else { return nil }
        let menu = NSMenu()
        for (index, script) in scripts.enumerated() {
            let item = menu.addItem(withTitle: script.name, action: #selector(runFileScriptItem(_:)), keyEquivalent: "")
            if StashShortcut.scripts.indices.contains(index) { StashShortcut.scripts[index].chord(in: preferences).apply(to: item) }
            item.target = self
            item.representedObject = script.path
            item.toolTip = script.path
        }
        return menu
    }

    @objc private func runFileScriptItem(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String,
              let script = FileScript.load(from: preferences).first(where: { $0.path == path }) else { return }
        runFileScript(script)
    }

    private func runFileScript(_ script: FileScript) {
        guard !snapshot else { return }
        let files = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
        guard !files.isEmpty, files.count == results.selectedItems.count else {
            footer.warning = true
            footer.text = L10n.text("fileScripts.unavailable")
            return
        }
        hidePanel?()
        if scriptWindow.isRunning { scriptWindow.present() }
        else { scriptWindow.start(script, files: files) }
    }

    func captureFilePasteDestination() {
        if !snapshot { filePaste.captureDestination() }
    }

    @objc private func pasteSelectionInPreviousApp() {
        guard !snapshot, let panel = view.window as? SearchPanel else { return }
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
        filePaste.paste(urls, dismiss: { [weak self, weak panel] in
            guard let self, self.selectedOnlineItems.map(\.path) == urls.map(\.path) else { return false }
            return panel?.dismissForFilePaste() == true
        }, failed: { [weak self] reason in
            guard let self else { return }
            if self.view.window?.isVisible == true {
                self.footer.warning = true
                self.footer.text = L10n.text("filePaste." + reason.rawValue)
            } else { NSSound.beep() }
        })
    }

    func showStash() {
        hidePanel?()
        stashWindow.present()
    }

    @objc private func stashSelection() {
        let urls = selectedOnlineItems.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        fileStash.add(urls) { [weak self] count in
            guard let self else { return }
            if count > 0 { self.stashExpanded = true }
            guard self.view.window?.isVisible == true else { return }
            self.refreshAccessories()
            if count > 0 {
                self.view.layoutSubtreeIfNeeded()
                self.accessories.revealAddedStashFiles(count)
            }
            self.footer.warning = false
            self.footer.text = count > 0
                ? L10n.text("stash.added", Presentation.countText(count))
                : L10n.text("stash.nothingAdded")
        }
    }

    @objc private func excludeSelected() {
        guard !snapshot, stateView == nil else { return }
        let paths = results.selectedItems.filter { $0.path != $0.source.store.rootPath }.map(\.path)
        guard !paths.isEmpty else { return }
        let previous = preferences.stringArray(forKey: "userExcludedPaths") ?? []
        let updated = ExcludedFolders.adding(paths, to: previous)
        guard updated != previous else { return }
        SettingsPreferences.setExcludedPaths(updated, in: preferences)
        footer.warning = false
        footer.text = L10n.text("scope.exclusionSaved")
    }
    @objc private func chooseApplication() {
        guard let file = selectedURL, !multipleSelected, allowOnlineAction() else { return }
        let location = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let applications = NSWorkspace.shared.urlsForApplications(toOpen: file).map { url in
                (url, FileManager.default.displayName(atPath: url.path))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.view.window?.isKeyWindow == true, self.selectedURL == file,
                      self.allowOnlineAction() else { return }
                let menu = NSMenu()
                menu.delegate = self
                if applications.isEmpty {
                    menu.addItem(withTitle: L10n.text("ctx.noApplications"), action: nil, keyEquivalent: "")
                }
                for (url, name) in applications {
                    let item = menu.addItem(withTitle: name, action: #selector(self.openWithApplication(_:)), keyEquivalent: "")
                    item.target = self; item.representedObject = [file, url]
                }
                menu.popUp(positioning: nil, at: location, in: self.view)
            }
        }
    }

    @objc private func openWithApplication(_ item: NSMenuItem) {
        guard let urls = item.representedObject as? [URL], urls.count == 2, selectedURL == urls[0], allowOnlineAction() else { return }
        NSWorkspace.shared.open([urls[0]], withApplicationAt: urls[1], configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                if error == nil { self?.hidePanel?() }
                else { NSSound.beep() }
            }
        }
    }

    @objc private func contextAction(_ item: NSMenuItem) {
        switch item.tag { case 0: openSelected(); case 1: revealSelected(); case 2: previewSelected(); case 7: trashSelected(); default: break }
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false; hideIfInactive() }
    private func hideIfInactive() {
        if CFAbsoluteTimeGetCurrent() - quickLookDismissTime < 0.4 { return }
        if view.window?.isKeyWindow == false && !quickLook.isVisible && !menuTracking && !dragging { hidePanel?() }
    }
    func windowDidResignKey(_ notification: Notification) {
        // Quick Look visibility settles after the key-window transition.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.quickLook.isVisible || CFAbsoluteTimeGetCurrent() - self.quickLookDismissTime < 0.4 { return }
            self.hideIfInactive()
        }
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === searchField.input ? searchField.editor : nil
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { selectedURL != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }
}
