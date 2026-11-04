import AppKit

@MainActor
enum AppController {
    /// Обычный запрос на завершение (как ⌘Q). Принудительно ничего не закрывается.
    static func quit(_ apps: [ManagedApp]) async -> [String] {
        var problems: [String] = []
        var pending: [(name: String, process: NSRunningApplication)] = []

        // Finder перезапускается системой и держит рабочий стол — его не закрываем.
        for app in apps where app.bundleID != "com.apple.finder" {
            for process in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                if process.terminate() {
                    pending.append((app.name, process))
                } else {
                    problems.append("macOS отклонила завершение \(app.name)")
                }
            }
        }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, pending.contains(where: { !$0.process.isTerminated }) {
            try? await Task.sleep(for: .milliseconds(200))
        }

        let stillRunning = Set(pending.filter { !$0.process.isTerminated }.map(\.name))
        problems += stillRunning.sorted().map { "\($0) не закрылось — возможно, ждёт ответа в своём окне" }
        return problems
    }

    /// Запускает без вывода на передний план; уже запущенные пропускаются.
    static func launch(_ apps: [ManagedApp]) async -> [String] {
        var problems: [String] = []
        for app in apps where NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
            guard FileManager.default.fileExists(atPath: app.path) else {
                problems.append("\(app.name): приложение не найдено")
                continue
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.addsToRecentItems = false
            do {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: app.path), configuration: config)
            } catch {
                problems.append("Не удалось запустить \(app.name)")
            }
        }
        return problems
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
