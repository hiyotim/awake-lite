import AppKit
import Combine
import SwiftUI

/// App-side owner of the aggregate decision, pause, and the single power
/// boundary. It never inspects processes and never polls: a decision arrives
/// through `update(decision:)`, and only pause and quit change the policy
/// directly.
final class AwakeController: ObservableObject {
    @Published private(set) var isPaused = false

    /// The Stage 1 aggregate decision power is derived from. Nothing supplies
    /// it yet (model wiring is Stage 5.3), so it starts as confirmed idle.
    private(set) var decision = AggregateDecision(state: .idle, holdAssertion: false, reasons: [])

    /// The only assertion owner in the app.
    private let power = PowerPolicy()

    private var statusObserver: AnyCancellable?
    private var isTerminating = false

    var pauseBinding: Binding<Bool> {
        Binding(get: { self.isPaused }, set: { self.setPaused($0) })
    }

    /// The real IOKit state, not the intent to hold.
    var powerStatus: PowerStatus { power.status }

    var isHolding: Bool { power.status == .held }

    var statusText: String {
        switch (isPaused, power.status) {
        case (true, .failedRelease(let code)):
            return "Пауза, но IOKit не снял блокировку (\(Self.code(code)))"
        case (true, _):
            return "Пауза"
        case (false, .idle):
            return "Сон разрешён"
        case (false, .held):
            return "Сон заблокирован: идёт работа"
        case (false, .failedAcquire(let code)):
            return "Ошибка IOKit: блокировка не создана (\(Self.code(code)))"
        case (false, .failedRelease(let code)):
            return "Ошибка IOKit: блокировка не снята (\(Self.code(code)))"
        }
    }

    init() {
        // PowerPolicy publishes its own status; relay it so the menu reads
        // the IOKit result rather than a mirrored intent.
        statusObserver = power.$status.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        power.update(decision: decision, paused: isPaused)
    }

    /// Connects the caller's aggregate decision. Repeated identical decisions
    /// are absorbed by `PowerPolicy` and do not touch IOKit again.
    func update(decision: AggregateDecision) {
        guard !isTerminating else { return }
        self.decision = decision
        power.update(decision: decision, paused: isPaused)
    }

    /// Pause releases immediately while the observation and task state in
    /// `decision` is preserved; unpausing recomputes from it.
    func setPaused(_ paused: Bool) {
        guard !isTerminating, paused != isPaused else { return }
        isPaused = paused
        power.update(decision: decision, paused: isPaused)
    }

    func quit() {
        isTerminating = true
        power.releaseAll()
        NSApplication.shared.terminate(nil)
    }

    private static func code(_ result: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: result))
    }
}
