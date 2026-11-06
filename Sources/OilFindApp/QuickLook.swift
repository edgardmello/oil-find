import AppKit
import Quartz

/// Drives the shared Quick Look panel without letting it own the keyboard.
///
/// The search panel is a nonactivating panel in an accessory app. Making the native
/// preview panel key (as Finder does) hands key status to a window of an app that is
/// usually not active, so keystrokes leak to the previously active app: the preview can
/// no longer be dismissed and typing in the search field stops working. The preview is
/// therefore shown without becoming key, and whenever it does become key (for example
/// after a click inside it) key status is handed straight back to the host window.
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var selectedURL: (() -> URL?)?
    /// Keys the preview panel receives while it is key; returns whether they were consumed.
    var onKey: ((NSEvent) -> Bool)?
    var onWillOpen: (() -> Void)?
    /// Asks the host to take key status back from the preview panel.
    var onReclaimFocus: (() -> Void)?
    var onWillClose: (() -> Void)?
    var onDidClose: (() -> Void)?
    private var observers: [Any] = []

    var isVisible: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func toggle() {
        if isVisible { close() } else { open() }
    }

    func open() {
        guard !isVisible, selectedURL?() != nil, let panel = QLPreviewPanel.shared() else { return }
        onWillOpen?()
        panel.updateController()
        panel.reloadData()
        // Order front without taking key status, so keystrokes keep reaching the search panel.
        panel.orderFront(nil)
        onReclaimFocus?()
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
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.onWillClose?()
            DispatchQueue.main.async { [weak self] in self?.onDidClose?() }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            // Defer so the key-window transition finishes before key status is handed back.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.onReclaimFocus?()
            }
        })
    }

    func end(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        // The panel can also go away on its own (close button, orderOut by the system)
        // without posting willClose; restore focus in that case too.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isVisible else { return }
            self.onDidClose?()
        }
    }

    func refresh() { if isVisible { QLPreviewPanel.shared().reloadData() } }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedURL?() == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { selectedURL?() as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let commandY = flags == .command && event.charactersIgnoringModifiers?.lowercased() == "y"
        if (event.keyCode == 49 && flags.isEmpty) || event.keyCode == 53 || commandY {
            if !event.isARepeat { close() }
            return true
        }
        // Everything else (navigation, typing, shortcuts) belongs to the search panel.
        let handled = onKey?(event) ?? false
        refresh()
        return handled
    }
}
