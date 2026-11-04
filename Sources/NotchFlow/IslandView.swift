import AppKit
import ServiceManagement
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.16, green: 0.50, blue: 1.0)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.69, blue: 1.0), Color(red: 0.13, green: 0.43, blue: 1.0)],
        startPoint: .top, endPoint: .bottom
    )
    static let cardTop = Color(red: 0.12, green: 0.16, blue: 0.27)
    static let cardBottom = Color(red: 0.07, green: 0.09, blue: 0.17)
    static let secondary = Color(red: 0.63, green: 0.70, blue: 0.84)
    static let hairline = Color.white.opacity(0.09)
    static let columnWidth: CGFloat = 78
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @ObservedObject var engine: ModeEngine

    var body: some View {
        VStack(spacing: 4) {
            // Нажатия на чёлку обрабатывает окно (IslandPanel.onMouseDown), а не SwiftUI.
            NotchArea(model: model, mode: engine.pendingMode ?? store.prefs.currentMode, isSwitching: engine.isSwitching)
                // Правый край чёлки — на правом крае выреза, где бы ни было окно.
                .padding(.leading, max(0, model.notchRightX - model.notchShapeSize.width))
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isExpanded {
                PanelCard(model: model, store: store, engine: engine)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Notch

/// Чёрная область точно по размеру выреза: в покое сливается с ним, нажатие открывает панель.
/// При наведении слева от выреза выдвигается выступ с текущим режимом.
private struct NotchArea: View {
    @ObservedObject var model: IslandModel
    let mode: Mode?
    let isSwitching: Bool

    private var isPeeking: Bool { model.isHovered || model.isExpanded }

    var body: some View {
        let size = model.notchShapeSize
        UnevenRoundedRectangle(bottomLeadingRadius: isPeeking ? size.height / 2 : 9, bottomTrailingRadius: 9)
            .fill(.black)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                if isPeeking {
                    HStack(spacing: 5) {
                        if isSwitching {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: mode?.symbol ?? "circle.dashed")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(mode == nil ? Color.white.opacity(0.5) : Theme.accent)
                        }
                        Text(mode?.title ?? "Без режима")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(mode == nil ? 0.6 : 0.95))
                            .lineLimit(1)
                    }
                    .frame(width: IslandModel.hoverExtension)
                    .transition(.opacity.combined(with: .offset(x: 12)))
                }
            }
    }
}

// MARK: - Card

struct PopoverShape: Shape {
    static let arrowHeight: CGFloat = 7
    var radius: CGFloat = 18
    var arrowWidth: CGFloat = 20

