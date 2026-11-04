import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = Store()
    private lazy var engine = ModeEngine(store: store)
    private var island: IslandWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }),
              let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSLog("NotchFlow уже запущен (PID \(others[0].processIdentifier)); второй экземпляр завершается")
            exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DebugSnapshot.runIfRequested(store: store, engine: engine) { return }
        let island = IslandWindowController(store: store, engine: engine)
        island.show()
        self.island = island
        if BootSession.isFirstLaunchSinceBoot() {
            engine.startFreshSession()
        }
    }
}
