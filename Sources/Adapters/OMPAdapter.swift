import Foundation

// MARK: - OMP adapter

/// OMP in-process extension adapter (ROADMAP 3.2).
///
/// Sources, fetched before this file was written:
///
/// - `packages/coding-agent/docs/extensions.md` (event surface, prompt/turn
///   lifecycle, subagent lifecycle, reliability signals, background work).
/// - `packages/coding-agent/docs/extension-loading.md` (discovery roots and
///   one-level `index.ts` / `index.js` scanning).
/// - `src/extensibility/extensions/types.ts` and `src/extensibility/shared-events.ts`
///   (`SessionStartEvent`, `SessionShutdownEvent`, `AgentEndEvent`,
///   `SessionStopEvent`, `AutoRetryStartEvent`, `AutoRetryEndEvent`,
///   `ToolApprovalRequestedEvent`, `ToolApprovalResolvedEvent`,
///   `ExtensionAgentIdentity`).
///
/// Documented facts the mapping rests on:
///
/// - `session_start` fires on initial session load and carries no reason; an
///   open session is not work (A04).
/// - `agent_start` / `agent_end` are "agent loop lifecycle notification".
///   `AgentEndEvent.willContinue` documents "not a terminal settle: an
///   automatic continuation is scheduled, or background work may resume the
///   session", and `awaitingAsyncWork` distinguishes background work. With
///   neither flag the loop ended, which is a terminal settle for a keep-awake
///   observer; this is also the only end signal when the user interrupts with
///   Esc while the session stays open.
/// - `session_stop` is the "main-session stop hook, awaited before settle",
///   "never fires for task/subagent sessions", and "defers until agent-owned
///   background jobs are fully idle". It completes a run that is still working;
///   when `agent_end` already completed it, the model ignores the duplicate
///   terminal update.
/// - `auto_retry_start` / `auto_retry_end` report automatic retry, with
///   `AutoRetryEndEvent.success`.
/// - `tool_approval_requested` / `tool_approval_resolved` are documented
///   observability events for a tool approval, the documented human wait (A08).
/// - `session_shutdown` is documented as "fired on process exit
///   (SIGINT/SIGTERM)".
/// - Extension factories are rebound to every subagent session and
///   `ctx.agent` documents `kind: "main" | "sub"` plus the spawning agent's
///   `parentId`, so a subagent reports separate child work with a parent (A09).
///
/// Payload envelope written by `Resources/Integrations/omp/assets/awake-lite.omp.js`
/// and read here, field by field:
///
/// | Field | Source |
/// | --- | --- |
/// | `session` | documented `ctx.sessionManager.getSessionId()` |
/// | `workGeneration` | AwakeLite run discriminator stamped by the extension at `agent_start`; the vendor documents no run id, and a later run must not reuse an earlier one (A11) |
/// | `agentKind` | documented `ctx.agent.kind` |
/// | `parentWork` | documented `ctx.agent.parentId` |
/// | `sequence` | documented `turnIndex` |
/// | `willContinue`, `awaitingAsyncWork` | documented `agent_end` fields |
/// | `success` | documented `auto_retry_end.success` |
///
/// `workGeneration` is optional on `session_shutdown`: the asset includes it
/// only when a run is active, so teardown cancels that run instead of guessing
/// a run identity or retiring another session's work.
///
/// `session_stop` also documents a `turn_id`, but it is a different counter from
/// `turnIndex`. The model has one sequence per work item and rejects a value
/// that does not exceed the last one, so mixing the two counters could reject a
/// real completion. `session_stop` therefore carries no sequence, and the run
/// generation separates runs.
///
/// ## `run_superseded` (AwakeLite-internal, not an OMP event)
///
/// The extension stamps a new `workGeneration` at every `agent_start`. A
/// continuation (including one a `session_stop` handler requested), a retry, or
/// a reloaded runtime starts a run while the previous one may still be
/// `working`, and OMP emits no event that closes the replaced run in a mode
/// that never reaches `session_stop`. The asset keeps the previous generation
/// and emits `run_superseded` with `{session, workGeneration: <previous>}`
/// immediately before the new `agent_start`, and before resetting the
/// generator on a `session_start` that arrives while a run is active; this
/// adapter maps it to `cancelled` for that generation with no sequence.
/// Without it the replaced run would hold the assertion until the process
/// shuts down. The model also ends an active main run whose generation is
/// older than the newest record in the same session, so one lost best-effort
/// emission cannot hold the assertion forever. OMP never emits this name; it
/// exists only between the bundled asset and the helper.
///
/// Documented limitations, recorded rather than guessed:
///
/// - `session_switch` documents only `previousSessionFile` for the old session;
///   no old-session identifier is documented, so a switch cannot retire the old
///   session's work authoritatively from the new session's handler.
/// - `agent_end` carries no run outcome, so a main-session run that fails or is
///   aborted still settles as `completed`; `auto_retry_end success: false` is
///   the only explicit failure signal.
/// - A `session_stop` handler can request a continuation (the documented cap is
///   8), which reopens work through the next `agent_start`; no event states the
///   requesting handler's outcome.
/// - A mode that emits neither a terminal `agent_end` nor `session_stop` leaves
///   a main-session run working until `session_shutdown`.
/// - Vendor identifiers (`session`, `parentWork`) must already be canonical and
///   at most 64 scalars; anything else is a malformed payload. Canonicalizing
///   would merge two vendor ids into one session, child, or parent record. A
///   documented `parentId` outside that set therefore attaches no child work:
///   the direction is conservative, and no parent is invented.
/// - The documentation says `tool_approval_requested` / `tool_approval_resolved`
///   are emitted only when a tool requires approval and an approval handler is
///   registered. Whether this extension's subscription alone satisfies that
///   condition is unverified, so the human-wait mapping is unverified too.
struct OMPAdapter: HookAdapter {
    static let familyName = "omp"

