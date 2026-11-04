import AppKit
import CoreGraphics

/// Переключает рабочие столы системным сочетанием Control+1…9.
/// Нужны разрешение «Универсальный доступ» и включённые сочетания в настройках Mission Control.
@MainActor
enum SpaceSwitcher {
    /// Коды клавиш 1…9 в раскладке ANSI.
    private static let digitKeyCodes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    static func requestAccess() {
        if !CGRequestPostEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Возвращает описание проблемы или nil, если macOS подтвердила смену рабочего стола.
    static func switchTo(desktop: Int) async -> String? {
        guard (1...9).contains(desktop) else {
            return "Поддерживаются только Рабочие столы 1–9"
        }
        guard canPostEvents else {
            return "рабочий стол не переключён — нет разрешения «Универсальный доступ»"
        }
        let changed = await waitForSpaceChange(timeout: 3) {
            post(keyCode: digitKeyCodes[desktop - 1])
        }
        return changed ? nil
            : "macOS не сообщила о смене рабочего стола (уже на Рабочем столе \(desktop) или Control+\(desktop) выключено в Mission Control)"
    }

    private static func post(keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskControl
        up.flags = .maskControl
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func waitForSpaceChange(timeout: TimeInterval, after action: () -> Void) async -> Bool {
        let center = NSWorkspace.shared.notificationCenter
        var token: NSObjectProtocol?
        defer { if let token { center.removeObserver(token) } }

        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool) -> Void = { result in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            token = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
                finish(true)
            }
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}
