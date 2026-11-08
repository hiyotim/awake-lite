import Foundation
import XCTest
@testable import AwakeLiteCore

/// Unit 3.2: the OMP in-process extension adapter and its bundled asset.
///
/// Every check injects the adapter through `HelperRunner`, exactly as the
/// registry owner does.
final class OMPAdapterTests: XCTestCase {
    private var sandbox: URL!
    private var support: URL!

    private let epoch = HelperFixtures.epoch

    private lazy var owner: OwnerIdentity = OwnerIdentityProbe.identity(pid: getpid())

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

    func testOmpAgentEndWithoutContinuationCompletesTheRun() throws {
        let cases: [[String: Bool]?] = [nil, ["willContinue": false, "awaitingAsyncWork": false]]
        for flags in cases {
            try HelperFixtures.activate(family: "omp", root: support)
            let start = try emitEvent(
                family: "omp", target: "omp.cli", event: "agent_start",
                payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
                adapters: ompAdapters
            )
            let end = try emitEvent(
                family: "omp", target: "omp.cli", event: "agent_end",
                payload: ompPayload(
                    overrides: flags ?? [:],
                    removing: flags == nil
                        ? ["sequence", "willContinue", "awaitingAsyncWork", "success"]
                        : ["sequence", "success"]
                ),
                adapters: ompAdapters, at: 1
            )

            XCTAssertEqual(end.transition, .completed, "flags \(String(describing: flags))")

            var model = activatedModel("omp")
            XCTAssertEqual(model.apply(start), .applied)
            XCTAssertEqual(model.apply(end), .applied)
            XCTAssertEqual(model.decision.state, .idle)
            XCTAssertFalse(model.decision.holdAssertion)
        }
    }