    func path(in r: CGRect) -> Path {
        let top = r.minY + Self.arrowHeight
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: top))
        p.addLine(to: CGPoint(x: r.midX - arrowWidth / 2, y: top))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.midX - arrowWidth / 5, y: top))
        p.addQuadCurve(to: CGPoint(x: r.midX + arrowWidth / 2, y: top), control: CGPoint(x: r.midX + arrowWidth / 5, y: top))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: top))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: top + radius), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: r.minX, y: top + radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.minX + radius, y: top), radius: radius)
        p.closeSubpath()
        return p
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PanelCard: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @ObservedObject var engine: ModeEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(model: model, engine: engine)
            ModeSelector(store: store, engine: engine)
            TabBar(model: model)
            Group {
                switch model.tab {
                case .apps: AppsTab(model: model, store: store, reorder: model.reorder)
                case .transition: TransitionTab(store: store, engine: engine)
                case .general: GeneralTab(store: store)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14 + PopoverShape.arrowHeight)
        .padding(.bottom, 14)
        .frame(width: IslandModel.cardSize.width, height: IslandModel.cardSize.height, alignment: .top)
        .background {
            ZStack {
                VisualEffectBackground()
                LinearGradient(
                    colors: [Theme.cardTop.opacity(0.88), Theme.cardBottom.opacity(0.94)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .clipShape(PopoverShape())
        }
        .overlay(PopoverShape().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 8)
    }
}

private struct PanelHeader: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var engine: ModeEngine

    private var subtitle: String {
        if engine.isSwitching { return engine.status }
        return engine.lastProblem ?? "Режимы и приложения"
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.25, green: 0.62, blue: 1.0), Color(red: 0.45, green: 0.30, blue: 0.98)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text("NotchFlow")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(engine.lastProblem != nil && !engine.isSwitching ? Color.orange : Theme.secondary)
                    .lineLimit(1)
                    .help(subtitle)
            }

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                Button { model.tab = .general } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Настройки")

                Menu {
                    Button("Предпросмотр анимации") { engine.preview() }
                    Divider()
                    Button("Выйти из NotchFlow") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 26, height: 26)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

private struct ModeSelector: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: ModeEngine
    @Namespace private var selection

    private var selected: Mode? { engine.pendingMode ?? store.prefs.currentMode }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Mode.allCases) { mode in
                Button { engine.switchTo(mode) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: mode.symbol).font(.system(size: 13, weight: .medium))
                        Text(mode.title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(selected == mode ? Color.white : Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if selected == mode {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Theme.accentGradient)
                                .shadow(color: Theme.accent.opacity(0.5), radius: 6)
                                .matchedGeometryEffect(id: "mode", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(engine.isSwitching && selected != mode)
            }
        }
        .padding(2)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.08), lineWidth: 1))
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selected)
    }
}

private struct TabBar: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(PanelTab.allCases) { tab in
                    let isSelected = model.tab == tab
                    Button { model.tab = tab } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 11))
                            Text(tab.title).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.65))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            GeometryReader { geo in
                let third = geo.size.width / CGFloat(PanelTab.allCases.count)
                let index = CGFloat(PanelTab.allCases.firstIndex(of: model.tab) ?? 0)
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: third, height: 2)
                        .offset(x: third * index)
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.tab)
    }
}

// MARK: - Controls

struct PillToggleStyle: ToggleStyle {
    var width: CGFloat = 32
    var height: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.13)))
                        .overlay(Capsule().stroke(.white.opacity(configuration.isOn ? 0.15 : 0.07), lineWidth: 1))
                    Circle()
                        .fill(.white)
                        .padding(2)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                }
                .frame(width: width, height: height)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isOn)
    }
}

private struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

// MARK: - Apps

