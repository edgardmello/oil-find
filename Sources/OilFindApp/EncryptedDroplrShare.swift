import AppKit
import Security
import UniformTypeIdentifiers

enum EncryptedShareImage {
    enum Failure: Error { case noFiles, unsupportedFile, encryption, password }

    static func password() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.password }
        return Data(bytes).base64EncodedString()
    }

    static func create(from files: [URL], at destination: URL, password: String) throws {
        guard !files.isEmpty else { throw Failure.noFiles }
        let manager = FileManager.default
        let work = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: work) }
        let source = manager.temporaryDirectory.appendingPathComponent("OilFindShare-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: source) }

        for url in files {
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard metadata.isSymbolicLink != true, metadata.isRegularFile == true || metadata.isDirectory == true else {
                throw Failure.unsupportedFile
            }
            let name = url.lastPathComponent
            var target = source.appendingPathComponent(name)
            var suffix = 2
            while manager.fileExists(atPath: target.path) {
                target = source.appendingPathComponent("\(suffix) - \(name)")
                suffix += 1
            }
            try manager.copyItem(at: url, to: target)
        }

        let image = work.appendingPathComponent("Encrypted.dmg")
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["create", "-quiet", "-srcfolder", source.path, "-fs", "Case-sensitive HFS+",
                             "-format", "UDZO", "-encryption", "AES-256", "-stdinpass", "-volname", "Shared Files", image.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(password.utf8) + Data([0]))
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.encryption }
        // The save panel chooses the destination, but a file may appear there while the image builds.
        try manager.moveItem(at: image, to: destination)
    }
}

final class EncryptedDroplrShare {
    private var busy = false
    var isAvailable: Bool {
        !busy && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.droplr.Desktop") != nil
    }

    func prepare(_ files: [URL], dismiss: () -> Void) {
        guard !files.isEmpty, isAvailable else { return }
        busy = true
        dismiss()
        NSApp.activate()

        let panel = NSSavePanel()
        panel.title = L10n.text("droplr.prepare")
        panel.message = L10n.text("droplr.saveHint")
        panel.nameFieldStringValue = "Encrypted Share.dmg"
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { busy = false; return }

        let progress = progressPanel()
        progress.center()
        progress.orderFrontRegardless()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result {
                let password = try EncryptedShareImage.password()
                try EncryptedShareImage.create(from: files, at: destination, password: password)
                return password
            }
            DispatchQueue.main.async {
                progress.orderOut(nil)
                defer { self.busy = false }
                self.finish(result, destination: destination)
            }
        }
    }

    private func progressPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 62),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L10n.text("droplr.title")
        let spinner = NSProgressIndicator(frame: NSRect(x: 16, y: 21, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: L10n.text("droplr.creating"))
        label.frame = NSRect(x: 48, y: 21, width: 326, height: 20)
        panel.contentView?.addSubview(spinner)
        panel.contentView?.addSubview(label)
        return panel
    }

    private func finish(_ result: Result<String, Error>, destination: URL) {
        let alert = NSAlert()
        switch result {
        case .success(let password):
            alert.messageText = L10n.text("droplr.ready")
            alert.informativeText = L10n.text("droplr.readyHint")
            let field = NSTextField(labelWithString: password)
            field.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            field.isSelectable = true
            field.sizeToFit()
            alert.accessoryView = field
            alert.addButton(withTitle: L10n.text("droplr.reveal"))
            alert.addButton(withTitle: L10n.text("droplr.copyPassword"))
            if alert.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(password, forType: .string)
            }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = L10n.text("droplr.failed")
            alert.informativeText = error is EncryptedShareImage.Failure ? L10n.text("droplr.failedHint") : error.localizedDescription
            alert.runModal()
        }
    }
}
