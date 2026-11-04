import Darwin
import Foundation
import XCTest
@testable import AwakeLiteCore

/// Unit 3.4: the Codex CLI and desktop hook adapter and its installed asset.
///
/// Every check drives the production path: `HelperRunner.execute` →
/// `HookNormalizer` → `CodexAdapter` → `LocalEventStore`, against a temporary
/// app-support root. Nothing reads or writes the real `~/.codex` or the real
/// app-support directory, and no Codex process is started.
final class CodexAdapterTests: XCTestCase {
    private var sandbox: URL!
    private var support: URL!

    private let adapters: [HookAdapter] = [CodexAdapter()]
    private let owner = OwnerIdentityProbe.identity(pid: getpid())
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Seeded values that must never reach an event file or a diagnostic.
    private enum Seed {
        static let prompt = "PROMPT-SEED-9e1"
        static let response = "RESPONSE-SEED-8d2"
        static let toolInput = "TOOLINPUT-SEED-7c3"
        static let toolOutput = "TOOLOUTPUT-SEED-6b4"
        static let transcript = "TRANSCRIPT-SEED-5a5"
        static let credential = "CREDENTIAL-SEED-4z6"
        static let workingDirectory = "CWD-SEED-3y7"
        static let model = "MODEL-SEED-2x8"

