import AppKit
import QuartzCore

final class PanelSurface: FlippedView {
    private let effect = NSVisualEffectView()
    private let tint: SurfaceTint
    var material: SearchMaterial = .glassy {
        didSet {
            effect.isHidden = material == .opaque
            effect.material = material == .vibrant ? .hudWindow : .popover
            tint.material = material
        }
    }
    init(snapshot: Bool) {
        tint = SurfaceTint(snapshot: snapshot)
        super.init(frame: NSRect(origin: .zero, size: Theme.panelSize))
        wantsLayer = true; layer?.cornerRadius = Theme.corner; layer?.cornerCurve = .continuous; layer?.masksToBounds = true
        if !snapshot {
            effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
            let mask = NSImage(size: NSSize(width: 46, height: 46), flipped: false) { rect in
                NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: 22, yRadius: 22).fill(); return true
            }
            mask.capInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
            mask.resizingMode = .stretch; effect.maskImage = mask
            addSubview(effect)
        }
        addSubview(tint)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout(); effect.frame = bounds
        tint.frame = bounds
    }
}

private final class SurfaceTint: NSView {
    let snapshot: Bool
    var material: SearchMaterial = .glassy { didSet { needsDisplay = true } }
    init(snapshot: Bool) { self.snapshot = snapshot; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.dark(self)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 22, yRadius: 22)
        if material == .opaque {
            NSColor.windowBackgroundColor.setFill(); path.fill()
        } else if snapshot {
            NSColor(srgbRed: dark ? 35/255 : 244/255, green: dark ? 35/255 : 244/255, blue: dark ? 38/255 : 246/255, alpha: 1).setFill(); path.fill()
        }
        (dark ? NSColor.black.withAlphaComponent(0.18) : NSColor.white.withAlphaComponent(0.30)).setFill(); path.fill()
        let pixel = Theme.pixel(self)
        (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: 22 - pixel / 2, yRadius: 22 - pixel / 2)
        border.lineWidth = pixel; border.stroke()
    }
}

enum PanelSource: String {
    case hotkey, menu, reopen, welcome, settings, indexing, interaction
}

// NSWindow has no public presentation layer. NSAnimation keeps alphaValue at the
// displayed value, allowing a reversal to start from that exact alpha.
private final class WindowFade: NSAnimation, NSAnimationDelegate {
    weak var window: NSWindow?
    let startAlpha: CGFloat, endAlpha: CGFloat
    var completion: (() -> Void)?
    init(window: NSWindow, target: CGFloat, duration: Double, curve: NSAnimation.Curve, completion: (() -> Void)? = nil) {
        self.window = window; startAlpha = window.alphaValue; endAlpha = target; self.completion = completion
        super.init(duration: duration, animationCurve: curve)
        animationBlockingMode = .nonblocking; frameRate = 60; delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set {
            super.currentProgress = newValue
            window?.alphaValue = startAlpha + (endAlpha - startAlpha) * CGFloat(currentValue)
        }
    }
    func animationDidEnd(_ animation: NSAnimation) { window?.alphaValue = endAlpha; completion?() }
}

