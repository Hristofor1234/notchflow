import AppKit

@MainActor
final class ModeEngine: ObservableObject {
    @Published private(set) var isSwitching = false
    @Published private(set) var status = "Готово"
    /// Режим, в который идёт переключение (кнопка режима выделяется сразу).
    @Published private(set) var pendingMode: Mode?
    /// Что не удалось при последнем переключении.
    @Published private(set) var lastProblem: String?

    private let store: Store
    private let overlay = TransitionOverlay()

    init(store: Store) {
        self.store = store
    }

    func switchTo(_ mode: Mode) {
        guard !isSwitching, mode != store.prefs.currentMode else { return }
        isSwitching = true
        pendingMode = mode
        Task { await perform(mode) }
    }

    /// Первый запуск после включения Mac: режим не выбран, открываются только общие приложения
    /// (включённые в обоих режимах). Ничего не закрывается и рабочий стол не меняется.
    func startFreshSession() {
        guard !isSwitching else { return }
        store.prefs.currentMode = nil
        lastProblem = nil
        guard store.prefs.launchOnEnter else {
            status = "Режим не выбран"
            return
        }
        let shared = store.prefs.apps.filter { $0.openInWork && $0.openInLeisure }
        guard !shared.isEmpty else {
            status = "Режим не выбран"
            return
        }
        isSwitching = true
        status = "Открытие общих приложений…"
        Task {
            defer { isSwitching = false }
            let problems = await AppController.launch(shared)
            if problems.isEmpty {
                status = "Режим не выбран; общие приложения открыты"
            } else {
                lastProblem = "Не всё удалось: " + problems.joined(separator: "; ")
                status = lastProblem ?? ""
            }
        }
    }

    func preview() {
        guard !isSwitching else { return }
        isSwitching = true
        Task {
            defer { isSwitching = false }
            let p = store.prefs
            status = "Предпросмотр…"
            guard await overlay.cover(mode: p.currentMode?.other ?? .work, effect: p.effect, intensity: p.intensity) else {
                status = "Анимация недоступна: Metal не запустился"
                return
            }
            try? await Task.sleep(for: .seconds(1))
            await overlay.reveal()
            status = "Предпросмотр завершён; приложения и рабочие столы не менялись"
        }
    }

    /// Ждёт затишья: `quiet` секунд без смены рабочего стола и запуска, закрытия или переключения
    /// приложений, но не дольше `limit`. Иначе экран открывается посреди системной анимации.
    private func waitForQuiet(quiet: TimeInterval = 0.4, limit: TimeInterval = 2) async {
        // Читается и пишется только на главной очереди (queue: .main ниже).
        final class LastEvent: @unchecked Sendable { var date = Date() }
        let last = LastEvent()
        let center = NSWorkspace.shared.notificationCenter
        let names = [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        let tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in last.date = Date() }
        }
        defer { tokens.forEach(center.removeObserver) }

        let start = Date()
        while Date().timeIntervalSince(last.date) < quiet, Date().timeIntervalSince(start) < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Порядок: закрыть экран анимацией → закрыть приложения, выключенные в новом режиме →
    /// сменить рабочий стол → открыть приложения, включённые в новом режиме → открыть экран.
    private func perform(_ target: Mode) async {
        defer {
            isSwitching = false
            pendingMode = nil
        }
        status = "Переключение режима…"
        lastProblem = nil
        let p = store.prefs
        var problems: [String] = []

        var covered = false
        if p.showAnimation {
            covered = await overlay.cover(mode: target, effect: p.effect, intensity: p.intensity)
        }

        if p.closeOnLeave {
            status = "Закрытие приложений…"
            problems += await AppController.quit(p.apps.filter { !$0.opens(in: target) })
        }

        if p.switchDesktops {
            status = "Переключение рабочего стола…"
            if let issue = await SpaceSwitcher.switchTo(desktop: p.desktop(for: target)) {
                problems.append(issue)
            }
        }

        if p.launchOnEnter {
            status = "Открытие приложений…"
            problems += await AppController.launch(p.apps.filter { $0.opens(in: target) })
        }

        store.prefs.currentMode = target
        if covered {
            await waitForQuiet()
            await overlay.reveal()
        }

        if problems.isEmpty {
            status = "Режим «\(target.title)» включён"
        } else {
            lastProblem = "Не всё удалось: " + problems.joined(separator: "; ")
            status = lastProblem ?? ""
        }
    }
}
