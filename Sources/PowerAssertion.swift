import Combine
import Foundation
import IOKit.pwr_mgt

/// Result of asking the power boundary to create one assertion.
enum PowerAcquireOutcome: Equatable {
    case acquired(IOPMAssertionID)
    case failed(IOReturn)
}

/// The injectable seam over IOKit. It exposes only what the sleep policy
/// needs: create one assertion and release one assertion. Both calls return
/// the actual `IOReturn`, so the caller can never mistake an intent for a
/// result.
protocol PowerAssertionIO {
    func acquire(named name: String) -> PowerAcquireOutcome
    func release(_ assertionID: IOPMAssertionID) -> IOReturn
}

/// The real facade. It creates a `PreventUserIdleSystemSleep` assertion only:
/// no `SleepDisabled`, no `pmset`, no lid control, and no privileged helper.
struct IOKitPowerAssertionIO: PowerAssertionIO {
    func acquire(named name: String) -> PowerAcquireOutcome {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return .failed(result) }
        return .acquired(id)
    }

    func release(_ assertionID: IOPMAssertionID) -> IOReturn {
        IOPMAssertionRelease(assertionID)
    }
}

/// What the app can truthfully say about the system assertion.
///
/// `failedAcquire` means nothing is held and IOKit refused to create the
/// assertion. `failedRelease` means the app asked IOKit to release and IOKit
/// did not confirm it; that state stays visible instead of collapsing to
/// `idle`, because the Mac may still be kept awake by the assertion the app
/// believes it no longer wants.
enum PowerStatus: Equatable {
    case idle
    case held
    case failedAcquire(IOReturn)
    case failedRelease(IOReturn)

    var isHolding: Bool {
        self == .held
    }
}

/// The single owner of the app's sleep assertion.
///
/// The policy is driven entirely by its caller: `update(decision:paused:)`
/// receives the Stage 1 aggregate decision plus the user's pause. It never
/// inspects processes, never runs a timer, and never polls. An assertion is
/// created only on a transition into a holding decision and released only on
/// a transition out of one, so repeated identical decisions cannot stack
/// assertions or repeat a release.
///
/// All calls are expected on the main thread.
final class PowerPolicy: ObservableObject {
    /// Long enough for `pmset -g assertions` to identify the owner, short
    /// enough to stay readable.
    static let defaultAssertionName = "AwakeLite: work in progress"

    @Published private(set) var status: PowerStatus = .idle

    private let io: PowerAssertionIO
    private let assertionName: String
    private var assertionID: IOPMAssertionID?
    private var holdingIntent = false

    init(
        io: PowerAssertionIO = IOKitPowerAssertionIO(),
        assertionName: String = PowerPolicy.defaultAssertionName
    ) {
        self.io = io
        self.assertionName = assertionName
    }

    deinit {
        // Best effort: a terminated app cannot report a release failure, but
        // it must not leak a live assertion when IOKit still lets us drop it.
        if let id = assertionID {
            _ = io.release(id)
        }
    }

    /// Applies one aggregate decision and the current pause state.
    ///
    /// `paused` suppresses the hold without changing the decision: pause
    /// releases immediately, and the next unpaused call with a holding
    /// decision acquires again.
    @discardableResult
    func update(decision: AggregateDecision, paused: Bool) -> PowerStatus {
        apply(hold: decision.holdAssertion && !paused)
    }

    /// Releases immediately and records that the app no longer intends to
    /// hold. Used by quit; the status still reflects the real IOKit result.
    @discardableResult
    func releaseAll() -> PowerStatus {
        holdingIntent = false
        return release()
    }

    private func apply(hold: Bool) -> PowerStatus {
        guard hold != holdingIntent else { return status }
        holdingIntent = hold
        return hold ? acquire() : release()
    }

    private func acquire() -> PowerStatus {
        // A failed release may have left the previous assertion alive. Retire
        // it first so this app never owns two assertions at once; if it still
        // refuses to release, surface that instead of acquiring a second one.
        if let stale = assertionID {
            let result = io.release(stale)
            guard result == kIOReturnSuccess else {
                status = .failedRelease(result)
                return status
            }
            assertionID = nil
        }

        switch io.acquire(named: assertionName) {
        case .acquired(let id):
            assertionID = id
            status = .held
        case .failed(let code):
            assertionID = nil
            status = .failedAcquire(code)
        }
        return status
    }

    private func release() -> PowerStatus {
        guard let id = assertionID else {
            // Nothing is held: releasing is a no-op. A failed release keeps
            // its id, so it cannot reach this branch and cannot look idle.
            status = .idle
            return status
        }

        let result = io.release(id)
        if result == kIOReturnSuccess {
            assertionID = nil
            status = .idle
        } else {
            status = .failedRelease(result)
        }
        return status
    }
}
