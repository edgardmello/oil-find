import AppKit
import Foundation

if CommandLine.arguments.contains("--verify-launch") {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.oiloil.find")
        if running.contains(where: { $0.bundleURL?.path == "/Applications/Oil Find.app" && !$0.isTerminated && $0.isFinishedLaunching }) {
            exit(0)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    fputs("Installed Oil Find did not finish launching.\n", stderr)
    exit(1)
}

// NSRunningApplication avoids Apple Events and their Automation permission prompt.
let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.oiloil.find")
for application in applications {
    guard application.terminate() else {
        fputs("Oil Find refused to quit. Installation cancelled.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(30)
while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if applications.contains(where: { !$0.isTerminated }) {
    fputs("Oil Find did not quit within 30 seconds. Installation cancelled.\n", stderr)
    exit(1)
}
