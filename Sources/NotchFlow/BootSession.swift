import Foundation

/// Отличает первый запуск NotchFlow после включения Mac от перезапуска или обновления.
/// Время загрузки хранится отдельно от настроек, чтобы снимок настроек при обновлении не менялся.
enum BootSession {
    private static let defaults = UserDefaults(suiteName: "com.hristofor.notchflow.runtime") ?? .standard
    private static let key = "lastBootTime"

    static func currentBootTime() -> Int? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
        return bootTime.tv_sec
    }

    /// true — Mac был перезагружен с прошлого запуска NotchFlow.
    /// Самый первый запуск этой версии (время ещё не записано) новой загрузкой не считается,
    /// чтобы обновление не сбрасывало выбранный режим.
    static func isFirstLaunchSinceBoot() -> Bool {
        guard let boot = currentBootTime() else { return false }
        let previous = defaults.object(forKey: key) as? Int
        defaults.set(boot, forKey: key)
        guard let previous else { return false }
        return previous != boot
    }
}
