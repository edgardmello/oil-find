import AppKit
import OilFindCore

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
    private static let more = [
        ("fuzzy:rdm", "按顺序匹配文件名字符", "Match filename letters in order"),
        ("'report", "连续匹配文本", "Match contiguous text"),
        ("vacation photos", "每个词都必须匹配", "Match every word"),
        ("foo | bar", "匹配任意一个词", "Match either term"),
        (".jpg .png", "匹配任一扩展名", "Match either extension"),
        ("ext:pdf;docx", "按扩展名筛选", "Filter by extension"),
        ("in:Documents", "只在指定文件夹内搜索", "Search inside a folder"),
        ("depth:2", "最多向下搜索两层", "Search up to two folder levels"),
        ("folder:photos", "只查找匹配的文件夹", "Find matching folders"),
        ("file:", "只查找文件", "Find files only"),
        ("Photos/", "查找文件夹内的项目", "Find items inside Photos"),
        ("size:>10mb", "按大小筛选", "Filter by file size"),
        ("modified:7d", "最近七天修改的项目", "Modified in the past seven days"),
        ("dm:lastweek", "上周修改的项目", "Modified last week"),
        ("dm:2025-01..2025-03", "按修改日期范围筛选", "Filter by modification date range"),
        ("^report", "名称以 report 开头", "Name starts with report"),
        ("report$", "名称以 report 结尾，可带扩展名", "Name ends in report, with optional extension"),
        ("!.zip", "排除 ZIP 文件", "Exclude ZIP files"),
        ("!Backups/", "排除文件夹里的项目", "Exclude items inside Backups"),
        ("!/", "排除文件夹结果", "Exclude folders from results"),
        ("invoice [client]", "在发票文件内搜索文字", "Find text inside matching files"),
        ("[invoice|receipt]", "内容匹配任意一项", "Match either term inside the file"),
        ("content:\"paid invoice\"", "按短语搜索文件内容", "Find a phrase in file contents"),
        ("#work", "按访达标签搜索（需启用内容索引）", "Find Finder tags with content indexing enabled"),
        ("regex:^IMG_\\d+", "正则表达式", "Regular expression")
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
    var shortcutPreferences: UserDefaults = .standard
    private var moreRows: [[String]] { Self.more.map { [$0.0, L10n.chinese ? $0.1 : $0.2] } }
    private var keyRows: [[String]] {
        let global = Shortcut.symbols(
            keyCode: UInt32(clamping: shortcutPreferences.object(forKey: "hotKeyCode") as? Int ?? Int(Shortcut.defaultKeyCode)),
            modifiers: UInt32(clamping: shortcutPreferences.object(forKey: "hotKeyModifiers") as? Int ?? Int(Shortcut.defaultModifiers))
        )
        return [[global, L10n.text("settings.shortcut")]] + StashShortcut.allCases.map {
            [$0.symbols(in: shortcutPreferences), $0.settingsTitle]
        }
    }
    var contentHeight: CGFloat { CGFloat(410 + keyLabels.count * 20 + 24) }
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
        let keysTop: CGFloat = 410
        let keysX: CGFloat = 28
        let keysWidth = max(0, split - keysX - 20)
        keysTitle.frame = NSRect(x: keysX, y: keysTop, width: keysWidth, height: 18)
        for i in keyLabels.indices {
            let y = keysTop + 24 + CGFloat(i * 20)
            keyLabels[i].frame = NSRect(x: keysX, y: y, width: 90, height: 18)
            keyDescriptions[i].frame = NSRect(x: keysX + 96, y: y + 1, width: max(0, keysWidth - 96), height: 17)
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
