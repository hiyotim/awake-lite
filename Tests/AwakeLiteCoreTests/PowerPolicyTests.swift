import IOKit.pwr_mgt
import XCTest
@testable import AwakeLiteCore

/// Fixture facade: it records every call and returns a programmable result so
/// the policy's reporting can be checked independently of the real IOKit.
private final class FakePowerAssertionIO: PowerAssertionIO {
    /// `nil` means success; a value makes the next call fail with that code.
    var acquireResult: IOReturn?
    var releaseResult: IOReturn?

    private(set) var acquireNames: [String] = []
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var activeIDs: Set<IOPMAssertionID> = []

    private var nextID: IOPMAssertionID = 100

    func acquire(named name: String) -> PowerAcquireOutcome {
        acquireCount += 1
        acquireNames.append(name)

        if let code = acquireResult {
            return .failed(code)
        }

        let id = nextID
        nextID += 1
        activeIDs.insert(id)
        return .acquired(id)
    }

    func release(_ assertionID: IOPMAssertionID) -> IOReturn {
        releaseCount += 1

        if let code = releaseResult {
            // IOKit did not confirm the release, so the assertion is still
            // considered held by the operating system.
            return code
        }

        activeIDs.remove(assertionID)
        return kIOReturnSuccess
    }
}

final class PowerPolicyTests: XCTestCase {
    private let working = AggregateDecision(
        state: .working,
        holdAssertion: true,
        reasons: ["work:running"]
    )
    private let idle = AggregateDecision(state: .idle, holdAssertion: false, reasons: [])

    // MARK: - Transitions

