import Foundation
import XCTest
@testable import AwakeLiteCore

final class AppCoordinatorTests: XCTestCase {
    private var sandbox: URL!
    private var support: URL!
    private var coordinator: AppCoordinator?
    private var decisions: [AggregateDecision] = []
    private var diagnostics: [String] = []

    private let owner = OwnerIdentityProbe.identity(pid: getpid())

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try IntegrationFixtures.makeSandbox()
        support = sandbox.appendingPathComponent("support", isDirectory: true)
        decisions = []
        diagnostics = []
    }

    override func tearDownWithError() throws {
        coordinator?.stop()
        coordinator = nil
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        support = nil
        try super.tearDownWithError()
    }

    // MARK: - Startup

    func testDisabledOMPRunsNoObserverAndDeliversIdle() {
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertNil(coordinator.activationState?.generation(for: "omp"))
        XCTAssertEqual(
            decisions.last?.state,
            .idle,
            "diagnostic=\(coordinator.lastDiagnostic ?? "nil") decisions=\(decisions.map(\.state.rawValue))"
        )
        XCTAssertEqual(decisions.last?.holdAssertion, false)
    }

    func testActiveOMPStartsObservation() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(coordinator.activationState?.generation(for: "omp"), 1)
        XCTAssertTrue(coordinator.isObserving)
        XCTAssertEqual(decisions.last?.state, .idle)
    }

    func testUnresolvedJournalStopsObservationOnActivationRefresh() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()
        XCTAssertTrue(coordinator.isObserving)

        try HelperFixtures.writeJournal(family: "omp", stage: .recoveryRequired, root: support)
        coordinator.activationChanged()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertNotNil(coordinator.activationState?.unresolvedOperation(for: "omp"))
        XCTAssertNotNil(coordinator.lastDiagnostic)
    }

    func testCorruptCheckpointIsNotReplacedWithAnEmptyModel() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let checkpoint = support.appendingPathComponent("checkpoint.json")
        try Data("not a checkpoint".utf8).write(to: checkpoint)

        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertEqual(decisions.last?.state, .unknown)
        XCTAssertEqual(decisions.last?.holdAssertion, false)
        XCTAssertNotNil(coordinator.lastDiagnostic)
        XCTAssertEqual(try String(contentsOf: checkpoint, encoding: .utf8), "not a checkpoint")
    }

    // MARK: - Events

    func testStartAndFinishDriveDecisionAndPersistCheckpoint() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(
            try emit("agent_start", payload: ["session": "s1", "workGeneration": 1, "agentKind": "main"]),
            0
        )
        coordinator.reconcileNow()

        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        XCTAssertEqual(
            try emit("session_stop", payload: ["session": "s1", "workGeneration": 1, "agentKind": "main"]),
            0
        )
        coordinator.reconcileNow()

        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(model.decision.state, .idle)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 0)
    }

    func testHumanWaitReleasesAndResumeHoldsAgain() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        _ = try emit("agent_start", payload: ["session": "s2", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)

        _ = try emit("tool_approval_requested", payload: ["session": "s2", "workGeneration": 1])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .waitingForUser)
        XCTAssertEqual(decisions.last?.holdAssertion, false)

        _ = try emit("tool_approval_resolved", payload: ["session": "s2", "workGeneration": 1])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)
    }

    // MARK: - Activation changes

    func testRemovalDeactivatesAndStopsObservation() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()
        XCTAssertTrue(coordinator.isObserving)

        _ = try emit("agent_start", payload: ["session": "s3", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)

        try FileManager.default.removeItem(
            at: support.appendingPathComponent("receipts/omp.json")
        )
        coordinator.activationChanged()

        XCTAssertFalse(coordinator.isObserving)
        XCTAssertNil(coordinator.activationState?.generation(for: "omp"))
        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)
        XCTAssertTrue(try LocalEventStore(root: support).loadModel().activeGenerations.isEmpty)
    }

    func testReinstallMovesObservationToTheNewGeneration() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        _ = try emit("agent_start", payload: ["session": "s4", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)

        try HelperFixtures.activate(family: "omp", generation: 2, root: support)
        coordinator.activationChanged()

        XCTAssertEqual(coordinator.activationState?.generation(for: "omp"), 2)
        XCTAssertTrue(coordinator.isObserving)
        XCTAssertEqual(decisions.last?.state, .idle, "old-generation work is dropped")
        XCTAssertEqual(try LocalEventStore(root: support).loadModel().activeGenerations["omp"], 2)
    }

    // MARK: - Owner liveness

    func testDeadOwnerRetiresWorkAndRecomputesDecision() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        var dead = false
        let coordinator = makeCoordinator(liveness: OwnerLiveness { _ in dead })
        coordinator.start()

        _ = try emit("agent_start", payload: ["session": "s7", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()

        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)
        XCTAssertEqual(try LocalEventStore(root: support).loadModel().activeOwners.count, 1)

        dead = true
        coordinator.reconcileNow()

        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)
        let retired = try LocalEventStore(root: support).loadModel()
        XCTAssertTrue(retired.activeOwners.isEmpty)
        XCTAssertEqual(retired.works.values.filter { $0.state.isActive }.count, 0)
        XCTAssertEqual(retired.decision.state, .idle)

        // The next task is observed normally after the retirement.
        dead = false
        _ = try emit("agent_start", payload: ["session": "s8", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        _ = try emit("session_stop", payload: ["session": "s8", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)
    }

    func testSuppliedLiveOwnerIsNotReleased() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        let supplied = (instance: "p\(getpid())-supplied", pid: getpid())
        _ = try emit(
            "agent_start",
            payload: ["session": "s9", "workGeneration": 1, "agentKind": "main"],
            suppliedOwner: supplied
        )
        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        coordinator.reconcileNow()
        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(model.activeOwners.count, 1)
        XCTAssertEqual(model.activeOwners.first?.startTimeMicros, 0)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 1)
    }

    func testSuppliedDeadOwnerIsEndedByReconcile() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let coordinator = makeCoordinator()
        coordinator.start()

        let pid = try DeadProcess.pid()
        _ = try emit(
            "agent_start",
            payload: ["session": "s10", "workGeneration": 1, "agentKind": "main"],
            suppliedOwner: ("p\(pid)-dead", pid)
        )
        coordinator.reconcileNow()

        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)
        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertTrue(model.activeOwners.isEmpty)
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 0)
        XCTAssertEqual(model.decision.state, .idle)
    }

    // MARK: - Orphaned run supersede

    func testStartupSupersedeEndsOrphanedRunAfterNewerCompletion() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let seeded = try seedOrphanCheckpoint()
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(decisions.last?.state, .idle)
        XCTAssertEqual(decisions.last?.holdAssertion, false)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 1, work: "turn-1")]?.state,
            .ended
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 2, work: "turn-2")]?.state,
            .completed
        )
        XCTAssertEqual(model.works.values.filter { $0.state.isActive }.count, 0)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testStartupSupersedeKeepsANewerActiveRun() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let seeded = try seedOrphanCheckpoint(newerCompleted: false)
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 1, work: "turn-1")]?.state,
            .ended
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 2, work: "turn-2")]?.state,
            .working,
            "the live supplied owner keeps the newest run"
        )
    }

    func testStartupSupersedeLeavesChildWorkAlone() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let seeded = try seedOrphanCheckpoint(childGeneration: 1)
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 1, work: "turn-1")]?.state,
            .ended
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 1, work: "child")]?.state,
            .working
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 2, work: "turn-2")]?.state,
            .completed
        )
    }

    func testStartupSupersedeIgnoresHigherChildGeneration() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let seeded = try seedOrphanCheckpoint(childGeneration: 10, newerCompleted: false)
        let coordinator = makeCoordinator()
        coordinator.start()

        XCTAssertEqual(decisions.last?.state, .working)
        XCTAssertEqual(decisions.last?.holdAssertion, true)

        let model = try LocalEventStore(root: support).loadModel()
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 1, work: "turn-1")]?.state,
            .ended
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 2, work: "turn-2")]?.state,
            .working,
            "a child's higher generation must not end the newest main run"
        )
        XCTAssertEqual(
            model.works[WorkIdentity(session: seeded.session, generation: 10, work: "child")]?.state,
            .working
        )
    }

    // MARK: - Real IOKit

    func testRealAssertionFollowsCoordinatorDecisions() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let power = PowerPolicy()
        let coordinator = makeCoordinator { decision in
            power.update(decision: decision, paused: false)
        }
        coordinator.start()
        XCTAssertEqual(power.status, .idle)

        _ = try emit("agent_start", payload: ["session": "s5", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(power.status, .held)

        if case .failedAcquire = power.status {
            throw XCTSkip("IOKit refused the real assertion")
        }

        _ = try emit("session_stop", payload: ["session": "s5", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(power.status, .idle)

        // Pause releases while the decision stays working; unpause reapplies it.
        _ = try emit("agent_start", payload: ["session": "s6", "workGeneration": 1, "agentKind": "main"])
        coordinator.reconcileNow()
        XCTAssertEqual(power.status, .held)
        let working = try XCTUnwrap(decisions.last)
        power.update(decision: working, paused: true)
        XCTAssertEqual(power.status, .idle)
        power.update(decision: working, paused: false)
        XCTAssertEqual(power.status, .held)

        power.releaseAll()
        XCTAssertEqual(power.status, .idle)
    }

    // MARK: - Helpers

    /// Saves a checkpoint whose session holds an older active main run and a
    /// newer run, both owned by a live supplied owner. The startup pass must
    /// end only the older main run.
    @discardableResult
    private func seedOrphanCheckpoint(
        childGeneration: UInt64? = nil,
        newerCompleted: Bool = true
    ) throws -> (owner: OwnerIdentity, session: SessionIdentity) {
        let supplied = OwnerIdentityProbe.supplied(instance: "p\(getpid())-test", pid: getpid())
        let session = SessionIdentity(family: "omp", instance: supplied.instance, session: "s1")
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        func event(
            _ id: String,
            _ transition: ActivityTransition,
            _ work: String,
            generation: UInt64,
            parentWork: String? = nil,
            offset: TimeInterval
        ) -> ActivityEvent {
            ActivityEvent(
                id: id,
                source: "omp",
                activationGeneration: 1,
                owner: supplied,
                session: session,
                transition: transition,
                work: work,
                generation: generation,
                parentWork: parentWork,
                timestamp: base.addingTimeInterval(offset)
            )
        }

        var seeded = ActivityModel()
        seeded.activate(family: "omp", generation: 1)
        XCTAssertEqual(seeded.apply(event("seed-old", .started, "turn-1", generation: 1, offset: 0)), .applied)
        if let childGeneration {
            XCTAssertEqual(
                seeded.apply(
                    event("seed-child", .started, "child", generation: childGeneration, parentWork: "turn-1", offset: 1)
                ),
                .applied
            )
        }
        XCTAssertEqual(seeded.apply(event("seed-new", .started, "turn-2", generation: 2, offset: 1)), .applied)
        if newerCompleted {
            XCTAssertEqual(
                seeded.apply(event("seed-new-done", .completed, "turn-2", generation: 2, offset: 2)),
                .applied
            )
        }
        try LocalEventStore(root: support).saveModel(seeded)
        return (supplied, session)
    }

    @discardableResult
    private func makeCoordinator(
        interval: TimeInterval = 0,
        liveness: OwnerLiveness = .system(),
        decisionHandler: ((AggregateDecision) -> Void)? = nil
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            configuration: AppCoordinator.Configuration(
                appSupportRoot: support,
                catalogRoot: IntegrationFixtures.shippedIntegrationsRoot,
                helperPath: IntegrationPaths.helperPath,
                reconcileInterval: interval,
                ownerLiveness: liveness
            ),
            decisionHandler: { [weak self] decision in
                self?.decisions.append(decision)
                decisionHandler?(decision)
            },
            diagnosticHandler: { [weak self] text in
                if let text { self?.diagnostics.append(text) }
            }
        )
        self.coordinator = coordinator
        return coordinator
    }

    @discardableResult
    private func emit(
        _ event: String,
        payload: [String: Any],
        generation: UInt64 = 1,
        suppliedOwner: (instance: String, pid: Int32)? = nil
    ) throws -> Int32 {
        var arguments = [
            "--family", "omp",
            "--target", "omp.cli",
            "--generation", String(generation),
            "--event", event
        ]
        if let suppliedOwner {
            arguments += [
                "--owner-instance", suppliedOwner.instance,
                "--owner-pid", String(suppliedOwner.pid)
            ]
        }
        var lines: [String] = []
        let code = HelperRunner.run(
            arguments: arguments,
            stdin: try HelperFixtures.payload(payload),
            appSupportRoot: support,
            adapters: [OMPAdapter()],
            now: Date(),
            owner: suppliedOwner == nil ? owner : nil
        ) { lines.append($0) }
        XCTAssertEqual(lines, [], "\(event) should not produce a diagnostic")
        return code
    }
}
