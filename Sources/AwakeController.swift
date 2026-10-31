import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Таймер опроса, счётчик пропусков и блокировка сна.
final class AwakeController: ObservableObject {
    /// Имя агента, без суффикса `.exe`: вариант с ним добавляет шаблон сканера.
    static let watched = ["opencode", "omp"]

    @Published private(set) var statusText = "Агентов нет"
    @Published private(set) var isHolding = false
    @Published private(set) var isPaused = false

    var pauseBinding: Binding<Bool> {
        Binding(get: { self.isPaused }, set: { self.setPaused($0) })
    }

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
        if isPaused {
            statusText = "Пауза"
        } else {
            statusText = found.isEmpty
                ? "Агентов нет"
                : "Агент запущен: " + found.joined(separator: ", ")
        }
        // Пока пустых проверок меньше трёх, ничего не меняем: это окно
        // перезапуска агента, и отпускать блокировку в нём нельзя.
        if isPaused {
            setHolding(false)
        } else if !found.isEmpty {
            setHolding(true)
        } else if misses >= missesBeforeRelease {
            setHolding(false)
        }
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        poll()
    }

    func quit() {
        timer?.invalidate()
        timer = nil
        if holdsAssertion { release() }
        NSApplication.shared.terminate(nil)
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
