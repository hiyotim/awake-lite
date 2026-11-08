import Darwin
import XCTest
@testable import AwakeLiteCore

/// Unit 3.1: helper ingestion, adapter fixtures, allowlist normalization, and
/// activation gating.
final class HelperIngestTests: XCTestCase {
    private var sandbox: URL!
    private var support: URL!

    private let adapters: [HookAdapter] = [FixtureAdapter()]

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

    private func arguments(
        event: String = "start",
        family: String = HelperFixtures.family,
        target: String = HelperFixtures.target,
        generation: UInt64 = 1,
        extra: [String] = []
    ) -> [String] {
        [
            "--family", family,
            "--target", target,
            "--generation", String(generation),
            "--event", event
        ] + extra
    }

    private func emit(
        _ arguments: [String],
        payload: Data = Data(),
        root: URL? = nil,
        adapters: [HookAdapter]? = nil,
        now: Date = HelperFixtures.epoch,
        owner: OwnerIdentity? = OwnerIdentityProbe.identity(pid: getpid())
    ) -> (code: Int32, lines: [String]) {
        var lines: [String] = []
        let code = HelperRunner.run(
            arguments: arguments,
            stdin: payload,
            appSupportRoot: root ?? support,
            adapters: adapters ?? self.adapters,
            now: now,
            owner: owner
        ) { lines.append($0) }
        return (code, lines)
    }

    /// Drives the shipped registry (`HookAdapterRegistry.all`) instead of an
    /// injected fixture adapter.
    private func emitWithRegistry(
        family: String,
        target: String,
        event: String,
        generation: UInt64,
        payload: [String: Any],
        root: URL
    ) throws -> HelperOutcome {
        HelperRunner.execute(
            arguments: [
                "--family", family,
                "--target", target,
                "--generation", String(generation),
                "--event", event
            ],
            stdin: try HelperFixtures.payload(payload),
            appSupportRoot: root,
            adapters: HookAdapterRegistry.all,
            now: HelperFixtures.epoch,
            owner: OwnerIdentityProbe.identity(pid: getpid())
        )
    }

    // MARK: - Success path