private struct AppsTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: Store
    @ObservedObject var reorder: ReorderState
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Приложение")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ColumnHeader(mode: .work)
                ColumnHeader(mode: .leisure)
            }
            .frame(height: 26)
            Hairline()

            if store.prefs.apps.isEmpty {
                Text("Добавьте приложения и отметьте, в каком режиме каждое открывать. В другом режиме NotchFlow его закроет.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.prefs.apps.enumerated()), id: \.element.id) { index, app in
                            let isDragged = reorder.draggingID == app.id
                            AppRow(
                                app: app,
                                openInWork: binding(app.id, \.openInWork),
                                openInLeisure: binding(app.id, \.openInLeisure),
                                onMoveUp: index > 0 ? { move(app.id, by: -1) } : nil,
                                onMoveDown: index < store.prefs.apps.count - 1 ? { move(app.id, by: 1) } : nil
                            ) {
                                store.prefs.apps.removeAll { $0.id == app.id }
                            }
                            .overlay(alignment: .bottom) { Hairline().opacity(isDragged ? 0 : 1) }
                            // Взятая строка «приподнимается»: подложка, тень, чуть крупнее.
                            .background {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Theme.cardTop)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.5), radius: 14, y: 8)
                                    .padding(.horizontal, -6)
                                    .opacity(isDragged ? 1 : 0)
                            }
                            .scaleEffect(isDragged ? 1.03 : 1)
                            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isDragged)
                            // Взятая строка идёт за курсором без задержки, остальные расступаются пружиной.
                            .offset(y: reorder.offset(for: app.id, at: index))
                            .animation(isDragged ? nil : Self.reflow, value: reorder.offset(for: app.id, at: index))
                            .zIndex(isDragged ? 1 : 0)
                            .gesture(dragGesture(for: app.id, at: index))
                        }
                    }
                    // Запас внутри прокрутки, чтобы поднятая строка с тенью не обрезалась по краям;
                    // снаружи он компенсирован, строки остаются вровень с заголовком.
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.never)
                .padding(.horizontal, -12)
                .padding(.vertical, -8)
            }

            HStack {
                Button(action: add) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        Text("Добавить").font(.system(size: 12))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.white.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(message ?? Self.countLabel(store.prefs.apps.count))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 10)
        }
    }

    private static let reflow = Animation.spring(response: 0.3, dampingFraction: 0.82)

    private func dragGesture(for id: String, at index: Int) -> some Gesture {
        // minimumDistance: обычный клик по переключателю не начинает перетаскивание.
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !reorder.isActive {
                    reorder.begin(id: id, index: index, count: store.prefs.apps.count)
                    NSCursor.closedHand.push()
                }
                if reorder.update(translation: value.translation.height) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
            .onEnded { _ in
                guard reorder.isActive else { return }
                NSCursor.pop()
                let from = reorder.startIndex, to = reorder.targetIndex
                // Порядок меняется одной транзакцией с возвратом смещений — строка мягко встаёт на место.
                withAnimation(Self.reflow) {
                    if from != to {
                        store.prefs.apps.move(fromOffsets: [from], toOffset: ReorderState.moveDestination(from: from, to: to))
                    }
                    reorder.reset()
                }
            }
    }

    private func move(_ id: String, by offset: Int) {
        guard let from = store.prefs.apps.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard store.prefs.apps.indices.contains(to) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            store.prefs.apps.swapAt(from, to)
        }
    }

    private func binding(_ id: String, _ key: WritableKeyPath<ManagedApp, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.prefs.apps.first { $0.id == id }?[keyPath: key] ?? false },
            set: { newValue in
                if let i = store.prefs.apps.firstIndex(where: { $0.id == id }) {
                    store.prefs.apps[i][keyPath: key] = newValue
                }
            }
        )
    }

    private func add() {
        model.isPresentingPicker = true
        defer { model.isPresentingPicker = false }
        guard let url = AppPicker.pick() else { return }
        do {
            let app = try AppPicker.entry(for: url, currentMode: store.prefs.currentMode, existing: store.prefs.apps)
            store.prefs.apps.append(app)
            message = "Добавлено: \(app.name)"
        } catch let error as AppPickerError {
            message = error.message
        } catch {
            message = error.localizedDescription
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { message = nil }
    }

    static func countLabel(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "приложение"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "приложения"
        } else {
            word = "приложений"
        }
        return "\(n) \(word)"
    }
}

private struct ColumnHeader: View {
    let mode: Mode

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: mode.symbol).font(.system(size: 10, weight: .medium))
            Text(mode.title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(width: Theme.columnWidth)
    }
}

private struct AppRow: View {
    let app: ManagedApp
    @Binding var openInWork: Bool
    @Binding var openInLeisure: Bool
    /// nil — строка уже первая (последняя), двигать некуда.
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            cell($openInWork, mode: .work)
            cell($openInLeisure, mode: .leisure)
        }
        .frame(height: 36)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Выше") { onMoveUp?() }.disabled(onMoveUp == nil)
            Button("Ниже") { onMoveDown?() }.disabled(onMoveDown == nil)
            Divider()
            Button("Удалить из списка", role: .destructive, action: onDelete)
        }
    }

    private func cell(_ isOn: Binding<Bool>, mode: Mode) -> some View {
        Toggle(isOn: isOn) { EmptyView() }
            .toggleStyle(PillToggleStyle())
            .help("«\(mode.title)»: \(isOn.wrappedValue ? "открывать" : "закрывать")")
            .frame(width: Theme.columnWidth)
    }
}

