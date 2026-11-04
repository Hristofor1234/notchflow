import Foundation

/// `NotchFlow --selftest-prefs`: проверяет, что настройки переживают обновление без потерь.
enum PreferencesSelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        func decode(_ json: String) -> Preferences? {
            try? JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        }

        // 1. Всё, что сохранено, читается обратно один в один, и повторная запись даёт те же байты.
        var custom = Preferences()
        custom.currentMode = .leisure
        custom.apps = [
            ManagedApp(bundleID: "a.one", name: "One", path: "/Applications/One.app", openInWork: true, openInLeisure: false),
            ManagedApp(bundleID: "a.two", name: "Two", path: "/Applications/Two.app", openInWork: false, openInLeisure: true),
        ]
        custom.closeOnLeave = false
        custom.launchOnEnter = false
        custom.switchDesktops = true
        custom.workDesktop = 3
        custom.leisureDesktop = 7
        custom.showAnimation = false
        custom.effect = .aurora
        custom.intensity = 0.37
        custom.autoHideInFullscreen = false
        let data = (try? Store.encode(custom)) ?? Data()
        let restored = try? JSONDecoder().decode(Preferences.self, from: data)
        check("все поля сохраняются и читаются без изменений", restored == custom)
        check("повторное сохранение даёт те же байты", restored.flatMap { try? Store.encode($0) } == data)

        // 2. Формат первой версии (одна категория у приложения).
        let legacy = decode("""
        {"currentMode":"leisure","apps":[
          {"bundleID":"w","name":"W","path":"/w","category":"work"},
          {"bundleID":"l","name":"L","path":"/l","category":"leisure"},
          {"bundleID":"s","name":"S","path":"/s","category":"shared"}]}
        """)
        check("старый формат категорий переносится", legacy?.currentMode == .leisure
            && legacy?.apps.map { [$0.openInWork, $0.openInLeisure] } == [[true, false], [false, true], [true, true]])

        // 3. Незнакомое значение (например, эффект из более новой версии) не сбрасывает остальное.
        let unknownEnum = decode(#"{"effect":"plasma","workDesktop":4,"currentMode":"leisure"}"#)
        check("незнакомое значение не сбрасывает остальные поля",
              unknownEnum?.effect == .liquid && unknownEnum?.workDesktop == 4 && unknownEnum?.currentMode == .leisure)

        // 4. Одна битая запись приложения не уничтожает остальные.
        let brokenApp = decode("""
        {"apps":[{"bundleID":"ok","name":"OK","path":"/ok","openInWork":true,"openInLeisure":false},
                 {"bundleID":"bad","name":"Bad"}],
         "intensity":0.5}
        """)
        check("битая запись приложения пропускается, остальные сохраняются",
              brokenApp?.apps.map(\.bundleID) == ["ok"] && brokenApp?.intensity == 0.5)

        // 5. Лишние поля из будущих версий не мешают.
        let extra = decode(#"{"futureFeature":{"x":1},"switchDesktops":true}"#)
        check("лишние поля игнорируются", extra?.switchDesktops == true)

        // 6. Отсутствующие поля получают значения по умолчанию.
        check("пустые настройки дают значения по умолчанию", decode("{}") == Preferences())

        // 7. «Режим не выбран» сохраняется и читается как есть.
        var noMode = custom
        noMode.currentMode = nil
        let noModeData = (try? Store.encode(noMode)) ?? Data()
        check("«режим не выбран» сохраняется без изменений",
              (try? JSONDecoder().decode(Preferences.self, from: noModeData)) == noMode)

        print(failures == 0 ? "Все проверки пройдены" : "Провалено проверок: \(failures)")
        return failures == 0
    }
}
