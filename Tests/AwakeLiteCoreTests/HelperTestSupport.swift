import Foundation
@testable import AwakeLiteCore

/// Fixtures shared by the helper-ingestion checks.
///
/// Family adapters are registered by `HookAdapterRegistry`, which ships with no
/// bundled family in unit 3.1. The tests therefore inject a fixture adapter with
/// the same shape a real one has: a family, a documented event allowlist, and
/// one mapping from allowlisted payload fields to an event.
enum HelperFixtures {
    static let family = "fixture"
    static let target = "fixture.cli"

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Seeded strings that must never reach stored bytes or a diagnostic.
    static let seededSecrets = [
        "PROMPT-SEED-3a1",
        "RESPONSE-SEED-4b2",
        "TOOLARGS-SEED-5c3",
        "CREDENTIAL-SEED-6d4"
    ]

    // MARK: Roots and install state

    static func makeSandbox() throws -> URL {
        try IntegrationFixtures.makeSandbox()
    }

    /// Writes a committed receipt, which is the only thing that activates a
    /// family for ingestion.
    @discardableResult
    static func activate(
        family: String = HelperFixtures.family,
        generation: UInt64 = 1,
        root: URL
    ) throws -> InstallReceipt {
        let storage = InstallerStorage(root: root)
        try storage.prepare()
        let receipt = InstallReceipt(
            schema: InstallReceipt.currentSchema,
            family: family,
            packageVersion: "1",
            activationGeneration: generation,
            installedAt: epoch,
            stage: .committed,
            entries: [],
            previousGeneration: generation > 1 ? generation - 1 : nil,
            createdDirectories: []
        )
        try storage.saveReceipt(receipt)
        return receipt
    }

    /// Writes an operation journal that has not reached `committed`.
    static func writeJournal(
        family: String = HelperFixtures.family,
        stage: InstallStage,
        root: URL
    ) throws {
        let storage = InstallerStorage(root: root)
        try storage.prepare()
        try storage.writeJournal(
            OperationJournal(
                schema: OperationJournal.currentSchema,
                operationId: "op-1",
                family: family,
                action: .install,
                stage: stage,
                startedAt: epoch,
                steps: [],
                createdPaths: [],
                expectedMutations: 0,
                receipt: nil
            )
        )
    }

    // MARK: Payloads

    static func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// The documented fixture payload shape plus the unknown keys a real vendor
    /// payload carries.
    static func documentedPayload(
        session: String = "session-1",
        work: String = "work-1",
        generation: UInt64 = 7,
        sequence: UInt64 = 42
    ) throws -> Data {
        try payload([
            "session": session,
            "work": work,
            "generation": generation,
            "sequence": sequence,
            "prompt": seededSecrets[0],
            "response": seededSecrets[1],
            "toolArguments": seededSecrets[2],
            "credential": seededSecrets[3]
        ])
    }

    // MARK: Inbox

    static func eventFiles(in root: URL) -> [URL] {
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        return IntegrationFixtures.files(under: inbox)
            .filter { $0.pathExtension == "event" }
    }

    /// Every regular file below `root`, for "nothing was written" assertions.
    static func files(in root: URL) -> [URL] {
        IntegrationFixtures.files(under: root)
    }

    static func decodeEvent(_ url: URL) throws -> ActivityEvent {
        try JSONDecoder().decode(ActivityEvent.self, from: Data(contentsOf: url))
    }

    static func decodeObject(_ url: URL) throws -> [String: Any] {
        try IntegrationFixtures.jsonObject(url)
    }
}

/// Adapter with the exact shape a family adapter has, over a documented
/// payload shape (`session`, `work`, `generation`, `sequence`, `parentWork`).
struct FixtureAdapter: HookAdapter {
    var family = HelperFixtures.family

    var eventNames: Set<String> = [
        "start", "wait", "resume", "finish", "fail", "cancel", "beat"
    ]

    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        let session = HookIdentifier.canonical(try payload.requiredString("session"))
        let work = HookIdentifier.canonical(try payload.requiredString("work"))
        let transition: ActivityTransition
        switch invocation.event {
        case "start": transition = .started
        case "wait": transition = .humanWait
        case "resume": transition = .resumed
        case "finish": transition = .completed
        case "fail": transition = .failed
        case "cancel": transition = .cancelled
        case "beat": transition = .heartbeat
        default: throw HookIngestError.unknownEvent(invocation.event)
        }
        return invocation.makeEvent(
            owner: owner,
            timestamp: now,
            session: session,
            transition: transition,
            work: work,
            workGeneration: payload.uint64("generation") ?? 1,
            parentWork: payload.string("parentWork").map(HookIdentifier.canonical),
            sequence: payload.uint64("sequence")
        )
    }
}

/// Adapter that passes a vendor identifier through unchanged. Used to prove the
/// normalizer refuses an identifier that would not survive `enqueue`'s
/// canonical check instead of silently aliasing two sessions.
struct RawIdentifierAdapter: HookAdapter {
    var family = HelperFixtures.family
    var eventNames: Set<String> = ["start"]

    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        invocation.makeEvent(
            owner: owner,
            timestamp: now,
            session: payload.string("session") ?? "",
            transition: .started,
            work: payload.string("work")
        )
    }
}

/// Adapter shaped like a snapshot-only source: it reports that a field it
/// documents is missing instead of guessing.
struct StrictAdapter: HookAdapter {
    var family = HelperFixtures.family
    var eventNames: Set<String> = ["start"]

    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        let required = try payload.requiredString("session")
        return invocation.makeEvent(
            owner: owner,
            timestamp: now,
            session: HookIdentifier.canonical(required),
            transition: .started
        )
    }
}
