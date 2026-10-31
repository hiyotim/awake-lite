import Foundation
import IOKit.pwr_mgt

/// Таймер опроса, счётчик пропусков и блокировка сна.
final class AwakeController: ObservableObject {
    /// Имя агента, без суффикса `.exe`: вариант с ним добавляет шаблон сканера.
    static let watched = ["opencode", "omp"]

    @Published private(set) var statusText = "Агентов нет"
    @Published private(set) var isHolding = false

    private let pollInterval: TimeInterval = 5
    private let missesBeforeRelease = 3
    private var timer: Timer?
    private var misses = 0
    private var assertionID: IOPMAssertionID = 0
    private var holdsAssertion = false

    init() {
        poll()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        if holdsAssertion { IOPMAssertionRelease(assertionID) }
    }

    private func poll() {
        let found = ProcessScanner.running(Self.watched)
        misses = found.isEmpty ? misses + 1 : 0
        statusText = found.isEmpty
            ? "Агентов нет"
            : "Агент запущен: " + found.joined(separator: ", ")
        setHolding(!found.isEmpty && misses < missesBeforeRelease)
    }

    private func setHolding(_ active: Bool) {
        if active && !holdsAssertion { acquire() }
        if !active && holdsAssertion { release() }
    }

    private func acquire() {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "AwakeLite: watched agent is running" as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return }
        assertionID = id
        holdsAssertion = true
        isHolding = true
    }

    private func release() {
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        holdsAssertion = false
        isHolding = false
    }
}
