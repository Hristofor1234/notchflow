import AppKit
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case apps, transition, general

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apps: "Приложения"
        case .transition: "Переход"
        case .general: "Общее"
        }
    }
    var symbol: String {
        switch self {
        case .apps: "square.grid.2x2"
        case .transition: "arrow.left.arrow.right"
        case .general: "switch.2"
        }
    }
}

@MainActor
final class IslandModel: ObservableObject {
    static let cardSize = CGSize(width: 400, height: 470)
    /// Запас вокруг карточки под тень.
    static let margin: CGFloat = 18
    /// Ширина выступа слева от чёлки, который появляется при наведении и показывает режим.
    static let hoverExtension: CGFloat = 96

    @Published var isExpanded = false
    @Published var isHovered = false
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var tab: PanelTab = .apps
    /// Правый край выреза в координатах окна. Окно меняет размер и положение,
    /// а чёлка рисуется от этой точки, чтобы на экране стоять на месте.
    @Published var notchRightX: CGFloat = 200
    /// Пока открыт системный диалог выбора приложения, панель не сворачивается.
    var isPresentingPicker = false
    /// Перетаскивание строк в списке приложений.
    let reorder = ReorderState()

    /// В покое окно совпадает с вырезом и залито чёрным — его не видно.
    var collapsedSize: CGSize { notchSize }

    /// Чёлка с выступом слева; правый край совпадает с вырезом.
    var hoverSize: CGSize { CGSize(width: notchSize.width + Self.hoverExtension, height: notchSize.height) }

    /// Чёлка при открытой панели тоже показывает выступ с режимом.
    var notchShapeSize: CGSize { isHovered || isExpanded ? hoverSize : collapsedSize }

    var expandedSize: CGSize {
        CGSize(
            // Окно центрировано по вырезу, поэтому ширины должно хватить на выступ слева.
            width: max(Self.cardSize.width + Self.margin * 2, notchSize.width + Self.hoverExtension * 2),
            height: notchSize.height + 4 + Self.cardSize.height + Self.margin
        )
    }
}

enum NotchGeometry {
    static func notchSize(on screen: NSScreen) -> CGSize {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width, height: top)
        }
        // Экран без выреза: островок по размеру строки меню.
        return CGSize(width: 180, height: max(NSStatusBar.system.thickness, 24))
    }
}

final class IslandPanel: NSPanel {
    /// Нажатие перехватывается до стандартной обработки окна: иначе первый клик по неактивной
    /// панели уходит на её активацию и до SwiftUI не доходит. true — нажатие обработано.
    var onMouseDown: (@MainActor (NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let onMouseDown, onMouseDown(event) { return }
        super.sendEvent(event)
    }
}

/// Кнопки панели срабатывают с первого клика, даже если окно не в фокусе.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandWindowController {
    private let panel: IslandPanel
    private let model = IslandModel()
    private let store: Store
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private var outsideTicks = 0
    private var hoverOutsideTicks = 0
    private var hiddenForFullscreen = false