    /// The only work name this adapter produces.
    static let workName = "run"

    static let agentKinds: Set<String> = ["main", "sub"]

    var family: String { Self.familyName }

    /// Documented OMP extension events the bundled asset maps, plus the
    /// AwakeLite-internal `run_superseded`.
    var eventNames: Set<String> {
        [
            "session_start",
            "session_shutdown",
            "agent_start",
            "turn_start",
            "agent_end",
            "session_stop",
            "auto_retry_start",
            "auto_retry_end",
            "tool_approval_requested",
            "tool_approval_resolved",
            "run_superseded"
        ]
    }

    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        let session = try Self.requiredIdentifier(payload, "session")

        switch invocation.event {
        case "session_start":
            // Incomplete snapshot: reports no work, and only makes this
            // session's unverified active work uncertain (A04).
            return Self.snapshot(
                invocation,
                owner: owner,
                now: now,
                session: session
            )

        case "session_shutdown":
            // Documented as process exit. A run this extension instance
            // observed cannot continue, so cancel exactly that run. Subagents
            // share the process owner, and no documented event ties a child
            // teardown to the parent, so this adapter never retires work by
            // owner identity.
            if let generation = payload.uint64("workGeneration"), generation > 0 {
                return invocation.makeEvent(
                    owner: owner,
                    timestamp: now,
                    session: session,
                    transition: .cancelled,
                    work: Self.workName,
                    workGeneration: generation
                )
            }
            // No run was observed. An incomplete session snapshot records no
            // work and cannot claim idle or success.
            return Self.snapshot(
                invocation,
                owner: owner,
                now: now,
                session: session
            )

        case "agent_start":
            let kind = try Self.requiredKind(payload)
            if kind == "sub" {
                let parent = try Self.requiredParent(payload)
                return try Self.run(
                    invocation,
                    payload: payload,
                    owner: owner,
                    now: now,
                    session: session,
                    transition: .childStarted,
                    parentWork: parent
                )
            }
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .started
            )

