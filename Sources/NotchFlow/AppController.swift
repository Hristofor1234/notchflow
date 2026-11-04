import AppKit

@MainActor
enum AppController {
    /// Сначала обычный запрос на завершение (как ⌘Q). Если `force` и приложение не закрылось
    /// за 5 с (диалог, зависло) — принудительное завершение. `closedByForce` — кого пришлось дожать.
    static func quit(_ apps: [ManagedApp], force: Bool) async -> (problems: [String], closedByForce: [String]) {
        var problems: [String] = []
        var pending: [(name: String, process: NSRunningApplication)] = []

        // Finder перезапускается системой и держит рабочий стол — его не закрываем.
        let targets = apps.filter { $0.bundleID != "com.apple.finder" }.flatMap { app in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).map { (app.name, $0) }
        }
        // Только что запущенное приложение (быстрое переключение туда-обратно) игнорирует
        // ⌘Q, пока не дозапустится — дожидаемся этого (до 3 с).
        let launchDeadline = Date().addingTimeInterval(3)
        while Date() < launchDeadline, targets.contains(where: { !$0.1.isFinishedLaunching && !$0.1.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for (name, process) in targets where !process.isTerminated {
            if process.terminate() || force {
                pending.append((name, process))
            } else {
                problems.append("macOS отклонила завершение \(name)")
            }
        }

        await waitUntilTerminated(pending.map(\.process), timeout: 5)

        var forced: [String] = []
        let closable = apps.filter { $0.bundleID != "com.apple.finder" }
        if force {
            // Некоторые приложения (Steam) при запуске перезапускают себя новым процессом —
            // поэтому каждый раунд заново ищем процессы по bundle ID, а не только запомненные.
            for _ in 1...4 {
                let alive = closable.flatMap { app in
                    NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                        .filter { !$0.isTerminated }.map { (app.name, $0) }
                }
                if alive.isEmpty { break }
                for (name, process) in alive {
                    process.forceTerminate()
                    forced.append(name)
                }
                await waitUntilTerminated(alive.map(\.1), timeout: 1.5)
                try? await Task.sleep(for: .milliseconds(500)) // успеет ли появиться новый процесс
            }
        }

        let stillRunning = Set(closable.filter { app in
            NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
        }.map(\.name))
        problems += stillRunning.sorted().map {
            force ? "\($0) не закрылось даже принудительно" : "\($0) не закрылось — возможно, ждёт ответа в своём окне"
        }
        return (problems, Array(Set(forced)).sorted())
    }

    private static func waitUntilTerminated(_ processes: [NSRunningApplication], timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, processes.contains(where: { !$0.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func isRunning(_ app: ManagedApp) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).contains { !$0.isTerminated }
    }

    /// Запускает без вывода на передний план; уже запущенные пропускаются.
    /// Потом проверяет, что всё действительно работает, и запускает пропавшие ещё раз:
    /// приложение, которое как раз закрывалось с прошлого переключения, считалось «запущенным»
    /// и пропускалось, а через мгновение исчезало.
    static func launch(_ apps: [ManagedApp]) async -> [String] {
        var problems: [String] = []
        var wanted: [ManagedApp] = []
        for app in apps {
            guard FileManager.default.fileExists(atPath: app.path) else {
                problems.append("\(app.name): приложение не найдено")
                continue
            }
            wanted.append(app)
        }

        for attempt in 1...3 {
            let missing = wanted.filter { !isRunning($0) }
            if missing.isEmpty { break }
            if attempt > 1 { NSLog("NotchFlow: повторный запуск (%d): %@", attempt, missing.map(\.name).joined(separator: ", ")) }
            await withTaskGroup(of: Void.self) { group in
                for app in missing {
                    group.addTask { await open(app) }
                }
            }
            // Даём закрывающимся с прошлого раза приложениям исчезнуть, затем проверяем снова.
            try? await Task.sleep(for: .milliseconds(attempt == 1 ? 800 : 1500))
        }

        problems += wanted.filter { !isRunning($0) }.map { "Не удалось запустить \($0.name)" }
        return problems
    }

    private static func open(_ app: ManagedApp) async {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
    }
}

struct AppPickerError: Error {
    let message: String
}

@MainActor
enum AppPicker {
    private static let protectedIDs: Set<String> = [
        "com.apple.dock", "com.apple.systemevents", "com.apple.loginwindow", "com.notchflow.app",
    ]

    static func pick() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение"
        panel.prompt = "Добавить"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Новое приложение открывается в текущем режиме и закрывается в другом;
    /// если режим не выбран — оба переключателя выключены.
    static func entry(for url: URL, currentMode: Mode?, existing: [ManagedApp]) throws -> ManagedApp {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            throw AppPickerError(message: "Не удалось прочитать выбранное приложение")
        }
        if protectedIDs.contains(id) || id == Bundle.main.bundleIdentifier {
            throw AppPickerError(message: "Системные приложения и NotchFlow нельзя добавлять")
        }
        if existing.contains(where: { $0.bundleID == id }) {
            throw AppPickerError(message: "Это приложение уже есть в списке")
        }
        return ManagedApp(
            bundleID: id,
            name: url.deletingPathExtension().lastPathComponent,
            path: url.path,
            openInWork: currentMode == .work,
            openInLeisure: currentMode == .leisure
        )
    }
}