        static let all = [
            prompt, response, toolInput, toolOutput,
            transcript, credential, workingDirectory, model
        ]
    }

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
        event: String,
        target: String = CodexAdapter.cliTarget,
        generation: UInt64 = 1
    ) -> [String] {
        [
            "--family", "codex",
            "--target", target,
            "--generation", String(generation),
            "--event", event
        ]
    }

    /// One Codex-shaped payload. Absent arguments model a missing documented
    /// field; `extra` models the content-bearing keys the adapter must ignore.
    private func payload(
        event: String? = nil,
        session: String? = "thr_2am",
        turn: String? = "turn_7",
        extra: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [:]
        if let event { object["hook_event_name"] = event }
        if let session { object["session_id"] = session }
        if let turn { object["turn_id"] = turn }
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @discardableResult
    private func emit(
        _ event: String,
        payload: Data,
        target: String = CodexAdapter.cliTarget,
        generation: UInt64 = 1,
        now: Date? = nil,
        owner: OwnerIdentity? = nil,
        root: URL? = nil
    ) -> (code: Int32, lines: [String]) {
        var lines: [String] = []
        let code = HelperRunner.run(
            arguments: arguments(event: event, target: target, generation: generation),
            stdin: payload,
            appSupportRoot: root ?? support,
            adapters: adapters,
            now: now ?? epoch,
            owner: owner ?? self.owner
        ) { lines.append($0) }
        return (code, lines)
    }

    /// The same production entry point without the stderr shell, so a test can
    /// assert the exit code and the single diagnostic line directly.
    private func execute(
        _ event: String,
        payload: Data,
        target: String = CodexAdapter.cliTarget,
        generation: UInt64 = 1,
        root: URL? = nil
    ) -> HelperOutcome {
        HelperRunner.execute(
            arguments: arguments(event: event, target: target, generation: generation),
            stdin: payload,
            appSupportRoot: root ?? support,
            adapters: adapters,
            now: epoch,
            owner: owner
        )
    }

    private func events() throws -> [ActivityEvent] {
        try HelperFixtures.eventFiles(in: support).map {
            try HelperFixtures.decodeEvent($0)
        }
    }

    private func record(
        _ model: ActivityModel,
        work: String,
        session: String = "thr_2am",
        instance: String? = nil,
        generation: UInt64 = CodexAdapter.turnGeneration
    ) -> WorkRecord? {
        model.works[
            WorkIdentity(
                session: SessionIdentity(
                    family: "codex",
                    instance: instance ?? owner.instance,
                    session: session
                ),
                generation: generation,
                work: work
            )
        ]
    }

    private func reconciledModel(generation: UInt64 = 1) throws -> ActivityModel {
        var model = ActivityModel()
        model.activate(family: "codex", generation: generation)
        _ = try LocalEventStore(root: support).reconcile(&model)
        return model
    }

    /// One composed sequence: emit, reconcile, and return the updated model.
    private func advance(
        _ event: String,
        _ model: inout ActivityModel,
        turn: String = "turn_7",
        at offset: TimeInterval,
        payload: Data? = nil
    ) throws {
        let body: Data
        if let payload {
            body = payload
        } else {
            body = try self.payload(event: event, turn: turn)
        }
        let result = emit(event, payload: body, now: epoch.addingTimeInterval(offset))
        XCTAssertEqual(result.code, 0, "\(event) failed: \(result.lines)")
        _ = try LocalEventStore(root: support).reconcile(&model)
    }

    // MARK: - Vocabulary

    func testAdapterDeclaresOnlyTheDocumentedCodexVocabulary() {
        let adapter = CodexAdapter()

        XCTAssertEqual(adapter.family, "codex")
        XCTAssertEqual(adapter.eventNames, CodexAdapter.documentedEvents)
        XCTAssertEqual(adapter.eventNames.count, 7)
        XCTAssertFalse(
            adapter.eventNames.contains("SessionStart"),
            "a session opening is not work and must not create a hold (A04)"
        )
        XCTAssertFalse(
            adapter.eventNames.contains("SessionEnd"),
            "one conversation ending is not proof the owner process died"
        )
        XCTAssertEqual(
            CodexAdapter.documentedTargets,
            ["codex.cli", "codex.desktop"],
            "both installed steps are served by one family adapter"
        )
        XCTAssertEqual(
            CodexAdapter.documentedPayloadFields,
            ["session_id", "turn_id", "hook_event_name", "permission_mode"]
        )

        // Registry lookup is by family, which is why one adapter serves both
        // compatibility targets.
        XCTAssertTrue(
            HookAdapterRegistry.adapter(for: "codex", in: adapters) is CodexAdapter
        )
        XCTAssertNil(HookAdapterRegistry.adapter(for: "codex.ci", in: adapters))
    }

    // MARK: - Event mapping

    func testEveryDocumentedEventMapsToTheIntendedTransitionAndWork() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        // Vendor event, transition, work name, parent work, and whether the
        // event is turn-scoped. Source: the Codex hooks contract, event tables.
        let cases: [(event: String, transition: ActivityTransition, work: String?, parent: String?)] = [
            ("UserPromptSubmit", .started, "turn-turn_7", nil),
            ("PermissionRequest", .humanWait, "turn-turn_7", nil),
            ("PostToolUse", .resumed, "turn-turn_7", nil),
            ("Stop", .completed, "turn-turn_7", nil),
            ("Interrupt", .cancelled, "turn-turn_7", nil),
            ("SubagentStart", .childStarted, "sub-turn_7", "turn-turn_7"),
            ("SubagentStop", .childFinished, "sub-turn_7", "turn-turn_7")
        ]

        for (index, item) in cases.enumerated() {
            let result = emit(
                item.event,
                payload: try payload(event: item.event, turn: "turn_7"),
                now: epoch.addingTimeInterval(Double(index))
            )
            XCTAssertEqual(result.code, 0, "\(item.event): \(result.lines)")
            XCTAssertTrue(result.lines.isEmpty, "a successful emission stays silent")
        }

        let written = try events()
        XCTAssertEqual(written.count, cases.count)
        // The file name carries the emission time, so the store's sorted order
        // is the order the events were emitted in.
        for (index, item) in cases.enumerated() {
            let event = written[index]
            XCTAssertEqual(event.transition, item.transition, item.event)
            XCTAssertEqual(event.work, item.work, item.event)
            XCTAssertEqual(event.parentWork, item.parent, item.event)
            XCTAssertEqual(
                event.generation,
                item.work == nil ? nil : CodexAdapter.turnGeneration,
                item.event
            )
            XCTAssertEqual(event.source, "codex", item.event)
            XCTAssertEqual(event.target, CodexAdapter.cliTarget, item.event)
            XCTAssertEqual(event.activationGeneration, 1, item.event)
            XCTAssertEqual(event.owner, owner, item.event)
            XCTAssertEqual(event.session.family, "codex", item.event)
            XCTAssertEqual(event.session.instance, owner.instance, item.event)
            XCTAssertEqual(event.session.session, "thr_2am", item.event)
            XCTAssertEqual(event.timestamp, epoch.addingTimeInterval(Double(index)), item.event)
            XCTAssertFalse(event.snapshotComplete, item.event)
            XCTAssertNil(event.scope, item.event)
            XCTAssertNil(event.snapshotEntries, item.event)
            XCTAssertNil(event.sequence, item.event)
        }
    }

    func testCliAndDesktopTargetsStayDistinctAndAreCarriedThrough() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        XCTAssertEqual(
            emit(
                "UserPromptSubmit",
                payload: try payload(event: "UserPromptSubmit"),
                target: CodexAdapter.cliTarget,
                now: epoch
            ).code,
            0
        )
        XCTAssertEqual(
            emit(
                "UserPromptSubmit",
                payload: try payload(event: "UserPromptSubmit"),
                target: CodexAdapter.desktopTarget,
                now: epoch.addingTimeInterval(1)
            ).code,
            0
        )

        XCTAssertNotEqual(CodexAdapter.cliTarget, CodexAdapter.desktopTarget)
        let targets = try events().map(\.target)
        XCTAssertEqual(targets, [CodexAdapter.cliTarget, CodexAdapter.desktopTarget])
        XCTAssertEqual(Set(targets), CodexAdapter.documentedTargets)

        // A third target is a configuration error, not another mode.
        let refused = emit(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit"),
            target: "codex.ci",
            now: epoch.addingTimeInterval(2)
        )
        XCTAssertEqual(refused.code, 2)
        XCTAssertEqual(refused.lines.count, 1)
        XCTAssertTrue(refused.lines[0].contains("codex.ci"))
        XCTAssertEqual(try events().count, 2)
    }

    func testPayloadKeysOutsideTheAllowlistAreDropped() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        // Every key a real Codex payload carries, documented or not. Only
        // session_id, turn_id, and hook_event_name may influence the result.
        let extra: [String: Any] = [
            "permission_mode": "acceptEdits",
            "transcript_path": "/tmp/\(Seed.transcript).jsonl",
            "cwd": "/tmp/\(Seed.workingDirectory)",
            "model": "gpt-\(Seed.model)",
            "prompt": Seed.prompt,
            "response": Seed.response,
            "tool_name": "Bash",
            "tool_input": ["command": Seed.toolInput],
            "tool_response": ["output": Seed.toolOutput],
            "agent_id": "agent_\(Seed.credential)",
            "agent_type": "worker",
            "stop_hook_active": true,
            "last_assistant_message": Seed.response,
            "reason": Seed.credential
        ]

        let result = emit(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit", extra: extra)
        )
        XCTAssertEqual(result.code, 0, "\(result.lines)")
        XCTAssertTrue(result.lines.isEmpty)

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 1)
        let object = try HelperFixtures.decodeObject(files[0])
        XCTAssertEqual(
            Set(object.keys),
            Set([
                "schema", "id", "source", "activationGeneration", "target", "owner",
                "session", "transition", "work", "generation", "timestamp",
                "snapshotComplete"
            ])
        )

        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(Set(session.keys), ["family", "instance", "session"])
        let owner = try XCTUnwrap(object["owner"] as? [String: Any])
        XCTAssertEqual(
            Set(owner.keys),
            ["bootID", "pid", "startTimeMicros", "uid", "instance"]
        )
        for key in ["transcript_path", "cwd", "model", "prompt", "tool_input", "tool_response"] {
            XCTAssertNil(object[key], "\(key) must never be persisted")
        }
    }

    func testSeededContentNeverReachesEventBytesOrDiagnostics() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        // A real transcript file and a transcript path that does not exist. A
        // read of either would be observable: the seeded content could leak, and
        // opening the absent path would fail. The emission must do neither.
        let transcript = sandbox.appendingPathComponent("transcript.jsonl")
        try Data(Seed.transcript.utf8).write(to: transcript)
        let absent = sandbox.appendingPathComponent("absent-transcript.jsonl")

        for path in [transcript.path, absent.path] {
            let result = emit(
                "UserPromptSubmit",
                payload: try payload(
                    event: "UserPromptSubmit",
                    extra: [
                        "transcript_path": path,
                        "cwd": "/tmp/\(Seed.workingDirectory)",
                        "model": Seed.model,
                        "prompt": Seed.prompt,
                        "tool_input": ["command": Seed.toolInput],
                        "tool_response": ["output": Seed.toolOutput],
                        "credential": Seed.credential
                    ]
                ),
                now: epoch.addingTimeInterval(Double(path == transcript.path ? 0 : 1))
            )
            XCTAssertEqual(result.code, 0, "\(path): \(result.lines)")
            XCTAssertTrue(result.lines.isEmpty)
        }

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 2)
        for file in files {
            let raw = try String(contentsOf: file, encoding: .utf8)
            for seed in Seed.all {
                XCTAssertFalse(raw.contains(seed), "seeded content reached the event file")
            }
        }

        // A rejected payload that carries the same content must not echo it.
        let rejected = emit(
            "UserPromptSubmit",
            payload: try payload(
                event: "UserPromptSubmit",
                session: nil,
                extra: [
                    "transcript_path": transcript.path,
                    "prompt": Seed.prompt,
                    "tool_response": Seed.toolOutput,
                    "credential": Seed.credential
                ]
            ),
            now: epoch.addingTimeInterval(2)
        )
        XCTAssertEqual(rejected.code, 2)
        XCTAssertEqual(rejected.lines.count, 1)
        XCTAssertTrue(rejected.lines[0].contains("session_id"))
        for seed in Seed.all {
            XCTAssertFalse(rejected.lines[0].contains(seed))
        }
        XCTAssertEqual(HelperFixtures.eventFiles(in: support).count, 2)
    }

    func testMissingOrUnusableDocumentedFieldsAreRefusedNamingTheField() throws {
        try HelperFixtures.activate(family: "codex", root: support)
        let longTurn = String(repeating: "t", count: CodexAdapter.maxTurnIdentifierCharacters + 1)

        let cases: [(event: String, payload: Data, field: String)] = [
            ("UserPromptSubmit", try payload(event: "UserPromptSubmit", session: nil), "session_id"),
            ("UserPromptSubmit", try payload(event: "UserPromptSubmit", session: ""), "session_id"),
            ("Stop", try payload(event: "Stop", turn: nil), "turn_id"),
            ("PermissionRequest", try payload(event: "PermissionRequest", turn: nil), "turn_id"),
            ("SubagentStart", try payload(event: "SubagentStart", turn: nil), "turn_id"),
            (
                "UserPromptSubmit",
                try JSONSerialization.data(
                    withJSONObject: [
                        "session_id": "thr_2am",
                        "turn_id": 42,
                        "hook_event_name": "UserPromptSubmit"
                    ]
                ),
                "turn_id"
            ),
            ("UserPromptSubmit", try payload(event: "UserPromptSubmit", turn: longTurn), "turn_id"),
            // A payload whose event name contradicts the configured handler.
            (
                "UserPromptSubmit",
                try payload(event: "UserPromptSubmit", extra: ["hook_event_name": "Stop"]),
                "hook_event_name"
            )
        ]

        for item in cases {
            let result = emit(item.event, payload: item.payload)
            XCTAssertEqual(result.code, 2, "\(item.field): \(result.lines)")
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertTrue(
                result.lines[0].contains("\"\(item.field)\""),
                "the diagnostic names the field: \(result.lines[0])"
            )
            XCTAssertFalse(result.lines[0].contains("thr_2am"))
            XCTAssertFalse(result.lines[0].contains("turn_7"))
            XCTAssertFalse(result.lines[0].contains(longTurn))
        }

        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
    }

    // MARK: - Activation gating

    func testInactiveStaleAndUnhealthyInstallsWriteNothing() throws {
        // No committed receipt: the app-support root is never created.
        let first = execute(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit")
        )
        XCTAssertEqual(first.exitCode, 3)
        XCTAssertNotNil(first.diagnostic)
        XCTAssertTrue(first.diagnostic?.contains("not active") == true)
        XCTAssertTrue(HelperFixtures.files(in: sandbox).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.path))

        // A stale generation.
        try HelperFixtures.activate(family: "codex", generation: 2, root: support)
        let stale = execute(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit"),
            generation: 1
        )
        XCTAssertEqual(stale.exitCode, 3)
        XCTAssertTrue(stale.diagnostic?.contains("2") == true)
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: support.appendingPathComponent("inbox").path)
        )

        // A committed receipt shadowed by a non-committed journal.
        let unhealthy = sandbox.appendingPathComponent("unhealthy", isDirectory: true)
        try HelperFixtures.activate(family: "codex", generation: 1, root: unhealthy)
        try HelperFixtures.writeJournal(family: "codex", stage: .prepared, root: unhealthy)
        let blocked = execute(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit"),
            root: unhealthy
        )
        XCTAssertEqual(blocked.exitCode, 3)
        XCTAssertTrue(HelperFixtures.eventFiles(in: unhealthy).isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: unhealthy.appendingPathComponent("inbox").path)
        )
    }

    // MARK: - Store validity

    func testExitZeroWritesOneStoreValidFileThatTheModelApplies() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        let result = emit(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit")
        )
        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(result.lines.isEmpty)

        let files = HelperFixtures.eventFiles(in: support)
        XCTAssertEqual(files.count, 1)
        let event = try HelperFixtures.decodeEvent(files[0])
        XCTAssertEqual(files[0].lastPathComponent, EventFileName.make(event: event, at: event.timestamp))
        let scope = EventFileName.scope(of: files[0].lastPathComponent)
        XCTAssertEqual(scope?.family, "codex")
        XCTAssertEqual(scope?.instance, owner.instance)

        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)
        let report = try LocalEventStore(root: support).reconcile(&model)

        XCTAssertEqual(report.applied, 1)
        XCTAssertEqual(report.processedFiles, 1)
        XCTAssertEqual(report.rejectedFiles, 0)
        XCTAssertEqual(report.duplicates, 0)
        XCTAssertTrue(report.ignored.isEmpty)
        XCTAssertFalse(report.overflowed)

        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty, "a pass consumes its files")
    }

    func testAnEventForUntrackedWorkNeverClaimsWorking() throws {
        try HelperFixtures.activate(family: "codex", root: support)

        // Hooks installed in the middle of a turn: the first event names work
        // the model never recorded. The store records a session-scoped gap, so
        // the aggregate reports unknown rather than inventing work or claiming a
        // confirmed idle (A04, A13).
        XCTAssertEqual(
            emit(
                "PostToolUse",
                payload: try payload(event: "PostToolUse"),
                now: epoch
            ).code,
            0
        )

        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)
        let report = try LocalEventStore(root: support).reconcile(&model)

        XCTAssertEqual(report.applied, 0)
        XCTAssertEqual(report.ignored["unknownWork"], 1)
        XCTAssertEqual(model.decision.state, .unknown)
        XCTAssertFalse(model.decision.holdAssertion)
        XCTAssertTrue(model.works.isEmpty)
    }

    // MARK: - Lifecycle

    func testStartWaitResumeCompleteCancelAndRestartLeaveTheIntendedState() throws {
        try HelperFixtures.activate(family: "codex", root: support)
        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)

        try advance("UserPromptSubmit", &model, at: 0)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)

        try advance("PermissionRequest", &model, at: 1)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .waitingForUser)
        XCTAssertEqual(model.decision.state, .waitingForUser, "an approval wait allows sleep (A08)")
        XCTAssertFalse(model.decision.holdAssertion)

        try advance("PostToolUse", &model, at: 2)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)

        try advance("Stop", &model, at: 3)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .completed)
        XCTAssertEqual(model.decision.state, .idle, "completion releases the hold (A07)")
        XCTAssertFalse(model.decision.holdAssertion)

        try advance("UserPromptSubmit", &model, turn: "turn_8", at: 4)
        XCTAssertEqual(record(model, work: "turn-turn_8")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertEqual(
            record(model, work: "turn-turn_7")?.state,
            .completed,
            "the finished turn is not reopened"
        )

        try advance("Interrupt", &model, turn: "turn_8", at: 5)
        XCTAssertEqual(record(model, work: "turn-turn_8")?.state, .cancelled)
        XCTAssertEqual(model.decision.state, .idle, "cancellation releases the hold (A07)")

        // Restart: the checkpoint round trip preserves every fact.
        let store = LocalEventStore(root: support)
        try store.saveModel(model)
        let restored = try store.loadModel()
        XCTAssertEqual(restored.works, model.works)
        XCTAssertEqual(restored.activeGenerations, ["codex": 1])
        XCTAssertEqual(restored.decision.state, .idle)
        XCTAssertFalse(restored.decision.holdAssertion)
    }

    func testSubagentWorkIsAChildOfTheTurnAndNeverReplacesIt() throws {
        try HelperFixtures.activate(family: "codex", root: support)
        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)

        try advance("UserPromptSubmit", &model, at: 0)
        try advance("SubagentStart", &model, at: 1)

        let child = record(model, work: "sub-turn_7")
        XCTAssertEqual(child?.state, .working)
        XCTAssertEqual(child?.parentWork, "turn-turn_7")
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)

        try advance("SubagentStop", &model, at: 2)
        XCTAssertEqual(record(model, work: "sub-turn_7")?.state, .completed)
        XCTAssertEqual(
            record(model, work: "turn-turn_7")?.state,
            .working,
            "a finished child does not finish its parent"
        )
        XCTAssertEqual(model.decision.state, .working)

        // Documented granularity limit: one child record per turn, so the next
        // subagent of the same turn cannot reopen it once it finished.
        let second = emit(
            "SubagentStart",
            payload: try payload(event: "SubagentStart"),
            now: epoch.addingTimeInterval(3)
        )
        XCTAssertEqual(second.code, 0)
        let reopened = try events().first
        let event = try XCTUnwrap(reopened)
        XCTAssertEqual(model.apply(event), .ignored(.terminalWork))

        try advance("Stop", &model, at: 4)
        XCTAssertEqual(model.decision.state, .idle)
    }

    func testSessionEndIsNotRegisteredAndAnOrphanedTurnKeepsItsHold() throws {
        try HelperFixtures.activate(family: "codex", root: support)
        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)

        try advance("UserPromptSubmit", &model, at: 0)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)

        // SessionEnd is outside the vocabulary: refused before the payload is
        // read, with one diagnostic that names the event, and nothing written.
        let refused = emit("SessionEnd", payload: try payload(event: "SessionEnd", turn: nil))
        XCTAssertEqual(refused.code, 2)
        XCTAssertEqual(refused.lines.count, 1)
        XCTAssertTrue(refused.lines[0].contains("SessionEnd"), refused.lines[0])
        XCTAssertTrue(HelperFixtures.eventFiles(in: support).isEmpty)

        // An orphaned conversation therefore keeps its hold. Verified owner
        // death is Stage 5's probe, not a hook, so nothing here may claim idle.
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .working)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
    }

    func testContinuationAfterStopReacquiresWithANewTurnAndDocumentsTheReuseGap() throws {
        try HelperFixtures.activate(family: "codex", root: support)
        var model = ActivityModel()
        model.activate(family: "codex", generation: 1)

        try advance("UserPromptSubmit", &model, turn: "turn_7", at: 0)
        try advance("Stop", &model, turn: "turn_7", at: 1)
        XCTAssertEqual(model.decision.state, .idle)

        // Codex documents a continuation as "a new continuation prompt that acts
        // as a new user prompt", so it arrives as another UserPromptSubmit with
        // its own turn. The hold is re-acquired on the next turn record.
        try advance("UserPromptSubmit", &model, turn: "turn_8", at: 2)
        XCTAssertEqual(model.decision.state, .working)
        XCTAssertTrue(model.decision.holdAssertion)
        XCTAssertEqual(record(model, work: "turn-turn_7")?.state, .completed)
        XCTAssertEqual(record(model, work: "turn-turn_8")?.state, .working)

        // Documented limitation: if a continuation reused the same turn id, the
        // model's terminal-state rule refuses to reopen the completed record, so
        // the model stays idle. The release/re-acquire gap is the price of
        // mapping Stop to completion without a documented finality signal.
        let reused = emit(
            "UserPromptSubmit",
            payload: try payload(event: "UserPromptSubmit", turn: "turn_7"),
            now: epoch.addingTimeInterval(3)
        )
        XCTAssertEqual(reused.code, 0)
        let event = try XCTUnwrap(try events().first)
        XCTAssertEqual(event.work, "turn-turn_7")
        XCTAssertEqual(model.apply(event), .ignored(.terminalWork))
        XCTAssertEqual(model.decision.state, .working, "the newer turn keeps the hold")
    }

    // MARK: - Installed asset

    func testAssetIsTheDocumentedCodexTableShapeAndTheCatalogStillLoads() throws {
        let catalog = try IntegrationFixtures.bundledCatalog()
        let manifest = try catalog.manifest(for: "codex")
        let text = try assetText(manifest)

        XCTAssertEqual(manifest.schema, 1)
        XCTAssertEqual(manifest.family, "codex")
        XCTAssertEqual(manifest.packageVersion, "1")
        XCTAssertTrue(manifest.requiresRestart)
        XCTAssertTrue(manifest.requiresHookTrust)
        XCTAssertEqual(manifest.targets.map(\.id), ["codex.cli", "codex.desktop"])
        XCTAssertEqual(manifest.targets.map(\.mode), [.cli, .desktop])
        // The CLI target has adapter fixtures; desktop delivery is unproven.
        let levels = Dictionary(uniqueKeysWithValues: manifest.targets.map { ($0.id, $0.verificationLevel) })
        XCTAssertEqual(levels["codex.cli"], .fixture)
        XCTAssertEqual(levels["codex.desktop"], .unverified, "desktop stays unverified")
        for target in manifest.targets {
            XCTAssertEqual(target.capabilities, [.lifecycleHooks])
        }
        XCTAssertEqual(manifest.steps.count, 2)
        for (index, target) in ["codex.cli", "codex.desktop"].enumerated() {
            let step = manifest.steps[index]
            XCTAssertEqual(step.kind, .hookConfig)
            XCTAssertEqual(step.target, target)
            XCTAssertEqual(step.format, .toml)
            XCTAssertEqual(step.configRoot, .home(".codex"))
            XCTAssertEqual(step.path, "config.toml")
            XCTAssertEqual(step.ownedEntries.map(\.marker), ["awake-lite/\(target)/hooks"])
            XCTAssertEqual(step.ownedEntries.map(\.asset), ["hooks-toml"])
        }

        // The notes must state the trust step and the evidence level honestly.
        let notes = manifest.notes.joined(separator: " ")
        XCTAssertTrue(notes.contains("/hooks"))
        XCTAssertTrue(notes.contains("trust"))
        XCTAssertTrue(notes.contains("unverified"))
        XCTAssertTrue(notes.lowercased().contains("cloud"))

        // Real inline hook tables, one command handler per event.
        for event in CodexAdapter.documentedEvents {
            XCTAssertTrue(text.contains("[[hooks.\(event)]]"), "missing matcher group for \(event)")
            XCTAssertTrue(
                text.contains("[[hooks.\(event).hooks]]"),
                "missing handler table for \(event)"
            )
            XCTAssertTrue(text.contains("--event \(event)"), "handler \(event) passes its event")
        }
        XCTAssertEqual(occurrences(of: "type = \"command\"", in: text), CodexAdapter.documentedEvents.count)
        XCTAssertEqual(occurrences(of: "async = true", in: text), CodexAdapter.documentedEvents.count)
        XCTAssertEqual(occurrences(of: "timeout = ", in: text), CodexAdapter.documentedEvents.count)
        XCTAssertFalse(
            text.contains("SessionEnd"),
            "SessionEnd is not installed: one conversation ending proves nothing about owner death"
        )
        XCTAssertFalse(text.contains("matcher"), "every handler matches every occurrence")
        XCTAssertTrue(text.contains("--family codex"))
        XCTAssertTrue(text.contains("--generation {generation}"))
        XCTAssertTrue(text.contains("{helperPath}"))
        XCTAssertTrue(text.contains("{target}"))
        XCTAssertTrue(text.contains("{family}"))
        XCTAssertTrue(text.contains("{marker}"))
    }

    func testAssetRendersOnlyAllowedPlaceholdersAndCarriesNoShellLogic() throws {
        let manifest = try IntegrationFixtures.bundledCatalog().manifest(for: "codex")
        let text = try assetText(manifest)

        XCTAssertNil(Template.firstUnknownPlaceholder(in: text))
        let tokens = placeholderTokens(in: text)
        XCTAssertEqual(
            tokens,
            Set(Template.allowed),
            "the asset renders exactly the five app-owned placeholders"
        )

        let helperPath = "/Applications/AwakeLite.app/Contents/MacOS/AwakeLiteHelper"
        for (target, marker) in [
            (CodexAdapter.cliTarget, "awake-lite/codex.cli/hooks"),
            (CodexAdapter.desktopTarget, "awake-lite/codex.desktop/hooks")
        ] {
            let rendered = Template.renderText(
                text,
                values: Template.values(
                    marker: marker,
                    family: "codex",
                    target: target,
                    generation: 3,
                    helperPath: helperPath
                )
            )

            XCTAssertFalse(Template.containsPlaceholder(rendered))
            XCTAssertFalse(rendered.contains("{"), "no placeholder survives rendering")
            XCTAssertFalse(rendered.contains("}"), "no placeholder survives rendering")

            let commands = rendered
                .split(separator: "\n")
                .map(String.init)
                .filter { $0.hasPrefix("command = ") }
            XCTAssertEqual(commands.count, CodexAdapter.documentedEvents.count)

            // Exactly one helper invocation per handler: no command
            // substitution, pipe, sequence, background job, or redirection can
            // turn the helper's output or exit status into a Codex decision.
            // The two backslashes in each line are TOML escapes for the quoted
            // helper path; the exact-equality check below pins them. Everything
            // else that could chain, substitute, redirect, or background a
            // command must be absent.
            let metacharacters = Set("$`|;&<>()")
            for command in commands {
                XCTAssertTrue(
                    metacharacters.isDisjoint(with: Set(command)),
                    "the command must be a single inert invocation: \(command)"
                )
            }

            for event in CodexAdapter.documentedEvents {
                let expected = "command = \""
                    + "\\\"" + helperPath + "\\\""
                    + " --family codex --target \(target) --generation 3 --event \(event)"
                    + "\""
                XCTAssertEqual(
                    commands.filter { $0 == expected }.count,
                    1,
                    "expected the rendered handler for \(event)"
                )
            }
            XCTAssertTrue(rendered.contains(marker))
        }
    }

    // MARK: - Asset helpers

    private func assetText(_ manifest: PackageManifest) throws -> String {
        let asset = try XCTUnwrap(manifest.asset(withID: "hooks-toml"))
        XCTAssertEqual(asset.destination, "hooks/codex-hooks.toml")
        let url = manifest.familyDirectory.appendingPathComponent(asset.source)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        var count = 0
        var searchStart = text.startIndex
        while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }

    /// Every `{identifier}` token the loader would scan.
    private func placeholderTokens(in text: String) -> Set<String> {
        var tokens: Set<String> = []
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "{") {
            guard let close = text[open...].firstIndex(of: "}") else { break }
            tokens.insert(String(text[text.index(after: open)..<close]))
            searchStart = text.index(after: open)
        }
        return tokens
    }
}