    func testSuccessWritesExactlyOneEventWithExpectedFields() throws {
        let receipt = try HelperFixtures.activate(root: support)
        let owner = OwnerIdentityProbe.identity(pid: getpid())
        let now = HelperFixtures.epoch

        let result = emit(
            arguments(),
            payload: try HelperFixtures.documentedPayload(),
            now: now
        )

        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.lines.isEmpty, "a successful emission must stay silent on stderr")

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].deletingLastPathComponent().lastPathComponent, "inbox")

        let event = try HelperFixtures.decodeEvent(files[0])
        XCTAssertEqual(event.schema, ActivityEvent.currentSchema)
        XCTAssertEqual(event.source, HelperFixtures.family)
        XCTAssertEqual(event.activationGeneration, receipt.activationGeneration)
        XCTAssertEqual(event.target, HelperFixtures.target)
        XCTAssertEqual(event.owner, owner)
        XCTAssertEqual(event.session.family, HelperFixtures.family)
        XCTAssertEqual(event.session.instance, owner.instance)
        XCTAssertEqual(event.session.session, "session-1")
        XCTAssertEqual(event.transition, .started)
        XCTAssertEqual(event.work, "work-1")
        XCTAssertEqual(event.generation, 7)
        XCTAssertEqual(event.sequence, 42)
        XCTAssertNil(event.parentWork)
        XCTAssertEqual(event.timestamp, now)
        XCTAssertFalse(event.snapshotComplete)
        XCTAssertNil(event.scope)
        XCTAssertNil(event.snapshotEntries)

        // The file itself is the store's, not the helper's invention.
        XCTAssertEqual(
            files[0].lastPathComponent,
            EventFileName.make(event: event, at: event.timestamp)
        )
    }

    func testSecondEmissionWritesASecondDistinctFile() throws {
        try HelperFixtures.activate(root: support)

        XCTAssertEqual(emit(arguments(), payload: try HelperFixtures.documentedPayload()).code, 0)
        XCTAssertEqual(
            emit(
                arguments(event: "finish"),
                payload: try HelperFixtures.documentedPayload(),
                now: HelperFixtures.epoch.addingTimeInterval(1)
            ).code,
            0
        )

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 2)
        XCTAssertNotEqual(files[0].lastPathComponent, files[1].lastPathComponent)

        let events = try files.map { try HelperFixtures.decodeEvent($0) }
        XCTAssertEqual(Set(events.map(\.id)).count, 2, "each emission needs its own event id")
        XCTAssertEqual(Set(events.map(\.transition)), [.started, .completed])
    }

    func testIdentifiersAreCanonicalAndEventIDsAreUnique() throws {
        try HelperFixtures.activate(root: support)
        // Same clock value twice: uniqueness must not depend on the timestamp.
        XCTAssertEqual(emit(arguments(), payload: try HelperFixtures.documentedPayload()).code, 0)
        XCTAssertEqual(emit(arguments(), payload: try HelperFixtures.documentedPayload()).code, 0)

        let events = try HelperFixtures.eventFiles(in: support).map {
            try HelperFixtures.decodeEvent($0)
        }
        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(EventFileName.sanitize(event.id), event.id)
            XCTAssertEqual(EventFileName.sanitize(event.source), event.source)
            XCTAssertEqual(EventFileName.sanitize(event.session.instance), event.session.instance)
            XCTAssertEqual(EventFileName.sanitize(event.session.session), event.session.session)
            XCTAssertTrue(HookIdentifier.isCanonical(event.id))
            XCTAssertTrue(HookIdentifier.isCanonical(event.session.session))
        }
        XCTAssertEqual(Set(events.map(\.id)).count, 2)
    }

    func testAppSupportFlagSelectsTheRoot() throws {
        try HelperFixtures.activate(root: support)

        let result = HelperRunner.run(
            arguments: arguments(extra: ["--app-support", support.path]),
            stdin: try HelperFixtures.documentedPayload(),
            adapters: adapters,
            now: HelperFixtures.epoch,
            owner: OwnerIdentityProbe.identity(pid: getpid())
        ) { _ in }

        XCTAssertEqual(result, 0)
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 1)
    }

    // MARK: - Activation

    func testInactiveFamilyWritesNothingAndCreatesNoDirectory() throws {
        let result = emit(arguments(), payload: try HelperFixtures.documentedPayload())

        XCTAssertEqual(result.code, 3)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
        XCTAssertTrue(HelperFixtures.files(in: sandbox).isEmpty)
    }

    func testStaleGenerationWritesNothing() throws {
        try HelperFixtures.activate(generation: 2, root: support)

        let result = emit(arguments(generation: 1), payload: try HelperFixtures.documentedPayload())

        XCTAssertEqual(result.code, 3)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("2"), "the diagnostic names the installed generation")
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("inbox").path
            )
        )
    }

    func testNonCommittedJournalBlocksAnOtherwiseCommittedFamily() throws {
        for stage in [InstallStage.prepared, .applying, .recoveryRequired] {
            let root = sandbox.appendingPathComponent(
                "support-\(stage.rawValue)",
                isDirectory: true
            )
            try HelperFixtures.activate(generation: 1, root: root)
            try HelperFixtures.writeJournal(stage: stage, root: root)

            let result = emit(
                arguments(),
                payload: try HelperFixtures.documentedPayload(),
                root: root
            )

            XCTAssertEqual(result.code, 3, "stage \(stage.rawValue) must not activate")
            XCTAssertTrue(HelperFixtures.eventFiles(in: root).isEmpty)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("inbox").path
                )
            )
        }
    }

    func testActivationIsCheckedBeforeThePayload() throws {
        // Inactive family plus an oversize body: activation wins, so nothing is
        // parsed and nothing is created.
        let oversize = Data(count: HelperRunner.maxPayloadBytes + 1)
        let result = emit(arguments(), payload: oversize)

        XCTAssertEqual(result.code, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))
    }

    // MARK: - Invalid input

    func testMalformedPayloadIsRefused() throws {
        try HelperFixtures.activate(root: support)

        let broken = [
            Data("not json".utf8),
            Data("{\"session\":".utf8),
            Data("[1,2,3]".utf8),
            Data("\"text\"".utf8)
        ]
        for payload in broken {
            let result = emit(arguments(), payload: payload)
            XCTAssertEqual(result.code, 2)
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        }
    }

    func testOversizePayloadIsRefusedWithoutWriting() throws {
        try HelperFixtures.activate(root: support)

        let result = emit(
            arguments(),
            payload: Data(count: HelperRunner.maxPayloadBytes + 1)
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.lines[0].contains("\(HelperRunner.maxPayloadBytes)"))
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
    }

    func testUnknownEventIsRefused() throws {
        try HelperFixtures.activate(root: support)

        let result = emit(
            arguments(event: "bogus"),
            payload: try HelperFixtures.documentedPayload()
        )

        XCTAssertEqual(result.code, 2)
        XCTAssertTrue(result.lines[0].contains("bogus"))
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
    }

    func testRegistryExposesOnlyTheShippedFamily() throws {
        let families = HookAdapterRegistry.all.map(\.family)

        XCTAssertEqual(families, ["omp"])
        XCTAssertEqual(Set(families).count, families.count, "one adapter per family")
        XCTAssertNotNil(HookAdapterRegistry.adapter(for: "omp"))
        // A canonical family without an adapter is still refused.
        XCTAssertNil(HookAdapterRegistry.adapter(for: "pi"))
        XCTAssertNil(HookAdapterRegistry.adapter(for: "codex"))
        XCTAssertNil(HookAdapterRegistry.adapter(for: "cursor"))
    }

    func testUnregisteredFamilyIsRefusedThroughTheRegistry() throws {
        try HelperFixtures.activate(family: "cursor", root: support)

        let outcome = try emitWithRegistry(
            family: "cursor",
            target: "cursor.desktop",
            event: "UserPromptSubmit",
            generation: 1,
            payload: ["session": "smoke"],
            root: support
        )

        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(outcome.diagnostic?.contains("cursor"), true)
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
    }

    func testRegisteredFamilyIngestsAndUnactivatedGenerationsWriteNothing() throws {
        let cases: [(family: String, target: String, event: String, payload: [String: Any], work: String)] = [
            ("omp", "omp.cli", "agent_start",
             ["session": "smoke", "workGeneration": 1, "agentKind": "main"], "run")
        ]

        for item in cases {
            let root = sandbox.appendingPathComponent("support-\(item.family)", isDirectory: true)
            try HelperFixtures.activate(family: item.family, root: root)

            let written = try emitWithRegistry(
                family: item.family,
                target: item.target,
                event: item.event,
                generation: 1,
                payload: item.payload,
                root: root
            )
            XCTAssertEqual(written.exitCode, 0, "\(item.family) must ingest")
            XCTAssertNil(written.diagnostic)

            let files = HelperFixtures.eventFiles(in: root)
            XCTAssertEqual(files.count, 1)
            let event = try HelperFixtures.decodeEvent(files[0])
            XCTAssertEqual(event.schema, ActivityEvent.currentSchema)
            XCTAssertEqual(event.source, item.family)
            XCTAssertEqual(event.transition, .started)
            XCTAssertEqual(event.work, item.work)
            XCTAssertEqual(event.activationGeneration, 1)
            XCTAssertEqual(event.target, item.target)
            XCTAssertFalse(event.snapshotComplete)
            var model = ActivityModel()
            model.activate(family: item.family, generation: 1)
            XCTAssertEqual(
                model.apply(event),
                .applied,
                "the event the helper wrote must be accepted by the model"
            )

            let inactiveRoot = sandbox.appendingPathComponent(
                "support-\(item.family)-inactive",
                isDirectory: true
            )
            let inactive = try emitWithRegistry(
                family: item.family,
                target: item.target,
                event: item.event,
                generation: 1,
                payload: item.payload,
                root: inactiveRoot
            )
            XCTAssertEqual(inactive.exitCode, 3, "\(item.family) without a receipt must not ingest")
            XCTAssertFalse(FileManager.default.fileExists(atPath: inactiveRoot.path))

            let stale = try emitWithRegistry(
                family: item.family,
                target: item.target,
                event: item.event,
                generation: 2,
                payload: item.payload,
                root: root
            )
            XCTAssertEqual(stale.exitCode, 3, "\(item.family) at a stale generation must not ingest")
            XCTAssertEqual(HelperFixtures.eventFiles(in: root).count, 1)
        }
    }

    func testBadTargetIsRefused() throws {
        try HelperFixtures.activate(root: support)

        for target in ["fixture", "other.cli", "fixture.", "fixture/../cli"] {
            let result = emit(
                arguments(target: target),
                payload: try HelperFixtures.documentedPayload()
            )
            XCTAssertEqual(result.code, 2, "target \(target) must be refused")
            XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        }
    }

    func testMissingDuplicateAndUnknownArgumentsAreRefused() throws {
        try HelperFixtures.activate(root: support)
        let payload = try HelperFixtures.documentedPayload()

        let cases: [[String]] = [
            [],
            ["--family", HelperFixtures.family],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "1"],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "1", "--event"],
            ["--family", HelperFixtures.family, "--family", HelperFixtures.family,
             "--target", HelperFixtures.target, "--generation", "1", "--event", "start"],
            ["--family", "", "--target", HelperFixtures.target,
             "--generation", "1", "--event", "start"],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "1", "--event", "start", "--bogus", "x"],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "0", "--event", "start"],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "nope", "--event", "start"],
            ["--family", "bad/family", "--target", "bad.family.cli",
             "--generation", "1", "--event", "start"],
            ["--family", HelperFixtures.family, "--target", HelperFixtures.target,
             "--generation", "1", "--event", "start", "--app-support", "relative/dir"]
        ]

        for arguments in cases {
            let result = emit(arguments, payload: payload)
            XCTAssertEqual(result.code, 2, "arguments \(arguments) must be refused")
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertFalse(result.lines[0].isEmpty)
            XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        }
    }

    func testAdapterFieldsAreAllowlistedAndFieldErrorsNameTheField() throws {
        try HelperFixtures.activate(root: support)

        let missing = try emit(
            arguments(),
            payload: HelperFixtures.payload(["work": "work-1"]),
            adapters: [StrictAdapter()]
        )
        XCTAssertEqual(missing.code, 2)
        XCTAssertTrue(missing.lines[0].contains("session"))
        XCTAssertFalse(missing.lines[0].contains("work-1"))

        let aliased = try emit(
            arguments(),
            payload: HelperFixtures.payload(["session": "session:1/x", "work": "work-1"]),
            adapters: [RawIdentifierAdapter()]
        )
        XCTAssertEqual(aliased.code, 2)
        XCTAssertTrue(aliased.lines[0].contains("session"))
        XCTAssertFalse(aliased.lines[0].contains("session:1/x"))
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
    }

    // MARK: - Privacy allowlist

    func testSeededPayloadContentNeverReachesStorageOrDiagnostics() throws {
        try HelperFixtures.activate(root: support)

        let result = emit(arguments(), payload: try HelperFixtures.documentedPayload())
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.lines.isEmpty)

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 1)
        let raw = try String(contentsOf: files[0], encoding: .utf8)
        let object = try HelperFixtures.decodeObject(files[0])

        for secret in HelperFixtures.seededSecrets {
            XCTAssertFalse(raw.contains(secret), "seeded content reached the event file")
            XCTAssertFalse(object.keys.joined(separator: ",").contains(secret))
        }
        for unknown in ["prompt", "response", "toolArguments", "credential", "transcript"] {
            XCTAssertNil(object[unknown], "unknown payload key \(unknown) must be dropped")
        }
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schema", "id", "source", "activationGeneration", "target", "owner",
                "session", "transition", "work", "generation", "sequence", "timestamp",
                "snapshotComplete"
            ])
        )

        // A rejected payload containing the same content must not echo it.
        let broken = Data("{\"prompt\":\"\(HelperFixtures.seededSecrets[0])\"".utf8)
        let rejected = emit(arguments(), payload: broken)
        XCTAssertEqual(rejected.code, 2)
        XCTAssertEqual(rejected.lines.count, 1)
        for secret in HelperFixtures.seededSecrets {
            XCTAssertFalse(rejected.lines[0].contains(secret))
        }
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 1)
    }

    // MARK: - Storage

    func testUnwritableRootReturnsStorageFailure() throws {
        try HelperFixtures.activate(root: support)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: support.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: support.path
            )
        }

        let result = emit(arguments(), payload: try HelperFixtures.documentedPayload())

        XCTAssertEqual(result.code, 4)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertTrue(result.lines[0].contains("cannot write the event"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: support.appendingPathComponent("inbox").path
            )
        )
    }

    func testMaximumPayloadCompletesQuicklyAndLeavesNoLockOrTemporaryFile() throws {
        try HelperFixtures.activate(root: support)

        let prefix = "{\"session\":\"session-1\",\"work\":\"work-1\",\"padding\":\""
        let suffix = "\"}"
        let payload = Data(
            (prefix
                + String(
                    repeating: "A",
                    count: HelperRunner.maxPayloadBytes - prefix.utf8.count - suffix.utf8.count
                )
                + suffix).utf8
        )
        XCTAssertEqual(payload.count, HelperRunner.maxPayloadBytes)

        let started = Date()
        let result = emit(arguments(), payload: payload)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.code, 0)
        XCTAssertLessThan(elapsed, 2.0, "a maximum-size accepted payload must complete promptly")
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 1)

        let all = HelperFixtures.files(in: support)
        XCTAssertFalse(all.contains { $0.lastPathComponent == ".lock" })
        XCTAssertFalse(all.contains { $0.lastPathComponent.hasSuffix(".tmp") })
        XCTAssertFalse(all.contains { $0.lastPathComponent.hasPrefix(".awake-lite-") })
    }

    // MARK: - Owner identity

    func testOwnerIdentityIsCanonicalStableAndBootScoped() throws {
        let probe = OwnerIdentityProbe.measure(pid: getpid())
        XCTAssertTrue(probe.measured)

        let first = probe.identity
        let second = OwnerIdentityProbe.identity(pid: getpid())
        XCTAssertEqual(first, second, "one process lifetime has one owner instance")
        XCTAssertEqual(first.pid, getpid())
        XCTAssertEqual(first.uid, geteuid())
        XCTAssertGreaterThan(first.startTimeMicros, 0)
        XCTAssertEqual(first.bootID, OwnerIdentityProbe.bootToken())
        XCTAssertTrue(HookIdentifier.isCanonical(first.instance))
        XCTAssertFalse(first.instance.hasPrefix("x-"))
    }

    func testOwnerIdentityDiffersForAnotherProcess() throws {
        let own = OwnerIdentityProbe.measure(pid: getpid())
        let parent = OwnerIdentityProbe.measure(pid: getppid())

        // The walk may skip a transient wrapper, so the resolved PID is an
        // ancestor of this process rather than necessarily `getppid()`.
        XCTAssertNotEqual(own.identity.instance, parent.identity.instance)
        XCTAssertNotEqual(own.identity.pid, parent.identity.pid)
        XCTAssertEqual(parent.identity.uid, geteuid())
        XCTAssertTrue(HookIdentifier.isCanonical(parent.identity.instance))
    }

    // MARK: - Owner ancestry

    func testNonTransientProcessIsNotSkipped() throws {
        let probe = OwnerIdentityProbe.measure(pid: getpid())

        XCTAssertTrue(probe.measured)
        XCTAssertEqual(probe.identity.pid, getpid(), "the test process itself is the owner")
        XCTAssertEqual(probe.identity.uid, geteuid())
        XCTAssertGreaterThan(probe.identity.startTimeMicros, 0)
    }

    func testTransientShellChainResolvesToTheTestProcess() throws {
        let own = OwnerIdentityProbe.measure(pid: getpid()).identity
        let pidFile = sandbox.appendingPathComponent("inner.pid")
        var spawned: [pid_t] = []
        defer {
            for pid in spawned { killShell(pid) }
        }

        spawned.append(try spawnShell("sleep 5; :"))
        spawned.append(try spawnShell("sh -c 'sleep 5; :'"))
        spawned.append(try spawnShell("sh -c 'sleep 5; :' & echo $! > \(pidFile.path); wait"))
        let inner = try waitForPID(in: pidFile)
        spawned.append(inner)

        for pid in spawned {
            let probe = OwnerIdentityProbe.measure(pid: pid)
            XCTAssertTrue(probe.measured)
            XCTAssertEqual(
                probe.identity,
                own,
                "a transient wrapper chain must never become the owner"
            )
            XCTAssertTrue(HookIdentifier.isCanonical(probe.identity.instance))
            XCTAssertLessThanOrEqual(probe.identity.instance.count, 64)
        }

        for pid in spawned { killShell(pid) }
        for pid in spawned { assertGone(pid) }
        spawned.removeAll()
    }

    func testSeparateShellInvocationsAgreeOnOwnerIdentity() throws {
        let own = OwnerIdentityProbe.measure(pid: getpid()).identity

        let first = try spawnShell("sleep 5; :")
        let firstIdentity = OwnerIdentityProbe.measure(pid: first).identity
        usleep(50_000)
        let second = try spawnShell("sleep 5; :")
        let secondIdentity = OwnerIdentityProbe.measure(pid: second).identity

        killShell(first)
        killShell(second)

        XCTAssertEqual(firstIdentity, own)
        XCTAssertEqual(secondIdentity, own)
        XCTAssertEqual(
            firstIdentity,
            secondIdentity,
            "every emission of one agent session needs the same owner"
        )

        assertGone(first)
        assertGone(second)
    }

    // MARK: - Supplied owner identity (detached helper)

    func testSuppliedOwnerIsIdenticalAcrossEmissionsAndNotTheProbedParent() throws {
        try HelperFixtures.activate(root: support)
        let instance = "p424242-0a1b2c3d"
        let flags = ["--owner-instance", instance, "--owner-pid", "424242"]

        XCTAssertEqual(
            emit(arguments(extra: flags), payload: try HelperFixtures.documentedPayload(), owner: nil).code,
            0
        )
        XCTAssertEqual(
            emit(
                arguments(extra: flags),
                payload: try HelperFixtures.documentedPayload(),
                now: HelperFixtures.epoch.addingTimeInterval(1),
                owner: nil
            ).code,
            0
        )

        let events = try HelperFixtures.eventFiles(in: support).map {
            try HelperFixtures.decodeEvent($0)
        }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].owner, events[1].owner, "one process has one supplied owner")

        let owner = events[0].owner
        XCTAssertEqual(owner.instance, instance)
        XCTAssertEqual(owner.pid, 424242)
        XCTAssertEqual(owner.startTimeMicros, 0, "a supplied owner carries no start-time measurement")
        XCTAssertEqual(owner.uid, geteuid())
        XCTAssertEqual(owner.bootID, OwnerIdentityProbe.bootToken())
        XCTAssertEqual(events[0].session.instance, instance)
        XCTAssertEqual(
            EventFileName.scope(of: HelperFixtures.eventFiles(in: support)[0].lastPathComponent)?.instance,
            instance
        )
        XCTAssertNotEqual(owner, OwnerIdentityProbe.identity(pid: getpid()))
    }

    func testMalformedOwnerFlagsExitTwoAndNameTheFlag() throws {
        try HelperFixtures.activate(root: support)
        let payload = try HelperFixtures.documentedPayload()
        let longInstance = String(repeating: "a", count: HelperRunner.maxOwnerInstanceLength + 1)

        let cases: [(flags: [String], flag: String)] = [
            (["--owner-instance", "p1-abcdef12"], "--owner-pid"),
            (["--owner-pid", "4242"], "--owner-instance"),
            (["--owner-instance", "bad token", "--owner-pid", "4242"], "--owner-instance"),
            (["--owner-instance", "p1/abcdef12", "--owner-pid", "4242"], "--owner-instance"),
            (["--owner-instance", longInstance, "--owner-pid", "4242"], "--owner-instance"),
            (["--owner-instance", "p1-abcdef12", "--owner-pid", "1"], "--owner-pid"),
            (["--owner-instance", "p1-abcdef12", "--owner-pid", "0"], "--owner-pid"),
            (["--owner-instance", "p1-abcdef12", "--owner-pid", "-9"], "--owner-pid"),
            (["--owner-instance", "p1-abcdef12", "--owner-pid", "abc"], "--owner-pid")
        ]

        for item in cases {
            let result = emit(arguments(extra: item.flags), payload: payload)
            XCTAssertEqual(result.code, 2, "flags \(item.flags)")
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertTrue(result.lines[0].contains(item.flag), result.lines[0])
            XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        }
    }

    func testDetachedHelperKeepsTheSuppliedOwnerAfterItsParentExits() throws {
        try HelperFixtures.activate(family: "omp", root: support)
        let helper = try helperBinary()
        let instance = "p424242-0a1b2c3d"
        let payloadFile = sandbox.appendingPathComponent("payload.json")
        try HelperFixtures.payload(["session": "smoke", "workGeneration": 9, "agentKind": "main"])
            .write(to: payloadFile)

        // The shell exits immediately, so the helper cannot be measured through
        // its parent: a probe would name launchd or a later unrelated process.
        let script = "\"\(helper.path)\" --family omp --target omp.cli --generation 1 "
            + "--event agent_start --app-support \"\(support.path)\" "
            + "--owner-instance \"\(instance)\" --owner-pid 424242 "
            + "< \"\(payloadFile.path)\" & exit 0"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        try shell.run()
        shell.waitUntilExit()
        XCTAssertEqual(shell.terminationStatus, 0)

        var files: [URL] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            files = HelperFixtures.eventFiles(in: support)
            if !files.isEmpty { break }
            usleep(20_000)
        }
        let written = try XCTUnwrap(files.first, "the orphaned helper must still write one event")
        XCTAssertEqual(files.count, 1)

        let event = try HelperFixtures.decodeEvent(written)
        XCTAssertEqual(event.owner.instance, instance)
        XCTAssertEqual(event.owner.pid, 424242)
        XCTAssertEqual(event.owner.startTimeMicros, 0)
        XCTAssertEqual(event.owner.uid, geteuid())
        XCTAssertNotEqual(event.owner, OwnerIdentityProbe.identity(pid: getpid()))
        XCTAssertEqual(EventFileName.scope(of: written.lastPathComponent)?.instance, instance)
        XCTAssertEqual(event.work, "run")
        XCTAssertEqual(event.generation, 9)
    }

    // MARK: - Unreadable install state

    func testUnreadableInstallStateNamesTheStatePathNotTheFamilyReceipt() throws {
        try HelperFixtures.activate(root: support)
        try IntegrationFixtures.write(
            "{ not json",
            to: support.appendingPathComponent("receipts/other.json")
        )

        let corrupt = emit(arguments(), payload: try HelperFixtures.documentedPayload())
        XCTAssertEqual(corrupt.code, 3)
        XCTAssertEqual(corrupt.lines.count, 1)
        XCTAssertTrue(
            corrupt.lines[0].contains("install state is unreadable at \(support.path)"),
            corrupt.lines[0]
        )
        XCTAssertFalse(
            corrupt.lines[0].contains("\(HelperFixtures.family).json"),
            "a healthy family receipt is not the unreadable state"
        )
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("inbox").path)
        )

        // A removed journal directory is unreadable state too, not a missing
        // receipt.
        let removedJournal = sandbox.appendingPathComponent("removed-journal", isDirectory: true)
        try HelperFixtures.activate(root: removedJournal)
        try FileManager.default.removeItem(at: removedJournal.appendingPathComponent("journal"))

        let unreadable = emit(
            arguments(),
            payload: try HelperFixtures.documentedPayload(),
            root: removedJournal
        )
        XCTAssertEqual(unreadable.code, 3)
        XCTAssertTrue(
            unreadable.lines[0].contains("install state is unreadable at \(removedJournal.path)"),
            unreadable.lines[0]
        )
        XCTAssertFalse(unreadable.lines[0].contains("\(HelperFixtures.family).json"))
        XCTAssertTrue(HelperFixtures.eventFiles(in: removedJournal).isEmpty)
    }

    // MARK: - Template rendering

    func testTemplateRenderingIsSinglePassAndNeverResubstitutesAValue() {
        let rendered = Template.renderText(
            "{family}-{target}-{generation}",
            values: [
                Template.family: "{target}",
                Template.target: "{helperPath}",
                Template.generation: "{generation}"
            ]
        )

        XCTAssertEqual(
            rendered,
            "{target}-{helperPath}-{generation}",
            "a value containing another token survives verbatim"
        )
        XCTAssertFalse(rendered.contains("/Applications"), "an inserted value is never expanded again")
    }

    // MARK: - Shell fixtures

    /// The `AwakeLiteHelper` executable SwiftPM builds beside the test bundle.
    private func helperBinary() throws -> URL {
        var starts = [Bundle(for: type(of: self)).bundleURL]
        starts.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        for start in starts {
            var directory = start
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("AwakeLiteHelper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory = directory.deletingLastPathComponent()
            }
        }
        throw XCTSkip("AwakeLiteHelper was not built beside the test bundle")
    }

    /// Spawns `/bin/sh -c <script>` in its own process group so the whole tree
    /// can be killed deterministically.
    ///
    /// `/bin/sh` execs a single simple command in place, so the script keeps a
    /// trailing no-op: the process that is measured stays a shell.
    private func spawnShell(_ script: String) throws -> pid_t {
        var pid: pid_t = 0
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let arguments: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"), strdup("-c"), strdup(script), nil
        ]
        defer {
            for pointer in arguments { free(pointer) }
        }

        let result = posix_spawn(&pid, "/bin/sh", nil, &attributes, arguments, environ)
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(result))
        }
        return pid
    }

    /// Kills one spawned process group and reaps its leader.
    private func killShell(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }

    private func waitForPID(in file: URL, timeout: TimeInterval = 3) throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: file, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               value > 1 {
                return value
            }
            usleep(10_000)
        }
        XCTFail("the shell chain did not report its child pid")
        throw NSError(domain: "HelperIngestTests", code: 1)
    }

    private func assertGone(_ pid: pid_t, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            usleep(10_000)
        }
        XCTFail("process \(pid) survived termination")
    }

    func testUnreadableProcessFallsBackToAnUnjoinableIdentity() throws {
        let unknown = OwnerIdentityProbe.measure(pid: Int32.max)

        XCTAssertFalse(unknown.measured)
        XCTAssertEqual(unknown.identity.startTimeMicros, 0)
        XCTAssertTrue(unknown.identity.instance.hasPrefix("x-"))
        XCTAssertTrue(HookIdentifier.isCanonical(unknown.identity.instance))
        XCTAssertEqual(unknown.identity.bootID, OwnerIdentityProbe.bootToken())

        let again = OwnerIdentityProbe.measure(pid: Int32.max)
        XCTAssertNotEqual(
            unknown.identity.instance,
            again.identity.instance,
            "an unmeasured owner must never merge with another emission"
        )
    }
}
