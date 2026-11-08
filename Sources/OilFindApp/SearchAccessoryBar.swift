import AppKit

final class SearchAccessoryBar: FlippedView {
    private var chips: [ChromeButton] = []
    private var stashControls: [ChromeButton] = []
    private let stashTable = InlineStashTable(frame: .zero)

    var desiredHeight: CGFloat {
        (chips.isEmpty ? 0 : 32) + (stashControls.isEmpty ? 0 : 30 + stashTable.desiredHeight)
    }

    func setFilters(_ filters: [(String, () -> Void)]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = filters.map { title, action in button(title, action: action) }
    }

    func setStash(files: [StashedFile], expanded: Bool, copy: @escaping () -> Void, open: @escaping () -> Void,
                  dragging: @escaping (Bool) -> Void, leaveSearch: @escaping () -> Void, remove: @escaping (Set<UUID>) -> Void, menuDelegate: NSMenuDelegate) {
        stashControls.forEach { $0.removeFromSuperview() }
        stashControls = []
        stashTable.onRemove = remove
        stashTable.onDragging = dragging
        stashTable.onOpen = leaveSearch
        stashTable.menuDelegate = menuDelegate
        stashTable.update(files, visible: expanded)
        stashTable.isHidden = !expanded || files.isEmpty
        if stashTable.superview == nil { addSubview(stashTable) }
        guard expanded else { return }
        if !files.isEmpty { stashControls.append(button(L10n.text("panel.copyStash", String(files.count)), action: copy)) }
        stashControls.append(button(L10n.text("panel.openStashWindow"), action: open))
    }

    func handleStashKey(_ event: NSEvent) -> Bool? { isHidden ? nil : stashTable.handleKey(event) }

    private func button(_ title: String, action: @escaping () -> Void) -> ChromeButton {
        let result = ChromeButton(title, style: .plain, size: 12, weight: .medium)
        result.toolTip = title
        result.setAccessibilityLabel(title)
        result.onPress = action
        addSubview(result)
        return result
    }

    override func layout() {
        super.layout()
        func row(_ buttons: [ChromeButton], y: CGFloat) {
            var x: CGFloat = 18
            let limit = max(0, (bounds.width - 36) / CGFloat(max(1, buttons.count)))
            for button in buttons {
                let full = ceil(Theme.textWidth(button.toolTip ?? "", font: button.font!)) + 16
                let width = min(limit, full)
                let title = button.toolTip ?? ""
                if full > width {
                    var shortened = title
                    while !shortened.isEmpty && Theme.textWidth(shortened + "…", font: button.font!) > max(0, width - 12) {
                        shortened.removeLast()
                    }
                    button.title = shortened + "…"
                } else { button.title = title }
                button.frame = NSRect(x: x, y: y, width: width, height: 26)
                x += width
            }
        }
        var y: CGFloat = 0
        if !chips.isEmpty { row(chips, y: y); y += 32 }
        if !stashControls.isEmpty { row(stashControls, y: y); y += 30 }
        stashTable.frame = NSRect(x: 18, y: y, width: max(0, bounds.width - 36), height: stashTable.desiredHeight)
    }
}
