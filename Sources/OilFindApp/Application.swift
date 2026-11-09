import AppKit
import OilFindCore

public enum Application {
    public static func run(appExtension: ApplicationExtension? = nil, arguments: [String] = Array(CommandLine.arguments.dropFirst())) {
    if arguments == ["--raycast-search"] { RaycastSearch.run(); return }
    if let status = appExtension?.handleLaunch(arguments: arguments) { exit(status) }
    let externalDrives = ExternalDriveCatalog()
#if DEBUG
    var arguments = arguments
    do { try externalDrives.prepareArguments(&arguments); try appExtension?.prepareArguments(&arguments) }
    catch { fputs("Oil Find arguments: \(error)\n", stderr); exit(1) }
    if arguments.contains("--snapshot") {
        appExtension?.attachExternalDrives(externalDrives)
        do { try Snapshot.run(arguments, appExtension: appExtension, externalDrives: externalDrives); exit(0) }
        catch { fputs("Oil Find snapshot: \(error)\n", stderr); exit(1) }
    }
    if UpdateExercise.handles(arguments) {
        do { try UpdateExercise.start(arguments); NSApplication.shared.run(); exit(0) }
        catch { fputs("Oil Find update exercise: \(error)\n", stderr); exit(1) }
    }
#endif
    SystemUpdateFiles().registerLaunch(application: Bundle.main.bundleURL, current: UpdateManager.current)
    let app = NSApplication.shared
    SettingsPreferences.register()
    let delegate = AppDelegate(appExtension: appExtension, externalDrives: externalDrives)
    app.delegate = delegate
    app.run()
    }
}