    init(store: Store, engine: ModeEngine) {
        self.store = store
        panel = IslandPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let root = IslandView(model: model, store: store, engine: engine)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.onMouseDown = { [weak self] event in self?.handleMouseDown(event) ?? false }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        })
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
        // 20 раз в секунду: наведение на чёлку должно отзываться сразу.
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerTick() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fullscreenTick() }
        })
    }

    // MARK: - Layout

    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private enum WindowState {
        case collapsed, hover, expanded
    }

    private func layout() {
        guard let screen else { return }
        model.notchSize = NotchGeometry.notchSize(on: screen)
        resize(to: windowState)
    }

    private var windowState: WindowState {
        if model.isExpanded { return .expanded }
        return model.isHovered ? .hover : .collapsed
    }

    private func resize(to state: WindowState) {
        guard let screen else { return }
        let rect = frame(for: state, on: screen)
        // Без анимации и до смены рамки: чёлка остаётся на том же месте экрана.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.notchRightX = screen.frame.midX + model.notchSize.width / 2 - rect.minX
        }
        panel.setFrame(rect, display: true)
    }

    /// Окно уменьшается после анимации, иначе содержимое обрежется посреди перехода.
    private func shrinkAfterAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resize(to: self.windowState)
            }
        }
    }

    /// Рамка окна в координатах экрана. Выступ растёт только влево: справа от выреза
    /// иконки строки меню, их окно перекрывать не должно.
    private func frame(for state: WindowState, on screen: NSScreen) -> NSRect {
        let notch = model.notchSize
        let top = screen.frame.maxY
        switch state {
        case .collapsed:
            return NSRect(x: screen.frame.midX - notch.width / 2, y: top - notch.height, width: notch.width, height: notch.height)
        case .hover:
            let size = model.hoverSize
            return NSRect(x: screen.frame.midX + notch.width / 2 - size.width, y: top - size.height, width: size.width, height: size.height)
        case .expanded:
            let size = model.expandedSize
            return NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        }
    }

    // MARK: - Expand / collapse

    private func toggle() {
        model.isExpanded ? collapse() : expand()
    }

    /// Чёлка (с выступом или без) в координатах окна; AppKit считает y снизу.
    private var notchRectInWindow: NSRect {
        let shape = model.notchShapeSize
        return NSRect(
            x: model.notchRightX - shape.width,
            y: panel.frame.height - shape.height,
            width: shape.width,
            height: shape.height
        )
    }

    /// Нажатие на чёлку открывает или закрывает панель сразу, по нажатию кнопки мыши.
    private func handleMouseDown(_ event: NSEvent) -> Bool {
        guard notchRectInWindow.insetBy(dx: -2, dy: -2).contains(event.locationInWindow) else { return false }
        toggle()
        return true
    }

    private func expand() {
        guard !model.isExpanded else { return }
        resize(to: .expanded)
        outsideTicks = 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { model.isExpanded = true }
    }

    private func collapse() {
        guard model.isExpanded else { return }
        let stillOverNotch = notchFrame(.hover).contains(NSEvent.mouseLocation)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
            model.isExpanded = false
            model.isHovered = stillOverNotch
        }
        shrinkAfterAnimation()
    }

    private func setHovered(_ hovered: Bool) {
        guard hovered != model.isHovered else { return }
        if hovered {
            resize(to: .hover)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) { model.isHovered = true }
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { model.isHovered = false }
            shrinkAfterAnimation()
        }
    }

    /// Прямоугольник чёлки (в покое или с выступом) в координатах экрана.
    private func notchFrame(_ state: WindowState) -> NSRect {
        guard let screen else { return .zero }
        return frame(for: state, on: screen)
    }

    private func pointerTick() {
        guard !hiddenForFullscreen else { return }
        let mouse = NSEvent.mouseLocation

        if model.isExpanded {
            // Панель сворачивается, если курсор ушёл с неё на секунду.
            if model.isPresentingPicker || panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
                outsideTicks = 0
            } else {
                outsideTicks += 1
                if outsideTicks >= 20 { collapse() }
            }
            return
        }

        // Курсор у самого верхнего края экрана тоже считается наведением на чёлку.
        let area = notchFrame(model.isHovered ? .hover : .collapsed).insetBy(dx: -2, dy: -2)
        if area.contains(mouse) {
            hoverOutsideTicks = 0
            setHovered(true)
        } else if model.isHovered {
            hoverOutsideTicks += 1
            if hoverOutsideTicks >= 3 { setHovered(false) }
        }
    }

    // MARK: - Click self-test

    /// `NotchFlow --click-test`: нажатия мышью отправляются в окно тем же путём, что и от macOS,
    /// в том числе в момент, когда чёлка меняет размер. Окно на экран не выводится.
    func runClickTest() async -> Bool {
        layout()
        var failures = 0
        var checks = 0
        func click(at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ) {
                    panel.sendEvent(event)
                }
            }
        }
        func expect(_ name: String, _ ok: Bool) {
            checks += 1
            if !ok { failures += 1; print("FAIL  \(name)") }
        }

        let pauses: [Double] = [0, 0.05, 0.2, 0.4, 0.8]
        for i in 0..<40 {
            // Каждый третий клик — сразу после того, как чёлка выдвинула выступ (окно сменило размер).
            if !model.isExpanded && i % 3 == 0 { setHovered(true) }
            if !model.isExpanded && i % 7 == 0 { setHovered(false) }
            let wasExpanded = model.isExpanded
            let notch = notchRectInWindow
            click(at: NSPoint(x: notch.midX, y: notch.midY))
            expect("клик \(i + 1) по чёлке (было \(wasExpanded ? "открыто" : "закрыто"))", model.isExpanded != wasExpanded)
            try? await Task.sleep(for: .seconds(pauses[i % pauses.count]))
        }

        // Клик по карточке не должен закрывать панель.
        if !model.isExpanded { expand() }
        try? await Task.sleep(for: .seconds(0.4))
        click(at: NSPoint(x: panel.frame.width / 2, y: 40))
        expect("клик по карточке не закрывает панель", model.isExpanded)

        print(failures == 0 ? "PASS  проверок кликов: \(checks)" : "Провалено: \(failures) из \(checks)")
        return failures == 0
    }

    // MARK: - Fullscreen

    private func fullscreenTick() {
        let hide = store.prefs.autoHideInFullscreen && !model.isExpanded && Self.frontmostIsFullscreen(on: screen)
        guard hide != hiddenForFullscreen else { return }
        hiddenForFullscreen = hide
        if hide { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    /// Окно активного приложения закрывает весь экран, включая строку меню.
    private static func frontmostIsFullscreen(on screen: NSScreen?) -> Bool {
        guard let screen,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        let size = screen.frame.size
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return false }
            return bounds.width >= size.width && bounds.height >= size.height
        }
    }
}
