import AppKit
import UniformTypeIdentifiers

final class DroplrUpload {
    private static let bundleID = "com.droplr.Desktop"
    private var panel: NSPanel?

    var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    func upload(_ file: URL, dismiss: () -> Void) {
        guard file.isFileURL,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }

        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }

        dismiss()
        panel?.close()
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 104),
                             styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.title = L10n.text("droplr.title")
        let content = NSView()
        let hint = NSTextField(wrappingLabelWithString: L10n.text("droplr.dragHint"))
        hint.textColor = .secondaryLabelColor
        let row = DroplrDragRow(file: file) { [weak window] in window?.close() }
        window.contentView = content
        for view in [hint, row] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            row.leadingAnchor.constraint(equalTo: hint.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: hint.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            let frame = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: frame.maxX - window.frame.width - 16, y: frame.maxY - 12))
        } else {
            window.center()
        }
        panel = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private final class DroplrDragRow: NSView, NSDraggingSource {
    private let file: URL
    private let icon: NSImage
    private let onDrop: () -> Void
    private var press: NSPoint?

    init(file: URL, onDrop: @escaping () -> Void) {
        self.file = file
        self.onDrop = onDrop
        icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: file.pathExtension) ?? .data)
        super.init(frame: .zero)
        let image = NSImageView(image: icon)
        image.imageScaling = .scaleProportionallyDown
        let title = NSTextField(labelWithString: file.lastPathComponent)
        title.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [image, title])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 24),
            image.heightAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        toolTip = file.path
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(file.lastPathComponent)
        setAccessibilityHelp(L10n.text("droplr.dragHint"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) { press = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let press, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) >= 4 else { return }
        self.press = nil
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.contains(.copy) { onDrop() }
    }
}
