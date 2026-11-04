import SwiftUI

/// Перетаскивание строк списка приложений: взятая строка идёт за курсором,
/// остальные расступаются, порядок меняется только при отпускании.
@MainActor
final class ReorderState: ObservableObject {
    /// Строка 36 точек + разделитель 1 точка.
    nonisolated static let rowHeight: CGFloat = 37

    @Published private(set) var draggingID: String?
    @Published private(set) var startIndex = 0
    @Published private(set) var translation: CGFloat = 0
    private(set) var count = 0

    var isActive: Bool { draggingID != nil }
    var targetIndex: Int { Self.target(start: startIndex, translation: translation, count: count) }

    func begin(id: String, index: Int, count: Int) {
        draggingID = id
        startIndex = index
        self.count = count
        translation = 0
    }

    /// Возвращает true, если строка перескочила на новое место (для отклика трекпада).
    @discardableResult
    func update(translation newValue: CGFloat) -> Bool {
        let before = targetIndex
        // Не даём утащить строку дальше первой и последней позиции (с небольшим запасом).
        let minY = -CGFloat(startIndex) * Self.rowHeight - 8
        let maxY = CGFloat(count - 1 - startIndex) * Self.rowHeight + 8
        translation = min(max(newValue, minY), maxY)
        return targetIndex != before
    }

    func reset() {
        draggingID = nil
        translation = 0
    }

    /// Смещение строки по вертикали во время перетаскивания.
    func offset(for id: String, at index: Int) -> CGFloat {
        guard let draggingID else { return 0 }
        if id == draggingID { return translation }
        return Self.shift(index: index, start: startIndex, target: targetIndex)
    }

    // MARK: - Расчёт (чистые функции, проверяются в --selftest-reorder)

    /// Новое место строки: по середине строки, а не по курсору.
    nonisolated static func target(start: Int, translation: CGFloat, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let moved = Int((translation / rowHeight).rounded())
        return min(max(start + moved, 0), count - 1)
    }

    /// Насколько сдвигается соседняя строка, освобождая место.
    nonisolated static func shift(index: Int, start: Int, target: Int) -> CGFloat {
        if start < target, index > start, index <= target { return -rowHeight }
        if start > target, index >= target, index < start { return rowHeight }
        return 0
    }

    /// Аргумент toOffset для Array.move: куда вставить строку, чтобы она оказалась на месте target.
    nonisolated static func moveDestination(from: Int, to: Int) -> Int { to > from ? to + 1 : to }

    nonisolated static func selfTest() -> Bool {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        let h = rowHeight
        check("без сдвига строка остаётся на месте", target(start: 2, translation: 10, count: 6) == 2)
        check("за середину следующей строки — переезд вниз", target(start: 2, translation: h * 0.6, count: 6) == 3)
        check("вверх на две строки", target(start: 4, translation: -h * 2.2, count: 6) == 2)
        check("не дальше первой", target(start: 1, translation: -h * 5, count: 6) == 0)
        check("не дальше последней", target(start: 4, translation: h * 5, count: 6) == 5)
        check("вниз: промежуточные строки поднимаются",
              (0..<6).map { shift(index: $0, start: 1, target: 3) } == [0, 0, -h, -h, 0, 0])
        check("вверх: промежуточные строки опускаются",
              (0..<6).map { shift(index: $0, start: 4, target: 1) } == [0, h, h, h, 0, 0])

        // Итоговый порядок совпадает с тем, что пользователь видел при перетаскивании.
        for (from, to) in [(0, 5), (5, 0), (1, 3), (4, 1), (2, 2)] {
            var items = Array(0..<6)
            items.move(fromOffsets: [from], toOffset: moveDestination(from: from, to: to))
            check("перенос \(from) → \(to)", items[to] == from && items.count == 6 && Set(items).count == 6)
        }
        print(failures == 0 ? "Все проверки перетаскивания пройдены" : "Провалено: \(failures)")
        return failures == 0
    }
}
