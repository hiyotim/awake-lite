import Foundation

// MARK: - Codex lifecycle hooks

/// Codex CLI and desktop (`codex.cli`, `codex.desktop`) lifecycle hooks.
///
/// Contract source: <https://learn.chatgpt.com/docs/hooks> (fetched 2026-11-01).
/// Hooks are configured inline in `~/.codex/config.toml` as
/// `[[hooks.<Event>]]` matcher groups with one `[[hooks.<Event>.hooks]]`
/// `type = "command"` handler, and every command handler receives one JSON
/// object on stdin. The asset this adapter serves is
/// `Resources/Integrations/codex/assets/codex-hooks.toml`.
///
/// ## One adapter for two targets
///
/// `HookAdapter` has a single `family`, and `HookAdapterRegistry` looks an
/// adapter up by family, so two adapters both claiming `codex` could never both
/// be reached. Both installed steps write the same asset into the same Codex
/// configuration file, differing only in the marker and the rendered `--target`.
/// This adapter therefore serves the family and reads the target from the
/// invocation (`HookInvocation.target`, stamped onto every event by
/// `HookInvocation.makeEvent`), refusing a target that is not one of the
/// documented ones. CLI and desktop events stay distinct in the model through
/// that field.
///
/// ## Documented payload allowlist
///
/// Only `session_id`, `turn_id`, and `hook_event_name` are read.
/// `permission_mode` is a documented field and stays in the allowlist, but no
/// transition depends on it, so it is not consulted: reading it would add a
/// rejection path without changing any state. Every other documented or
/// undocumented key (transcript location, working directory, model slug, prompt
/// text, tool input, tool output, subagent identifiers, continuation state) is
/// unreachable through `HookPayload`, so it cannot reach an event, a file name,
/// a diagnostic, or a stored byte.
///
/// ## Event set and mapping
///
/// | Vendor event | Documented meaning | Transition | Work |
/// | --- | --- | --- | --- |
/// | `UserPromptSubmit` | a prompt is about to be sent; turn-scoped | `started` | `turn-<turn_id>` |
/// | `PermissionRequest` | Codex is about to ask for approval | `humanWait` | `turn-<turn_id>` |
/// | `PostToolUse` | a supported tool produced output | `resumed` | `turn-<turn_id>` |
/// | `Stop` | the turn stopped | `completed` | `turn-<turn_id>` |
/// | `Interrupt` | the user interrupted an active turn | `cancelled` | `turn-<turn_id>` |
/// | `SubagentStart` | a subagent started | `childStarted` | `sub-<turn_id>`, parent `turn-<turn_id>` |
/// | `SubagentStop` | a subagent stopped | `childFinished` | `sub-<turn_id>`, parent `turn-<turn_id>` |
///
/// `SessionStart` is deliberately not registered. A session opening is not
/// work: an ordinary open desktop chat with no request must produce no hold
/// (A04), and `SessionStart` would be the only event that fires there.
/// `SessionEnd` is not registered either; see the owner-death limitation below.
///
/// ## Per-turn work instead of a session-long work item
///
/// Work is one record per turn, named from `turn_id`, so a continuation that
/// Codex starts after `Stop` begins a *new* record rather than resuming a
/// terminal one. This is required by the model's terminal-state rule: a
/// `completed`, `failed`, or `cancelled` record never accepts a later `resumed`
/// or `started` (only a snapshot `ended` record is revivable). Each turn is
/// therefore already a new work generation; the `generation` field stays `1`
/// because the work name itself never repeats inside one session and the
/// adapter holds no state between emissions.
///
/// ## Documented limitations
///
/// - **Release/re-acquire gap after `Stop`.** A `Stop` that another hook turns
///   into a continuation is not final (SPEC §4). The adapter cannot see that
///   decision: its own handler returns nothing, but another `Stop` handler may
///   return `decision: block` or exit 2, and Codex then creates a continuation
///   prompt. The completion event has already released the turn's record, so
///   the model is briefly idle until the continuation's `UserPromptSubmit`
///   starts the next turn. If a Codex version reuses the same `turn_id` for the
///   continuation, the `started` event is ignored as `terminalWork` and the
///   model stays idle while the continuation runs. The turn-id reuse question is
///   unverified, and `CodexAdapterTests` records both behaviors.
/// - **Approval decision is unobservable.** No documented event reports whether
///   a `PermissionRequest` was allowed, denied, or declined. `PostToolUse` is the
///   earliest documented signal after the request, so a long gated command, and
///   a denial followed by more work, stay `waitingForUser` until it arrives.
///   Only `SessionStart` documents an approval-related `source`, and registering
///   it would contradict A04.
/// - **Subagent granularity.** The identifier that distinguishes concurrent
///   subagents is outside the payload allowlist, so subagents of one turn share
///   one child record. A second concurrent subagent cannot reopen that record
///   once it reports `childFinished`; the parent turn stays `working` and keeps
///   the aggregate correct while related subagents run (A09 at aggregate level).
/// - **Owner death has no hook path.** `SessionEnd` reports that one
///   conversation ended, not that the owner process died, and the model's
///   `ownerTerminated` transition retires the whole owner instance. A process
///   that hosts several conversations would therefore release every other
///   conversation's hold on one conversation's end. Verified owner death is
///   Stage 5's probe, not a hook: this adapter declares no owner-death event.
///   A Codex session that ends without its turn reaching `Stop` or `Interrupt`
///   keeps that turn's hold (conservative) until the model reconciles it
///   another way; an orphaned session is never assumed idle.
/// - **Mid-turn installation.** A turn that started before the package was
///   installed has no record, so its `PermissionRequest`, `PostToolUse`, `Stop`,
///   and subagent events are ignored as `unknownWork`. The store reacts to that
///   with a session-scoped observation gap, so the aggregate reports `unknown`
///   (which allows sleep) instead of `idle` until the package is removed or
///   reinstalled; hooks have no authoritative snapshot that could clear it.
///   Nothing claims work the model never saw.
/// - **Cloud orchestration.** The vendor contract excludes local command hooks
///   from cloud orchestration. No hook runs, so nothing is observed there and no
///   work is invented. Local desktop delivery of these events is unverified;
///   the desktop target stays `unverified` in the manifest.
struct CodexAdapter: HookAdapter {
    // MARK: Documented vocabulary