        case "turn_start":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .started
            )

        case "agent_end":
            let willContinue = payload.bool("willContinue") ?? false
            let awaitingAsyncWork = payload.bool("awaitingAsyncWork") ?? false
            if willContinue || awaitingAsyncWork {
                // Documented as not a terminal settle: a continuation is
                // scheduled or background work may resume the session (A10).
                return try Self.run(
                    invocation,
                    payload: payload,
                    owner: owner,
                    now: now,
                    session: session,
                    transition: .heartbeat
                )
            }
            // `willContinue: false` is a terminal settle for the agent loop.
            // `session_stop` is the awaited pre-settle hook, but it does not
            // fire when the user interrupts a turn with Esc while the session
            // stays open; treating that end as a heartbeat left the assertion
            // held indefinitely. A subagent has no session_stop at all, so its
            // loop end is the only completion signal.
            let kind = try Self.requiredKind(payload)
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: kind == "sub" ? .childFinished : .completed
            )

        case "session_stop":
            guard try Self.requiredKind(payload) == "main" else {
                // Documented: session_stop never fires for task/subagent sessions.
                throw HookIngestError.malformedPayload("agentKind")
            }
            var event = try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .completed
            )
            // Never let a stop overwrite the run sequence with another counter.
            event.sequence = nil
            return event

        case "auto_retry_start":
            // A retry is the run still working, never a completion.
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .heartbeat
            )

        case "auto_retry_end":
            let succeeded = payload.bool("success")
            guard let succeeded else {
                throw HookIngestError.malformedPayload("success")
            }
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: succeeded ? .heartbeat : .failed
            )

        case "tool_approval_requested":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .humanWait
            )

        case "tool_approval_resolved":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .resumed
            )

        case "run_superseded":
            // AwakeLite-internal: the asset names the generation it is about to
            // replace. Terminal for that generation only, with no sequence, so
            // a run that never reaches `session_stop` cannot hold the assertion
            // for the rest of the process lifetime.
            var event = try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .cancelled
            )
            event.sequence = nil
            return event

        default:
            throw HookIngestError.unknownEvent(invocation.event)
        }
    }

    // MARK: Builders

    private static func run(
        _ invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date,
        session: String,
        transition: ActivityTransition,
        parentWork: String? = nil
    ) throws -> ActivityEvent {
        let workGeneration = try payload.requiredUInt64("workGeneration")
        return invocation.makeEvent(
            owner: owner,
            timestamp: now,
            session: session,
            transition: transition,
            work: Self.workName,
            workGeneration: workGeneration,
            parentWork: parentWork,
            sequence: payload.uint64("sequence")
        )
    }

    /// Session-scoped snapshot with no entries and `snapshotComplete == false`
    /// (the helper re-stamps it anyway). It records no work and cannot claim
    /// idle; it only turns this session's unverified active work uncertain.
    private static func snapshot(
        _ invocation: HookInvocation,
        owner: OwnerIdentity,
        now: Date,
        session: String
    ) -> ActivityEvent {
        ActivityEvent(
            id: "",
            source: invocation.family,
            activationGeneration: invocation.generation,
            target: invocation.target,
            owner: owner,
            session: SessionIdentity(
                family: invocation.family,
                instance: owner.instance,
                session: session
            ),
            transition: .snapshot,
            timestamp: now,
            scope: .session,
            snapshotEntries: [],
            snapshotComplete: false
        )
    }

    // MARK: Payload helpers

    private static func requiredKind(_ payload: HookPayload) throws -> String {
        let kind = try payload.requiredString("agentKind")
        guard agentKinds.contains(kind) else {
            throw HookIngestError.malformedPayload("agentKind")
        }
        return kind
    }

    /// A subagent's documented spawning agent id, canonicalized. Missing means
    /// the child cannot be attached to a parent, which is refused rather than
    /// recorded as parentless child work (A09).
    private static func requiredParent(_ payload: HookPayload) throws -> String {
        try requiredIdentifier(payload, "parentWork")
    }

    /// A documented vendor identifier, used as-is.
    ///
    /// The value must already be canonical and at most 64 scalars. Anything
    /// else is refused naming only the field: canonicalizing or truncating
    /// would silently merge two vendor ids into one session, child, or parent
    /// work record.
    private static func requiredIdentifier(_ payload: HookPayload, _ field: String) throws -> String {
        let value = try payload.requiredString(field)
        guard !value.isEmpty,
              value.unicodeScalars.count <= HookIdentifier.maxLength,
              HookIdentifier.canonical(value) == value
        else {
            throw HookIngestError.malformedPayload(field)
        }
        return value
    }
}
