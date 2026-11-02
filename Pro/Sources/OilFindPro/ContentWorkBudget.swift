import Foundation
import Darwin

/// Caps the sustained CPU time of background content indexing on the calling thread.
/// PDF, Office and text extraction can otherwise keep a full core busy for minutes after
/// launch, which shows up as high CPU while the app is idle in the menu bar.
final class ContentWorkBudget {
    private let fraction: Double
    private var wall = ProcessInfo.processInfo.systemUptime
    private var cpu: Double
    private var nextCheck: Double = 0

    init(fraction: Double = 0.2) {
        self.fraction = min(1, max(0.05, fraction))
        cpu = Self.threadCPU()
    }

    private static func threadCPU() -> Double {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    /// Sleeps until CPU used since the window began fits inside `fraction` of wall time.
    func checkpoint(isCancelled: () -> Bool) {
        var now = ProcessInfo.processInfo.systemUptime
        guard now >= nextCheck else { return }
        let used = Self.threadCPU() - cpu
        var delay = used / fraction - (now - wall)
        while delay > 0.001 && !isCancelled() {
            Thread.sleep(forTimeInterval: min(0.05, delay))
            now = ProcessInfo.processInfo.systemUptime
            delay = used / fraction - (now - wall)
        }
        if now - wall >= 1 { wall = now; cpu = Self.threadCPU() }
        nextCheck = now + 0.005
    }
}
