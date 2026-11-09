import Darwin
import Foundation
import XCTest
@testable import AwakeLiteCore

final class OwnerLivenessTests: XCTestCase {
    // MARK: - Real process presence

    func testCurrentProcessIsAlive() {
        let owner = OwnerIdentityProbe.identity(pid: getpid())

        XCTAssertGreaterThan(owner.startTimeMicros, 0, "the test process is measurable")
        XCTAssertFalse(OwnerLiveness.system().isDead(owner))
    }

    func testNonexistentPIDIsDead() throws {
        let pid = try DeadProcess.pid()
        let owner = OwnerIdentityProbe.identity(pid: pid)

        XCTAssertEqual(owner.pid, pid)
        XCTAssertEqual(owner.startTimeMicros, 0, "an unmeasurable process takes the fallback identity")
        XCTAssertTrue(OwnerLiveness.system().isDead(owner))
    }

    func testBootTokenMismatchIsDead() {
        var owner = OwnerIdentityProbe.identity(pid: getpid())
        owner.bootID = "b0-1"

        XCTAssertNotEqual(owner.bootID, OwnerIdentityProbe.bootToken())
        XCTAssertTrue(OwnerLiveness.system().isDead(owner))
    }

    func testSuppliedOwnerWithLivePIDIsNotDead() {
        let owner = OwnerIdentityProbe.supplied(instance: "p\(getpid())-live", pid: getpid())

        XCTAssertEqual(owner.startTimeMicros, 0, "a supplied owner carries no measurement")
        XCTAssertFalse(OwnerLiveness.system().isDead(owner))
    }

    func testSuppliedOwnerWithDeadPIDIsDead() throws {
        let pid = try DeadProcess.pid()
        let owner = OwnerIdentityProbe.supplied(instance: "p\(pid)-dead", pid: pid)

        XCTAssertEqual(owner.startTimeMicros, 0)
        XCTAssertTrue(OwnerLiveness.system().isDead(owner))
    }

    // MARK: - Injected probe rules

    func testMeasuredOwnerWithDifferentStartTimeIsDead() {
        let owner = measuredOwner()
        let reused = OwnerProbe(
            identity: identityCopies(owner, startTimeMicros: owner.startTimeMicros + 1),
            measured: true
        )

        XCTAssertTrue(
            OwnerLiveness.evaluate(
                owner: owner,
                bootToken: owner.bootID,
                presence: .alive,
                measure: { _ in reused }
            )
        )
    }

    func testIndeterminateOrUnmeasurablePresenceIsNotDead() {
        let owner = measuredOwner()
        let reused = OwnerProbe(
            identity: identityCopies(owner, startTimeMicros: owner.startTimeMicros + 1),
            measured: true
        )

        // `unknown` covers EPERM and every unexpected `kill` result: the pid
        // exists but nothing proves it is the recorded owner.
        XCTAssertFalse(
            OwnerLiveness.evaluate(
                owner: owner,
                bootToken: owner.bootID,
                presence: .unknown,
                measure: { _ in reused }
            )
        )

        // A live pid libproc cannot describe is also not dead.
        XCTAssertFalse(
            OwnerLiveness.evaluate(
                owner: owner,
                bootToken: owner.bootID,
                presence: .alive,
                measure: { _ in OwnerProbe(identity: owner, measured: false) }
            )
        )
    }

    func testMeasuredOwnerThatMatchesIsNotDead() {
        let owner = measuredOwner()

        XCTAssertFalse(
            OwnerLiveness.evaluate(
                owner: owner,
                bootToken: owner.bootID,
                presence: .alive,
                measure: { _ in OwnerProbe(identity: owner, measured: true) }
            )
        )
    }

    func testAbsentPresenceIsDeadEvenWhenMeasurementIsProvided() {
        let owner = measuredOwner()

        XCTAssertTrue(
            OwnerLiveness.evaluate(
                owner: owner,
                bootToken: owner.bootID,
                presence: .absent,
                measure: { _ in OwnerProbe(identity: owner, measured: true) }
            )
        )
    }

    // MARK: - Helpers

    private func measuredOwner() -> OwnerIdentity {
        let probe = OwnerIdentityProbe.measure(pid: getpid())
        XCTAssertTrue(probe.measured, "the test process is measurable")
        return probe.identity
    }

    private func identityCopies(_ owner: OwnerIdentity, startTimeMicros: UInt64) -> OwnerIdentity {
        OwnerIdentity(
            bootID: owner.bootID,
            pid: owner.pid,
            startTimeMicros: startTimeMicros,
            uid: owner.uid,
            instance: "p\(owner.pid)-reused"
        )
    }
}

/// Provides a process id that provably names no running process.
enum DeadProcess {
    enum Failure: Error {
        case noDeadPID
    }

    /// Spawns and reaps `/bin/sleep`, then waits until `kill(pid, 0)` reports
    /// `ESRCH`. A reused pid is discarded by starting again.
    static func pid() throws -> Int32 {
        for _ in 0..<5 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["0.01"]
            try process.run()
            let pid = process.processIdentifier
            process.waitUntilExit()

            for _ in 0..<20 {
                if kill(pid, 0) == -1 && errno == ESRCH { return pid }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        throw Failure.noDeadPID
    }
}
