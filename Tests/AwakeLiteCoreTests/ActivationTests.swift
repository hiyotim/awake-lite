import XCTest
@testable import AwakeLiteCore

/// Unit 2.4: activation-generation handoff and inactive-package behavior.
final class ActivationTests: XCTestCase {
    private struct SimulatedCrash: Error {}

    private var sandbox: URL!
    private var home: URL!
    private var support: URL!
    private var applications: URL!
    private var catalog: Catalog!
    private var installer: Installer!

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = try IntegrationFixtures.makeSandbox()
        home = sandbox.appendingPathComponent("home", isDirectory: true)
        support = sandbox.appendingPathComponent("support", isDirectory: true)
        applications = sandbox.appendingPathComponent("applications", isDirectory: true)
        for directory in [home, applications] {
            try FileManager.default.createDirectory(
                at: directory!,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        catalog = try IntegrationFixtures.bundledCatalog()
        installer = Installer(catalog: catalog)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        sandbox = nil
        home = nil
        support = nil
        applications = nil
        catalog = nil
        installer = nil
        try super.tearDownWithError()
    }

    // MARK: - Committed receipts

    func testCommittedReceiptActivatesAndOtherGenerationsAreRejected() throws {
        let receipt = try install("claude-code")
        XCTAssertEqual(receipt.activationGeneration, 1)

        var model = ActivityModel()
        let handoff = ActivationHandoff(appSupportRoot: support)
        let state = try handoff.apply(to: &model)

        XCTAssertEqual(state.active, [ActiveFamily(family: "claude-code", generation: 1)])
        XCTAssertTrue(state.inactive.isEmpty)
        XCTAssertTrue(state.unresolved.isEmpty)
        XCTAssertEqual(state.generation(for: "claude-code"), 1)
        XCTAssertEqual(model.activeGenerations, ["claude-code": 1])

        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "e1")),
            .applied
        )
        XCTAssertEqual(model.works.count, 1)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 2, id: "e2")),
            .ignored(.staleActivation)
        )
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 0, id: "e3")),
            .ignored(.staleActivation)
        )
        XCTAssertEqual(model.works.count, 1, "rejected events must not register work")
    }

    func testHandoffWritesNothing() throws {
        _ = try install("claude-code")
        let before = tree(support)
        var model = ActivityModel()

        let state = try ActivationHandoff(appSupportRoot: support).apply(to: &model)

        XCTAssertFalse(state.active.isEmpty)
        XCTAssertEqual(tree(support), before, "activation must not write")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("inbox").path),
            "activation must not write events"
        )
    }

    func testAbsentStorageRootIsInactiveWithoutThrowing() throws {
        var model = ActivityModel()
        model.activate(family: "claude-code", generation: 3)
        let handoff = ActivationHandoff(appSupportRoot: sandbox.appendingPathComponent("absent"))

        let state = try handoff.apply(to: &model)

        XCTAssertTrue(state.active.isEmpty)
        XCTAssertTrue(state.inactive.isEmpty)
        XCTAssertTrue(state.unresolved.isEmpty)
        XCTAssertNil(model.activeGenerations["claude-code"])
    }

    // MARK: - Removal and reinstall

    func testRemovalDeactivatesAndRejectsOldGeneration() throws {
        _ = try install("claude-code")
        var model = ActivityModel()
        let handoff = ActivationHandoff(appSupportRoot: support)
        _ = try handoff.apply(to: &model)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "work-1")),
            .applied
        )
        XCTAssertEqual(model.works.count, 1)

        _ = try installer.remove(family: "claude-code", appSupportRoot: support)
        let state = try handoff.apply(to: &model)

        XCTAssertTrue(state.active.isEmpty)
        XCTAssertNil(model.activeGenerations["claude-code"])
        XCTAssertTrue(model.works.isEmpty, "removal drops the family's work")
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "late-after-removal")),
            .ignored(.inactiveSource)
        )
        XCTAssertTrue(model.works.isEmpty)
    }

    func testRevokeDropsWorkAfterRemoval() throws {
        _ = try install("claude-code")
        var model = ActivityModel()
        let handoff = ActivationHandoff(appSupportRoot: support)
        _ = try handoff.apply(to: &model)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "work-1")),
            .applied
        )

        _ = try installer.remove(family: "claude-code", appSupportRoot: support)
        let state = try handoff.revoke(family: "claude-code", in: &model)

        XCTAssertTrue(state.isActive("claude-code") == false)
        XCTAssertNil(model.activeGenerations["claude-code"])
        XCTAssertTrue(model.works.isEmpty)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "late")),
            .ignored(.inactiveSource)
        )
    }

    func testRevokeRefusesWhileStillInstalled() throws {
        _ = try install("claude-code")
        var model = ActivityModel()
        let handoff = ActivationHandoff(appSupportRoot: support)
        _ = try handoff.apply(to: &model)

        XCTAssertThrowsError(try handoff.revoke(family: "claude-code", in: &model)) { error in
            guard case .conflict(let summary)? = error as? InstallerError else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertTrue(summary.contains("claude-code"))
        }
        XCTAssertEqual(model.activeGenerations["claude-code"], 1, "a refused revoke changes nothing")
    }

    func testReinstallIssuesNewGenerationAndLateOldEventsAreRejected() throws {
        _ = try install("claude-code")
        var model = ActivityModel()
        let handoff = ActivationHandoff(appSupportRoot: support)
        _ = try handoff.apply(to: &model)
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "old-work")),
            .applied
        )
        XCTAssertEqual(model.works.count, 1)

        let second = try install("claude-code")
        XCTAssertEqual(second.activationGeneration, 2)
        let state = try handoff.apply(to: &model)

        XCTAssertEqual(state.generation(for: "claude-code"), 2)
        XCTAssertEqual(model.activeGenerations["claude-code"], 2)
        XCTAssertTrue(model.works.isEmpty, "work from the previous generation is dropped")

        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "late-old-event")),
            .ignored(.staleActivation)
        )
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 2, id: "current-event")),
            .applied
        )
        XCTAssertEqual(model.works.count, 1)
    }

    // MARK: - Inactive packages

    func testFamilyWithoutCommittedReceiptIsInactiveAndObservesNothing() throws {
        _ = try install("claude-code")
        var model = ActivityModel()
        // A stale checkpoint could still hold an activation for a package that
        // is not installed; the handoff must drop it.
        model.activate(family: "codex", generation: 7)

        let state = try ActivationHandoff(appSupportRoot: support).apply(to: &model)

        XCTAssertEqual(state.active.map(\.family), ["claude-code"])
        XCTAssertNil(model.activeGenerations["codex"])
        XCTAssertEqual(
            model.apply(event(family: "codex", generation: 7, id: "codex-1")),
            .ignored(.inactiveSource)
        )
        XCTAssertTrue(model.works.isEmpty, "an inactive package registers no observation")
        XCTAssertTrue(model.gaps.isEmpty)
        XCTAssertTrue(model.recentEventIDs.isEmpty)
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testUnresolvedOperationsNeverActivate() throws {
        for scenario in UnresolvedScenario.allCases {
            let fresh = try IntegrationFixtures.makeSandbox()
            defer { try? FileManager.default.removeItem(at: fresh) }
            let freshHome = fresh.appendingPathComponent("home", isDirectory: true)
            let freshSupport = fresh.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: freshHome, withIntermediateDirectories: true)

            let clean = Installer(catalog: catalog)
            func preview() throws -> InstallPreview {
                try clean.preview(
                    family: "claude-code",
                    configRoot: freshHome,
                    appSupportRoot: freshSupport,
                    discovery: ProductDiscovery(homeRoot: freshHome, applicationRoots: [applications])
                )
            }

            // A committed generation 1 exists, then a reinstall is interrupted.
            _ = try clean.apply(try preview())
            let crashed = Installer(catalog: catalog, faults: { point in
                if point == scenario.faultPoint { throw SimulatedCrash() }
            })
            XCTAssertThrowsError(try crashed.apply(try preview()), "scenario \(scenario)")

            let settings = freshHome.appendingPathComponent(".claude/settings.json")
            var savedBytes: Data?
            if scenario == .recoveryRequired {
                savedBytes = try Data(contentsOf: settings)
                var object = try IntegrationFixtures.jsonObject(settings)
                object["userEdit"] = "made after the interruption"
                try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
                    .write(to: settings)
                let reports = try clean.recoverPending(appSupportRoot: freshSupport)
                XCTAssertEqual(reports.first?.outcome, .recoveryRequired)
            }

            let handoff = ActivationHandoff(appSupportRoot: freshSupport)
            let state = try handoff.readState()
            XCTAssertTrue(state.active.isEmpty, "scenario \(scenario): must not activate")
            XCTAssertEqual(state.inactive, ["claude-code"])
            let unresolved = try XCTUnwrap(
                state.unresolvedOperation(for: "claude-code"),
                "scenario \(scenario): unresolved operation must be reported"
            )
            XCTAssertEqual(unresolved.stage, scenario.expectedStage)
            XCTAssertFalse(unresolved.operationId.isEmpty)

            var model = ActivityModel()
            _ = try handoff.apply(to: &model)
            XCTAssertNil(model.activeGenerations["claude-code"])
            XCTAssertEqual(
                model.apply(event(family: "claude-code", generation: 1, id: "g1-\(scenario)")),
                .ignored(.inactiveSource)
            )
            XCTAssertEqual(
                model.apply(event(family: "claude-code", generation: 2, id: "g2-\(scenario)")),
                .ignored(.inactiveSource)
            )

            // Recovery restores activation at the surviving generation.
            if let savedBytes {
                try savedBytes.write(to: settings)
            }
            let reports = try clean.recoverPending(appSupportRoot: freshSupport)
            XCTAssertNotEqual(reports.first?.outcome, .recoveryRequired, "scenario \(scenario)")
            let recovered = try handoff.apply(to: &model)
            XCTAssertEqual(recovered.generation(for: "claude-code"), 1, "scenario \(scenario)")
            XCTAssertEqual(model.activeGenerations["claude-code"], 1)
            XCTAssertEqual(
                model.apply(event(family: "claude-code", generation: 1, id: "after-\(scenario)")),
                .applied
            )
        }
    }

    func testUnresolvedOperationDoesNotAffectOtherFamilies() throws {
        _ = try install("claude-code")
        _ = try install("pi")

        let crashed = Installer(catalog: catalog, faults: { point in
            if point == .beforeStep(0) { throw SimulatedCrash() }
        })
        let piPreview = try installer.preview(
            family: "pi",
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertThrowsError(try crashed.apply(piPreview))

        var model = ActivityModel()
        let state = try ActivationHandoff(appSupportRoot: support).apply(to: &model)

        XCTAssertEqual(state.active, [ActiveFamily(family: "claude-code", generation: 1)])
        XCTAssertEqual(state.inactive, ["pi"])
        XCTAssertEqual(state.unresolvedOperation(for: "pi")?.family, "pi")
        XCTAssertNil(state.unresolvedOperation(for: "claude-code"))

        XCTAssertEqual(
            model.apply(event(family: "pi", generation: 1, id: "pi-1")),
            .ignored(.inactiveSource)
        )
        XCTAssertEqual(
            model.apply(event(family: "claude-code", generation: 1, id: "claude-1")),
            .applied
        )
    }

    // MARK: - Scenarios and helpers

    private enum UnresolvedScenario: String, CaseIterable {
        case prepared
        case applying
        case recoveryRequired

        var faultPoint: InstallerFaultPoint {
            switch self {
            case .prepared: return .journalWritten
            case .applying: return .beforeStep(0)
            case .recoveryRequired: return .beforeStep(1)
            }
        }

        var expectedStage: InstallStage {
            switch self {
            case .prepared: return .prepared
            case .applying: return .applying
            case .recoveryRequired: return .recoveryRequired
            }
        }
    }

    private func discovery() -> ProductDiscovery {
        ProductDiscovery(homeRoot: home, applicationRoots: [applications])
    }

    private func makePreview(_ family: String) throws -> InstallPreview {
        let preview = try installer.preview(
            family: family,
            configRoot: home,
            appSupportRoot: support,
            discovery: discovery()
        )
        XCTAssertTrue(preview.conflicts.isEmpty, "\(family): \(preview.conflicts)")
        return preview
    }

    @discardableResult
    private func install(_ family: String) throws -> InstallReceipt {
        try installer.apply(try makePreview(family))
    }

    private func event(
        family: String,
        generation: UInt64,
        id: String,
        transition: ActivityTransition = .started,
        work: String = "work-1",
        at offset: TimeInterval = 0
    ) -> ActivityEvent {
        let instance = "\(family)-instance"
        return ActivityEvent(
            id: id,
            source: family,
            activationGeneration: generation,
            owner: OwnerIdentity(
                bootID: "boot-1",
                pid: 4711,
                startTimeMicros: 1,
                uid: 501,
                instance: instance
            ),
            session: SessionIdentity(family: family, instance: instance, session: "session-1"),
            transition: transition,
            work: work,
            generation: 1,
            timestamp: epoch.addingTimeInterval(offset)
        )
    }

    private func tree(_ root: URL) -> Set<String> {
        var result: Set<String> = [root.path]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                result.insert(url.path)
            }
        }
        return result
    }
}
