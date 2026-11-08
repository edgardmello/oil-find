import AppKit
import Quartz
import UniformTypeIdentifiers

final class InlinePreview: FlippedView {
    private enum Status: String {
        case select, loading, unsupported, unavailable
    }

    private let divider = SeparatorView()
    private let message = Theme.label(12, .regular, .secondaryLabelColor)
    private var preview: QLPreviewView?
    private var url: URL?
    private var generation = 0
    private var status: Status = .select
    private var pendingCheck: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        message.alignment = .center
        message.maximumNumberOfLines = 2
        addSubview(divider)
        addSubview(message)
        localize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func localize() { message.stringValue = L10n.text("inlinePreview." + status.rawValue) }

    private var contentFrame: NSRect {
        NSRect(x: 12, y: 12, width: max(0, bounds.width - 24), height: max(0, bounds.height - 24))
    }

    override func layout() {
        super.layout()
        divider.frame = NSRect(x: 0, y: 0, width: Theme.pixel(self), height: bounds.height)
        let content = contentFrame
        message.frame = NSRect(x: content.minX, y: content.midY - 18, width: content.width, height: 36)
        preview?.frame = content
    }

    func update(url: URL?, isDirectory: Bool = false, isUnavailable: Bool = false) {
        if url != nil && url == self.url && !isUnavailable { return }
        self.url = url
        generation += 1
        pendingCheck?.cancel()
        pendingCheck = nil
        preview?.close()
        preview?.removeFromSuperview()
        preview = nil
        message.isHidden = false

        if isUnavailable { show(.unavailable); return }
        guard let url else { show(.select); return }
        guard !isDirectory, let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .pdf) || type.conforms(to: .image) || type.conforms(to: .text) else {
            show(.unsupported); return
        }
        show(.loading)

        let token = generation
        // Give keyboard repeats time to settle before touching the selected file.
        let check = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let readable = FileManager.default.isReadableFile(atPath: url.path)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.pendingCheck = nil
                    guard readable, let preview = QLPreviewView(frame: self.contentFrame, style: .normal) else {
                        self.show(.unavailable); return
                    }
                    self.preview = preview
                    self.message.isHidden = true
                    self.addSubview(preview)
                    preview.previewItem = url as NSURL
                }
            }
        }
        pendingCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(90), execute: check)
    }

    private func show(_ status: Status) {
        self.status = status
        localize()
    }
}