final class SearchPanel: NSPanel {
    static let collapsedHeight: CGFloat = 64
    let searchController: SearchViewController
    private(set) var hiding = false
    private var animationGeneration = 0
    private var fade: WindowFade?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(snapshot: Bool = false) {
        searchController = SearchViewController(snapshot: snapshot)
        super.init(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false; hidesOnDeactivate = false; isOpaque = false; backgroundColor = .clear; hasShadow = true
        isReleasedWhenClosed = false
        contentViewController = searchController; delegate = searchController
        searchController.hidePanel = { [weak self] in self?.hide(source: .interaction) }
        if let layer = contentView?.layer {
            let frame = layer.frame; layer.anchorPoint = CGPoint(x: 0.5, y: 0.5); layer.frame = frame
        }
        invalidateShadow()
    }
    func toggle(source: PanelSource = .hotkey) {
        if isVisible && isKeyWindow && !hiding { hide(source: source) } else { show(source: source) }
    }
    func resizeForInlinePreview(usePreferredDisplay: Bool = false, display: Bool = true) {
        let target: NSScreen?
        if usePreferredDisplay {
            target = searchController.opensOnPointerDisplay
                ? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                : NSScreen.screens.first
        } else {
            target = screen
        }
        guard let screen = target ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(searchController.inlinePreviewVisible && !searchController.barCollapsed ? 1160 : 800, visible.width - 80)
        let expandedHeight = min(560, visible.height - 120)
        let height = searchController.barCollapsed ? Self.collapsedHeight : expandedHeight
        let top = (visible.midY + expandedHeight / 2).rounded()
        let frame = NSRect(x: (visible.midX - width / 2).rounded(), y: top - height,
                           width: width, height: height)
        setFrame(frame, display: display)
        invalidateShadow()
    }
    func show(source: PanelSource = .interaction) {
        let cold = !isVisible
        if cold || hiding || !isKeyWindow { searchController.captureFilePasteDestination() }
        if cold || hiding {
            searchController.preparePanelAppearance()
            resizeForInlinePreview(usePreferredDisplay: cold, display: false)
        }
        AppLog.logger.info("panel show source=\(source.rawValue, privacy: .public)")
        animationGeneration += 1; hiding = false; fade?.stop()
        contentView?.layoutSubtreeIfNeeded()
        if let layer = contentView?.layer {
            if cold {
                alphaValue = 0
                let transform = CATransform3DScale(CATransform3DMakeTranslation(0, Theme.Motion.panelInOffset, 0), Theme.Motion.panelInScale, Theme.Motion.panelInScale, 1)
                Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: Theme.Motion.reduced ? CATransform3DIdentity : transform), using: nil)
            }
            Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: CATransform3DIdentity), using: Theme.Motion.reduced ? nil : Theme.Motion.panelIn)
        }
        orderFrontRegardless(); makeKey()
        searchController.panelWillShow(); searchController.searchField.focus(selectAll: true)
        fade = WindowFade(window: self, target: 1, duration: Theme.Motion.reduced ? Theme.Motion.reducedFade : Theme.Motion.panelInFade, curve: .easeOut)
        fade?.start()
    }
    func dismissForFilePaste() -> Bool {
        guard isVisible, isKeyWindow, !hiding else { return false }
        searchController.panelDidHide()
        animationGeneration += 1
        fade?.stop()
        searchController.results.cancelPress()
        orderOut(nil)
        searchController.quickLook.close()
        return true
    }
    func hide(source: PanelSource = .interaction) {
        searchController.panelDidHide()
        guard isVisible, !hiding else { return }
        AppLog.logger.info("panel hide source=\(source.rawValue, privacy: .public)")
        animationGeneration += 1; let token = animationGeneration
        hiding = true; fade?.stop(); searchController.results.cancelPress()
        if let layer = contentView?.layer {
            let target = CATransform3DMakeScale(Theme.Motion.panelOutScale, Theme.Motion.panelOutScale, 1)
            Theme.Motion.animate(layer, "transform", to: NSValue(caTransform3D: Theme.Motion.reduced ? CATransform3DIdentity : target), using: Theme.Motion.reduced ? nil : Theme.Motion.basic(Theme.Motion.panelOut, .easeIn))
        }
        fade = WindowFade(window: self, target: 0, duration: Theme.Motion.reduced ? Theme.Motion.reducedFade : Theme.Motion.panelOut, curve: .easeIn) { [weak self] in
            guard let self, self.hiding, self.animationGeneration == token else { return }
            self.orderOut(nil); self.searchController.quickLook.close(); self.hiding = false
        }
        fade?.start()
    }
    override func keyDown(with event: NSEvent) {
        if !searchController.handleKey(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !searchController.searchField.editor.hasMarkedText(), searchController.handleKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
