import Foundation
import XCTest
@testable import AwakeLiteCore

/// Unit 3.2: the Pi and OMP in-process extension adapters and their bundled
/// assets.
///
/// The helper registry ships no family in unit 3.1, so every check injects one
/// adapter through `HelperRunner`, exactly as the registry owner will.
final class PiOMPAdapterTests: XCTestCase {
    private var sandbox: URL!
    private var support: URL!

    private let epoch = HelperFixtures.epoch

    private lazy var owner: OwnerIdentity = OwnerIdentityProbe.identity(pid: getpid())

    private var piAdapters: [HookAdapter] { [PiAdapter()] }
    private var ompAdapters: [HookAdapter] { [OMPAdapter()] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try HelperFixtures.makeSandbox()
        support = sandbox.appendingPathComponent("support", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let support {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: support.path
            )
        }
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        support = nil
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func emit(
        family: String,
        target: String,
        event: String,
        payload: [String: Any],
        adapters: [HookAdapter],
        generation: UInt64 = 1,
        at time: TimeInterval = 0,
        root: URL? = nil
    ) throws -> (code: Int32, lines: [String], event: ActivityEvent?) {
        let rootURL = root ?? support!
        let before = Set(HelperFixtures.eventFiles(in: rootURL))
        var lines: [String] = []
        let code = HelperRunner.run(
            arguments: [
                "--family", family,
                "--target", target,
                "--generation", String(generation),
                "--event", event
            ],
            stdin: try HelperFixtures.payload(payload),
            appSupportRoot: rootURL,
            adapters: adapters,
            now: epoch.addingTimeInterval(time),
            owner: owner
        ) { lines.append($0) }
        let written = HelperFixtures.eventFiles(in: rootURL).filter { !before.contains($0) }
        let decoded = try written.first.map { try HelperFixtures.decodeEvent($0) }
        return (code, lines, decoded)
    }

    /// Emits one event that must succeed and returns the single event file the
    /// helper wrote.
    @discardableResult
    private func emitEvent(
        family: String,
        target: String,
        event: String,
        payload: [String: Any],
        adapters: [HookAdapter],
        generation: UInt64 = 1,
        at time: TimeInterval = 0,
        root: URL? = nil
    ) throws -> ActivityEvent {
        let result = try emit(
            family: family,
            target: target,
            event: event,
            payload: payload,
            adapters: adapters,
            generation: generation,
            at: time,
            root: root
        )
        XCTAssertEqual(result.code, 0, "\(family)/\(event) should be accepted")
        XCTAssertEqual(result.lines, [], "a successful emission stays silent")
        return try XCTUnwrap(result.event, "\(family)/\(event) should write exactly one event")
    }

    private func activatedModel(_ family: String, generation: UInt64 = 1) -> ActivityModel {
        var model = ActivityModel()
        model.activate(family: family, generation: generation)
        return model
    }

    private func runRecord(
        _ model: ActivityModel,
        family: String,
        session: String,
        generation: UInt64
    ) -> WorkRecord? {
        model.works[
            WorkIdentity(
                session: SessionIdentity(family: family, instance: owner.instance, session: session),
                generation: generation,
                work: "run"
            )
        ]
    }

    private func piPayload(
        overrides: [String: Any] = [:],
        removing: [String] = []
    ) -> [String: Any] {
        var object: [String: Any] = [
            "session": "pi-session-1",
            "workGeneration": 7,
            "sequence": 3,
            "reason": "startup",
            "outcome": "completed",
            "aborted": false
        ]
        for (key, value) in overrides { object[key] = value }
        for key in removing { object.removeValue(forKey: key) }
        return object
    }

    private func ompPayload(
        overrides: [String: Any] = [:],
        removing: [String] = []
    ) -> [String: Any] {
        var object: [String: Any] = [
            "session": "omp-session-1",
            "workGeneration": 7,
            "agentKind": "main",
            "sequence": 4,
            "willContinue": false,
            "awaitingAsyncWork": false,
            "success": true
        ]
        for (key, value) in overrides { object[key] = value }
        for key in removing { object.removeValue(forKey: key) }
        return object
    }

    // MARK: - Pi: lifecycle

    func testPiSessionStartCreatesNoWork() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let event = try emitEvent(
            family: "pi",
            target: "pi.cli",
            event: "session_start",
            payload: piPayload(overrides: ["session": "pi-session-1"]),
            adapters: piAdapters
        )

        XCTAssertEqual(event.transition, .snapshot)
        XCTAssertEqual(event.scope, .session)
        XCTAssertEqual(event.snapshotEntries, [])
        XCTAssertFalse(event.snapshotComplete, "an open session cannot claim confirmed idle")
        XCTAssertNil(event.work)
        XCTAssertNil(event.generation)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(event), .applied)
        XCTAssertTrue(model.works.isEmpty, "session start must not create work")
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testPiAgentStartCreatesWorkingRun() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let event = try emitEvent(
            family: "pi",
            target: "pi.cli",
            event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )

