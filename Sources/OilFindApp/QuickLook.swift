import AppKit
import Quartz

final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var selectedURL: (() -> URL?)?
    var onKey: ((NSEvent) -> Bool)?
    var onWillClose: (() -> Void)?
    var onDidClose: (() -> Void)?
    private var closeObserver: Any?

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle() {
        if isVisible {
            close()
        } else if selectedURL?() != nil {
            let panel = QLPreviewPanel.shared()
            panel?.updateController()
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard isVisible else { return }
        onWillClose?()
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared().orderOut(nil)
        }
        onDidClose?()
    }

    func begin(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.onWillClose?()
                DispatchQueue.main.async { [weak self] in
                    self?.onDidClose?()
                }
            }
        }
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
    }

    func refresh() { if isVisible { QLPreviewPanel.shared().reloadData() } }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURL?() as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 ||
           (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "y") {
            close()
            return true
        }
        if [125, 126, 116, 121, 115, 119].contains(event.keyCode) {
            let handled = onKey?(event) ?? false
            refresh()
            return handled
        }
        return false
    }
}
