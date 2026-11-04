import XCTest
@testable import AwakeLiteCore

/// Unit 3.3: the read-only OpenCode connector, driven only by fixtures.
///
/// Every check runs without a live service: `FixtureTransport` returns the
/// documented payload shapes, and no URLSession request is made.
final class OpenCodeAdapterTests: XCTestCase {
    private let alpha = "ses_alpha"
    private let beta = "ses_beta"
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try IntegrationFixtures.makeSandbox()
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        try super.tearDownWithError()
    }

    // MARK: - Complete snapshot

    func testCompleteSnapshotWithRunningExecutionHoldsSleep() async throws {
        let transport = makeTransport(active: [alpha: runningRow()])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        XCTAssertTrue(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.transition, .snapshot)
        XCTAssertEqual(snapshot.scope, .instance)
        XCTAssertEqual(snapshot.source, "opencode")
        XCTAssertEqual(snapshot.target, "opencode.tui")
        XCTAssertEqual(snapshot.activationGeneration, 1)
        XCTAssertEqual(snapshot.snapshotEntries?.count, 1)

        let entry = try XCTUnwrap(snapshot.snapshotEntries?.first)
        XCTAssertEqual(entry.session, SessionIdentity(family: "opencode", instance: "service", session: alpha))
        XCTAssertEqual(entry.work, "execution")
        XCTAssertEqual(entry.generation, 0)
        XCTAssertEqual(entry.state, .working)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testEmptyActiveListingConfirmsAbsenceOfWork() async throws {
        let transport = makeTransport(active: [:])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        XCTAssertTrue(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries, [])

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    // MARK: - Open but idle

    func testOpenButIdleSessionIsNoDataNotWork() async throws {
        let transport = makeTransport(active: [alpha: ["type": "idle"]])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, let inactivity) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        XCTAssertTrue(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries, [], "a non-running row is not work")
        XCTAssertEqual(inactivity.count, 1)
        XCTAssertEqual(inactivity.first?.scope, .session)
        XCTAssertEqual(inactivity.first?.session.session, alpha)
        XCTAssertEqual(inactivity.first?.snapshotComplete, true)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.apply(inactivity[0]), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertFalse(
            transport.requested.contains(OpenCodeService.sessionPath(alpha)),
            "a non-running row needs no execution detail"
        )
    }

    func testRowWithoutRunningTypeIsNotWork() async throws {
        // The row carries no documented `type` at all: unreadable, so the
        // observation is uncertain rather than idle, and it creates no work.
        let transport = makeTransport(active: [alpha: [String: Any]()])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .incomplete(let snapshot, _, let losses, let problems) = observation else {
            return XCTFail("expected an incomplete observation, got \(observation)")
        }
        XCTAssertFalse(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries, [])
        XCTAssertEqual(problems, [.unreadableActiveRow])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.scope, .session)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        for loss in losses { XCTAssertEqual(model.apply(loss), .applied) }
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertTrue(model.works.isEmpty)
    }

    // MARK: - Human waits

    func testPendingPermissionMapsToHumanWait() async throws {
        let permission: [String: Any] = [
            "id": "per_1",
            "sessionID": alpha,
            "action": "bash",
            "resources": ["npm test"],
            "message": "allow this command?"
        ]
        let transport = makeTransport(active: [alpha: runningRow()], permissions: [alpha: [permission]])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        XCTAssertEqual(snapshot.snapshotEntries?.count, 1)
        XCTAssertEqual(snapshot.snapshotEntries?.first?.state, .waitingForUser)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testPendingFormMapsToHumanWait() async throws {
        let form: [String: Any] = [
            "id": "frm_1",
            "sessionID": alpha,
            "title": "which branch?",
            "fields": [["name": "branch", "type": "string"]]
        ]
        let transport = makeTransport(active: [alpha: runningRow()], forms: [alpha: [form]])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        XCTAssertEqual(snapshot.snapshotEntries?.first?.state, .waitingForUser)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testWaitingSessionDoesNotCancelAnotherWorkingSession() async throws {
        let permission: [String: Any] = [
            "id": "per_1",
            "sessionID": beta,
            "action": "bash",
            "resources": ["make"]
        ]
        let transport = makeTransport(
            active: [alpha: runningRow(), beta: runningRow()],
            permissions: [beta: [permission]]
        )
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }
        let states = Dictionary(uniqueKeysWithValues: (snapshot.snapshotEntries ?? []).map {
            ($0.session.session, $0.state)
        })
        XCTAssertEqual(states[alpha], .working)
        XCTAssertEqual(states[beta], .waitingForUser)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testUnknownExecutionOutcomeIsUncertainNotWorking() async throws {
        let transport = makeTransport(
            active: [alpha: runningRow()],
            details: [alpha: detail(alpha, outcome: "paused")]
        )
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .incomplete(let snapshot, _, let losses, let problems) = observation else {
            return XCTFail("expected an incomplete observation, got \(observation)")
        }
        XCTAssertEqual(problems, [.sessionDetailMalformed])
        XCTAssertEqual(snapshot.snapshotEntries, [])
        XCTAssertEqual(losses.count, 1)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        for loss in losses { XCTAssertEqual(model.apply(loss), .applied) }
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertTrue(model.works.isEmpty)
    }

    // MARK: - Finished rows

    func testInactiveRowLeftInActiveListReleasesHold() async throws {
        var model = activatedModel()
        let first = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let running, let noInactivity) = first else {
            return XCTFail("expected a complete snapshot, got \(first)")
        }
        XCTAssertTrue(noInactivity.isEmpty)
        XCTAssertEqual(model.apply(running), .applied)
        XCTAssertEqual(model.decision.state, .working)

        // The service still lists the session, but the documented inactive row
        // type proves no execution is running. Its detail is not consulted, so
        // a stale terminal outcome cannot be mistaken for the current one.
        let finishedTransport = makeTransport(
            active: [alpha: ["type": "idle"]],
            details: [alpha: detail(alpha, outcome: "succeeded")]
        )
        let second = try await adapter(finishedTransport).observe(at: epoch.addingTimeInterval(30))
        guard case .complete(let finished, let inactivity) = second else {
            return XCTFail("expected a complete snapshot, got \(second)")
        }
        XCTAssertEqual(finished.snapshotEntries, [])
        XCTAssertEqual(inactivity.count, 1)
        XCTAssertEqual(inactivity.first?.scope, .session)
        XCTAssertEqual(inactivity.first?.snapshotComplete, true)
        XCTAssertEqual(inactivity.first?.snapshotEntries, [])
        XCTAssertEqual(inactivity.first?.session.session, alpha)
        XCTAssertFalse(
            finishedTransport.requested.contains(OpenCodeService.sessionPath(alpha)),
            "an inactive row needs no execution detail"
        )

        XCTAssertEqual(model.apply(finished), .applied)
        XCTAssertEqual(model.apply(inactivity[0]), .applied)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .ended)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testRunningRowWithTerminalOutcomeIsAProblemNotCompletion() async throws {
        // A stale detail outcome must not end work the listing still calls
        // running: the detail can describe an earlier execution.
        var model = activatedModel()
        let first = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let running, _) = first else {
            return XCTFail("expected a complete snapshot, got \(first)")
        }
        XCTAssertEqual(model.apply(running), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let contradictory = makeTransport(
            active: [alpha: runningRow()],
            details: [alpha: detail(alpha, outcome: "interrupted")]
        )
        let second = try await adapter(contradictory).observe(at: epoch.addingTimeInterval(30))
        guard case .incomplete(let snapshot, let inactivity, let losses, let problems) = second else {
            return XCTFail("expected an incomplete observation, got \(second)")
        }
        XCTAssertFalse(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries, [])
        XCTAssertTrue(inactivity.isEmpty)
        XCTAssertEqual(problems, [.runningRowWithFinishedOutcome])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.scope, .session)
        XCTAssertEqual(losses.first?.session.session, alpha)

        XCTAssertEqual(model.apply(snapshot), .applied)
        for loss in losses { XCTAssertEqual(model.apply(loss), .applied) }
        XCTAssertEqual(record(in: model, session: alpha)?.state, .uncertain)
        XCTAssertNotEqual(record(in: model, session: alpha)?.state, .ended)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testUndocumentedActiveRowTypeIsUnreadable() async throws {
        let transport = makeTransport(active: [alpha: ["type": "queued"]])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .incomplete(let snapshot, let inactivity, let losses, let problems) = observation else {
            return XCTFail("expected an incomplete observation, got \(observation)")
        }
        XCTAssertFalse(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries, [])
        XCTAssertTrue(inactivity.isEmpty)
        XCTAssertEqual(problems, [.unreadableActiveRow])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.session.session, alpha)

        // An unreadable row is never turned into a request whose answer would
        // be guessed at.
        XCTAssertEqual(
            transport.requested,
            [OpenCodeService.activeSessionsPath],
            "an unreadable row must not cause per-session reads"
        )

        var model = activatedModel()
        for event in observation.events { XCTAssertEqual(model.apply(event), .applied) }
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(model.decision.state, .unknown)
    }

    // MARK: - Incomplete coverage

    func testIncompleteListingLeavesOmittedWorkUncertainEndToEnd() async throws {
        let store = LocalEventStore(root: sandbox.appendingPathComponent("events", isDirectory: true))
        var model = activatedModel()
        let first = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let snapshot, _) = first else {
            return XCTFail("expected a complete snapshot, got \(first)")
        }
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)
        try store.saveModel(model)

        let brokenTransport = makeTransport(
            active: [alpha: runningRow()],
            overrides: [OpenCodeService.sessionPath(alpha): .failure(.unreachable)]
        )
        let second = try await adapter(brokenTransport).observe(at: epoch.addingTimeInterval(60))
        guard case .incomplete(let partial, _, let losses, let problems) = second else {
            return XCTFail("expected an incomplete observation, got \(second)")
        }
        XCTAssertFalse(partial.snapshotComplete)
        XCTAssertEqual(partial.snapshotEntries, [])
        XCTAssertEqual(problems, [.sessionDetailUnavailable])
        XCTAssertEqual(losses.map(\.transition), [.observationLost])

        let written = try adapter(brokenTransport).enqueue(second, into: store)
        XCTAssertEqual(written, 2)

        let names = try FileManager.default
            .contentsOfDirectory(atPath: store.inbox.path)
            .filter { $0.hasSuffix(".event") }
            .sorted()
        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names[0].contains("@snap-"), "the snapshot must apply before the loss: \(names)")
        XCTAssertTrue(names[1].contains("@uncertain-"), "the loss must apply after the snapshot: \(names)")

        var reloaded = try store.loadModel()
        let report = try store.reconcile(&reloaded)
        XCTAssertEqual(report.applied, 2)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(record(in: reloaded, session: alpha)?.state, .uncertain)
        XCTAssertNotEqual(record(in: reloaded, session: alpha)?.state, .ended)
        XCTAssertEqual(reloaded.decision.state, .uncertain)
        XCTAssertTrue(reloaded.decision.holdAssertion)
    }

    func testIncompleteSnapshotStillRecordsProvenWorkingSession() async throws {
        let transport = makeTransport(
            active: [alpha: runningRow(), beta: runningRow()],
            overrides: [OpenCodeService.sessionPath(beta): .failure(.timedOut)]
        )
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .incomplete(let snapshot, _, let losses, let problems) = observation else {
            return XCTFail("expected an incomplete observation, got \(observation)")
        }
        XCTAssertFalse(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries?.count, 1)
        XCTAssertEqual(snapshot.snapshotEntries?.first?.session.session, alpha)
        XCTAssertEqual(snapshot.snapshotEntries?.first?.state, .working)
        XCTAssertEqual(problems, [.sessionDetailUnavailable])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.scope, .session)
        XCTAssertEqual(losses.first?.session.session, beta)

        var model = activatedModel()
        XCTAssertEqual(model.apply(snapshot), .applied)
        for loss in losses { XCTAssertEqual(model.apply(loss), .applied) }
        XCTAssertEqual(record(in: model, session: alpha)?.state, .working)
        XCTAssertNil(record(in: model, session: beta))
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
        XCTAssertEqual(model.gaps.count, 1, "the failed session keeps its own gap")
    }

    func testUnusableSessionIdentifierNeverReachesEvents() async throws {
        let hostile = "not-a-session"
        let transport = makeTransport(active: [hostile: runningRow()])
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .incomplete(_, _, let losses, let problems) = observation else {
            return XCTFail("expected an incomplete observation, got \(observation)")
        }
        XCTAssertEqual(problems, [.invalidSessionIdentifier])
        XCTAssertEqual(losses.count, 1)
        XCTAssertEqual(losses.first?.scope, .instance)
        for event in observation.events {
            let encoded = try JSONEncoder().encode(event)
            XCTAssertNil(
                String(data: encoded, encoding: .utf8)?.range(of: hostile),
                "an unusable identifier must not be persisted"
            )
        }
    }

    // MARK: - Staleness

    func testOlderSnapshotCannotEndNewerWork() async throws {
        var model = activatedModel()
        let newer = try await adapter(makeTransport(active: [alpha: runningRow()]))
            .observe(at: epoch.addingTimeInterval(120))
        guard case .complete(let newerSnapshot, _) = newer else {
            return XCTFail("expected a complete snapshot, got \(newer)")
        }
        XCTAssertEqual(model.apply(newerSnapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)

        // An older, complete snapshot with an empty listing is applied after
        // the newer fact. The model's freshness rule must keep the record.
        let older = try await adapter(makeTransport(active: [:])).observe(at: epoch)
        guard case .complete(let olderSnapshot, _) = older else {
            return XCTFail("expected a complete snapshot, got \(older)")
        }
        XCTAssertEqual(model.apply(olderSnapshot), .applied)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    // MARK: - Proven inactivity

    func testProvenInactiveSessionEndsWhenAnotherReadFails() async throws {
        var model = activatedModel()
        let first = try await adapter(makeTransport(active: [alpha: runningRow(), beta: runningRow()]))
            .observe(at: epoch)
        guard case .complete(let running, _) = first else {
            return XCTFail("expected a complete snapshot, got \(first)")
        }
        XCTAssertEqual(model.apply(running), .applied)
        XCTAssertEqual(model.decision.state, .working)

        // alpha's row is now inactive while beta still works, and alpha's
        // permission list cannot be read, so the pass cannot be complete.
        let transport = makeTransport(
            active: [alpha: ["type": "idle"], beta: runningRow()],
            overrides: [OpenCodeService.permissionsPath(alpha): .failure(.unreachable)]
        )
        let second = try await adapter(transport).observe(at: epoch.addingTimeInterval(60))
        guard case .incomplete(let snapshot, let inactivity, let losses, let problems) = second else {
            return XCTFail("expected an incomplete observation, got \(second)")
        }
        XCTAssertFalse(snapshot.snapshotComplete)
        XCTAssertEqual(snapshot.snapshotEntries?.count, 1)
        XCTAssertEqual(snapshot.snapshotEntries?.first?.session.session, beta)
        XCTAssertEqual(snapshot.snapshotEntries?.first?.state, .working)
        XCTAssertEqual(problems, [.permissionListUnavailable])

        // The proved-inactive session is stated on its own, after the instance
        // snapshot and before the losses.
        XCTAssertEqual(inactivity.map(\.session.session), [alpha])
        XCTAssertEqual(inactivity.first?.scope, .session)
        XCTAssertEqual(inactivity.first?.snapshotComplete, true)
        XCTAssertEqual(inactivity.first?.snapshotEntries, [])
        XCTAssertEqual(losses.map(\.session.session), [alpha])
        XCTAssertEqual(second.events.map(\.transition), [.snapshot, .snapshot, .observationLost])
        XCTAssertEqual(second.events.map(\.scope), [.instance, .session, .session])

        // The incomplete instance snapshot alone cannot reconcile the finished
        // session; the per-session statement is what ends its record.
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .working)

        for event in inactivity + losses { XCTAssertEqual(model.apply(event), .applied) }
        XCTAssertEqual(record(in: model, session: alpha)?.state, .ended)
        XCTAssertEqual(record(in: model, session: beta)?.state, .working)
        XCTAssertEqual(model.gaps.count, 1)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        // The same facts through the inbox. File order is what the store
        // applies, so the instance snapshot, the per-session complete snapshot,
        // and the loss must sort in that order at one observation time.
        let store = LocalEventStore(root: sandbox.appendingPathComponent("inactivity", isDirectory: true))
        try adapter(makeTransport(active: [alpha: runningRow(), beta: runningRow()])).enqueue(first, into: store)
        try adapter(transport).enqueue(second, into: store)

        let names = try FileManager.default.contentsOfDirectory(atPath: store.inbox.path)
            .filter { $0.hasSuffix(".event") }
            .sorted()
        XCTAssertEqual(names.count, 4)
        XCTAssertTrue(names[1].contains("@snap-"), "instance snapshot first: \(names)")
        XCTAssertTrue(names[2].contains("@snapsession-"), "session snapshot second: \(names)")
        XCTAssertTrue(names[3].contains("@uncertain-"), "loss last: \(names)")

        var replayed = activatedModel()
        XCTAssertEqual(try store.reconcile(&replayed).applied, 4)
        XCTAssertEqual(record(in: replayed, session: alpha)?.state, .ended)
        XCTAssertEqual(record(in: replayed, session: beta)?.state, .working)
        XCTAssertEqual(replayed.gaps.count, 1)
        XCTAssertEqual(replayed.decision.state, .working)
    }

    func testCompletePassWithOnlyFinishedRowsLeavesNoActiveRecord() async throws {
        var model = activatedModel()
        let first = try await adapter(makeTransport(active: [alpha: runningRow(), beta: runningRow()]))
            .observe(at: epoch)
        guard case .complete(let running, _) = first else {
            return XCTFail("expected a complete snapshot, got \(first)")
        }
        XCTAssertEqual(model.apply(running), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let idle = try await adapter(makeTransport(active: [
            alpha: ["type": "idle"],
            beta: ["type": "idle"]
        ])).observe(at: epoch.addingTimeInterval(30))
        guard case .complete(let finished, let inactivity) = idle else {
            return XCTFail("expected a complete snapshot, got \(idle)")
        }
        XCTAssertEqual(finished.snapshotEntries, [])
        XCTAssertEqual(inactivity.map(\.session.session), [alpha, beta])
        for event in idle.events { XCTAssertEqual(model.apply(event), .applied) }

        XCTAssertTrue(model.works.values.allSatisfy { !$0.state.isActive })
        XCTAssertEqual(record(in: model, session: alpha)?.state, .ended)
        XCTAssertEqual(record(in: model, session: beta)?.state, .ended)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    // MARK: - Same-instant identity

    func testTwoObservationsAtTheSameInstantKeepDistinctWork() async throws {
        // Both passes happen in the same microsecond. Each emission needs its
        // own identity, or the second proven-working snapshot is dropped as a
        // duplicate of the first.
        let first = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        let second = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        XCTAssertEqual(first.events.count, 1)
        XCTAssertEqual(second.events.count, 1)
        XCTAssertNotEqual(first.events[0].id, second.events[0].id)
        XCTAssertTrue(first.events[0].id.hasPrefix("snap-"))
        XCTAssertTrue(second.events[0].id.hasPrefix("snap-"))

        let store = LocalEventStore(root: sandbox.appendingPathComponent("same-instant", isDirectory: true))
        try adapter(makeTransport(active: [alpha: runningRow()])).enqueue(first, into: store)
        try adapter(makeTransport(active: [alpha: runningRow()])).enqueue(second, into: store)
        XCTAssertEqual(IntegrationFixtures.files(under: store.inbox).count, 2)

        var model = activatedModel()
        XCTAssertEqual(model.apply(first.events[0]), .applied)
        XCTAssertEqual(model.apply(second.events[0]), .applied)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        // A fresh model replays both files through the inbox path; neither may
        // be dropped as a duplicate of the other.
        var replayed = activatedModel()
        let report = try store.reconcile(&replayed)
        XCTAssertEqual(report.applied, 2, "no fact may be dropped as a duplicate")
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertEqual(report.rejectedFiles, 0)
        XCTAssertEqual(record(in: replayed, session: alpha)?.state, .working)
        XCTAssertEqual(replayed.decision.state, .working)
    }

    // MARK: - Oversize

    func testOversizeEntryCountIsAnErrorAndRecordsCapacityGap() async throws {
        let count = ActivityModel.maxWorks + 1
        var active: [String: Any] = [:]
        for index in 0..<count {
            active[String(format: "ses_%04d", index)] = runningRow()
        }
        let transport = makeTransport(active: active)
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .oversize(let oversize) = observation else {
            return XCTFail("expected an oversize outcome, got \(observation)")
        }
        XCTAssertEqual(oversize.entryCount, count)
        XCTAssertEqual(oversize.entryLimit, ActivityModel.maxWorks)
        XCTAssertTrue(oversize.exceededEntryLimit)
        XCTAssertTrue(observation.events.isEmpty, "an oversize snapshot is never truncated into an event")

        var model = activatedModel()
        let working = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let snapshot, _) = working else {
            return XCTFail("expected a complete snapshot, got \(working)")
        }
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)

        OpenCodeAdapter.recordCapacityGap(for: oversize, in: &model)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .uncertain)
        XCTAssertEqual(model.gaps.values.first?.reasons, Set([GapReason.capacityExceeded]))
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testOversizeEncodedBytesIsAnError() async throws {
        let longID = "ses_" + String(repeating: "a", count: 120)
        var active: [String: Any] = [:]
        for index in 0..<100 {
            // Distinct, still usable identifiers of realistic maximum length,
            // inside the row bound so the byte bound is what fires.
            let suffix = String(format: "%03d", index)
            active[String(longID.prefix(124)) + suffix] = runningRow()
        }
        let transport = makeTransport(active: active)
        let observation = try await adapter(transport, maxEventBytes: 1024).observe(at: epoch)

        guard case .oversize(let oversize) = observation else {
            return XCTFail("expected an oversize outcome, got \(observation)")
        }
        XCTAssertFalse(oversize.exceededEntryLimit)
        XCTAssertTrue(oversize.exceededByteLimit)
        XCTAssertGreaterThan(oversize.encodedBytes, oversize.byteLimit)
        XCTAssertEqual(oversize.byteLimit, 1024)
        XCTAssertTrue(observation.events.isEmpty)
    }

    // MARK: - Fan-out bound

    func testRowBoundRefusesFanOutBeforeAnySessionRead() async throws {
        var active: [String: Any] = [:]
        for index in 0..<300 {
            active[String(format: "ses_%04d", index)] = ["type": "idle"]
        }
        let transport = makeTransport(active: active)
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .oversize(let oversize) = observation else {
            return XCTFail("expected an oversize outcome, got \(observation)")
        }
        XCTAssertEqual(oversize.entryCount, 300)
        XCTAssertEqual(oversize.entryLimit, ActivityModel.maxWorks)
        XCTAssertTrue(observation.events.isEmpty)
        XCTAssertEqual(
            transport.requested,
            [OpenCodeService.activeSessionsPath],
            "a listing past the row bound may not trigger a per-session read"
        )
    }

    func testRowBoundFiresAtOnePastTheLimit() async throws {
        var active: [String: Any] = [:]
        for index in 0..<(OpenCodeAdapter.maxSessionsPerObservation + 1) {
            active[String(format: "ses_%04d", index)] = ["type": "idle"]
        }
        let transport = makeTransport(active: active)
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .oversize(let oversize) = observation else {
            return XCTFail("expected an oversize outcome, got \(observation)")
        }
        XCTAssertEqual(oversize.entryCount, OpenCodeAdapter.maxSessionsPerObservation + 1)
        XCTAssertTrue(observation.events.isEmpty)
        XCTAssertEqual(transport.requested, [OpenCodeService.activeSessionsPath])
    }

    func testRowBoundAtTheLimitProceeds() async throws {
        var active: [String: Any] = [:]
        for index in 0..<OpenCodeAdapter.maxSessionsPerObservation {
            active[String(format: "ses_%04d", index)] = ["type": "idle"]
        }
        let transport = makeTransport(active: active)
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .complete(let snapshot, let inactivity) = observation else {
            return XCTFail("a listing at the row bound must proceed, got \(observation)")
        }
        XCTAssertEqual(snapshot.snapshotEntries, [])
        XCTAssertEqual(inactivity.count, OpenCodeAdapter.maxSessionsPerObservation)
        XCTAssertEqual(observation.events.count, OpenCodeAdapter.maxSessionsPerObservation + 1)
        XCTAssertEqual(
            transport.requested.count,
            1 + OpenCodeAdapter.maxSessionsPerObservation * 2,
            "an idle row costs exactly its two pending-list reads"
        )
    }

    // MARK: - Transport failure

    func testTransportFailureYieldsUncertaintyNeverIdle() async throws {
        let transport = FixtureTransport()
        let observation = try await adapter(transport).observe(at: epoch)

        guard case .unavailable(let loss, let problem) = observation else {
            return XCTFail("expected an unavailable observation, got \(observation)")
        }
        XCTAssertEqual(problem, .activeListingUnavailable)
        XCTAssertEqual(loss.transition, .observationLost)
        XCTAssertEqual(loss.scope, .instance)
        XCTAssertEqual(observation.events.count, 1)

        var model = activatedModel()
        XCTAssertEqual(model.apply(loss), .applied)
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertEqual(model.gaps.values.first?.reasons, Set([GapReason.observerLost]))
    }

    func testTransportFailureMakesObservedWorkUncertain() async throws {
        var model = activatedModel()
        let working = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let snapshot, _) = working else {
            return XCTFail("expected a complete snapshot, got \(working)")
        }
        XCTAssertEqual(model.apply(snapshot), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let failure = try await adapter(FixtureTransport()).observe(at: epoch.addingTimeInterval(60))
        guard case .unavailable(let loss, _) = failure else {
            return XCTFail("expected an unavailable observation, got \(failure)")
        }
        XCTAssertEqual(model.apply(loss), .applied)
        XCTAssertEqual(record(in: model, session: alpha)?.state, .uncertain)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    // MARK: - Activation gates

    func testInactiveFamilyIsRejectedByModel() async throws {
        let observation = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }

        var model = ActivityModel()
        XCTAssertEqual(model.apply(snapshot), .ignored(.inactiveSource))
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testStaleActivationGenerationIsRejectedByModel() async throws {
        let observation = try await adapter(makeTransport(active: [alpha: runningRow()])).observe(at: epoch)
        guard case .complete(let snapshot, _) = observation else {
            return XCTFail("expected a complete snapshot, got \(observation)")
        }

        var model = ActivityModel()
        model.activate(family: "opencode", generation: 2)
        XCTAssertEqual(model.apply(snapshot), .ignored(.staleActivation))
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - Privacy

    func testSecretsNeverAppearInEventsOrProblemText() async throws {
        let token = "sk-live-OPENCODE-TOKEN-42"
        let prompt = "PROMPT-MARKER-OPENCODE"
        let response = "RESPONSE-MARKER-OPENCODE"
        let secrets = [token, prompt, response]

        let permission: [String: Any] = [
            "id": "per_1",
            "sessionID": alpha,
            "action": "bash",
            "resources": [prompt],
            "metadata": ["token": token],
            "message": response
        ]
        let form: [String: Any] = [
            "id": "frm_1",
            "sessionID": alpha,
            "title": prompt,
            "fields": [["name": "token", "value": token]]
        ]
        let transport = makeTransport(
            active: [alpha: ["type": "running", "authorization": token]],
            details: [alpha: ["data": [
                "id": alpha,
                "title": response,
                "metadata": ["token": token]
            ]]],
            permissions: [alpha: [permission]],
            forms: [alpha: [form]]
        )
        let connector = try adapter(transport)
        let observation = await connector.observe(at: epoch)
        XCTAssertFalse(observation.events.isEmpty)

        let store = LocalEventStore(root: sandbox.appendingPathComponent("privacy", isDirectory: true))
        try connector.enqueue(observation, into: store)
        for file in IntegrationFixtures.files(under: store.root) {
            let bytes = try Data(contentsOf: file)
            let text = String(decoding: bytes, as: UTF8.self)
            for secret in secrets {
                XCTAssertNil(text.range(of: secret), "\(file.lastPathComponent) leaked a seeded secret")
            }
        }

        // Error text and descriptions are fixed tokens, never payload or
        // authorization material.
        var descriptions: [String] = [
            String(describing: observation),
            String(describing: OpenCodeConfigurationError.notVerifiedLocalEndpoint),
            String(describing: OpenCodeTransportFailure.other)
        ]
        let redactedTransport = URLSessionOpenCodeTransport(
            baseURL: URL(string: "http://127.0.0.1:4096")!,
            authorization: { token }
        )
        descriptions.append(String(describing: redactedTransport))
        for secret in secrets {
            for text in descriptions {
                XCTAssertNil(text.range(of: secret), "description leaked a seeded secret")
            }
        }

        // A failing response body that carries a secret must not surface in the
        // outcome either.
        let failing = makeTransport(
            active: [alpha: runningRow()],
            overrides: [
                OpenCodeService.sessionPath(alpha): .response(OpenCodeHTTPResponse(
                    status: 500,
                    body: Data("\(token) \(prompt)".utf8)
                ))
            ]
        )
        let failure = try await adapter(failing).observe(at: epoch.addingTimeInterval(10))
        XCTAssertTrue(secrets.allSatisfy { !String(describing: failure).contains($0) })
        XCTAssertEqual(failure.problems, [.sessionDetailUnavailable])
    }

    // MARK: - Inertness guard

    func testAdapterSourceHasNoSchedulingConstructs() throws {
        // This is a source-level guard against accidentally reintroducing
        // polling. The adapter must stay callable and inert; Stage 5 owns
        // scheduling and gates it on activation.
        let sourceURL = IntegrationFixtures.repositoryRoot
            .appendingPathComponent("Sources/Adapters/OpenCodeAdapter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let forbidden = [
            "Timer", "DispatchSource", "DispatchQueue", "Task {", "Task(",
            "while true", "while(true", "Thread", "asyncAfter", "sleep("
        ]
        for token in forbidden {
            XCTAssertFalse(source.contains(token), "adapter must not contain \(token)")
        }
        XCTAssertTrue(source.contains("func observe(at date: Date) async"))
        XCTAssertTrue(source.contains("protocol OpenCodeTransport"))
    }

    // MARK: - Configuration

    func testResponseBodyBudgetStopsAtTheLimit() {
        var budget = OpenCodeBodyBudget(limit: 4)
        budget.append([1, 2])
        XCTAssertEqual(budget.data.count, 2)
        XCTAssertFalse(budget.exceededLimit)

        budget.append([3, 4])
        XCTAssertEqual(budget.data.count, 4)
        XCTAssertFalse(budget.exceededLimit)

        // One byte past the limit is kept so the adapter's own `<=` check still
        // refuses the body instead of decoding a truncated one.
        budget.append([5, 6, 7])
        XCTAssertTrue(budget.exceededLimit)
        XCTAssertEqual(budget.data.count, 5)

        budget.append([8])
        XCTAssertEqual(budget.data.count, 5, "nothing is stored after the bound is passed")
        XCTAssertTrue(budget.exceededLimit)
    }

    func testEndpointAndConfigurationRefusals() throws {
        XCTAssertThrowsError(try OpenCodeEndpoint(baseURL: URL(string: "http://example.com:4096")!)) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .notVerifiedLocalEndpoint)
        }
        XCTAssertThrowsError(try OpenCodeEndpoint(baseURL: URL(string: "http://user:pass@127.0.0.1:4096")!)) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .notVerifiedLocalEndpoint)
            XCTAssertFalse(String(describing: $0).contains("pass"))
        }
        XCTAssertThrowsError(try OpenCodeEndpoint(baseURL: URL(string: "http://127.0.0.1:4096?token=abc")!)) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .notVerifiedLocalEndpoint)
        }
        XCTAssertThrowsError(try OpenCodeEndpoint(baseURL: URL(string: "http://127.0.0.1:4096/api")!)) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .notVerifiedLocalEndpoint)
        }
        XCTAssertNoThrow(try OpenCodeEndpoint(baseURL: URL(string: "http://127.0.0.1:4096")!))
        XCTAssertNoThrow(try OpenCodeEndpoint(baseURL: URL(string: "http://localhost:4096")!))
        XCTAssertNoThrow(try OpenCodeEndpoint(baseURL: URL(string: "http://[::1]:4096")!))

        let owner = OwnerIdentity(bootID: "boot", pid: 1, startTimeMicros: 2, uid: 501, instance: "other")
        XCTAssertThrowsError(try OpenCodeConfiguration(
            instance: "service",
            activationGeneration: 1,
            owner: owner
        )) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .ownerInstanceMismatch)
        }
        XCTAssertThrowsError(try OpenCodeConfiguration(
            instance: "not canonical",
            activationGeneration: 1,
            owner: OwnerIdentity(bootID: "boot", pid: 1, startTimeMicros: 2, uid: 501, instance: "not canonical")
        )) {
            XCTAssertEqual($0 as? OpenCodeConfigurationError, .invalidInstance)
        }
    }

    // MARK: - Fixtures

    private final class FixtureTransport: OpenCodeTransport {
        var responses: [String: OpenCodeTransportResult] = [:]
        private(set) var requested: [String] = []

        func get(_ path: String) async -> OpenCodeTransportResult {
            requested.append(path)
            return responses[path] ?? .failure(.unreachable)
        }
    }

    private func runningRow() -> Any {
        ["type": "running"]
    }

    private func detail(_ sessionID: String, outcome: String?) -> Any {
        var data: [String: Any] = [
            "id": sessionID,
            "projectID": "prj_test",
            "cost": 0,
            "tokens": [String: Any](),
            "time": ["created": 1, "updated": 2, "busy": 2, "idle": 1],
            "location": [String: Any]()
        ]
        if let outcome { data["outcome"] = outcome }
        return ["data": data]
    }

    private func jsonResponse(_ object: Any, status: Int = 200) -> OpenCodeTransportResult {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return .response(OpenCodeHTTPResponse(status: status, body: data))
    }

    private func makeTransport(
        active: [String: Any],
        details: [String: Any] = [:],
        permissions: [String: [Any]] = [:],
        forms: [String: [Any]] = [:],
        overrides: [String: OpenCodeTransportResult] = [:]
    ) -> FixtureTransport {
        let transport = FixtureTransport()
        transport.responses[OpenCodeService.activeSessionsPath] = jsonResponse(["data": active])
        for sessionID in active.keys {
            transport.responses[OpenCodeService.sessionPath(sessionID)] =
                jsonResponse(details[sessionID] ?? detail(sessionID, outcome: nil))
            transport.responses[OpenCodeService.permissionsPath(sessionID)] =
                jsonResponse(["data": permissions[sessionID] ?? []])
            transport.responses[OpenCodeService.formsPath(sessionID)] =
                jsonResponse(["data": forms[sessionID] ?? []])
        }
        for (path, result) in overrides {
            transport.responses[path] = result
        }
        return transport
    }

    private func configuration(
        generation: UInt64 = 1,
        maxEventBytes: Int = LocalEventStore.Limits().maxEventBytes
    ) throws -> OpenCodeConfiguration {
        try OpenCodeConfiguration(
            instance: "service",
            activationGeneration: generation,
            owner: OwnerIdentity(
                bootID: "boot",
                pid: 4242,
                startTimeMicros: 1_000,
                uid: 501,
                instance: "service"
            ),
            maxEventBytes: maxEventBytes
        )
    }

    private func adapter(
        _ transport: FixtureTransport,
        generation: UInt64 = 1,
        maxEventBytes: Int = LocalEventStore.Limits().maxEventBytes
    ) throws -> OpenCodeAdapter {
        OpenCodeAdapter(
            endpoint: try OpenCodeEndpoint(baseURL: URL(string: "http://127.0.0.1:4096")!),
            configuration: try configuration(generation: generation, maxEventBytes: maxEventBytes),
            transport: transport
        )
    }

    private func activatedModel(generation: UInt64 = 1) -> ActivityModel {
        var model = ActivityModel()
        model.activate(family: "opencode", generation: generation)
        return model
    }

    private func record(in model: ActivityModel, session: String) -> WorkRecord? {
        model.works.first {
            $0.key.session.family == "opencode"
                && $0.key.session.session == session
                && $0.key.work == "execution"
        }?.value
    }
}
