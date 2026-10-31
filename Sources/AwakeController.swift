import Foundation

/// Состояние меню: пока только строка статуса.
final class AwakeController: ObservableObject {
    /// Имя агента, без суффикса `.exe`: вариант с ним добавляет шаблон сканера.
    static let watched = ["opencode", "omp"]

    @Published private(set) var statusText = "Агентов нет"

    init() {
        refresh()
    }

    func refresh() {
        let found = ProcessScanner.running(Self.watched)
        statusText = found.isEmpty
            ? "Агентов нет"
            : "Агент запущен: " + found.joined(separator: ", ")
    }
}
