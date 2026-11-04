import AppKit
import SwiftUI

/// Самопроверка без доступа к экрану:
/// `NotchFlow --snapshot <папка>` сохраняет язычок и все вкладки панели в PNG (на демо-данных),
/// `NotchFlow --preview-test` прогоняет анимацию и пишет время фаз.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: Store, engine: ModeEngine) -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            snapshot(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if args.contains("--click-test") {
            let controller = IslandWindowController(store: Store(preview: demoPreferences()), engine: engine)
            Task { exit(await controller.runClickTest() ? 0 : 1) }
            return true
        }
        if args.contains("--selftest-prefs") {
            exit(PreferencesSelfTest.run() ? 0 : 1)
        }
        // Проверки разрешений имеют смысл только у приложения, запущенного через open:
        // macOS отвечает о правах того процесса, который их запросил.
        // open -n -a NotchFlow --args --check-access <файл> / --space-test <файл>
        if let i = args.firstIndex(of: "--check-access"), i + 1 < args.count {
            let report = "postEvents=\(SpaceSwitcher.canPostEvents) accessibility=\(AXIsProcessTrusted())\n"
            try? report.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "--space-test"), i + 1 < args.count {
            let path = args[i + 1]
            Task {
                var lines: [String] = ["postEvents=\(SpaceSwitcher.canPostEvents)"]
                for desktop in [2, 1] {
                    let issue = await SpaceSwitcher.switchTo(desktop: desktop)
                    lines.append("desktop \(desktop): \(issue ?? "OK, macOS подтвердила смену")")
                    try? await Task.sleep(for: .seconds(1))
                }
                try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        // Заставка во время смены рабочего стола: для каждого уровня окна — сколько мс заставку
        // не было видно и самый долгий перерыв между кадрами. Экран ездит на стол 2 и обратно.
        // open -n -a NotchFlow --args --overlay-space-test <файл>
        if let i = args.firstIndex(of: "--overlay-space-test"), i + 1 < args.count {
            let path = args[i + 1]
            Task {
                var report: [String] = []
                _ = await SpaceSwitcher.switchTo(desktop: 1)
                let variants: [(String, NSWindow.Level)] = [
                    ("screenSaver (сейчас)", .screenSaver),
                    ("shielding (экранирующий)", NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))),
                ]
                for (name, level) in variants {
                    let overlay = TransitionOverlay()
                    overlay.level = level
                    var hiddenMs = 0, maxGapMs = 0, gapMs = 0, lastFrames = 0
                    let sampler = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
                        MainActor.assumeIsolated {
                            guard let d = overlay.diagnostics else { return }
                            if !d.visible { hiddenMs += 10 }
                            if d.frames == lastFrames { gapMs += 10 } else { gapMs = 0; lastFrames = d.frames }
                            maxGapMs = max(maxGapMs, gapMs)
                        }
                    }
                    _ = await overlay.cover(mode: .leisure, effect: .liquid, intensity: 0.8)
                    try? await Task.sleep(for: .seconds(0.3))
                    hiddenMs = 0; maxGapMs = 0
                    let to2 = await SpaceSwitcher.switchTo(desktop: 2) == nil
                    try? await Task.sleep(for: .seconds(1))
                    let to1 = await SpaceSwitcher.switchTo(desktop: 1) == nil
                    try? await Task.sleep(for: .seconds(1))
                    sampler.invalidate()
                    await overlay.reveal()
                    report.append("\(name): не видна \(hiddenMs) мс, самый долгий перерыв кадров \(maxGapMs) мс, смена на 2: \(to2 ? "да" : "нет"), на 1: \(to1 ? "да" : "нет")")
                    try? await Task.sleep(for: .seconds(0.5))
                }
                try? (report.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                exit(0)
            }
            return true
        }
        if args.contains("--selftest-reorder") {
            exit(ReorderState.selfTest() ? 0 : 1)
        }
        if args.contains("--preview-test") {
            Task {
                let overlay = TransitionOverlay()
                let start = Date()
                let ok = await overlay.cover(mode: .leisure, effect: .liquid, intensity: 0.8)
                let covered = Date().timeIntervalSince(start)
                await overlay.reveal()
                print(String(format: "metal=%@ cover=%.2fs total=%.2fs", ok ? "ok" : "unavailable", covered, Date().timeIntervalSince(start)))
                exit(ok ? 0 : 1)
            }
            return true
        }
        if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") }) {
            print("Неизвестный флаг \(unknown). Доступны: --snapshot <папка>, --preview-test, --selftest-prefs, --selftest-reorder, --click-test, --check-access <файл>, --space-test <файл>")
            exit(2)
        }
        return false
    }

    private static func demoPreferences() -> Preferences {
        var prefs = Preferences()
        prefs.currentMode = .work
        prefs.switchDesktops = true
        let demo: [(String, String, String, Bool, Bool)] = [
            ("com.microsoft.Word", "Microsoft Word", "/Applications/Microsoft Word.app", true, false),
            ("com.apple.iWork.Pages", "Pages", "/Applications/Pages.app", true, false),
            ("com.apple.Safari", "Safari", "/Applications/Safari.app", true, false),
            ("ru.keepcoder.Telegram", "Telegram", "/Applications/Telegram.app", false, true),
            ("com.google.Chrome", "Google Chrome", "/Applications/Google Chrome.app", true, true),
            ("com.apple.finder", "Finder", "/System/Library/CoreServices/Finder.app", false, false),
        ]
        prefs.apps = demo.map { ManagedApp(bundleID: $0.0, name: $0.1, path: $0.2, openInWork: $0.3, openInLeisure: $0.4) }
        return prefs
    }

    private static func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = Store(preview: demoPreferences())
        let engine = ModeEngine(store: store)
        let model = IslandModel()
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            model.notchSize = NotchGeometry.notchSize(on: screen)
        }
        print("notch=\(model.notchSize)")

        // notchRightX — как в IslandWindowController: правый край выреза в координатах окна.
        model.notchRightX = model.collapsedSize.width
        render(model: model, store: store, engine: engine, size: model.collapsedSize, to: dir.appendingPathComponent("collapsed.png"))
        model.isHovered = true
        model.notchRightX = model.hoverSize.width
        render(model: model, store: store, engine: engine, size: model.hoverSize, to: dir.appendingPathComponent("hover.png"))
        let mode = store.prefs.currentMode
        store.prefs.currentMode = nil
        render(model: model, store: store, engine: engine, size: model.hoverSize, to: dir.appendingPathComponent("hover-no-mode.png"))
        store.prefs.currentMode = mode
        model.isHovered = false
        model.isExpanded = true
        model.notchRightX = model.expandedSize.width / 2 + model.notchSize.width / 2
        for tab in PanelTab.allCases {
            model.tab = tab
            render(model: model, store: store, engine: engine, size: model.expandedSize, to: dir.appendingPathComponent("\(tab.rawValue).png"))
        }

        // Посреди перетаскивания: Pages (вторая строка) взята и протащена на полторы строки вниз.
        model.tab = .apps
        model.reorder.begin(id: store.prefs.apps[1].id, index: 1, count: store.prefs.apps.count)
        model.reorder.update(translation: ReorderState.rowHeight * 1.6)
        render(model: model, store: store, engine: engine, size: model.expandedSize, to: dir.appendingPathComponent("dragging.png"))
        model.reorder.reset()
    }

    private static func render(model: IslandModel, store: Store, engine: ModeEngine, size: CGSize, to url: URL) {
        let root = IslandView(model: model, store: store, engine: engine)
            .background(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("saved \(url.path)")
    }
}
