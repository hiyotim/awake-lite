import Foundation

// MARK: - Pi adapter

/// Pi in-process extension adapter (ROADMAP 3.2).
///
/// Sources, fetched before this file was written:
///
/// - `packages/coding-agent/docs/extensions.md` (event lifecycle, session and
///   agent events, `ui_prompt_start` / `ui_prompt_end`, extension discovery).
/// - `packages/coding-agent/src/core/extensions/types.ts` (`SessionStartEvent`,
///   `SessionShutdownEvent`, `AgentSettledEvent`, `TurnEndEvent`,
///   `AgentActivityOutcome`).
///
/// Documented facts the mapping rests on:
///
/// - `session_start` fires when a session is started, loaded, or reloaded, with
///   `reason: "startup" | "reload" | "new" | "resume" | "fork"`. An open or
///   freshly loaded session is not work (A04), so it never emits `started`.
/// - `agent_start` begins one low-level agent run. `agent_end` is explicitly
///   *not* a final-idle signal (retry, final-attempt recovery, compaction retry,
///   queued messages may follow); `agent_settled` is the final, notification-only
///   event.
/// - `turn_end.outcome` is `"completed" | "aborted" | "error"`.
/// - `ui_prompt_start` / `ui_prompt_end` bracket a blocking extension UI prompt,
///   documented "so host/status integrations can report 'waiting for user'".
/// - `session_shutdown.reason` is `"quit" | "reload" | "new" | "resume" | "fork"`.
///
/// Payload envelope written by `Resources/Integrations/pi/assets/awake-lite.pi.js`
/// and read here, field by field:
///
/// | Field | Source |
/// | --- | --- |
/// | `session` | documented `ctx.sessionManager.getSessionId()` |
/// | `workGeneration` | AwakeLite run discriminator stamped by the extension at `agent_start`; the vendor documents no run id, and the model needs a value that a later run cannot reuse (A11) |
/// | `sequence` | documented `turnIndex` |
/// | `reason` | documented `session_start` / `session_shutdown` reason |
/// | `outcome` | documented `turn_end` outcome |
/// | `aborted` | documented `agent_settled.aborted` |
///
/// `workGeneration` is optional on `session_shutdown`: the asset includes it
/// only when a run is active, so teardown cancels exactly that run. Without it,
/// `reason: "quit"` retires the owner's remaining work, and the other
/// documented reasons (`reload`, `new`, `resume`, `fork`) emit the same
/// incomplete session snapshot as `session_start`, because the process lives on
/// and a detached helper may land after the replacement runtime starts.
///
/// Work identity is one `run` per session and run generation. The run is the
/// unit that holds the assertion: a turn ending does not end the run, because
/// Pi may retry, compact, or run queued follow-ups. Only `agent_settled` is
/// terminal.
///
/// ## `run_superseded` (AwakeLite-internal, not a Pi event)
///
/// The extension stamps a new `workGeneration` at every `agent_start`. A retry,
/// compaction retry, or reloaded runtime therefore starts a generation while
/// the previous one may still be `working`, and Pi emits no event that closes
/// the replaced run. The asset keeps the previous generation and emits
/// `run_superseded` with `{session, workGeneration: <previous>}` immediately
/// before the new `agent_start`, which this adapter maps to `cancelled` for
/// that generation with no sequence. Without it a superseded run would hold the
/// assertion until the session shuts down. Pi never emits this name; it exists
/// only between the bundled asset and the helper.
///
/// Documented limitations, recorded rather than guessed:
///
/// - Pi exposes no subagent/task lifecycle event, so this adapter reports no
///   child work identity (A09 remains unverified for Pi).
/// - Human wait is only observable for extension UI prompts. Pi documents no
///   event for a host-owned prompt or approval.
/// - A run that fails without an `error` turn outcome is indistinguishable from
///   a completed one at `agent_settled`, which carries only `aborted`.
/// - `turn_end` with outcome `error` ends that run's generation. Pi may retry
///   after `agent_end`; the retry's `agent_start` is a new generation preceded
///   by `run_superseded`. Between the `agent_end` and that retry,
///   `turn_start`/`turn_end` have already been reported and the run keeps
///   working: this adapter does not subscribe to `agent_end`, so the backoff
///   window is conservative (a hold) rather than an unobserved idle claim. A
///   run that reports `error` and is then retried is closed by the supersede
///   event even when the error generation never reached `agent_settled`.
/// - Vendor identifiers are refused, not canonicalized: a `session` or
///   `parentWork` value outside `[A-Za-z0-9_-]`, or longer than 64 characters,
///   is a malformed payload. Canonicalizing would silently merge two vendor ids
///   into one session or one work record.
/// - `turn_start` and `turn_end` carry the documented `turnIndex` when Pi
///   provides it, but the run generation already separates runs and a missing
///   index must not make a turn event unusable; `sequence` is optional.
/// - A run that a hot reload replaced without the old extension observing it is
///   left uncertain, not retired: the process outlives a `reload`, and the
///   detached shutdown helper's write order relative to the new runtime is not
///   documented.
struct PiAdapter: HookAdapter {
    static let familyName = "pi"

