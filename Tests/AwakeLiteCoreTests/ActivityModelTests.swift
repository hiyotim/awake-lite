import XCTest
@testable import AwakeLiteCore

final class ActivityModelTests: XCTestCase {
    private let family = "codex"
    private let instance = "cli"

    private var model: ActivityModel!

    override func setUp() {
        super.setUp()
        model = ActivityModel()
        model.activate(family: family, generation: 1)
    }

    override func tearDown() {
        model = nil
        super.tearDown()
    }

    // MARK: - Parallel work

    func testParallelSessionsAreIndependent() {
        let first = session("first")
        let second = session("second")

        XCTAssertEqual(apply(start("a1", session: first, work: "task")), .applied)
        XCTAssertEqual(apply(start("b1", session: second, work: "task")), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(update("a2", transition: .completed, session: first, work: "task")), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(update("b2", transition: .completed, session: second, work: "task")), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testWaitingParentKeepsHoldWhileChildWorks() {
        let shared = session("parent")

        XCTAssertEqual(apply(start("p1", session: shared, work: "parent")), .applied)
        XCTAssertEqual(apply(update("p2", transition: .humanWait, session: shared, work: "parent")), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)

        XCTAssertEqual(apply(start("c1", session: shared, work: "child", parentWork: "parent")), .applied)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(update("c2", transition: .childFinished, session: shared, work: "child", parentWork: "parent")), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    // MARK: - Continuation and retry

    func testBackgroundChildStartedAfterParentCompletionHoldsSleep() {
        let shared = session("s1")

        XCTAssertEqual(apply(start("bg-parent", session: shared, work: "parent")), .applied)
        XCTAssertEqual(apply(update("bg-parent-done", transition: .completed, session: shared, work: "parent")), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)

        XCTAssertEqual(apply(start("bg-child", session: shared, work: "background", parentWork: "parent")), .applied)
        XCTAssertEqual(record(for: shared, work: "background")?.parentWork, "parent")
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(update("bg-child-done", transition: .childFinished, session: shared, work: "background", parentWork: "parent")), .applied)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testRetryAfterFailureIsAcceptedAsNewGeneration() {
        let shared = session("s1")

        XCTAssertEqual(apply(start("retry-g1", session: shared, work: "task", generation: 1)), .applied)
        XCTAssertEqual(apply(update("retry-g1-failed", transition: .failed, session: shared, work: "task", generation: 1)), .applied)
        XCTAssertEqual(record(for: shared, work: "task", generation: 1)?.state, .failed)
        XCTAssertEqual(model.decision.state, .idle)

        XCTAssertEqual(apply(start("retry-g2", session: shared, work: "task", generation: 2)), .applied)
        XCTAssertEqual(record(for: shared, work: "task", generation: 2)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(update("retry-g2-done", transition: .completed, session: shared, work: "task", generation: 2)), .applied)
        XCTAssertEqual(record(for: shared, work: "task", generation: 1)?.state, .failed)
        XCTAssertEqual(record(for: shared, work: "task", generation: 2)?.state, .completed)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    // MARK: - Generations and duplicates

    func testLateCompletionOfOldGenerationDoesNotCloseNewWork() {
        let shared = session("s1")

        XCTAssertEqual(apply(start("g1-start", session: shared, work: "task", generation: 1)), .applied)
        XCTAssertEqual(apply(start("g2-start", session: shared, work: "task", generation: 2)), .applied)
        XCTAssertEqual(apply(update("g1-done", transition: .completed, session: shared, work: "task", generation: 1)), .applied)

        XCTAssertEqual(record(for: shared, work: "task", generation: 1)?.state, .completed)
        XCTAssertEqual(record(for: shared, work: "task", generation: 2)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
    }

    func testDuplicateEventIsIdempotent() {
        let event = start("dup", session: session("s1"), work: "task")

        XCTAssertEqual(model.apply(event), .applied)
        let before = model.decision
        XCTAssertEqual(model.apply(event), .duplicate)
        XCTAssertEqual(model.decision, before)
        XCTAssertEqual(model.works.count, 1)
    }

    func testEventWithMismatchedSessionFamilyIsInvalid() {
        let foreign = SessionIdentity(family: "pi", instance: instance, session: "s1")
        let event = ActivityEvent(
            id: "family-mismatch",
            source: family,
            activationGeneration: 1,
            owner: owner(),
            session: foreign,
            transition: .started,
            work: "task",
            generation: 1,
            timestamp: date(0)
        )

        XCTAssertEqual(model.apply(event), .ignored(.invalidEvent))
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testOwnerMismatchFromReusedPIDIsIgnored() {
        let shared = session("s1")
        let original = owner(bootID: "boot-1", pid: 42, startMicros: 1_000)
        let reused = owner(bootID: "boot-2", pid: 42, startMicros: 9_000)

        XCTAssertEqual(model.apply(start("o1", session: shared, work: "task", owner: original)), .applied)
        let completion = update(
            "o2",
            transition: .completed,
            session: shared,
            work: "task",
            owner: reused
        )
        XCTAssertEqual(model.apply(completion), .ignored(.ownerMismatch))
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
    }

    /// The same opaque event ID from two families names two different facts.
    func testDeduplicationIsNamespacedBySourceAndInstance() {
        var combined = ActivityModel()
        combined.activate(family: family, generation: 1)
        combined.activate(family: "pi", generation: 1)

        let codexEvent = start("shared-id", session: session("s1"), work: "task")
        let piEvent = ActivityEvent(
            id: "shared-id",
            source: "pi",
            activationGeneration: 1,
            owner: owner(pid: 77),
            session: SessionIdentity(family: "pi", instance: instance, session: "s1"),
            transition: .started,
            work: "task",
            generation: 1,
            timestamp: date(0)
        )

        XCTAssertEqual(combined.apply(codexEvent), .applied)
        XCTAssertEqual(combined.apply(piEvent), .applied)
        XCTAssertEqual(combined.apply(codexEvent), .duplicate)
        XCTAssertEqual(combined.works.count, 2)
        XCTAssertEqual(combined.decision.state, .working)
    }

    /// Rejected events are not remembered: the same event applies once its
    /// gate opens.
    func testOnlyAppliedEventsAreRemembered() {
        var gated = ActivityModel()
        let dormant = start("dormant", session: session("s1"), work: "task")

        XCTAssertEqual(gated.apply(dormant), .ignored(.inactiveSource))
        gated.activate(family: family, generation: 1)
        XCTAssertEqual(gated.apply(dormant), .applied)
        XCTAssertEqual(gated.apply(dormant), .duplicate)
    }

    /// An ignored outcome is not remembered, so the same completion applies
    /// once the work it refers to exists.
    func testIgnoredOutcomeIsNotRememberedAndReplays() {
        let shared = session("s1")
        let completion = update("late-completion", transition: .completed, session: shared, work: "task")

        XCTAssertEqual(model.apply(completion), .ignored(.unknownWork))
        XCTAssertFalse(model.recentEventIDs.contains("\(family)|\(instance)|late-completion"))
        XCTAssertTrue(model.recentEventIDs.isEmpty)

        XCTAssertEqual(apply(start("late-start", session: shared, work: "task")), .applied)
        XCTAssertEqual(model.apply(completion), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .completed)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testStaleActivationEventIsReplayableAfterReactivation() {
        let shared = session("s1")
        let dormant = start("dormant-2", session: shared, work: "task", activationGeneration: 2)

        XCTAssertEqual(model.apply(dormant), .ignored(.staleActivation))
        XCTAssertTrue(model.recentEventIDs.isEmpty)

        model.activate(family: family, generation: 2)
        XCTAssertEqual(model.apply(dormant), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
    }

    /// The dedup ring stays bounded and an evicted key is replayable again.
    func testDedupRingStaysBoundedAndEvictsOldest() {
        let shared = session("s1")
        let first = start("ring-start", session: shared, work: "task")
        XCTAssertEqual(model.apply(first), .applied)

        for index in 0..<ActivityModel.maxRecentEventIDs {
            XCTAssertEqual(apply(heartbeat("ring-\(index)", session: shared, work: "task", at: 0)), .applied)
        }
        XCTAssertEqual(model.recentEventIDs.count, ActivityModel.maxRecentEventIDs)
        XCTAssertFalse(model.recentEventIDs.contains { $0.hasSuffix("|ring-start") })

        // Evicted, so it is no longer recognised as a duplicate.
        XCTAssertEqual(model.apply(first), .applied)
    }

    // MARK: - Staleness

    func testStaleSnapshotDoesNotEndNewerWorkOrClearNewerGap() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("stale-start", session: shared, work: "task", at: 10)), .applied)

        model.recordGap(family: family, instance: instance, session: "s1", reason: .observerLost, at: date(20))
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)

        let stale = snapshot("stale-snap", session: shared, entries: [], at: 15)
        XCTAssertEqual(model.apply(stale), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)
        XCTAssertNotNil(model.gaps[GapKey(family: family, instance: instance, session: "s1")])
        XCTAssertEqual(model.decision.state, .uncertain)

        let fresh = snapshot("fresh-snap", session: shared, entries: [], at: 21)
        XCTAssertEqual(model.apply(fresh), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .ended)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testSnapshotEntryOlderThanItsRecordIsSkipped() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("entry-start", session: shared, work: "task", at: 30)), .applied)

        let stale = snapshot(
            "entry-snap",
            session: shared,
            entries: [entry(shared, work: "task", state: .waitingForUser)],
            at: 25
        )
        XCTAssertEqual(model.apply(stale), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
        XCTAssertEqual(record(for: shared, work: "task")?.updatedAt, date(30))
    }

    func testLateTransitionsWithOlderTimestampAreIgnored() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("late-start", session: shared, work: "task", at: 10)), .applied)

        XCTAssertEqual(
            apply(update("late-wait", transition: .humanWait, session: shared, work: "task", at: 5)),
            .ignored(.staleTimestamp)
        )
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)