    func testHoldingDecisionAcquiresExactlyOnce() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)

        XCTAssertEqual(policy.update(decision: working, paused: false), .held)
        XCTAssertEqual(policy.update(decision: working, paused: false), .held)
        XCTAssertEqual(policy.update(decision: working, paused: false), .held)

        XCTAssertEqual(io.acquireCount, 1)
        XCTAssertEqual(io.activeIDs.count, 1)
        XCTAssertEqual(io.releaseCount, 0)
    }

    func testLeavingHoldingReleasesExactlyOnce() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)

        XCTAssertEqual(policy.update(decision: idle, paused: false), .idle)
        XCTAssertEqual(io.releaseCount, 1)
        XCTAssertTrue(io.activeIDs.isEmpty)

        XCTAssertEqual(policy.update(decision: idle, paused: false), .idle)
        XCTAssertEqual(io.releaseCount, 1)
    }

    func testPauseReleasesImmediatelyAndUnpauseReacquires() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)

        XCTAssertEqual(policy.update(decision: working, paused: true), .idle)
        XCTAssertEqual(io.releaseCount, 1)
        XCTAssertTrue(io.activeIDs.isEmpty)

        // Pause must not replace the decision: the same decision re-acquires.
        XCTAssertEqual(policy.update(decision: working, paused: true), .idle)
        XCTAssertEqual(io.acquireCount, 1)

        XCTAssertEqual(policy.update(decision: working, paused: false), .held)
        XCTAssertEqual(io.acquireCount, 2)
        XCTAssertEqual(io.activeIDs.count, 1)
    }

    func testReleaseAllReleasesImmediatelyAndStaysIdle() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)

        XCTAssertEqual(policy.releaseAll(), .idle)
        XCTAssertEqual(io.releaseCount, 1)
        XCTAssertTrue(io.activeIDs.isEmpty)

        XCTAssertEqual(policy.releaseAll(), .idle)
        XCTAssertEqual(io.releaseCount, 1)
    }

    // MARK: - Failures

    func testFailedAcquireIsReportedAndNeverClaimsHeld() {
        let io = FakePowerAssertionIO()
        io.acquireResult = kIOReturnNotPermitted
        let policy = PowerPolicy(io: io)

        XCTAssertEqual(
            policy.update(decision: working, paused: false),
            .failedAcquire(kIOReturnNotPermitted)
        )
        XCTAssertEqual(policy.status, .failedAcquire(kIOReturnNotPermitted))
        XCTAssertFalse(policy.status.isHolding)
        XCTAssertTrue(io.activeIDs.isEmpty)

        // A repeated identical decision must not stack attempts or pretend
        // the hold now exists.
        XCTAssertEqual(
            policy.update(decision: working, paused: false),
            .failedAcquire(kIOReturnNotPermitted)
        )
        XCTAssertEqual(io.acquireCount, 1)
        XCTAssertFalse(policy.status.isHolding)
    }

    func testFailedReleaseIsReportedAndIsNotIdle() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)
        io.releaseResult = kIOReturnError

        XCTAssertEqual(
            policy.update(decision: idle, paused: false),
            .failedRelease(kIOReturnError)
        )
        XCTAssertEqual(policy.status, .failedRelease(kIOReturnError))
        XCTAssertEqual(io.activeIDs.count, 1)

        // The error stays visible on repeated idle decisions and the release
        // is not hammered.
        XCTAssertEqual(
            policy.update(decision: idle, paused: false),
            .failedRelease(kIOReturnError)
        )
        XCTAssertEqual(io.releaseCount, 1)
        XCTAssertNotEqual(policy.status, .idle)
    }

    func testReacquireAfterFailedReleaseRetiresTheStaleAssertion() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)
        io.releaseResult = kIOReturnError
        policy.update(decision: idle, paused: false)

        io.releaseResult = nil
        XCTAssertEqual(policy.update(decision: working, paused: false), .held)

        XCTAssertEqual(io.acquireCount, 2)
        XCTAssertEqual(io.releaseCount, 2)
        // Exactly one assertion is live: the stale one was released before a
        // second one was created.
        XCTAssertEqual(io.activeIDs.count, 1)
    }

    // MARK: - Acceptance shapes

    /// A01: process presence is not an input to this boundary. With no
    /// integrations enabled the app supplies the idle decision repeatedly, and
    /// even repeated decisions never acquire anything.
    func testIdleDecisionWithProcessPresenceAcquiresNothing() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)

        for _ in 0..<10 {
            XCTAssertEqual(policy.update(decision: idle, paused: false), .idle)
        }

        XCTAssertEqual(io.acquireCount, 0)
        XCTAssertEqual(io.releaseCount, 0)
        XCTAssertEqual(policy.status, .idle)
    }

    /// A05: a confirmed working decision creates exactly one assertion.
    func testWorkingDecisionAcquiresOneAssertion() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)

        XCTAssertEqual(policy.update(decision: working, paused: false), .held)
        XCTAssertEqual(io.acquireCount, 1)
        XCTAssertEqual(io.activeIDs.count, 1)
    }

    /// A06: low CPU and long requests have no path into the policy, so the
    /// hold survives any number of unchanged decisions.
    func testRepeatedWorkingDecisionsKeepTheHold() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)

        for _ in 0..<100 {
            XCTAssertEqual(policy.update(decision: working, paused: false), .held)
        }

        XCTAssertEqual(io.acquireCount, 1)
        XCTAssertEqual(io.releaseCount, 0)
        XCTAssertEqual(io.activeIDs.count, 1)
    }

    func testAssertionNameIdentifiesAwakeLite() {
        let io = FakePowerAssertionIO()
        let policy = PowerPolicy(io: io)
        policy.update(decision: working, paused: false)

        XCTAssertEqual(io.acquireNames, [PowerPolicy.defaultAssertionName])
        XCTAssertTrue(io.acquireNames[0].contains("AwakeLite"))
    }

    // MARK: - Real IOKit

    /// The one check against the real facade: create an assertion, read it
    /// back through IOKit, release it, and confirm IOKit no longer reports it.
    func testRealIOKitAssertionIsCreatedAndReleased() throws {
        let io = IOKitPowerAssertionIO()
        let name = "AwakeLite test: real IOKit readback"

        guard case .acquired(let id) = io.acquire(named: name) else {
            throw XCTSkip("IOKit refused a PreventUserIdleSystemSleep assertion in this environment")
        }

        var released = false
        defer {
            if !released { _ = io.release(id) }
        }

        let properties = IOPMAssertionCopyProperties(id)?
            .takeRetainedValue() as? [String: Any]
        XCTAssertNotNil(properties, "the created assertion must exist in IOKit")
        XCTAssertEqual(properties?["AssertName"] as? String, name)
        XCTAssertEqual(properties?["AssertType"] as? String, "PreventUserIdleSystemSleep")

        XCTAssertEqual(io.release(id), kIOReturnSuccess)
        released = true

        // After a confirmed release IOKit reports nothing for this id.
        XCTAssertNil(IOPMAssertionCopyProperties(id))
    }
}