    static let familyName = "codex"
    static let cliTarget = "codex.cli"
    static let desktopTarget = "codex.desktop"

    /// The target ids both bundled install steps use. An invocation with any
    /// other target is a configuration error, not a third compatibility mode.
    static let documentedTargets: Set<String> = [cliTarget, desktopTarget]

    /// Every payload key this adapter may read. See the allowlist note above.
    static let documentedPayloadFields: Set<String> = [
        "session_id", "turn_id", "hook_event_name", "permission_mode"
    ]

    /// The seven documented events this adapter declares. `--event` outside
    /// this set is refused before the payload is read.
    static let documentedEvents: Set<String> = [
        "UserPromptSubmit",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "Interrupt",
        "SubagentStart",
        "SubagentStop"
    ]

    /// Work name prefixes. `turn-` and `sub-` keep a turn record and its child
    /// records distinct inside one session.
    static let turnWorkPrefix = "turn-"
    static let childWorkPrefix = "sub-"

    /// One work generation per distinct work name; see the note above.
    static let turnGeneration: UInt64 = 1

    /// Longest accepted raw `session_id`, so `HookIdentifier.canonical` never
    /// truncates it into another session's name.
    static let maxSessionIdentifierCharacters = 64

    /// Longest accepted raw `turn_id`. Both prefixes plus this bound stay inside
    /// the 64-character canonical limit, so a work name is never truncated.
    static let maxTurnIdentifierCharacters = 64
        - max(turnWorkPrefix.count, childWorkPrefix.count)

    var family = CodexAdapter.familyName
    var eventNames = CodexAdapter.documentedEvents

    // MARK: Mapping

    func event(
        for invocation: HookInvocation,
        payload: HookPayload,
        owner: OwnerIdentity,
        now: Date
    ) throws -> ActivityEvent {
        guard Self.documentedTargets.contains(invocation.target) else {
            // The target is app-owned text rendered by the installer, never
            // payload content.
            throw HookIngestError.invalidUsage(
                "--target \"\(invocation.target)\" is not a documented Codex target"
            )
        }
        // The payload repeats the event name. A mismatch means the installed
        // command and the running hook disagree; the field name is the only
        // thing reported.
        if let reported = payload.string("hook_event_name"), reported != invocation.event {
            throw HookIngestError.malformedPayload("hook_event_name")
        }

        let session = try self.session(payload)

        switch invocation.event {
        case "UserPromptSubmit":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .started,
                work: try turnWork(payload),
                workGeneration: Self.turnGeneration
            )
        case "PermissionRequest":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .humanWait,
                work: try turnWork(payload),
                workGeneration: Self.turnGeneration
            )
        case "PostToolUse":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .resumed,
                work: try turnWork(payload),
                workGeneration: Self.turnGeneration
            )
        case "Stop":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .completed,
                work: try turnWork(payload),
                workGeneration: Self.turnGeneration
            )
        case "Interrupt":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .cancelled,
                work: try turnWork(payload),
                workGeneration: Self.turnGeneration
            )
        case "SubagentStart":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .childStarted,
                work: try childWork(payload),
                workGeneration: Self.turnGeneration,
                parentWork: try turnWork(payload)
            )
        case "SubagentStop":
            return invocation.makeEvent(
                owner: owner,
                timestamp: now,
                session: session,
                transition: .childFinished,
                work: try childWork(payload),
                workGeneration: Self.turnGeneration,
                parentWork: try turnWork(payload)
            )
        default:
            throw HookIngestError.unknownEvent(invocation.event)
        }
    }

    // MARK: Identifier mapping

    /// The parent session. Documented for every event.
    private func session(_ payload: HookPayload) throws -> String {
        try identifier(payload, "session_id", limit: Self.maxSessionIdentifierCharacters)
    }

    /// `turn-<turn_id>`. Documented for every event this adapter declares.
    private func turnWork(_ payload: HookPayload) throws -> String {
        Self.turnWorkPrefix + (try identifier(
            payload,
            "turn_id",
            limit: Self.maxTurnIdentifierCharacters
        ))
    }

    /// `sub-<turn_id>`: one child record per turn, as documented in the
    /// subagent-granularity limitation.
    private func childWork(_ payload: HookPayload) throws -> String {
        Self.childWorkPrefix + (try identifier(
            payload,
            "turn_id",
            limit: Self.maxTurnIdentifierCharacters
        ))
    }

    /// Reads one documented identifier, naming only the field on failure.
    ///
    /// Values are canonicalized like every adapter's (`HookIdentifier.canonical`),
    /// which maps characters outside `[A-Za-z0-9_-]` to `_`; two vendor ids that
    /// differ only in such characters would therefore alias. Documented Codex ids
    /// are UUID-shaped and unaffected. Length is refused instead of truncated,
    /// because truncation would merge identifiers inside the adapter itself.
    private func identifier(
        _ payload: HookPayload,
        _ field: String,
        limit: Int
    ) throws -> String {
        let raw = try payload.requiredString(field)
        guard !raw.isEmpty, raw.unicodeScalars.count <= limit else {
            throw HookIngestError.malformedPayload(field)
        }
        return HookIdentifier.canonical(raw)
    }
}
