import Foundation
import SwiftUI

enum Mode: String, Codable, CaseIterable, Identifiable {
    case work, leisure

    var id: String { rawValue }
    var title: String { self == .work ? "Работа" : "Досуг" }
    var symbol: String { self == .work ? "briefcase.fill" : "gamecontroller" }
    var other: Mode { self == .work ? .leisure : .work }
}

struct ManagedApp: Codable, Identifiable, Hashable {
    var bundleID: String
    var name: String
    var path: String
    /// true — открывать при входе в режим, false — закрывать.
    var openInWork: Bool
    var openInLeisure: Bool

    var id: String { bundleID }

    init(bundleID: String, name: String, path: String, openInWork: Bool, openInLeisure: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        self.openInWork = openInWork
        self.openInLeisure = openInLeisure
    }

    func opens(in mode: Mode) -> Bool { mode == .work ? openInWork : openInLeisure }

    private enum CodingKeys: String, CodingKey {
        case bundleID, name, path, openInWork, openInLeisure, category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        if let work = try c.decodeIfPresent(Bool.self, forKey: .openInWork),
           let leisure = try c.decodeIfPresent(Bool.self, forKey: .openInLeisure) {
            openInWork = work
            openInLeisure = leisure
        } else {
            // Ранняя версия хранила одну категорию: work / leisure / shared.
            let category = try c.decodeIfPresent(String.self, forKey: .category) ?? "shared"
            openInWork = category != "leisure"
            openInLeisure = category != "work"
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(openInWork, forKey: .openInWork)
        try c.encode(openInLeisure, forKey: .openInLeisure)
    }
}

enum TransitionEffect: String, Codable, CaseIterable, Identifiable {
    case liquid, aurora

    var id: String { rawValue }
    var title: String { self == .liquid ? "Liquid Glass" : "Aurora Sweep" }
    var shaderIndex: Int32 { self == .liquid ? 0 : 1 }
}

struct Preferences: Codable, Equatable {
    /// nil — режим не выбран (так бывает после включения Mac).
    var currentMode: Mode?
    var apps: [ManagedApp] = []
    var closeOnLeave = true
    /// Если приложение не закрылось за 5 с — завершить принудительно.
    var forceQuit = true
    var launchOnEnter = true
    var switchDesktops = false
    var workDesktop = 1
    var leisureDesktop = 2
    var showAnimation = true
    var effect: TransitionEffect = .liquid
    var intensity = 0.8
    var autoHideInFullscreen = true
    /// Версия формата настроек. Повышается, когда старые данные нужно переносить в новый вид.
    var schemaVersion = Preferences.currentSchema

    static let currentSchema = 1

    init() {}

    func desktop(for mode: Mode) -> Int { mode == .work ? workDesktop : leisureDesktop }

    // Каждое поле читается отдельно: отсутствующее или непонятное значение заменяется значением
    // по умолчанию только для этого поля, остальные настройки сохраняются.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        currentMode = c.lossy(Mode.self, .currentMode) ?? d.currentMode
        apps = c.lossy([Lossy<ManagedApp>].self, .apps)?.compactMap(\.value) ?? d.apps
        closeOnLeave = c.lossy(Bool.self, .closeOnLeave) ?? d.closeOnLeave
        forceQuit = c.lossy(Bool.self, .forceQuit) ?? d.forceQuit
        launchOnEnter = c.lossy(Bool.self, .launchOnEnter) ?? d.launchOnEnter
        switchDesktops = c.lossy(Bool.self, .switchDesktops) ?? d.switchDesktops
        workDesktop = c.lossy(Int.self, .workDesktop) ?? d.workDesktop
        leisureDesktop = c.lossy(Int.self, .leisureDesktop) ?? d.leisureDesktop
        showAnimation = c.lossy(Bool.self, .showAnimation) ?? d.showAnimation
        effect = c.lossy(TransitionEffect.self, .effect) ?? d.effect
        intensity = c.lossy(Double.self, .intensity) ?? d.intensity
        autoHideInFullscreen = c.lossy(Bool.self, .autoHideInFullscreen) ?? d.autoHideInFullscreen
        schemaVersion = c.lossy(Int.self, .schemaVersion) ?? d.schemaVersion
    }
}

/// Элемент массива, который при ошибке чтения пропускается, а не роняет весь массив.
struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

@MainActor
final class Store: ObservableObject {
    static let key = "NotchFlow.preferences.v1"
    private let persists: Bool

    @Published var prefs: Preferences {
        didSet { if persists, prefs != oldValue { save() } }
    }

    init() {
        persists = true
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.key) else {
            prefs = Preferences()
            return
        }
        if let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            prefs = saved
        } else {
            // Данные совсем не читаются (не JSON). Сохраняем их копию, чтобы следующее
            // сохранение не уничтожило единственный экземпляр.
            let stamp = ISO8601DateFormatter().string(from: Date())
            defaults.set(data, forKey: "\(Self.key).unreadable.\(stamp)")
            NSLog("NotchFlow: настройки не читаются; копия сохранена под ключом \(Self.key).unreadable.\(stamp)")
            prefs = Preferences()
        }
    }

    /// Хранилище в памяти: ничего не пишет в UserDefaults.
    init(preview: Preferences) {
        persists = false
        prefs = preview
    }

    nonisolated static func encode(_ prefs: Preferences) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(prefs)
    }

    private func save() {
        if let data = try? Self.encode(prefs) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
