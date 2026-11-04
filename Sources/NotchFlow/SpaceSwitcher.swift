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

    /// Номер текущего рабочего стола (1…) на экране, где сейчас активный стол, и сколько их всего.
    /// Читается у WindowServer напрямую (CGSCopyManagedDisplaySpaces) — это единственный способ
    /// узнать, на каком столе оказался Mac. Полноэкранные приложения в счёт не идут, как и у Control+N.
    static func currentDesktop() -> (index: Int, count: Int)? {
        guard let cgs = CGS.shared else { return nil }
        let conn = cgs.connection()
        let active = cgs.activeSpace(conn)
        guard let displays = cgs.displaySpaces(conn).takeRetainedValue() as? [[String: Any]] else { return nil }
        for display in displays {
            let desktops = (display["Spaces"] as? [[String: Any]] ?? [])
                .filter { ($0["type"] as? Int ?? 0) == 0 }
                .compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            if let i = desktops.firstIndex(of: active) { return (i + 1, desktops.count) }
        }
        return nil
    }

    /// Возвращает описание проблемы или nil, если Mac на нужном столе.
    static func switchTo(desktop: Int) async -> String? {
        guard (1...9).contains(desktop) else {
            return "Поддерживаются только Рабочие столы 1–9"
        }
        let now = currentDesktop()
        if let now {
            if now.index == desktop { return nil }
            if desktop > now.count { return "Рабочего стола \(desktop) нет — их всего \(now.count)" }
        }
        guard canPostEvents else {
            return "рабочий стол не переключён — нет разрешения «Универсальный доступ»"
        }
        let changed = await waitForSpaceChange(timeout: 3) {
            post(keyCode: digitKeyCodes[desktop - 1])
        }
        if let after = currentDesktop() {
            if after.index == desktop { return nil }
            return changed ? "macOS открыла стол \(after.index) вместо \(desktop)"
                : "Control+\(desktop) не сработало — проверьте сочетания в Mission Control"
        }
        return changed ? nil
            : "macOS не сообщила о смене рабочего стола (Control+\(desktop) выключено в Mission Control?)"
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

/// Закрытые функции WindowServer для чтения списка столов (только чтение, ничего не меняют).
/// Ищутся во время работы: если в будущей macOS их не станет, проверка стола просто отключится.
private struct CGS {
    typealias ConnFn = @convention(c) () -> Int32
    typealias ActiveFn = @convention(c) (Int32) -> UInt64
    typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>
    let connection: ConnFn
    let activeSpace: ActiveFn
    let displaySpaces: CopyFn

    static let shared: CGS? = {
        let h = dlopen(nil, RTLD_NOW)
        guard let c = dlsym(h, "CGSMainConnectionID"), let a = dlsym(h, "CGSGetActiveSpace"),
              let d = dlsym(h, "CGSCopyManagedDisplaySpaces") else { return nil }
        return CGS(connection: unsafeBitCast(c, to: ConnFn.self),
                   activeSpace: unsafeBitCast(a, to: ActiveFn.self),
                   displaySpaces: unsafeBitCast(d, to: CopyFn.self))
    }()
}