    /// The only work name this adapter produces.
    static let workName = "run"

    static let startReasons: Set<String> = ["startup", "reload", "new", "resume", "fork"]
    static let shutdownReasons: Set<String> = ["quit", "reload", "new", "resume", "fork"]

    static let transitionsByOutcome: [String: ActivityTransition] = [
        // A completed turn is progress inside the run, not its completion.
        "completed": .heartbeat,
        "error": .failed,
        "aborted": .cancelled
    ]

    var family: String { Self.familyName }

    /// Documented Pi extension events the bundled asset maps, plus the
    /// AwakeLite-internal `run_superseded`. Anything else is refused by the
    /// normalizer as an undocumented event.
    var eventNames: Set<String> {
        [
            "session_start",
            "session_shutdown",
            "agent_start",
            "turn_start",
            "turn_end",
            "ui_prompt_start",
            "ui_prompt_end",
            "agent_settled",
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
            _ = try Self.requireReason(payload, allowed: Self.startReasons)
            // An incomplete session snapshot records no work and cannot claim
            // idle: it only turns this session's unverified active work
            // uncertain. That is the conservative answer for a session that has
            // just been loaded, reloaded, or created (A04).
            return Self.snapshot(
                invocation,
                owner: owner,
                now: now,
                session: session
            )

        case "session_shutdown":
            let reason = try Self.requireReason(payload, allowed: Self.shutdownReasons)
            // A run this extension instance observed cannot continue once the
            // runtime is torn down, so cancel exactly that run. The model's
            // `snapshot` path cannot express completion here: `HookNormalizer`
            // re-stamps `snapshotComplete` to false.
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
            // Only `quit` ends the process. Retirement by owner identity is
            // correct there: it ends this owner's remaining work instead of
            // leaving a stale hold. `reload`, `new`, `resume`, and `fork` keep
            // the process alive, and their detached helper may land after the
            // replacement runtime's `agent_start`, so retiring by owner would
            // end a newer run and hold the Mac awake. Those reasons therefore
            // produce the same conservative incomplete session snapshot as
            // `session_start`: no work recorded, no idle claim, and other
            // sessions or newer generations are untouched.
            guard reason == "quit" else {
                return Self.snapshot(
                    invocation,
                    owner: owner,
                    now: now,
                    session: session
                )
            }
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .ownerTerminated
            )

        case "agent_start":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .started
            )

        case "turn_start":
            // A turn begins inside the run, so the run is still working. The
            // documented `turnIndex` is optional: the run generation already
            // separates runs, and a missing index must not lose the turn.
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .started
            )

        case "turn_end":
            let outcome = try payload.requiredString("outcome")
            guard let transition = Self.transitionsByOutcome[outcome] else {
                throw HookIngestError.malformedPayload("outcome")
            }
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: transition
            )

        case "ui_prompt_start":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .humanWait
            )

        case "ui_prompt_end":
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: .resumed
            )

        case "agent_settled":
            let aborted = payload.bool("aborted") ?? false
            return try Self.run(
                invocation,
                payload: payload,
                owner: owner,
                now: now,
                session: session,
                transition: aborted ? .cancelled : .completed
            )

        case "run_superseded":
            // AwakeLite-internal: the asset names the generation it is about to
            // replace. It is terminal for that generation only and carries no
            // sequence, so a run that never reaches `agent_settled` cannot hold
            // the assertion for the rest of the session.
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
        transition: ActivityTransition
    ) throws -> ActivityEvent {
        let workGeneration = try payload.requiredUInt64("workGeneration")
        return invocation.makeEvent(
            owner: owner,
            timestamp: now,
            session: session,
            transition: transition,
            work: Self.workName,
            workGeneration: workGeneration,
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

    /// A documented vendor identifier, used as-is.
    ///
    /// The value must already be canonical and at most 64 scalars. Anything
    /// else is refused naming only the field: canonicalizing or truncating
    /// would silently merge two vendor ids into one session or one work
    /// record, and the model would then treat one agent's events as another's.
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

    private static func requireReason(_ payload: HookPayload, allowed: Set<String>) throws -> String {
        let reason = try payload.requiredString("reason")
        guard allowed.contains(reason) else {
            throw HookIngestError.malformedPayload("reason")
        }
        return reason
    }
}
