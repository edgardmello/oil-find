import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class DroplrUpload {
    enum Failure: String { case accessibility, chooser }

    private static let bundleID = "com.droplr.Desktop"
    private let queue = DispatchQueue(label: "com.oiloil.find.droplrUpload", qos: .userInitiated)
    private var busy = false

    var isAvailable: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
    }

    func upload(_ file: URL, dismiss: () -> Void, failed: @escaping (Failure) -> Void) {
        guard !busy, file.isFileURL,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
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

        busy = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        dismiss()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [self] app, _ in
            queue.async {
                let success = app.map { Self.selectFile(file, pid: $0.processIdentifier) } ?? false
                DispatchQueue.main.async {
                    self.busy = false
                    if !success { failed(.chooser) }
                }
            }
        }
    }

    private static func selectFile(_ file: URL, pid: pid_t) -> Bool {
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.20)
        // Don't reuse a picker that may already belong to an unrelated upload.
        guard picker(in: app) == nil, key(kVK_ANSI_1, flags: [.maskAlternate, .maskShift]),
              let window = waitFor({ picker(in: app) }), isFrontmost(pid),
              key(kVK_ANSI_G, flags: [.maskCommand, .maskShift], pid: pid) else { return false }

        guard let field = waitFor({ pathField(in: app, window: window, pid: pid) }),
              AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, file.path as CFString) == .success,
              isFrontmost(pid), element(app, kAXFocusedUIElementAttribute).map({ CFEqual($0, field) }) == true else { return false }
        // Leave Go to Folder open so no generated keystroke can confirm an upload.
        return string(field, kAXValueAttribute) == file.path
    }

    private static func picker(in app: AXUIElement) -> AXUIElement? {
        guard let window = element(app, kAXFocusedWindowAttribute),
              let button = element(window, kAXDefaultButtonAttribute),
              string(button, kAXTitleAttribute) == "Upload",
              string(window, kAXTitleAttribute) == "Upload a file" ||
                string(window, kAXSubroleAttribute) == kAXDialogSubrole as String else { return nil }
        return window
    }

    private static func pathField(in app: AXUIElement, window: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard isFrontmost(pid), let field = element(app, kAXFocusedUIElementAttribute),
              let role = string(field, kAXRoleAttribute),
              [kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role) else { return nil }
        var ancestor = element(field, kAXParentAttribute)
        var inSheet = false
        for _ in 0..<12 {
            guard let current = ancestor else { return nil }
            if CFEqual(current, window) { return inSheet ? field : nil }
            inSheet = inSheet || string(current, kAXRoleAttribute) == kAXSheetRole as String
            ancestor = element(current, kAXParentAttribute)
        }
        return nil
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func waitFor<T>(_ observe: () -> T?) -> T? {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        repeat {
            if let value = observe() { return value }
            Thread.sleep(forTimeInterval: 0.05)
        } while ProcessInfo.processInfo.systemUptime < deadline
        return nil
    }

    private static func key(_ key: Int, flags: CGEventFlags = [], pid: pid_t? = nil) -> Bool {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        for event in [down, up] {
            if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
        }
        return true
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
