import AppKit

enum FileClipboardFormat: Int, CaseIterable {
    case lines, shell, json

    private var titleKey: String {
        switch self {
        case .lines: return "ctx.copyLines"
        case .shell: return "ctx.copyShell"
        case .json: return "ctx.copyJSON"
        }
    }

    static func addMenu(to menu: NSMenu, titleKey: String, target: AnyObject, action: Selector, baseTag: Int) {
        let submenu = NSMenu()
        for format in allCases {
            let item = submenu.addItem(withTitle: L10n.text(format.titleKey), action: action, keyEquivalent: "")
            item.target = target
            item.tag = baseTag + format.rawValue
        }
        let item = menu.addItem(withTitle: L10n.text(titleKey), action: nil, keyEquivalent: "")
        item.submenu = submenu
    }

    func copy(_ values: [String]) {
        guard !values.isEmpty else { return }
        let text: String
        switch self {
        case .lines: text = values.joined(separator: "\n")
        case .shell: text = values.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        case .json:
            guard let data = try? JSONEncoder().encode(values) else { return }
            text = String(decoding: data, as: UTF8.self)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
