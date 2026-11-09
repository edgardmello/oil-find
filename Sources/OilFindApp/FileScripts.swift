import Carbon
import Darwin
import Foundation

struct FileScript: Codable, Identifiable, Equatable {
    let path: String
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }

    init(url: URL) { path = url.standardizedFileURL.path }

    private static let key = "fileScripts"
    static let shortcutKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                               kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map(UInt32.init)
    static let outputLimit = 64 * 1024

    static func load(from preferences: UserDefaults) -> [FileScript] {
        guard let data = preferences.data(forKey: key),
              let scripts = try? JSONDecoder().decode([FileScript].self, from: data) else { return [] }
        var seen = Set<String>()
        return scripts.filter { $0.path.hasPrefix("/") && seen.insert($0.path).inserted }
    }

    static func save(_ scripts: [FileScript], to preferences: UserDefaults) {
        if let data = try? JSONEncoder().encode(scripts) { preferences.set(data, forKey: key) }
    }
}

final class FileScriptRun {
    enum Outcome {
        case exited(Int32), signaled(Int32), stopped, failed(String)
    }
    struct Result {
        let outcome: Outcome
        let output: String
        let truncated: Bool
    }

    private let lock = NSLock()
    private var stopping = false

    func stop() {
        lock.lock()
        stopping = true
        lock.unlock()
    }

    private var isStopping: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    static func start(_ script: FileScript, files: [URL], completion: @escaping (Result) -> Void) -> FileScriptRun {
        let run = FileScriptRun()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = run.execute(script, files: files)
            DispatchQueue.main.async { completion(result) }
        }
        return run
    }

    private func execute(_ script: FileScript, files: [URL]) -> Result {
        let stopped = Result(outcome: .stopped, output: "", truncated: false)
        guard !isStopping else { return stopped }
        guard !files.isEmpty, files.allSatisfy({ $0.isFileURL && (try? $0.checkResourceIsReachable()) == true }) else {
            return Result(outcome: .failed("fileScripts.unavailable"), output: "", truncated: false)
        }

        let process = Process()
        process.executableURL = script.url
        process.currentDirectoryURL = script.url.deletingLastPathComponent()
        process.arguments = files.map(\.path)
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let reader = pipe.fileHandleForReading
        let writer = pipe.fileHandleForWriting
        defer { try? reader.close(); try? writer.close() }
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return Result(outcome: .failed("fileScripts.outputFailed"), output: "", truncated: false)
        }
        guard !isStopping else { return stopped }
        do { try process.run() }
        catch { return Result(outcome: .failed("fileScripts.launchFailed"), output: error.localizedDescription, truncated: false) }
        try? writer.close()

        var output = Data()
        var truncated = false
        var stopTime: TimeInterval?
        var sentKill = false
        var readsAfterExit = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let running = process.isRunning
            if running && isStopping {
                if let stopTime {
                    if !sentKill && ProcessInfo.processInfo.systemUptime - stopTime > 1 {
                        sentKill = true
                        kill(process.processIdentifier, SIGKILL)
                    }
                } else {
                    stopTime = ProcessInfo.processInfo.systemUptime
                    process.terminate()
                }
            }

            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                if !running {
                    readsAfterExit += 1
                    if readsAfterExit > 32 { truncated = true; break }
                }
                let keep = min(count, FileScript.outputLimit - output.count)
                output.append(contentsOf: buffer.prefix(keep))
                if keep < count { truncated = true }
            } else if count < 0 && errno == EINTR { continue }
            else if !running { break }
            else if count == 0 { Thread.sleep(forTimeInterval: 0.05) }
            else { _ = poll(&descriptor, 1, 50) }
        }
        process.waitUntilExit()
        let outcome: Outcome
        if stopTime != nil { outcome = .stopped }
        else if process.terminationReason == .uncaughtSignal { outcome = .signaled(process.terminationStatus) }
        else { outcome = .exited(process.terminationStatus) }
        return Result(outcome: outcome, output: String(decoding: output, as: UTF8.self), truncated: truncated)
    }
}
