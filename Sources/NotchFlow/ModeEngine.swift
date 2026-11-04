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
    /// Журнал последнего переключения: этапы, смены рабочего стола и активные приложения
    /// с отметками времени. Пишется и в системный журнал (log show --predicate 'process == "NotchFlow"').
    private(set) var trace: [String] = []
    private var traceStart = Date()

    private func mark(_ text: String) {
        let line = String(format: "%5.2f  %@", Date().timeIntervalSince(traceStart), text)
        trace.append(line)
        NSLog("NotchFlow trace: %@", line)
    }

    /// Для проверки (--switch-test): то же переключение, что и по кнопке, с ожиданием конца.
    func switchForTest(_ mode: Mode) async {
        isSwitching = true
        pendingMode = mode
        await perform(mode)
        isSwitching = false
        pendingMode = nil
    }
    private let overlay = TransitionOverlay()

    init(store: Store) {
        self.store = store
    }

    /// Режим, выбранный во время идущего переключения: выполняется сразу после него,
    /// чтобы быстрые нажатия не терялись и в итоге был включён последний выбранный режим.
    private var queuedMode: Mode?

    func switchTo(_ mode: Mode) {
        if isSwitching {
            queuedMode = mode
            pendingMode = mode
            return
        }
        guard mode != store.prefs.currentMode else { return }
        isSwitching = true
        pendingMode = mode
        Task {
            await perform(mode)
            while let next = queuedMode {
                queuedMode = nil
                if next != store.prefs.currentMode {
                    pendingMode = next
                    await perform(next)
                }
            }
            isSwitching = false
            pendingMode = nil
        }
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

    /// Закрытие и активация приложений заставляют macOS переходить на их столы уже после
    /// нашего Control+N (замер: Claude, Steam, Finder). Когда всё стихло, проверяем, где Mac
    /// на самом деле, и при необходимости переключаем ещё раз (до двух попыток).
    private func settleDesktop(_ target: Mode, _ p: Preferences) async -> [String] {
        guard p.switchDesktops else { return [] }
        let desktop = p.desktop(for: target)
        var issue: String?
        for attempt in 1...2 {
            guard let now = SpaceSwitcher.currentDesktop() else { return [] }
            if now.index == desktop { return [] }
            mark("стол \(now.index) вместо \(desktop), попытка \(attempt)")
            issue = await SpaceSwitcher.switchTo(desktop: desktop)
            if issue != nil, desktop > now.count { break }
            await waitForQuiet(quiet: 0.5, limit: 2)
        }
        let final = SpaceSwitcher.currentDesktop()?.index
        mark("итог: стол \(final ?? 0)")
        if final == desktop { return [] }
        return [issue ?? "рабочий стол \(desktop) не удержался — macOS перешла на стол \(final ?? 0)"]
    }

    /// Закрыть выключенные в режиме приложения → сменить стол → открыть включённые.
    private func applyMode(_ target: Mode, _ p: Preferences) async -> [String] {
        var problems: [String] = []
        if p.closeOnLeave {
            status = "Закрытие приложений…"
            let result = await AppController.quit(p.apps.filter { !$0.opens(in: target) }, force: p.forceQuit)
            problems += result.problems
            mark("приложения закрыты" + (result.closedByForce.isEmpty ? "" : "; принудительно: " + result.closedByForce.joined(separator: ", ")))
        }
        if p.switchDesktops {
            status = "Переключение рабочего стола…"
            let issue = await SpaceSwitcher.switchTo(desktop: p.desktop(for: target))
            mark("стол \(SpaceSwitcher.currentDesktop()?.index ?? 0)\(issue.map { " — " + $0 } ?? "")")
        }
        if p.launchOnEnter {
            status = "Открытие приложений…"
            problems += await AppController.launch(p.apps.filter { $0.opens(in: target) })
            mark("приложения открыты")
        }
        store.prefs.currentMode = target
        return problems
    }

    /// Порядок: закрыть экран анимацией → закрыть приложения, выключенные в новом режиме →
    /// сменить рабочий стол → открыть приложения, включённые в новом режиме → открыть экран.
    private func perform(_ target: Mode) async {
        status = "Переключение режима…"
        lastProblem = nil
        let p = store.prefs
        trace = []
        traceStart = Date()
        let center = NSWorkspace.shared.notificationCenter
        let observers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.mark("⚠︎ macOS сменила рабочий стол") }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let name = app?.localizedName ?? "?"
                MainActor.assumeIsolated { self?.mark("активно: \(name)") }
            },
        ]
        defer { observers.forEach(center.removeObserver) }
        mark("начало → \(target.title)")
        var problems: [String] = []

        var covered = false
        if p.showAnimation {
            covered = await overlay.cover(mode: target, effect: p.effect, intensity: p.intensity)
        }

        // Всё, что меняет экран, идёт под затемнением дисплея: не только наша смена стола,
        // но и те, что macOS делает сама, когда закрываются или активируются приложения
        // (замер: Steam, активировавшись после смены стола, переключал стол ещё раз).
        if covered {
            mark("заставка закрыла экран")
            problems += await overlay.whileMasked {
                mark("дисплей затемнён")
                let found = await applyMode(target, p)
                // Приложения активируются и тянут за собой столы с задержкой до ~1 с.
                await waitForQuiet(quiet: 0.6, limit: 3)
                mark("затишье")
                return found + (await settleDesktop(target, p))
            }.result
            mark("затемнение снято, открываю экран")
            await overlay.reveal()
        } else {
            problems += await applyMode(target, p)
            await waitForQuiet(quiet: 0.6, limit: 3)
            problems += await settleDesktop(target, p)
        }
        mark("конец")

        if problems.isEmpty {
            status = "Режим «\(target.title)» включён"
        } else {
            lastProblem = "Не всё удалось: " + problems.joined(separator: "; ")
            status = lastProblem ?? ""
        }
    }
}
