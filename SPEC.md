# AwakeLite specification

Status: first-version scope reset on 2026-11-02. The user selected OMP CLI. Implementation remains incomplete; [STATE.md](STATE.md) records evidence.

## Purpose

AwakeLite is a native macOS menu-bar utility for personal use. It prevents automatic system sleep while OMP CLI performs observed work. It allows sleep after that work finishes or waits for a person. Leaving a conversation open must not keep the Mac awake.

Use Swift, SwiftUI, Foundation, and public macOS APIs. The deployment target remains macOS 13. Verification on one Mac does not establish support for other processor architectures.

## First-version scope

The only active compatibility target is `omp.cli`. Record the tested OMP version and execution mode during live acceptance. Do not infer compatibility with other versions or desktop products.

Reuse the existing OMP extension, native helper, activity model, event store, and power boundary. Use the existing installer only for OMP setup, with isolated-root verification before real configuration changes. The existing catalog is not a prerequisite for acceptance and receives no new features in this version.

Pi, Codex, OpenCode, Claude Code, Cursor, and Antigravity support is deferred. Existing files and historical evidence remain in the repository. Seven bundled families and ten manifest targets describe the existing inventory, not a first-release promise. Keep non-OMP families outside the first-version runtime contribution.

Defer a redesigned catalog, universal installation improvements, online packages, additional transports, and publication work. Do not delete unrelated work or installed support as part of documentation cleanup.

## User behavior

1. The user enables OMP support through a documented setup and starts a fresh OMP test session.
2. An open session with no active work shows idle or no data and creates no assertion.
3. A reliable work-start event creates one system-sleep assertion.
4. Long requests, retries, and observed background work retain the hold despite low CPU usage.
5. Completion, failure, or cancellation releases that work's contribution.
6. Waiting for a person permits sleep when no other observed work remains active.
7. Pause releases the assertion while retaining task state. Unpause recomputes the decision.
8. Quit releases the assertion and stops observation.

If OMP cannot report a required transition in the tested mode, record that limitation and keep automatic support experimental. Do not substitute a guessed timeout or silently claim full acceptance. In particular, verify `session_stop` and approval events on the installed OMP version.

## State and recovery

Track owner, session, work identity, and generations independently. Late or duplicate events and PID reuse must not end newer or unrelated work. Preserve the existing reducer protections even though only one family is active.

When observation of previously confirmed work is lost, preserve its hold and show uncertainty. An open but unobserved session creates no hold. Reliable completion, an authoritative state recovery, or verified owner termination can end work. Process presence, silence, and low CPU are not activity evidence.

Restore persisted facts on app restart and validate their owners before claiming idle. Bound event and checkpoint storage. Queue overflow or incomplete delivery must be visible. Never delete required history merely to achieve a size limit.

Only the app owns the model checkpoint and the power assertion. The short-lived helper writes metadata events and exits. Disabled packages run no observer. Reconciliation must recover from missed file notifications without running periodic inbox polling when no integration is enabled.

## Setup and privacy

Only committed OMP activation at the recorded generation may contribute to the model. Reject events from removed or older installations. Preserve receipt, journal, and generation checks when reusing the installer.

Change only AwakeLite-owned configuration entries. Preserve foreign settings and later user edits. Refuse unsafe paths, stale previews, unsupported formats, and conflicts. Do not download OMP or other agents to close an acceptance check.

Persist only lifecycle metadata. Do not inspect transcripts or persist conversation content, tool arguments, raw hook payloads, or credentials. Add no privileged service, persistent helper daemon, mandatory extra runtime, or analytics.

The assertion prevents automatic idle system sleep and permits display sleep. Closed-lid behavior, lock-screen bypass, and `pmset` changes are outside scope. UI status must reflect actual IOKit results, including acquisition and release errors.

## Acceptance criteria

The existing IDs remain stable. Apply them to OMP CLI for the first version; older multi-target evidence stays in STATE.

| ID | Observable behavior |
| --- | --- |
| A01 | With OMP support disabled, process presence creates no hold and no observer runs |
| A02 | OMP setup configures only selected support and repeated setup creates no duplicates |
| A03 | Removal preserves foreign settings and failures remain recoverable |
| A04 | An open idle OMP conversation permits sleep |
| A05 | Starting real OMP work creates a real IOKit assertion |
| A06 | Long requests and commands retain the assertion despite low CPU use |
| A07 | Completion, failure, and cancellation release the corresponding work's hold |
| A08 | Waiting for input or approval permits sleep when no other observed work remains active |
| A09 | Observed parallel sessions, subagents, and background work retain independent contributions |
| A10 | Continuation and retry do not produce false idle state |
| A11 | Duplicate and late events cannot corrupt newer work or reinstall generations |
| A12 | Restart, owner death, and PID reuse cannot create false idle state |
| A13 | Lost events, observer failure, and overflow appear as uncertainty |
| A14 | Pause and quit release the assertion, and IOKit errors are reported accurately |
| A15 | Persisted data and diagnostics contain no conversation content or credentials |
| A16 | Long observation does not create unbounded event storage |
| A17 | CPU use and wakeups are measured with OMP disabled, idle, and active |

Target processing latency after receiving a reliable event is at most two seconds. Measure OMP hook delivery separately. Neither latency nor battery cost is currently verified.

## Completion

A first isolated start/finish proof is a development checkpoint, not full acceptance. Before calling the OMP version accepted, record each applicable criterion, exact version, mode, evidence, and limitations. Fixtures and compilation do not replace live OMP checks. Missing lifecycle evidence keeps the affected behavior unverified.

[ROADMAP.md](ROADMAP.md) defines the order of work. [ARCHITECTURE.md](ARCHITECTURE.md) preserves the contracts of the existing code. Additional families require a later explicit scope decision after OMP acceptance and use.