// MARK: - Settings building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.secondary)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
                )
        }
    }
}

private struct SettingsRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12)).foregroundStyle(.white)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle(isOn: $isOn) { EmptyView() }.toggleStyle(PillToggleStyle())
        }
    }
}

private struct RowDivider: View {
    var body: some View { Hairline().padding(.leading, 10) }
}

private struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.08)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct DesktopStepper: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") { value = max(1, value - 1) }
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .frame(width: 20)
            stepButton("plus") { value = min(9, value + 1) }
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transition

private struct TransitionTab: View {
    @ObservedObject var store: Store
    @ObservedObject var engine: ModeEngine
    @State private var canSwitchSpaces = SpaceSwitcher.canPostEvents

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSection(title: "Анимация") {
                    SettingsToggle(title: "Показывать анимацию", isOn: $store.prefs.showAnimation)
                    if store.prefs.showAnimation {
                        RowDivider()
                        SettingsRow(title: "Эффект") {
                            HStack(spacing: 4) {
                                ForEach(TransitionEffect.allCases) { effect in
                                    Chip(title: effect.title, isSelected: store.prefs.effect == effect) {
                                        store.prefs.effect = effect
                                    }
                                }
                            }
                        }
                        RowDivider()
                        SettingsRow(title: "Интенсивность") {
                            Slider(value: $store.prefs.intensity, in: 0.2...1)
                                .tint(Theme.accent)
                                .controlSize(.small)
                                .frame(width: 110)
                            Chip(title: "Просмотр", isSelected: false) { engine.preview() }
                                .disabled(engine.isSwitching)
                        }
                    }
                }

                SettingsSection(title: "Приложения") {
                    SettingsToggle(
                        title: "Закрывать приложения",
                        detail: "Сначала как ⌘Q",
                        isOn: $store.prefs.closeOnLeave
                    )
                    if store.prefs.closeOnLeave {
                        RowDivider()
                        SettingsToggle(
                            title: "Дожимать за 5 секунд",
                            detail: "Не закрылось — принудительно; несохранённое пропадёт",
                            isOn: $store.prefs.forceQuit
                        )
                    }
                    RowDivider()
                    SettingsToggle(
                        title: "Открывать приложения",
                        detail: "Без вывода на передний план",
                        isOn: $store.prefs.launchOnEnter
                    )
                }

                SettingsSection(title: "Рабочие столы") {
                    SettingsToggle(title: "Переключать рабочий стол", isOn: $store.prefs.switchDesktops)
                    if store.prefs.switchDesktops {
                        RowDivider()
                        SettingsRow(title: "«Работа» — стол") {
                            DesktopStepper(value: $store.prefs.workDesktop)
                        }
                        RowDivider()
                        SettingsRow(title: "«Досуг» — стол") {
                            DesktopStepper(value: $store.prefs.leisureDesktop)
                        }
                        RowDivider()
                        SettingsRow(
                            title: canSwitchSpaces ? "Доступ разрешён" : "Нужен «Универсальный доступ»",
                            detail: "И сочетания Control+N в Mission Control"
                        ) {
                            if canSwitchSpaces {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Chip(title: "Разрешить…", isSelected: true) { SpaceSwitcher.requestAccess() }
                            }
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .scrollIndicators(.never)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            canSwitchSpaces = SpaceSwitcher.canPostEvents
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: Store
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSection(title: "Система") {
                SettingsToggle(title: "Запуск при входе", detail: loginError, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                RowDivider()
                SettingsToggle(
                    title: "Скрывать в полноэкранном режиме",
                    isOn: $store.prefs.autoHideInFullscreen
                )
            }
            SettingsSection(title: "О приложении") {
                SettingsRow(title: "NotchFlow", detail: "Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")") {
                    Chip(title: "Выйти", isSelected: false) { NSApp.terminate(nil) }
                }
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Не удалось: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}
