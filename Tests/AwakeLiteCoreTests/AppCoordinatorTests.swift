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

    @discardableResult
    private func makeCoordinator(
        interval: TimeInterval = 0,
        decisionHandler: ((AggregateDecision) -> Void)? = nil
    ) -> AppCoordinator {
        let coordinator = AppCoordinator(
            configuration: AppCoordinator.Configuration(
                appSupportRoot: support,
                catalogRoot: IntegrationFixtures.shippedIntegrationsRoot,
                helperPath: IntegrationPaths.helperPath,
                reconcileInterval: interval
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
        generation: UInt64 = 1
    ) throws -> Int32 {
        var lines: [String] = []
        let code = HelperRunner.run(
            arguments: [
                "--family", "omp",
                "--target", "omp.cli",
                "--generation", String(generation),
                "--event", event
            ],
            stdin: try HelperFixtures.payload(payload),
            appSupportRoot: support,
            adapters: [OMPAdapter()],
            now: Date(),
            owner: owner
        ) { lines.append($0) }
        XCTAssertEqual(lines, [], "\(event) should not produce a diagnostic")
        return code
    }
}
