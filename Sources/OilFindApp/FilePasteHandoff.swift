import AppKit
import ApplicationServices
import OilFindCore

final class FilePasteHandoff {
    enum Failure: String {
        case accessibility, destination, files, clipboard
    }

    struct Focus: Equatable {
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element) && lhs.window == rhs.window
        }

        static func read(pid: pid_t) -> Self? {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.25)
            func element(_ attribute: String) -> AXUIElement? {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return (value as! AXUIElement)
            }
            guard let focused = element(kAXFocusedUIElementAttribute) else { return nil }
            return Focus(pid: pid, element: focused, window: element(kAXFocusedWindowAttribute))
        }
    }

    private let queue = DispatchQueue(label: "com.oiloil.find.filePaste", qos: .userInitiated)
    private var focus: Focus?
    private var generation = 0
    private var sending = false

    func captureDestination() {
        generation += 1
        let token = generation
        focus = nil
        guard AXIsProcessTrusted(), let pid = Self.frontmostPID, pid != ProcessInfo.processInfo.processIdentifier else { return }
        queue.async { [weak self] in
            let target = Focus.read(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, Self.frontmostPID == pid else { return }
                self.focus = target
            }
        }
    }

    func paste(_ urls: [URL], dismiss: @escaping () -> Bool, failed: @escaping (Failure) -> Void) {
        guard !sending else { return }
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { failed(.files); return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            failed(.accessibility)
            return
        }
        guard CGPreflightPostEventAccess() else {
            _ = CGRequestPostEventAccess()
            failed(.accessibility)
            return
        }
        guard let focus, Self.frontmostPID == focus.pid else { failed(.destination); return }
        guard let pasteKey = (0..<128).first(where: { Shortcut.keyEquivalent(UInt32($0)) == "v" }),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(pasteKey), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(pasteKey), keyDown: false) else {
            failed(.destination)
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        let token = generation
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        sending = true

        queue.async { [weak self] in
            let reachable = urls.allSatisfy { (try? $0.checkResourceIsReachable()) == true }
            let destination = Focus.read(pid: focus.pid)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.generation == token else { self.sending = false; return }
                guard reachable else { self.sending = false; failed(.files); return }
                guard destination == focus, Self.frontmostPID == focus.pid, dismiss() else {
                    self.sending = false
                    failed(.destination)
                    return
                }
                // The nonactivating search panel releases keyboard focus when it orders out.
                self.queue.async { [weak self] in
                    let returnedFocus = Focus.read(pid: focus.pid)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.sending = false
                        guard self.generation == token else { return }
                        guard returnedFocus == focus, Self.frontmostPID == focus.pid else { failed(.destination); return }
                        guard pasteboard.changeCount == changeCount else { failed(.clipboard); return }
                        pasteboard.clearContents()
                        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { failed(.clipboard); return }
                        down.postToPid(focus.pid)
                        up.postToPid(focus.pid)
                    }
                }
            }
        }
    }

    private static var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
}