    func testOmpSessionStopAfterAgentEndIsIdempotent() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let start = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        let end = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_end",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 1
        )
        let stop = try emitEvent(
            family: "omp", target: "omp.cli", event: "session_stop",
            payload: ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters, at: 2
        )

        XCTAssertEqual(end.transition, .completed)
        XCTAssertEqual(stop.transition, .completed)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(start), .applied)
        XCTAssertEqual(model.apply(end), .applied)
        XCTAssertEqual(model.apply(stop), .ignored(.terminalWork))
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    // MARK: - OMP: retry and continuation

    func testOmpAutoRetrySequenceKeepsWorkingUntilAgentEnd() throws {
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
        XCTAssertEqual(end.transition, .completed)
        XCTAssertEqual(stop.transition, .completed)

        var model = activatedModel("omp")
        for event in [start, endWithContinuation, retryStart, retryEnd] {
            XCTAssertEqual(model.apply(event), .applied)
            XCTAssertEqual(model.decision.state, .working, "\(event.transition) must keep the run working")
        }
        XCTAssertEqual(model.apply(end), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.apply(stop), .ignored(.terminalWork))
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

    // MARK: - Rejection and privacy

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

    func testUnknownDocumentedEventIsRefused() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let omp = try emit(
            family: "omp", target: "omp.cli", event: "message_end",
            payload: ompPayload(), adapters: ompAdapters
        )
        XCTAssertEqual(omp.code, 2)
        XCTAssertTrue(omp.lines[0].contains("message_end"), omp.lines[0])
    }

    func testPayloadsNeverPersistSeededContent() throws {
        try HelperFixtures.activate(family: "omp", root: support)

        let extras: [String: Any] = [
            "prompt": HelperFixtures.seededSecrets[0],
            "response": HelperFixtures.seededSecrets[1],
            "toolArguments": HelperFixtures.seededSecrets[2],
            "credential": HelperFixtures.seededSecrets[3]
        ]

        let ompEvent = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: extras, removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )

        XCTAssertEqual(ompEvent.transition, .started)
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 1)

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

        for session in ["ses.a", longA, longB] {
            try HelperFixtures.activate(family: "omp", root: support)
            let refused = try emit(
                family: "omp", target: "omp.cli", event: "agent_start",
                payload: ompPayload(overrides: ["session": session],
                                    removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
                adapters: ompAdapters
            )
            XCTAssertEqual(refused.code, 2, "omp session must be refused")
            XCTAssertEqual(refused.lines.count, 1)
            XCTAssertTrue(refused.lines[0].contains("\"session\""), refused.lines[0])
            XCTAssertFalse(refused.lines[0].contains(session), "only the field name is reported")
            XCTAssertNil(refused.event)
        }

        let canonical = try emitEvent(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["session": "ses_a"],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        XCTAssertEqual(canonical.session.session, "ses_a", "the canonical id is kept verbatim")

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
        try HelperFixtures.activate(family: "omp", root: support)

        let result = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: ompPayload(overrides: ["session": ""],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.lines[0].contains("\"session\""), result.lines[0])
        XCTAssertNil(result.event)
    }

    // MARK: - Activation generation

    func testInactiveAndStaleAndJournalBlockedEmissionsAreRejected() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let payload = ompPayload(removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"])

        // No receipt at all.
        let inactive = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: payload, adapters: ompAdapters,
            root: sandbox.appendingPathComponent("inactive", isDirectory: true)
        )
        XCTAssertEqual(inactive.code, 3)
        XCTAssertNil(inactive.event)

        // Stale generation after a reinstall.
        let staleRoot = sandbox.appendingPathComponent("stale", isDirectory: true)
        try HelperFixtures.activate(family: "omp", generation: 2, root: staleRoot)
        let stale = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: payload, adapters: ompAdapters, generation: 1, root: staleRoot
        )
        XCTAssertEqual(stale.code, 3)
        XCTAssertNil(stale.event)
        XCTAssertTrue(HelperFixtures.eventFiles(in: staleRoot).isEmpty)

        // An unresolved journal never activates.
        let journalRoot = sandbox.appendingPathComponent("journal", isDirectory: true)
        try HelperFixtures.activate(family: "omp", generation: 1, root: journalRoot)
        try HelperFixtures.writeJournal(family: "omp", stage: .applying, root: journalRoot)
        let blocked = try emit(
            family: "omp", target: "omp.cli", event: "agent_start",
            payload: payload, adapters: ompAdapters, root: journalRoot
        )
        XCTAssertEqual(blocked.code, 3)
        XCTAssertNil(blocked.event)
        XCTAssertTrue(HelperFixtures.eventFiles(in: journalRoot).isEmpty)
    }

    func testReinstalledGenerationRejectsOldEventsInTheModel() throws {
        let event = ActivityEvent(
            id: "h-old",
            source: "omp",
            activationGeneration: 1,
            target: "omp.cli",
            owner: owner,
            session: SessionIdentity(family: "omp", instance: owner.instance, session: "omp-session-1"),
            transition: .started,
            work: "run",
            generation: 7,
            timestamp: epoch
        )

        var model = ActivityModel()
        model.activate(family: "omp", generation: 2)
        XCTAssertEqual(model.apply(event), .ignored(.staleActivation))
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - Superseded run generations

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
        try HelperFixtures.activate(family: "omp", root: support)

        let event = try emitEvent(
            family: "omp", target: "omp.cli", event: "run_superseded",
            payload: ompPayload(overrides: ["workGeneration": 99],
                                removing: ["sequence", "willContinue", "awaitingAsyncWork", "success"]),
            adapters: ompAdapters
        )
        XCTAssertEqual(event.transition, .cancelled)

        var model = activatedModel("omp")
        XCTAssertEqual(model.apply(event), .ignored(.unknownWork))
        XCTAssertTrue(model.works.isEmpty, "a supersede for an unobserved generation records no fact")
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - Bundled assets

    private var ompAsset: String {
        get throws {
            try String(
                contentsOf: IntegrationFixtures.shippedIntegrationsRoot
                    .appendingPathComponent("omp/assets/awake-lite.omp.js"),
                encoding: .utf8
            )
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

    func testShippedManifestAndAssetDecodeAndRender() throws {
        let catalog = try IntegrationFixtures.shippedCatalog()

        for family in IntegrationFixtures.shippedFamilies {
            let manifest = try catalog.manifest(for: family)
            XCTAssertEqual(manifest.family, family)
            // Adapter fixtures exist; live evidence does not.
            XCTAssertEqual(manifest.targets.map(\.verificationLevel), [.fixture])

            let step = try XCTUnwrap(manifest.steps.first)
            XCTAssertEqual(step.kind, .extensionFile)
            XCTAssertEqual(step.path, "awake-lite/index.js", "documented discovery needs index.js")
            XCTAssertEqual(step.configRoot, .home(".omp/agent/extensions"))

            let asset = try XCTUnwrap(manifest.asset(withID: "extension"))
            XCTAssertEqual(asset.destination, "extensions/awake-lite/index.js")

            let raw = try String(
                contentsOf: IntegrationFixtures.shippedIntegrationsRoot.appendingPathComponent("\(family)/\(asset.source)"),
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
