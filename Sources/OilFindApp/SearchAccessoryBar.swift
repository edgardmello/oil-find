import AppKit

final class SearchAccessoryBar: FlippedView {
    private var chips: [ChromeButton] = []
    private var stashControls: [ChromeButton] = []
    private var stashRows: [(NSTextField, ChromeButton)] = []

    var desiredHeight: CGFloat {
        (chips.isEmpty ? 0 : 32) + (stashControls.isEmpty ? 0 : 30 + CGFloat(stashRows.count) * 26)
    }

    func setFilters(_ filters: [(String, () -> Void)]) {
        chips.forEach { $0.removeFromSuperview() }
        chips = filters.map { title, action in button(title, action: action) }
    }

    func setStash(files: [StashedFile], total: Int, expanded: Bool, copy: @escaping () -> Void,
                  open: @escaping () -> Void, remove: @escaping (UUID) -> Void) {
        stashControls.forEach { $0.removeFromSuperview() }
        stashRows.forEach { $0.0.removeFromSuperview(); $0.1.removeFromSuperview() }
        stashControls = []; stashRows = []
        guard expanded else { return }
        if total > 0 { stashControls.append(button(L10n.text("panel.copyStash", String(total)), action: copy)) }
        stashControls.append(button(L10n.text("panel.openStashWindow"), action: open))
        for file in files {
            let label = Theme.label(12, .regular, .secondaryLabelColor)
            label.stringValue = (file.path as NSString).lastPathComponent
            label.toolTip = file.path
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
            let removeButton = button(L10n.text("stash.remove"), action: { remove(file.id) })
            removeButton.setAccessibilityLabel(L10n.text("panel.removeStashItem", label.stringValue))
            stashRows.append((label, removeButton))
        }
    }

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
        for (label, button) in stashRows {
            let width = ceil(Theme.textWidth(button.title, font: button.font!)) + 16
            label.frame = NSRect(x: 24, y: y + 5, width: max(0, bounds.width - width - 48), height: 17)
            button.frame = NSRect(x: bounds.width - 18 - width, y: y, width: width, height: 24)
            y += 26
        }
    }
}
