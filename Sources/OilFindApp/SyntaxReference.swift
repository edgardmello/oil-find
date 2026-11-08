import AppKit

// The tuples mirror site/content/dict.ts; site tests verify every example, explanation and group.
private final class SyntaxRow: NSButton {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
}
final class SyntaxReference: FlippedView {
    static let zh = [
        ["wd", "拼音首字母，找到「文档」", "拼音"],
        ["readme !node_modules", "包含 readme，排除 node_modules 里的", "排除"],
        ["*.png", "通配符，匹配整个名称", "通配"],
        ["~/Desktop/ png", "只在桌面下面找", "路径"],
        ["dm:today ext:md", "今天改过的 Markdown", "时间"]
    ]
    static let en = [
        ["wd", "Pinyin initials, finds 文档", "Pinyin"],
        ["readme !node_modules", "Contains readme, not inside node_modules", "Exclude"],
        ["*.png", "Wildcard, matches the whole name", "Wildcard"],
        ["~/Desktop/ png", "Only under the Desktop", "Path"],
        ["dm:today ext:md", "Markdown files changed today", "Date"]
    ]
    // The side column is app-only: more clickable syntax, then keys including multiple selection and dragging.
    static let moreZh = [
        ["foo | bar", "包含任意一个"],
        ["ext:pdf;docx", "按扩展名"],
        ["kind:image", "按类型：folder、app、doc、image…"],
        ["size:>10mb", "按大小，也可写 1mb..5mb"],
        ["folder:", "只看文件夹，file: 只看文件"],
        ["regex:^IMG_\\d+", "正则表达式"],
        ["fuzzy:rdm", "按顺序匹配文件名中的字符"]
    ]
    static let moreEn = [
        ["foo | bar", "Contains either one"],
        ["ext:pdf;docx", "By extension"],
        ["kind:image", "By kind: folder, app, doc, image…"],
        ["size:>10mb", "By size, or 1mb..5mb"],
        ["folder:", "Folders only, file: for files only"],
        ["regex:^IMG_\\d+", "Regular expression"],
        ["fuzzy:rdm", "Match filename characters in order"]
    ]
    static let keysZh = [
        ["↩  ⌘↩", "打开 / 在访达中显示"],
        ["⌘C  ⌥⌘C", "拷贝路径 / 名称"],
        ["⌘⌫", "移到废纸篓"],
        ["⇧ 点按", "选择一段连续的结果"],
        ["⌘ 点按", "加选或取消某一项"],
        ["⇧↑  ⇧↓", "用键盘扩展选择"],
        ["⌘A", "浏览结果时全选"],
        ["拖移", "拖到访达文件夹即移动，按住 ⌥ 拷贝"]
    ]
    static let keysEn = [
        ["↩  ⌘↩", "Open / Show in Finder"],
        ["⌘C  ⌥⌘C", "Copy path / name"],
        ["⌘⌫", "Move to Trash"],
        ["⇧ Click", "Select a range of results"],
        ["⌘ Click", "Add or remove one result"],
        ["⇧↑  ⇧↓", "Extend the selection"],
        ["⌘A", "Select all while browsing results"],
        ["Drag", "Move to a Finder folder, ⌥ copies"]
    ]
    private static let moreTag = 100
    var onExample: ((String) -> Void)?
    private let title = Theme.label(14, .semibold, .labelColor)
    private let moreTitle = Theme.label(12, .semibold, .secondaryLabelColor)
    private let keysTitle = Theme.label(12, .semibold, .secondaryLabelColor)
    private var buttons: [NSButton] = [], examples: [NSTextField] = [], descriptions: [NSTextField] = [], groups: [NSTextField] = []
    private var moreButtons: [NSButton] = [], moreExamples: [NSTextField] = [], moreDescriptions: [NSTextField] = []
    private var keyLabels: [NSTextField] = [], keyDescriptions: [NSTextField] = []
    private var rows: [[String]] { L10n.chinese ? Self.zh : Self.en }
    private var moreRows: [[String]] { L10n.chinese ? Self.moreZh : Self.moreEn }
    private var keyRows: [[String]] {
        [[L10n.text("syntax.previewKeys"), L10n.text("hint.preview")]] + (L10n.chinese ? Self.keysZh : Self.keysEn)
    }
    private var split: CGFloat { (bounds.width * 0.54).rounded() }
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true
        addSubview(title); addSubview(moreTitle); addSubview(keysTitle)
        // Main examples are added first so their button order stays stable.
        for (i, row) in rows.enumerated() {
            let button = SyntaxRow(title: row[0], target: self, action: #selector(choose(_:)))
            button.tag = i; button.isBordered = false; button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            let example = Theme.label(13, .medium, .controlAccentColor); example.font = button.font; example.stringValue = row[0]
            button.contentTintColor = .controlAccentColor
            let description = Theme.label(12, .regular, .secondaryLabelColor); description.stringValue = row[1]
            let group = Theme.label(11, .medium, .tertiaryLabelColor); group.stringValue = row[2]; group.alignment = .right
            buttons.append(button); examples.append(example); descriptions.append(description); groups.append(group)
            addSubview(button); [example, description, group].forEach(button.addSubview)
        }
        for (i, row) in moreRows.enumerated() {
            let button = SyntaxRow(title: row[0], target: self, action: #selector(choose(_:)))
            button.tag = Self.moreTag + i; button.isBordered = false; button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            let example = Theme.label(12, .medium, .controlAccentColor); example.font = button.font; example.lineBreakMode = .byTruncatingTail
            let description = Theme.label(11.5, .regular, .secondaryLabelColor); description.lineBreakMode = .byTruncatingTail
            moreButtons.append(button); moreExamples.append(example); moreDescriptions.append(description)
            addSubview(button); [example, description].forEach(button.addSubview)
        }
        for _ in keyRows {
            let key = Theme.label(12, .medium, .labelColor); key.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            let description = Theme.label(11.5, .regular, .secondaryLabelColor); description.lineBreakMode = .byTruncatingTail
            keyLabels.append(key); keyDescriptions.append(description); addSubview(key); addSubview(description)
        }
        localize()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func choose(_ sender: NSButton) {
        if sender.tag >= Self.moreTag { onExample?(moreRows[sender.tag - Self.moreTag][0]) } else { onExample?(rows[sender.tag][0]) }
    }
    func localize() {
        title.stringValue = L10n.text("hint.syntax")
        moreTitle.stringValue = L10n.text("syntax.more"); keysTitle.stringValue = L10n.text("syntax.keys")
        for (i, row) in rows.enumerated() {
            buttons[i].title = row[0]; examples[i].stringValue = row[0]
            descriptions[i].stringValue = row[1]; groups[i].stringValue = row[2]
        }
        for (i, row) in moreRows.enumerated() {
            moreButtons[i].title = row[0]; moreExamples[i].stringValue = row[0]; moreDescriptions[i].stringValue = row[1]
            moreButtons[i].toolTip = row[1]
        }
        for (i, row) in keyRows.enumerated() { keyLabels[i].stringValue = row[0]; keyDescriptions[i].stringValue = row[1]; keyDescriptions[i].toolTip = row[1] }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let split = split
        title.frame = NSRect(x: 28, y: 24, width: split - 56, height: 20)
        for i in buttons.indices {
            let y = CGFloat(64 + i * 67)
            buttons[i].frame = NSRect(x: 18, y: y - 4, width: split - 28, height: 63)
            examples[i].frame = NSRect(x: 10, y: 4, width: buttons[i].bounds.width - 116, height: 24)
            descriptions[i].frame = NSRect(x: 10, y: 31, width: buttons[i].bounds.width - 20, height: 18)
            groups[i].frame = NSRect(x: buttons[i].bounds.width - 98, y: 7, width: 88, height: 18)
        }
        let x = split + 28, width = max(0, bounds.width - x - 24)
        moreTitle.frame = NSRect(x: x, y: 26, width: width, height: 18)
        for i in moreButtons.indices {
            moreButtons[i].frame = NSRect(x: x - 6, y: CGFloat(50 + i * 22), width: width + 6, height: 22)
            moreExamples[i].frame = NSRect(x: 6, y: 2, width: 122, height: 18)
            moreDescriptions[i].frame = NSRect(x: 132, y: 3, width: max(0, moreButtons[i].bounds.width - 136), height: 17)
        }
        let keysTop = CGFloat(50 + moreButtons.count * 22 + 16)
        keysTitle.frame = NSRect(x: x, y: keysTop, width: width, height: 18)
        for i in keyLabels.indices {
            let y = keysTop + 24 + CGFloat(i * 20)
            keyLabels[i].frame = NSRect(x: x, y: y, width: 90, height: 18)
            keyDescriptions[i].frame = NSRect(x: x + 96, y: y + 1, width: max(0, width - 96), height: 17)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        let split = split
        for i in 0..<4 { NSRect(x: 28, y: CGFloat(120 + i * 67), width: split - 48, height: Theme.pixel(self)).fill() }
        NSRect(x: split + 8, y: 24, width: Theme.pixel(self), height: max(0, bounds.height - 48)).fill()
    }
}