        XCTAssertEqual(event.source, "pi")
        XCTAssertEqual(event.target, "pi.cli")
        XCTAssertEqual(event.activationGeneration, 1)
        XCTAssertEqual(event.owner, owner)
        XCTAssertEqual(event.session.family, "pi")
        XCTAssertEqual(event.session.instance, owner.instance)
        XCTAssertEqual(event.session.session, "pi-session-1")
        XCTAssertEqual(event.transition, .started)
        XCTAssertEqual(event.work, "run")
        XCTAssertEqual(event.generation, 7)
        XCTAssertNil(event.sequence)
        XCTAssertNil(event.parentWork)
        XCTAssertFalse(event.snapshotComplete)
        XCTAssertEqual(event.timestamp, epoch)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(event), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testPiTurnStartKeepsTheRunWorking() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let turn = try emitEvent(
            family: "pi", target: "pi.cli", event: "turn_start",
            payload: piPayload(removing: ["reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )

        XCTAssertEqual(turn.transition, .started)
        XCTAssertEqual(turn.work, "run")
        XCTAssertEqual(turn.generation, 7)
        XCTAssertEqual(turn.sequence, 3)
        XCTAssertEqual(turn.session.session, start.session.session)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(turn), .applied)
        XCTAssertEqual(model.works.count, 1)
        XCTAssertEqual(model.decision.state, .working)
    }

    func testPiHumanWaitAllowsSleepAndResumeHoldsAgain() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let wait = try emitEvent(
            family: "pi", target: "pi.cli", event: "ui_prompt_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )
        let resume = try emitEvent(
            family: "pi", target: "pi.cli", event: "ui_prompt_end",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 2
        )

        XCTAssertEqual(wait.transition, .humanWait)
        XCTAssertEqual(resume.transition, .resumed)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(wait), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)

        XCTAssertEqual(model.apply(resume), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testPiTurnOutcomesMapToDocumentedTransitions() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )

        let cases: [(outcome: String, transition: ActivityTransition, state: AggregateState)] = [
            ("completed", .heartbeat, .working),
            ("error", .failed, .idle),
            ("aborted", .cancelled, .idle)
        ]

        for (offset, item) in cases.enumerated() {
            let event = try emitEvent(
                family: "pi", target: "pi.cli", event: "turn_end",
                payload: piPayload(overrides: ["outcome": item.outcome], removing: ["reason", "aborted"]),
                adapters: piAdapters, at: TimeInterval(offset + 1)
            )
            XCTAssertEqual(event.transition, item.transition, "outcome \(item.outcome)")
            XCTAssertEqual(event.sequence, 3)

            var model = activatedModel("pi")
            XCTAssertEqual(model.apply(start), .applied)
            XCTAssertEqual(model.apply(event), .applied)
            XCTAssertEqual(model.decision.state, item.state, "outcome \(item.outcome)")
        }
    }