        XCTAssertEqual(
            apply(update("late-done", transition: .completed, session: shared, work: "task", at: 6)),
            .ignored(.staleTimestamp)
        )
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    // MARK: - Snapshot completeness

    func testIncompleteSnapshotMarksOmittedWorkUncertain() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("inc-start", session: shared, work: "task", at: 0)), .applied)

        let incomplete = snapshot(
            "inc-snap",
            session: shared,
            entries: [],
            at: 1,
            snapshotComplete: false
        )
        XCTAssertEqual(model.apply(incomplete), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)

        XCTAssertEqual(apply(start("inc-resume", session: shared, work: "task", at: 2)), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)

        let complete = snapshot("inc-complete", session: shared, entries: [], at: 3)
        XCTAssertEqual(model.apply(complete), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .ended)
        XCTAssertEqual(
            apply(update("inc-late-done", transition: .completed, session: shared, work: "task", at: 4)),
            .ignored(.terminalWork)
        )

        // `ended` is a snapshot statement, so a later start revives the work.
        XCTAssertEqual(apply(start("inc-revive", session: shared, work: "task", at: 5)), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)

        // An incomplete snapshot never clears a gap.
        model.recordGap(family: family, instance: instance, session: "s1", reason: .observerLost, at: date(6))
        let stillIncomplete = snapshot(
            "inc-snap-2",
            session: shared,
            entries: [],
            at: 7,
            snapshotComplete: false
        )
        XCTAssertEqual(model.apply(stillIncomplete), .applied)
        XCTAssertNotNil(model.gaps[GapKey(family: family, instance: instance, session: "s1")])
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)
    }

    func testIncompleteInstanceSnapshotLeavesOtherSessionsAndInstanceGap() {
        let listed = session("listed")
        let other = session("other")

        XCTAssertEqual(apply(start("ii-1", session: listed, work: "task", at: 0)), .applied)
        XCTAssertEqual(apply(start("ii-2", session: other, work: "task", at: 0)), .applied)
        model.recordGap(family: family, instance: instance, session: nil, reason: .eventRejected, at: date(1))

        let partial = snapshot(
            "ii-snap",
            session: listed,
            entries: [entry(listed, work: "task", state: .working)],
            at: 2,
            scope: .instance,
            snapshotComplete: false
        )
        XCTAssertEqual(model.apply(partial), .applied)
        XCTAssertEqual(record(for: listed, work: "task")?.state, .working)
        // The instance-wide gap already holds this session; the partial
        // snapshot does not resolve observation it never made.
        XCTAssertEqual(record(for: other, work: "task")?.state, .uncertain)
        XCTAssertNotNil(model.gaps[GapKey(family: family, instance: instance, session: nil)])

        let full = snapshot(
            "ii-snap-full",
            session: listed,
            entries: [entry(listed, work: "task", state: .working)],
            at: 3,
            scope: .instance
        )
        XCTAssertEqual(model.apply(full), .applied)
        XCTAssertEqual(record(for: other, work: "task")?.state, .ended)
        XCTAssertTrue(model.gaps.isEmpty)
    }

    // MARK: - Owner validation

    func testOwnerInstanceMismatchIsInvalid() {
        let event = start("owner-instance", session: session("s1"), work: "task", owner: owner(instanceName: "other"))

        XCTAssertEqual(model.apply(event), .ignored(.invalidEvent))
        XCTAssertTrue(model.works.isEmpty)
    }

    func testSnapshotWithConflictingOwnerLeavesRecordUncertain() {
        let shared = session("s1")
        let original = owner(pid: 40)
        let intruder = owner(pid: 41)

        XCTAssertEqual(
            model.apply(start("conflict-start", session: shared, work: "task", owner: original, at: 0)),
            .applied
        )

        let conflicting = snapshot(
            "conflict-snap",
            session: shared,
            entries: [entry(shared, work: "task", state: .working), entry(shared, work: "fresh", state: .working)],
            at: 1,
            owner: intruder
        )
        XCTAssertEqual(model.apply(conflicting), .applied)

        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)
        XCTAssertEqual(record(for: shared, work: "task")?.owner, original)
        // Entries the snapshot introduces adopt its owner.
        XCTAssertEqual(record(for: shared, work: "fresh")?.owner, intruder)
        XCTAssertEqual(record(for: shared, work: "fresh")?.state, .working)
    }

    // MARK: - Heartbeat and owner termination

    func testHeartbeatUpdatesFreshnessOnly() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("hb-start", session: shared, work: "task", at: 0)), .applied)

        XCTAssertEqual(apply(heartbeat("hb-1", session: shared, work: "task", at: 5)), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
        XCTAssertEqual(record(for: shared, work: "task")?.updatedAt, date(5))

        // A late heartbeat never rewinds freshness.
        XCTAssertEqual(apply(heartbeat("hb-2", session: shared, work: "task", at: 4)), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.updatedAt, date(5))

        XCTAssertEqual(
            apply(heartbeat("hb-3", session: shared, work: "other", at: 6)),
            .ignored(.unknownWork)
        )
        XCTAssertEqual(
            apply(heartbeat("hb-4", session: shared, work: "task", owner: owner(pid: 9), at: 7)),
            .ignored(.ownerMismatch)
        )

        XCTAssertEqual(apply(update("hb-done", transition: .completed, session: shared, work: "task", at: 8)), .applied)
        XCTAssertEqual(
            apply(heartbeat("hb-5", session: shared, work: "task", at: 9)),
            .ignored(.terminalWork)
        )
    }

    func testOwnerTerminatedEndsOnlyThatOwnersWork() {
        let shared = session("s1")
        let first = owner(pid: 1, startMicros: 1)
        let second = owner(pid: 2, startMicros: 2)

        XCTAssertEqual(model.apply(start("ot-a", session: shared, work: "a", owner: first, at: 0)), .applied)
        XCTAssertEqual(model.apply(start("ot-b", session: shared, work: "b", owner: second, at: 0)), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let terminated = ActivityEvent(
            id: "ot-term",
            source: family,
            activationGeneration: 1,
            owner: first,
            session: shared,
            transition: .ownerTerminated,
            timestamp: date(1)
        )
        XCTAssertEqual(model.apply(terminated), .applied)
        XCTAssertEqual(record(for: shared, work: "a")?.state, .ended)
        XCTAssertEqual(record(for: shared, work: "b")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
    }

    func testOwnerTerminatedDoesNotEndWorkObservedAfterTheEvent() {
        let shared = session("s1")
        let sharedOwner = owner()
        XCTAssertEqual(
            model.apply(start("ot-new", session: shared, work: "turn-2", owner: sharedOwner, at: 200)),
            .applied
        )

        // A detached teardown can land after a later start. It cannot retire
        // work that was observed after its own timestamp.
        let lateTermination = ActivityEvent(
            id: "ot-late",
            source: family,
            activationGeneration: 1,
            owner: sharedOwner,
            session: shared,
            transition: .ownerTerminated,
            timestamp: date(150)
        )
        XCTAssertEqual(model.apply(lateTermination), .applied)
        XCTAssertEqual(record(for: shared, work: "turn-2")?.state, .working)
        XCTAssertEqual(
            record(for: shared, work: "turn-2")?.updatedAt,
            date(200),
            "a late termination never moves freshness backwards"
        )
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testRetireForeignBootsHoldsPreviousBootWork() {
        let shared = session("s1")
        XCTAssertEqual(
            model.apply(start("rb-old", session: shared, work: "old", owner: owner(bootID: "boot-old"), at: 0)),
            .applied
        )
        XCTAssertEqual(
            model.apply(start("rb-new", session: shared, work: "new", owner: owner(bootID: "boot-now"), at: 0)),
            .applied
        )

        model.retireForeignBoots(currentBootID: "boot-now")

        XCTAssertEqual(record(for: shared, work: "old")?.state, .uncertain)
        XCTAssertEqual(record(for: shared, work: "old")?.owner.bootID, "boot-old")
        XCTAssertEqual(record(for: shared, work: "old")?.updatedAt, date(0))
        XCTAssertEqual(record(for: shared, work: "new")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
    }

    // MARK: - Session supersede

    func testSupersedeEndsOlderMainRunWhenANewerOneCompleted() {
        let shared = session("s1")
        XCTAssertEqual(model.apply(start("ss-1", session: shared, work: "turn-1", generation: 1, at: 0)), .applied)
        XCTAssertEqual(model.apply(start("ss-2", session: shared, work: "turn-2", generation: 2, at: 1)), .applied)
        XCTAssertEqual(
            model.apply(update("ss-3", transition: .completed, session: shared, work: "turn-2", generation: 2, at: 2)),
            .applied
        )
        XCTAssertEqual(model.decision.state, .working)

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(3)), 1)

        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .ended)
        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.updatedAt, date(3))
        XCTAssertEqual(record(for: shared, work: "turn-2", generation: 2)?.state, .completed)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testSupersedeKeepsTheNewestActiveRun() {
        let shared = session("s1")
        XCTAssertEqual(model.apply(start("sa-1", session: shared, work: "turn-1", generation: 1, at: 0)), .applied)
        XCTAssertEqual(model.apply(start("sa-2", session: shared, work: "turn-2", generation: 2, at: 1)), .applied)

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(2)), 1)

        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .ended)
        XCTAssertEqual(record(for: shared, work: "turn-2", generation: 2)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testSupersedeNeverTouchesChildWork() {
        let shared = session("s1")
        XCTAssertEqual(model.apply(start("sc-1", session: shared, work: "turn-3", generation: 3, at: 0)), .applied)
        XCTAssertEqual(
            model.apply(start("sc-2", session: shared, work: "child", generation: 1, parentWork: "p-main", at: 1)),
            .applied
        )
        XCTAssertEqual(model.apply(start("sc-3", session: shared, work: "turn-5", generation: 5, at: 2)), .applied)

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(3)), 1)

        XCTAssertEqual(record(for: shared, work: "turn-3", generation: 3)?.state, .ended)
        XCTAssertEqual(record(for: shared, work: "child", generation: 1)?.state, .working)
        XCTAssertEqual(record(for: shared, work: "turn-5", generation: 5)?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
    }

    func testSupersedeIgnoresAChildsHigherGeneration() {
        let shared = session("s1")
        XCTAssertEqual(model.apply(start("sg-1", session: shared, work: "turn-1", generation: 1, at: 0)), .applied)
        XCTAssertEqual(model.apply(start("sg-2", session: shared, work: "turn-2", generation: 2, at: 1)), .applied)
        XCTAssertEqual(
            model.apply(start("sg-3", session: shared, work: "child", generation: 10, parentWork: "turn-2", at: 2)),
            .applied
        )

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(3)), 1)

        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .ended)
        XCTAssertEqual(
            record(for: shared, work: "turn-2", generation: 2)?.state,
            .working,
            "a child's higher generation must not make the newest main run stale"
        )
        XCTAssertEqual(record(for: shared, work: "child", generation: 10)?.state, .working)
    }

    func testSupersedeIsScopedToOneSessionAndInstance() {
        let shared = session("s1")
        let otherSession = session("s2")
        let otherInstance = SessionIdentity(family: family, instance: "other", session: "s1")

        XCTAssertEqual(model.apply(start("sx-1", session: shared, work: "turn-1", generation: 1, at: 0)), .applied)
        XCTAssertEqual(model.apply(start("sx-2", session: shared, work: "turn-2", generation: 2, at: 1)), .applied)
        XCTAssertEqual(model.apply(start("sx-3", session: otherSession, work: "turn-9", generation: 9, at: 0)), .applied)
        XCTAssertEqual(
            model.apply(
                start(
                    "sx-4",
                    session: otherInstance,
                    work: "turn-9",
                    generation: 9,
                    owner: owner(instanceName: "other"),
                    at: 0
                )
            ),
            .applied
        )

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(2)), 1)

        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .ended)
        XCTAssertEqual(record(for: otherSession, work: "turn-9", generation: 9)?.state, .working)
        XCTAssertEqual(record(for: otherInstance, work: "turn-9", generation: 9)?.state, .working)
    }

    func testSupersedeLeavesWorkObservedAfterTheDateAndIsIdempotent() {
        let shared = session("s1")
        XCTAssertEqual(model.apply(start("sf-1", session: shared, work: "turn-1", generation: 1, at: 10)), .applied)
        XCTAssertEqual(model.apply(start("sf-2", session: shared, work: "turn-2", generation: 2, at: 20)), .applied)
        XCTAssertEqual(
            model.apply(update("sf-3", transition: .completed, session: shared, work: "turn-2", generation: 2, at: 21)),
            .applied
        )

        // The stale record was observed after this date, so this pass cannot
        // end it; the later pass can, and repeating it changes nothing.
        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(5)), 0)
        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .working)

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(30)), 1)
        XCTAssertEqual(record(for: shared, work: "turn-1", generation: 1)?.state, .ended)
        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(30)), 0)
    }

    func testSupersedeSkipsOtherFamilies() {
        let piSession = SessionIdentity(family: "pi", instance: instance, session: "s1")
        model.activate(family: "pi", generation: 1)

        func piEvent(_ id: String, _ work: String, _ generation: UInt64, at offset: TimeInterval) -> ActivityEvent {
            ActivityEvent(
                id: id,
                source: "pi",
                activationGeneration: 1,
                owner: owner(),
                session: piSession,
                transition: .started,
                work: work,
                generation: generation,
                timestamp: date(offset)
            )
        }

        XCTAssertEqual(model.apply(piEvent("pf-1", "turn-1", 1, at: 0)), .applied)
        XCTAssertEqual(model.apply(piEvent("pf-2", "turn-9", 9, at: 1)), .applied)

        XCTAssertEqual(model.supersedeStaleMainRuns(family: family, at: date(10)), 0)
        XCTAssertEqual(record(for: piSession, work: "turn-1", generation: 1)?.state, .working)
        XCTAssertEqual(model.supersedeStaleMainRuns(family: "pi", at: date(10)), 1)
        XCTAssertEqual(record(for: piSession, work: "turn-1", generation: 1)?.state, .ended)
    }

    // MARK: - Observation gaps

    func testGapMakesWorkUncertainAndSnapshotRecovers() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("w1", session: shared, work: "task")), .applied)

        model.recordGap(family: family, instance: instance, session: "s1", reason: .observerLost, at: date(10))
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)

        let listed = snapshot(
            "snap-listed",
            session: shared,
            entries: [entry(shared, work: "task", state: .working)],
            at: 11
        )
        XCTAssertEqual(model.apply(listed), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.gaps.isEmpty)

        model.recordGap(family: family, instance: instance, session: "s1", reason: .observerLost, at: date(20))
        XCTAssertEqual(record(for: shared, work: "task")?.state, .uncertain)

        let omitted = snapshot("snap-omitted", session: shared, entries: [], at: 21)
        XCTAssertEqual(model.apply(omitted), .applied)
        XCTAssertEqual(record(for: shared, work: "task")?.state, .ended)
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertFalse(model.decision.holdAssertion)
    }

    func testUnrelatedSessionSnapshotDoesNotClearAnotherSessionGap() {
        model.recordGap(family: family, instance: instance, session: "first", reason: .observerLost, at: date(10))
        XCTAssertEqual(model.decision.state, .unknown)

        let other = snapshot("snap-other", session: session("second"), entries: [], at: 11)
        XCTAssertEqual(model.apply(other), .applied)

        XCTAssertNotNil(model.gaps[GapKey(family: family, instance: instance, session: "first")])
        XCTAssertEqual(model.decision.state, .unknown)

        let covering = snapshot("snap-first", session: session("first"), entries: [], at: 12)
        XCTAssertEqual(model.apply(covering), .applied)
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testGapBoundCollapsesIntoOneInstanceGap() {
        for index in 0...(ActivityModel.maxGaps + 1) {
            model.recordGap(
                family: family,
                instance: instance,
                session: "g\(index)",
                reason: .observerLost,
                at: date(Double(index))
            )
        }

        let instanceGap = model.gaps[GapKey(family: family, instance: instance, session: nil)]
        XCTAssertNotNil(instanceGap)
        XCTAssertTrue(instanceGap?.reasons.contains(.observerLost) ?? false)
        XCTAssertEqual(instanceGap?.detectedAt, date(0))
        // The collapsed gap plus at most the gaps inserted after the collapse.
        XCTAssertLessThanOrEqual(model.gaps.count, 3)
        XCTAssertEqual(model.decision.state, .unknown)
    }

    /// One noisy instance must not evict everyone else's losses: collapsing
    /// only the inserting scope would leave the table over its bound here.
    func testGapBoundCollapsesDensestInstanceAcrossInstances() {
        let dense = "dense"
        let denseCount = ActivityModel.maxGaps - 4

        for index in 0..<denseCount {
            model.recordGap(
                family: family,
                instance: dense,
                session: "d\(index)",
                reason: .observerLost,
                at: date(Double(index))
            )
        }
        XCTAssertEqual(model.gaps.count, denseCount)

        // These instances each hold a single loss, so collapsing the scope
        // being inserted into would free no room at all.
        for index in 0..<12 {
            model.recordGap(
                family: family,
                instance: "sparse\(index)",
                session: "s\(index)",
                reason: .eventRejected,
                at: date(Double(1_000 + index))
            )
        }

        XCTAssertLessThanOrEqual(model.gaps.count, ActivityModel.maxGaps)
        XCTAssertEqual(Set(model.gaps.values.flatMap { $0.reasons }), [.observerLost, .eventRejected])
        XCTAssertTrue(model.gaps.values.allSatisfy { !$0.reasons.isEmpty })

        let collapsed = model.gaps[GapKey(family: family, instance: dense, session: nil)]
        XCTAssertEqual(collapsed?.reasons, [.observerLost])
        XCTAssertEqual(collapsed?.detectedAt, date(0))
        XCTAssertEqual(model.gaps.filter { $0.key.instance.hasPrefix("sparse") }.count, 12)
    }

    /// Every scope holding a single gap leaves nothing to collapse, so the
    /// oldest losses pair up and the bound still holds.
    func testGapBoundHoldsWithDistinctScopes() {
        let allReasons = Set(GapReason.allCases)
        let total = ActivityModel.maxGaps + 10

        for index in 0..<total {
            model.recordGap(
                family: family,
                instance: "sparse-\(index)",
                session: "s\(index)",
                reason: GapReason.allCases[index % GapReason.allCases.count],
                at: date(Double(index))
            )
            XCTAssertLessThanOrEqual(model.gaps.count, ActivityModel.maxGaps)
        }

        XCTAssertLessThanOrEqual(model.gaps.count, ActivityModel.maxGaps)
        XCTAssertEqual(Set(model.gaps.values.flatMap { $0.reasons }), allReasons)
        XCTAssertTrue(model.gaps.values.allSatisfy { !$0.reasons.isEmpty })
        XCTAssertEqual(model.decision.state, .unknown)
    }

    // MARK: - Activation

    func testDeactivateRemovesContributionAndStaleGenerationsAreIgnored() {
        let shared = session("s1")
        XCTAssertEqual(apply(start("d1", session: shared, work: "task")), .applied)
        XCTAssertEqual(model.decision.state, .working)

        model.deactivate(family: family)
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(model.decision.state, .idle)

        model.activate(family: family, generation: 2)
        let stale = start("d2", session: shared, work: "task", activationGeneration: 1)
        XCTAssertEqual(model.apply(stale), .ignored(.staleActivation))
        XCTAssertEqual(model.decision.state, .idle)

        let fresh = start("d3", session: shared, work: "task", activationGeneration: 2)
        XCTAssertEqual(model.apply(fresh), .applied)
        XCTAssertEqual(model.decision.state, .working)
    }

    // MARK: - Bounds

    func testCapacityBoundKeepsWorksBoundedAndRecordsGap() {
        for index in 0..<(ActivityModel.maxWorks + 2) {
            _ = model.apply(
                start("cap-\(index)", session: session("s1"), work: "work-\(index)", at: Double(index))
            )
        }

        XCTAssertLessThanOrEqual(model.works.count, ActivityModel.maxWorks)
        XCTAssertTrue(model.gaps.values.contains { $0.reasons.contains(.capacityExceeded) })
    }

    func testOversizedSnapshotIsRejectedWithCapacityGap() {
        let shared = session("s1")
        let entries = (0..<(ActivityModel.maxWorks + 1)).map {
            entry(shared, work: "work-\($0)", state: .working)
        }

        XCTAssertEqual(model.apply(snapshot("snap-huge", session: shared, entries: entries)), .ignored(.invalidSnapshot))
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(
            model.gaps[GapKey(family: family, instance: instance, session: nil)]?.reasons,
            [.capacityExceeded]
        )
        XCTAssertEqual(model.decision.state, .unknown)
    }

    // MARK: - Decision

    func testDecisionOrderAndReasonDeterminism() throws {
        let first = session("one")
        let second = session("two")

        // Waiting for user.
        XCTAssertEqual(apply(start("dec-wait", session: first, work: "wait", at: 0)), .applied)
        XCTAssertEqual(apply(update("dec-wait-2", transition: .humanWait, session: first, work: "wait", at: 1)), .applied)
        XCTAssertEqual(model.decision.state, .waitingForUser)

        // A gap outranks waiting for user while still naming the waiting work.
        model.recordGap(family: family, instance: instance, session: "three", reason: .observerLost, at: date(2))
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertTrue(model.decision.reasons.contains { $0.hasSuffix("wait is waitingForUser") })
        XCTAssertTrue(model.decision.reasons.contains { $0.hasPrefix("no observation for") })

        // Uncertain work outranks a gap.
        XCTAssertEqual(apply(start("dec-loose", session: second, work: "loose", at: 3)), .applied)
        model.recordGap(family: family, instance: instance, session: "two", reason: .observerLost, at: date(4))
        XCTAssertEqual(record(for: second, work: "loose")?.state, .uncertain)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertTrue(model.decision.holdAssertion)

        // Confirmed work outranks uncertainty.
        XCTAssertEqual(apply(start("dec-live", session: first, work: "live", at: 5)), .applied)
        XCTAssertEqual(model.decision.state, .working)

        let encoded = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ActivityModel.self, from: encoded)
        XCTAssertEqual(decoded.decision, model.decision)

        // The same holds once every state is gone and only gaps remain.
        XCTAssertEqual(apply(update("dec-live-done", transition: .completed, session: first, work: "live", at: 6)), .applied)
        XCTAssertEqual(model.decision.state, .uncertain)
        XCTAssertEqual(
            try JSONDecoder().decode(ActivityModel.self, from: JSONEncoder().encode(model)).decision,
            model.decision
        )
    }

    // MARK: - Fixtures

    private func apply(_ event: ActivityEvent) -> ApplyOutcome {
        model.apply(event)
    }

    private func record(for session: SessionIdentity, work: String, generation: UInt64 = 1) -> WorkRecord? {
        model.works[WorkIdentity(session: session, generation: generation, work: work)]
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func session(_ name: String) -> SessionIdentity {
        SessionIdentity(family: family, instance: instance, session: name)
    }

    private func owner(
        bootID: String = "boot-1",
        pid: Int32 = 42,
        startMicros: UInt64 = 1_000,
        instanceName: String? = nil
    ) -> OwnerIdentity {
        OwnerIdentity(
            bootID: bootID,
            pid: pid,
            startTimeMicros: startMicros,
            uid: 501,
            instance: instanceName ?? instance
        )
    }

    private func start(
        _ id: String,
        session: SessionIdentity,
        work: String,
        generation: UInt64 = 1,
        parentWork: String? = nil,
        owner: OwnerIdentity? = nil,
        activationGeneration: UInt64 = 1,
        at offset: TimeInterval = 0
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            source: family,
            activationGeneration: activationGeneration,
            owner: owner ?? self.owner(),
            session: session,
            transition: .started,
            work: work,
            generation: generation,
            parentWork: parentWork,
            timestamp: date(offset)
        )
    }

    private func update(
        _ id: String,
        transition: ActivityTransition,
        session: SessionIdentity,
        work: String,
        generation: UInt64 = 1,
        parentWork: String? = nil,
        owner: OwnerIdentity? = nil,
        activationGeneration: UInt64 = 1,
        at offset: TimeInterval = 0
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            source: family,
            activationGeneration: activationGeneration,
            owner: owner ?? self.owner(),
            session: session,
            transition: transition,
            work: work,
            generation: generation,
            parentWork: parentWork,
            timestamp: date(offset)
        )
    }

    private func heartbeat(
        _ id: String,
        session: SessionIdentity,
        work: String,
        generation: UInt64 = 1,
        owner: OwnerIdentity? = nil,
        at offset: TimeInterval = 0
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            source: family,
            activationGeneration: 1,
            owner: owner ?? self.owner(),
            session: session,
            transition: .heartbeat,
            work: work,
            generation: generation,
            timestamp: date(offset)
        )
    }

    private func entry(
        _ session: SessionIdentity,
        work: String,
        generation: UInt64 = 1,
        state: WorkState
    ) -> SnapshotEntry {
        SnapshotEntry(
            session: session,
            work: work,
            generation: generation,
            parentWork: nil,
            state: state
        )
    }

    private func snapshot(
        _ id: String,
        session: SessionIdentity,
        entries: [SnapshotEntry],
        at offset: TimeInterval = 0,
        scope: SnapshotScope = .session,
        snapshotComplete: Bool = true,
        owner: OwnerIdentity? = nil
    ) -> ActivityEvent {
        ActivityEvent(
            id: id,
            source: family,
            activationGeneration: 1,
            owner: owner ?? self.owner(),
            session: session,
            transition: .snapshot,
            timestamp: date(offset),
            scope: scope,
            snapshotEntries: entries,
            snapshotComplete: snapshotComplete
        )
    }
}
