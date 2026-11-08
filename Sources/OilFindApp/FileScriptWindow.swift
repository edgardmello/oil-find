import AppKit

final class FileScriptWindow: NSWindowController {
    private let output = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let stopButton = NSButton()
    private var run: FileScriptRun?
    var isRunning: Bool { run != nil }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 350, height: 200)
        panel.center()

        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.textContainerInset = NSSize(width: 8, height: 8)
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true

        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stop)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, stopButton])
        footer.spacing = 8
        footer.alignment = .centerY
        let content = NSView()
        panel.contentView = content
        for view in [scroll, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func start(_ script: FileScript, files: [URL]) {
        guard run == nil else { return }
        window?.title = L10n.text("fileScripts.output", script.name)
        output.string = ""
        status.stringValue = L10n.text("fileScripts.running")
        stopButton.title = L10n.text("fileScripts.stop")
        stopButton.isEnabled = true
        run = FileScriptRun.start(script, files: files) { [weak self] result in
            self?.finish(result)
        }
        present()
    }

    func present() {
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func stop() {
        run?.stop()
        stopButton.isEnabled = false
        status.stringValue = L10n.text("fileScripts.stopping")
    }

    private func finish(_ result: FileScriptRun.Result) {
        run = nil
        stopButton.isEnabled = false
        output.string = result.output
        if result.truncated { output.string += "\n\n" + L10n.text("fileScripts.truncated") }
        switch result.outcome {
        case .exited(let code): status.stringValue = L10n.text("fileScripts.exitCode", String(code))
        case .signaled(let signal): status.stringValue = L10n.text("fileScripts.signal", String(signal))
        case .stopped: status.stringValue = L10n.text("fileScripts.stopped")
        case .failed(let key): status.stringValue = L10n.text(key)
        }
    }
}