    func testPiAgentSettledCompletesOrCancelsTheRun() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )

        let completed = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_settled",
            payload: piPayload(overrides: ["aborted": false], removing: ["sequence", "reason", "outcome"]),
            adapters: piAdapters, at: 1
        )
        let cancelled = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_settled",
            payload: piPayload(overrides: ["aborted": true], removing: ["sequence", "reason", "outcome"]),
            adapters: piAdapters, at: 2
        )

        XCTAssertEqual(completed.transition, .completed)
        XCTAssertEqual(cancelled.transition, .cancelled)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(completed), .applied)
        XCTAssertEqual(model.decision.state, .idle)

        var cancelledModel = activatedModel("pi")
        XCTAssertEqual(cancelledModel.apply(start), .applied)
        XCTAssertEqual(cancelledModel.apply(cancelled), .applied)
        XCTAssertEqual(cancelledModel.decision.state, .idle)
    }

    // MARK: - Pi: reload and switch

    func testPiReloadEndsTheOldRunAndStartsANewGeneration() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let run = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let turn = try emitEvent(
            family: "pi", target: "pi.cli", event: "turn_start",
            payload: piPayload(removing: ["reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )
        let shutdown = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "reload", "workGeneration": 7],
                               removing: ["outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 2
        )
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_start",
            payload: piPayload(overrides: ["reason": "reload"], removing: ["outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 3
        )
        let next = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 8], removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 4
        )

        XCTAssertEqual(shutdown.transition, .cancelled)
        XCTAssertEqual(shutdown.work, "run")
        XCTAssertEqual(shutdown.generation, 7)
        XCTAssertFalse(start.snapshotComplete)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(run), .applied)
        XCTAssertEqual(model.apply(turn), .applied)
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.decision.state, .idle, "reload must not leave a stale hold")

        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.decision.state, .idle)

        XCTAssertEqual(model.apply(next), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let oldIdentity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 7,
            work: "run"
        )
        let newIdentity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 8,
            work: "run"
        )
        XCTAssertEqual(model.works[oldIdentity]?.state, .cancelled)
        XCTAssertEqual(model.works[newIdentity]?.state, .working)
    }

    func testPiSessionSwitchRetiresTheOldSessionOnly() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let oldRun = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let shutdown = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "new", "workGeneration": 7],
                               removing: ["outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 1
        )
        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_start",
            payload: piPayload(overrides: ["session": "pi-session-2", "reason": "resume"],
                               removing: ["outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 2
        )

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(oldRun), .applied)
        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.decision.state, .idle)

        let oldIdentity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 7,
            work: "run"
        )
        XCTAssertEqual(model.works[oldIdentity]?.state, .cancelled)
    }

    func testPiShutdownWithoutAnObservedRunRetiresOwnerWork() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        // Simulates an extension instance that did not observe the run, for
        // example one bound after the run started.
        let shutdown = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "quit"],
                               removing: ["workGeneration", "outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 1
        )

        XCTAssertEqual(shutdown.transition, .ownerTerminated)
        XCTAssertNil(shutdown.work)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        let identity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 7,
            work: "run"
        )
        XCTAssertEqual(model.works[identity]?.state, .ended)
    }

    func testPiReloadShutdownWithoutAGenerationDoesNotRetireANewerRun() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        // A detached shutdown helper from the old runtime can land after the
        // replacement runtime's start; that start must stay working.
        let shutdown = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "reload"],
                               removing: ["workGeneration", "outcome", "aborted", "sequence"]),
            adapters: piAdapters
        )
        let next = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 8],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )

        XCTAssertEqual(shutdown.transition, .snapshot)
        XCTAssertFalse(shutdown.snapshotComplete)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.apply(next), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let identity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 8,
            work: "run"
        )
        XCTAssertEqual(model.works[identity]?.state, .working)
    }

    func testPiReloadShutdownCancelsOnlyItsObservedGeneration() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let first = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 7],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let second = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 8],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )
        let shutdown = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "reload", "workGeneration": 7],
                               removing: ["outcome", "aborted", "sequence"]),
            adapters: piAdapters, at: 2
        )

        XCTAssertEqual(shutdown.transition, .cancelled)
        XCTAssertEqual(shutdown.generation, 7)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(first), .applied)
        XCTAssertEqual(model.apply(second), .applied)
        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let oldIdentity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 7,
            work: "run"
        )
        let newIdentity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 8,
            work: "run"
        )
        XCTAssertEqual(model.works[oldIdentity]?.state, .cancelled)
        XCTAssertEqual(model.works[newIdentity]?.state, .working)
    }

    func testPiNonQuitShutdownReasonsAreConservativeSnapshots() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )

        let identity = WorkIdentity(
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            generation: 7,
            work: "run"
        )
        var transitions: Set<ActivityTransition> = []
        var states: Set<WorkState> = []

        for (offset, reason) in ["reload", "new", "resume", "fork"].enumerated() {
            let shutdown = try emitEvent(
                family: "pi", target: "pi.cli", event: "session_shutdown",
                payload: piPayload(overrides: ["reason": reason],
                                   removing: ["workGeneration", "outcome", "aborted", "sequence"]),
                adapters: piAdapters, at: TimeInterval(offset + 1)
            )

            XCTAssertEqual(shutdown.transition, .snapshot, reason)
            XCTAssertEqual(shutdown.scope, .session, reason)
            XCTAssertEqual(shutdown.snapshotEntries, [], reason)
            XCTAssertFalse(shutdown.snapshotComplete, reason)
            XCTAssertNil(shutdown.work, reason)
            transitions.insert(shutdown.transition)

            var model = activatedModel("pi")
            XCTAssertEqual(model.apply(start), .applied)
            XCTAssertEqual(model.apply(shutdown), .applied)
            XCTAssertEqual(model.decision.state, .uncertain, reason)
            XCTAssertTrue(model.decision.holdAssertion, reason)
            states.insert(try XCTUnwrap(model.works[identity]?.state))
        }

        XCTAssertEqual(transitions, [.snapshot], "every non-quit reason is a conservative snapshot")
        XCTAssertEqual(states, [.uncertain], "no reason retires or ends the session's work")
    }

    // MARK: - OMP: lifecycle

    func testOmpSessionStartCreatesNoWork() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let event = try emitEvent(
            family: "omp",
            target: "omp.cli",
            event: "session_start",
            payload: ompPayload(removing: ["workGeneration", "agentKind", "sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )

        XCTAssertEqual(event.transition, .snapshot)
        XCTAssertFalse(event.snapshotComplete)
        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(event), .applied)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testOmpAgentStartAndSessionStopCloseTheRun() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let stop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )

        XCTAssertEqual(start.transition, .started)
        XCTAssertEqual(start.work, "run")
        XCTAssertEqual(start.generation, 7)
        XCTAssertEqual(stop.transition, .completed)
        XCTAssertNil(stop.sequence, "session_stop.turn_id is a different counter from turnIndex")
        XCTAssertNil(stop.parentWork)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertEqual(model.apply(stop), .applied)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testOmpTurnStartAndShutdownRetireTheObservation() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let turn = try emitEvent(
            family: "omp", target: "omp.cli", event: "turn_start",
            payload: ompPayload(overrides: ["sequence": 1],
                                removing: ["willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let shutdown = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_shutdown",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["agentKind", "sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )
        let idleShutdown = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_shutdown",
            payload: ompPayload(removing: ["workGeneration", "agentKind", "sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 3
        )

        XCTAssertEqual(turn.transition, .started)
        XCTAssertEqual(turn.sequence, 1)
        XCTAssertEqual(shutdown.transition, .cancelled)
        XCTAssertEqual(shutdown.generation, 7)
        XCTAssertEqual(idleShutdown.transition, .snapshot)
        XCTAssertNil(idleShutdown.work)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(turn), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertEqual(model.apply(shutdown), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.apply(idleShutdown), .applied)
        XCTAssertEqual(model.decision.state, .idle)

        let identity = WorkIdentity(
            session: SessionIdentity(family: "omp", instance: owner.instance, session: "omp-session-1"),
            generation: 7,
            work: "run"
        )
        XCTAssertEqual(model.works[identity]?.state, .cancelled)
    }

    func testOmpAgentEndWithContinuationIsNotCompletion() throws {
        for flags in [["willContinue": true, "awaitingAsyncWork": false],
                      ["willContinue": false, "awaitingAsyncWork": true]] {
            try HelperFixtures.activate(family: "omp", root: support)
            let start = try emitEvent(
                family: "omp", target: "omp.cli", event: "agent_start",
                payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
                adapters: ompAdapters
            )
            let end = try emitEvent(
                family: "omp", target: "omp.cli", event: "agent_end",
                payload: ompPayload(overrides: flags,
                                    removing: ["sequence", "success"]),
                adapters: ompAdapters, at: 1
            )

            XCTAssertEqual(end.transition, .heartbeat, "flags \(flags)")

            var model = activatedModel("omp")
            XCTAssertEqual(model.apply(start), .applied)
            XCTAssertEqual(model.apply(end), .applied)
            XCTAssertEqual(model.decision.state, .working, "flags \(flags) must not produce idle")
        }
    }

    // MARK: - OMP: retry and continuation

    func testOmpAutoRetrySequenceNeverReportsIdleBeforeTheStop() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let endWithContinuation = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_end",
            payload: ompPayload(overrides: ["willContinue": true], removing: ["sequence", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let retryStart = try emitEvent(
            family: "omp", target: "omp.cli", event: "auto_retry_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )
        let retryEnd = try emitEvent(
            family: "omp", target: "omp.cli", event: "auto_retry_end",
            payload: ompPayload(overrides: ["success": true], removing: ["sequence", "willContinue", "awaitingAsyncWork"]),
            adapters: ompAdapters, at: 3
        )
        let end = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_end",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 4
        )
        let stop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 5
        )

        XCTAssertEqual(retryStart.transition, .heartbeat)
        XCTAssertEqual(retryEnd.transition, .heartbeat)
        XCTAssertEqual(end.transition, .heartbeat)
        XCTAssertEqual(stop.transition, .completed)

        var model = activatedModel("omp")
        for event in [start, endWithContinuation, retryStart, retryEnd, end] {
            XCTAssertEqual(model.apply(event), .applied)
            XCTAssertEqual(model.decision.state, .working, "\(event.transition) must keep the run working")
        }
        XCTAssertEqual(model.apply(stop), .applied)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testOmpContinuationStartsNewWorkAfterStop() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let firstStart = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let firstStop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let continuation = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["workGeneration": 8],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )
        let secondStop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(overrides: ["workGeneration": 8],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 3
        )

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(firstStart), .applied)
        XCTAssertEqual(model.apply(firstStop), .applied)
        XCTAssertEqual(model.decision.state, .idle)

        XCTAssertEqual(model.apply(continuation), .applied)
        XCTAssertEqual(model.decision.state, .working, "a queued continuation reopens work")
        XCTAssertEqual(model.apply(secondStop), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.works.values.filter { $0.state == .working }.count, 0)
    }

    func testOmpExhaustedRetryFailsTheRun() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let failed = try emitEvent(
            family: "omp", target: "omp.cli", event: "auto_retry_end",
            payload: ompPayload(overrides: ["success": false], removing: ["sequence", "willContinue", "awaitingAsyncWork"]),
            adapters: ompAdapters, at: 1
        )

        XCTAssertEqual(failed.transition, .failed)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(failed), .applied)
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - OMP: approval wait

    func testOmpApprovalWaitAndResume() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let requested = try emitEvent(
            family: "omp", target: "omp.cli", event: "tool_approval_requested",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let resolved = try emitEvent(
            family: "omp", target: "omp.cli", event: "tool_approval_resolved",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )

        XCTAssertEqual(requested.transition, .humanWait)
        XCTAssertEqual(resolved.transition, .resumed)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(requested), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)

        XCTAssertEqual(model.apply(resolved), .applied)
        XCTAssertEqual(model.decision.state, .working)
    }

    // MARK: - OMP: subagents

    func testOmpSubagentWorkIsSeparateWithParentIdentity() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let parentRun = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["session": "omp-parent", "workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let childRun = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: [
                "session": "omp-child",
                "workGeneration": 3,
                "agentKind": "sub",
                "parentWork": "Main_agent"
            ], removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let childEnd = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_end",
            payload: ompPayload(overrides: ["session": "omp-child", "workGeneration": 3, "agentKind": "sub"],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )
        let parentStop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(overrides: ["session": "omp-parent", "workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 3
        )

        XCTAssertEqual(childRun.transition, .childStarted)
        XCTAssertEqual(childRun.parentWork, "Main_agent", "the documented parent id is used as-is")
        XCTAssertNotEqual(childRun.session.session, parentRun.session.session)
        XCTAssertEqual(childEnd.transition, .childFinished)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(parentRun), .applied)
        XCTAssertEqual(model.apply(childRun), .applied)
        XCTAssertEqual(model.works.count, 2, "a child is its own work identity")
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.apply(childEnd), .applied)
        XCTAssertEqual(model.decision.state, .working, "the parent is still working")

        XCTAssertEqual(model.apply(parentStop), .applied)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testOmpSubagentWithoutParentIsRejected() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let result = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["agentKind": "sub"],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("\"parentWork\""), result.lines[0])
        XCTAssertNil(result.event)
    }

    // MARK: - Rejection and privacy, per family

    func testPiMissingDocumentedFieldNamesOnlyTheField() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let result = try emit(
            family: "pi", target: "pi.cli", event: "turn_end",
            payload: piPayload(overrides: ["prompt": HelperFixtures.seededSecrets[0]],
                               removing: ["outcome"]),
            adapters: piAdapters
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("\"outcome\""), result.lines[0])
        for secret in HelperFixtures.seededSecrets {
            XCTAssertFalse(result.lines[0].contains(secret))
        }
        XCTAssertNil(result.event)
    }

    func testOmpMissingDocumentedFieldNamesOnlyTheField() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let result = try emit(
            family: "omp", target: "omp.cli", event: "auto_retry_end",
            payload: ompPayload(overrides: ["prompt": HelperFixtures.seededSecrets[0]],
                                removing: ["success"]),
            adapters: ompAdapters
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("\"success\""), result.lines[0])
        XCTAssertNil(result.event)
    }

    func testUnknownDocumentedEventIsRefusedPerFamily() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        let pi = try emit(
            family: "pi", target: "pi.cli", event: "message_end",
            payload: piPayload(), adapters: piAdapters
        )
        XCTAssertEqual(pi.code, 2)
        XCTAssertTrue(pi.lines[0].contains("message_end"), pi.lines[0])

        try HelperFixtures.activate(family: "omp", root: support)
        let omp = try emit(
            family: "omp", target: "omp.cli", event: "message_end",
            payload: ompPayload(), adapters: ompAdapters
        )
        XCTAssertEqual(omp.code, 2)
        XCTAssertTrue(omp.lines[0].contains("message_end"), omp.lines[0])
    }

    func testFamilyPayloadsNeverPersistSeededContent() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        try HelperFixtures.activate(family: "omp", root: support)

        let extras: [String: Any] = [
            "prompt": HelperFixtures.seededSecrets[0],
            "response": HelperFixtures.seededSecrets[1],
            "toolArguments": HelperFixtures.seededSecrets[2],
            "credential": HelperFixtures.seededSecrets[3]
        ]

        let piEvent = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: extras, removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let ompEvent = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: extras, removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )

        XCTAssertEqual(piEvent.transition, .started)
        XCTAssertEqual(ompEvent.transition, .started)
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 2)

        for file in HelperFixtures.eventFiles(in: support) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for secret in HelperFixtures.seededSecrets {
                XCTAssertFalse(text.contains(secret), "\(file.lastPathComponent) leaked a seeded string")
            }
            for field in ["prompt", "response", "toolArguments", "credential"] {
                XCTAssertFalse(text.contains("\"\(field)\""), "unknown key \(field) was persisted")
            }
        }
    }

    func testVendorIdentifiersMustAlreadyBeCanonical() throws {
        // `ses.a` and `ses_a` would collapse into one session if the adapter
        // canonicalized the value, so the non-canonical form is refused and the
        // canonical form is accepted unchanged.
        XCTAssertEqual(HookIdentifier.canonical("ses.a"), "ses_a")
        XCTAssertNotEqual(HookIdentifier.canonical("ses.a"), "ses.a")

        let longA = String(repeating: "a", count: HookIdentifier.maxLength) + "b"
        let longB = String(repeating: "a", count: HookIdentifier.maxLength) + "c"
        XCTAssertEqual(HookIdentifier.canonical(longA), HookIdentifier.canonical(longB))

        for family in ["pi", "omp"] {
            try HelperFixtures.activate(family: family, root: support)
            let adapters: [HookAdapter] = family == "pi" ? piAdapters : ompAdapters

            for session in ["ses.a", longA, longB] {
                let payload = family == "pi"
                    ? piPayload(overrides: ["session": session],
                                removing: ["sequence", "reason", "outcome", "aborted"])
                    : ompPayload(overrides: ["session": session],
                                 removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"])
                let refused = try emit(
                    family: family, target: "\(family).cli", event: "agent_start",
                    payload: payload, adapters: adapters
                )
                XCTAssertEqual(refused.code, 2, "\(family) session must be refused")
                XCTAssertEqual(refused.lines.count, 1)
                XCTAssertTrue(refused.lines[0].contains("\"session\""), refused.lines[0])
                XCTAssertFalse(refused.lines[0].contains(session), "only the field name is reported")
                XCTAssertNil(refused.event)
            }

            let canonical = try emitEvent(
                family: family, target: "\(family).cli", event: "agent_start",
                payload: family == "pi"
                    ? piPayload(overrides: ["session": "ses_a"],
                                removing: ["sequence", "reason", "outcome", "aborted"])
                    : ompPayload(overrides: ["session": "ses_a"],
                                 removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
                adapters: adapters
            )
            XCTAssertEqual(canonical.session.session, "ses_a", "the canonical id is kept verbatim")
        }

        // A non-canonical OMP parent id cannot attach child work either.
        try HelperFixtures.activate(family: "omp", root: support)
        let parent = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(
                overrides: ["agentKind": "sub", "parentWork": "Main agent"],
                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]
            ),
            adapters: ompAdapters
        )
        XCTAssertEqual(parent.code, 2)
        XCTAssertTrue(parent.lines[0].contains("\"parentWork\""), parent.lines[0])
        XCTAssertNil(parent.event)
    }

    func testEmptySessionIdentifierIsRejected() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let result = try emit(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["session": ""],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.lines[0].contains("\"session\""), result.lines[0])
        XCTAssertNil(result.event)
    }

    // MARK: - Activation generation

    func testBothFamiliesRejectInactiveAndStaleAndJournalBlockedEmissions() throws {
        for family in ["pi", "omp"] {
            let adapters: [HookAdapter] = family == "pi" ? piAdapters : ompAdapters
            let payload = family == "pi"
                ? piPayload(removing: ["sequence", "reason", "outcome", "aborted"])
                : ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"])

            // No receipt at all.
            let inactive = try emit(
                family: family, target: "\(family).cli", event: "agent_start",
                payload: payload, adapters: adapters,
                root: sandbox.appendingPathComponent("inactive-\(family)", isDirectory: true)
            )
            XCTAssertEqual(inactive.code, 3, family)
            XCTAssertNil(inactive.event)

            // Stale generation after a reinstall.
            let staleRoot = sandbox.appendingPathComponent("stale-\(family)", isDirectory: true)
            try HelperFixtures.activate(family: family, generation: 2, root: staleRoot)
            let stale = try emit(
                family: family, target: "\(family).cli", event: "agent_start",
                payload: payload, adapters: adapters, generation: 1, root: staleRoot
            )
            XCTAssertEqual(stale.code, 3, family)
            XCTAssertNil(stale.event)
            XCTAssertTrue(HelperFixtures.eventFiles(in: staleRoot).isEmpty)

            // An unresolved journal never activates.
            let journalRoot = sandbox.appendingPathComponent("journal-\(family)", isDirectory: true)
            try HelperFixtures.activate(family: family, generation: 1, root: journalRoot)
            try HelperFixtures.writeJournal(family: family, stage: .applying, root: journalRoot)
            let blocked = try emit(
                family: family, target: "\(family).cli", event: "agent_start",
                payload: payload, adapters: adapters, root: journalRoot
            )
            XCTAssertEqual(blocked.code, 3, family)
            XCTAssertNil(blocked.event)
            XCTAssertTrue(HelperFixtures.eventFiles(in: journalRoot).isEmpty)
        }
    }

    func testReinstalledGenerationRejectsOldEventsInTheModel() throws {
        let event = ActivityEvent(
            id: "h-old",
            source: "pi",
            activationGeneration: 1,
            target: "pi.cli",
            owner: owner,
            session: SessionIdentity(family: "pi", instance: owner.instance, session: "pi-session-1"),
            transition: .started,
            work: "run",
            generation: 7,
            timestamp: epoch
        )

        var model = ActivityModel()
        model.activate(family: "pi", generation: 2)
        XCTAssertEqual(model.apply(event), .ignored(.staleActivation))
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - Superseded run generations

    func testPiSupersededRunIsClosedBeforeTheRetryStarts() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let first = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 7],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        // The documented retry shape: `agent_end` is not terminal and this
        // adapter does not subscribe to it, so the run stays working.
        let turn = try emitEvent(
            family: "pi", target: "pi.cli", event: "turn_end",
            payload: piPayload(overrides: ["workGeneration": 7, "outcome": "completed"],
                               removing: ["reason", "aborted"]),
            adapters: piAdapters, at: 1
        )
        let superseded = try emitEvent(
            family: "pi", target: "pi.cli", event: "run_superseded",
            payload: piPayload(overrides: ["workGeneration": 7],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 2
        )
        let retry = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(overrides: ["workGeneration": 8],
                               removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 3
        )
        let settled = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_settled",
            payload: piPayload(overrides: ["workGeneration": 8, "aborted": false],
                               removing: ["sequence", "reason", "outcome"]),
            adapters: piAdapters, at: 4
        )

        XCTAssertEqual(superseded.transition, .cancelled)
        XCTAssertEqual(superseded.work, "run")
        XCTAssertEqual(superseded.generation, 7)
        XCTAssertNil(superseded.sequence, "a supersede event carries no sequence")

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(first), .applied)
        XCTAssertEqual(model.apply(turn), .applied)
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.apply(superseded), .applied)
        XCTAssertEqual(model.decision.state, .idle, "the replaced run no longer holds the assertion")

        XCTAssertEqual(model.apply(retry), .applied)
        XCTAssertEqual(
            model.works.values.filter { $0.state.isActive }.count,
            1,
            "only the new generation is active"
        )
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.apply(settled), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 0)
        XCTAssertEqual(
            runRecord(model, family: "pi", session: "pi-session-1", generation: 7)?.state,
            .cancelled
        )
        XCTAssertEqual(
            runRecord(model, family: "pi", session: "pi-session-1", generation: 8)?.state,
            .completed
        )
    }

    func testOmpSupersededRunIsClosedBeforeTheContinuationStarts() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let first = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        // Documented retry shape: a continuation is scheduled, so `agent_end`
        // is a heartbeat and the run keeps working until `session_stop`.
        let retryStart = try emitEvent(
            family: "omp", target: "omp.cli", event: "auto_retry_start",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let retryEnd = try emitEvent(
            family: "omp", target: "omp.cli", event: "auto_retry_end",
            payload: ompPayload(overrides: ["workGeneration": 7, "success": true],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork"]),
            adapters: ompAdapters, at: 2
        )
        let superseded = try emitEvent(
            family: "omp", target: "omp.cli", event: "run_superseded",
            payload: ompPayload(overrides: ["workGeneration": 7],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 3
        )
        let continuation = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["workGeneration": 8],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 4
        )
        let stop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(overrides: ["workGeneration": 8],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 5
        )

        XCTAssertEqual(retryStart.transition, .heartbeat)
        XCTAssertEqual(retryEnd.transition, .heartbeat)
        XCTAssertEqual(superseded.transition, .cancelled)
        XCTAssertEqual(superseded.generation, 7)
        XCTAssertNil(superseded.sequence)

        var model = activatedModel("omp")
        for event in [first, retryStart, retryEnd] {
            XCTAssertEqual(model.apply(event), .applied)
            XCTAssertEqual(model.decision.state, .working)
        }
        XCTAssertEqual(model.apply(superseded), .applied)
        XCTAssertEqual(model.decision.state, .idle, "the replaced run no longer holds the assertion")

        XCTAssertEqual(model.apply(continuation), .applied)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 1)
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.apply(stop), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 0)
        XCTAssertEqual(
            runRecord(model, family: "omp", session: "omp-session-1", generation: 7)?.state,
            .cancelled
        )
        XCTAssertEqual(
            runRecord(model, family: "omp", session: "omp-session-1", generation: 8)?.state,
            .completed
        )
    }

    func testSupersededGenerationWithNoObservedWorkRecordsUnknownWork() throws {
        try HelperFixtures.activate(family: "pi", root: support)
        try HelperFixtures.activate(family: "omp", root: support)

        for family in ["pi", "omp"] {
            let adapters: [HookAdapter] = family == "pi" ? piAdapters : ompAdapters
            let payload = family == "pi"
                ? piPayload(overrides: ["workGeneration": 99],
                            removing: ["sequence", "reason", "outcome", "aborted"])
                : ompPayload(overrides: ["workGeneration": 99],
                             removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"])

            let event = try emitEvent(
                family: family, target: "\(family).cli", event: "run_superseded",
                payload: payload, adapters: adapters
            )
            XCTAssertEqual(event.transition, .cancelled, family)

            var model = activatedModel(family)
            XCTAssertEqual(model.apply(event), .ignored(.unknownWork), family)
            XCTAssertTrue(model.works.isEmpty, "a supersede for an unobserved generation records no fact")
            XCTAssertEqual(model.decision.state, .idle, family)
        }
    }

    // MARK: - Owner termination freshness

    func testLateOwnerTerminationDoesNotEndANewerRun() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let run = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 200
        )
        // `session_shutdown` without a generation and reason `quit` is the
        // documented ownerTerminated path; a detached helper can deliver it
        // after the run it does not describe has already started again.
        let terminated = try emitEvent(
            family: "pi", target: "pi.cli", event: "session_shutdown",
            payload: piPayload(overrides: ["reason": "quit"],
                               removing: ["workGeneration", "sequence", "outcome", "aborted"]),
            adapters: piAdapters, at: 150
        )

        XCTAssertEqual(terminated.transition, .ownerTerminated)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(run), .applied)
        XCTAssertEqual(model.apply(terminated), .applied)
        XCTAssertEqual(
            runRecord(model, family: "pi", session: "pi-session-1", generation: 7)?.state,
            .working,
            "a termination older than the work cannot end it"
        )
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    // MARK: - Turn sequence is optional

    func testPiTurnEventsMapWithoutATurnIndex() throws {
        try HelperFixtures.activate(family: "pi", root: support)

        let start = try emitEvent(
            family: "pi", target: "pi.cli", event: "agent_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters
        )
        let turn = try emitEvent(
            family: "pi", target: "pi.cli", event: "turn_start",
            payload: piPayload(removing: ["sequence", "reason", "outcome", "aborted"]),
            adapters: piAdapters, at: 1
        )
        let end = try emitEvent(
            family: "pi", target: "pi.cli", event: "turn_end",
            payload: piPayload(overrides: ["outcome": "completed"],
                               removing: ["sequence", "reason", "aborted"]),
            adapters: piAdapters, at: 2
        )

        XCTAssertEqual(turn.transition, .started)
        XCTAssertNil(turn.sequence)
        XCTAssertEqual(end.transition, .heartbeat)
        XCTAssertNil(end.sequence)

        var model = activatedModel("pi")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(turn), .applied)
        XCTAssertEqual(model.apply(end), .applied)
        XCTAssertEqual(model.decision.state, .working)
    }

    // MARK: - Bundled assets

    private var piAsset: String {
        get throws {
            try String(
                contentsOf: IntegrationFixtures.integrationsRoot
                    .appendingPathComponent("pi/assets/awake-lite.pi.js"),
                encoding: .utf8
            )
        }
    }

    private var ompAsset: String {
        get throws {
            try String(
                contentsOf: IntegrationFixtures.integrationsRoot
                    .appendingPathComponent("omp/assets/awake-lite.omp.js"),
                encoding: .utf8
            )
        }
    }

    func testPiAssetIsInertHelperOnlySource() throws {
        let text = try piAsset

        XCTAssertTrue(text.contains("export default function"))
        XCTAssertTrue(text.contains("pi.on(\"session_start\""))
        XCTAssertTrue(text.contains("pi.on(\"agent_settled\""))
        XCTAssertTrue(text.contains("detached: true"))
        XCTAssertTrue(text.contains("unref()"))
        XCTAssertTrue(text.contains("stdio: [\"pipe\", \"ignore\", \"ignore\"]"))
        XCTAssertTrue(text.contains("--generation"))
        XCTAssertTrue(text.contains("stdin.end("))
        // One owner per process and an explicit supersede before a new run.
        XCTAssertTrue(text.contains("--owner-instance"))
        XCTAssertTrue(text.contains("--owner-pid"))
        XCTAssertTrue(text.contains("randomUUID()"), "the owner token is minted once per process")
        XCTAssertTrue(text.contains("run_superseded\""))
        XCTAssertFalse(text.contains("setInterval"))
        XCTAssertFalse(text.contains("setTimeout"))
        XCTAssertFalse(text.contains("await "))
        XCTAssertFalse(text.contains("exitCode"), "the asset must ignore exit codes")
        XCTAssertFalse(text.contains("\"exit\""), "the asset must not observe helper exit")

        for forbidden in ["http", "fetch", "transcript", "node:net", "XMLHttpRequest"] {
            XCTAssertFalse(text.contains(forbidden), "asset must not use \(forbidden)")
        }
        for secret in HelperFixtures.seededSecrets {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testOmpAssetIsInertHelperOnlySource() throws {
        let text = try ompAsset

        XCTAssertTrue(text.contains("export default function"))
        XCTAssertTrue(text.contains("pi.on(\"session_stop\""))
        XCTAssertTrue(text.contains("pi.on(\"agent_end\""))
        XCTAssertTrue(text.contains("pi.on(\"auto_retry_start\""))
        XCTAssertTrue(text.contains("pi.on(\"tool_approval_requested\""))
        XCTAssertTrue(text.contains("detached: true"))
        XCTAssertTrue(text.contains("unref()"))
        XCTAssertTrue(text.contains("stdio: [\"pipe\", \"ignore\", \"ignore\"]"))
        XCTAssertTrue(text.contains("--generation"))
        XCTAssertTrue(text.contains("stdin.end("))
        // One owner per process and an explicit supersede before a new run.
        XCTAssertTrue(text.contains("--owner-instance"))
        XCTAssertTrue(text.contains("--owner-pid"))
        XCTAssertTrue(text.contains("randomUUID()"), "the owner token is minted once per process")
        XCTAssertTrue(text.contains("run_superseded\""))
        XCTAssertFalse(text.contains("setInterval"))
        XCTAssertFalse(text.contains("setTimeout"))
        XCTAssertFalse(text.contains("await "))
        XCTAssertFalse(text.contains("exitCode"), "the asset must ignore exit codes")
        XCTAssertFalse(text.contains("\"exit\""), "the asset must not observe helper exit")

        for forbidden in ["http", "fetch", "transcript", "node:net", "XMLHttpRequest"] {
            XCTAssertFalse(text.contains(forbidden), "asset must not use \(forbidden)")
        }
        for secret in HelperFixtures.seededSecrets {
            XCTAssertFalse(text.contains(secret))
        }
    }

    func testBundledManifestsAndAssetsStillDecodeAndRender() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()

        for family in ["pi", "omp"] {
            let manifest = try catalog.manifest(for: family)
            XCTAssertEqual(manifest.family, family)
            // Adapter fixtures exist for both targets; live evidence does not.
            XCTAssertEqual(manifest.targets.map(\.verificationLevel), [.fixture])

            let step = try XCTUnwrap(manifest.steps.first)
            XCTAssertEqual(step.kind, .extensionFile)
            XCTAssertEqual(step.path, "awake-lite/index.js", "documented discovery needs index.js")
            XCTAssertEqual(step.configRoot, .home(family == "pi" ? ".pi/agent/extensions" : ".omp/agent/extensions"))

            let asset = try XCTUnwrap(manifest.asset(withID: "extension"))
            XCTAssertEqual(asset.destination, "extensions/awake-lite/index.js")

            let raw = try String(
                contentsOf: IntegrationFixtures.integrationsRoot.appendingPathComponent("\(family)/\(asset.source)"),
                encoding: .utf8
            )
            XCTAssertNil(Template.firstUnknownPlaceholder(in: raw), "\(family) asset has a stray placeholder")

            let rendered = Template.renderText(
                raw,
                values: Template.values(
                    marker: step.ownedEntries[0].marker,
                    family: family,
                    target: step.target,
                    generation: 3,
                    helperPath: IntegrationPaths.helperPath
                )
            )
            XCTAssertFalse(Template.containsPlaceholder(rendered), "\(family) asset left a placeholder")
            XCTAssertTrue(rendered.contains(IntegrationPaths.helperPath))
            XCTAssertTrue(rendered.contains("Number(\"3\")"))
            XCTAssertTrue(rendered.contains("--family"))
        }
    }
}
