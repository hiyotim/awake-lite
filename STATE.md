# AwakeLite state

Updated: 2026-11-02. This update records source inspection and documentation changes only. No build, test, app launch, IOKit check, real settings edit, commit, or publication occurred in this reset.

## Current task and authorization

The user requested documentation cleanup and a plan for a smaller first working version. The user selected OMP CLI (`omp.cli`). That documentation task is complete; product implementation has not advanced in this reset.

Implementation was previously approved. The next development request starts with ROADMAP R1, not the former Stage 4 expansion. Commits, pushes, publication, release uploads, and system installs remain separately authorized actions. The current documentation task does not initiate them.

The worktree already contained modified and untracked implementation, tests, manifests, build files, and documents before cleanup. These source changes remain intact. HEAD is `8ad74fd`; its historical prototype behavior is not the current worktree's behavior. No reset, checkout, or deletion was performed.

## Active scope

- First-version target: OMP CLI only. The exact version and execution mode must be recorded at live acceptance.
- First objective: a real OMP task starts an assertion and completion releases it while the idle conversation stays open.
- Next development unit: R1, the isolated production path, followed immediately by R2, real OMP delivery.
- Other families, desktop support, catalog expansion, and universal installation improvements are deferred.
- Existing seven-family, ten-target resources and historical fixtures remain preserved. No target is `live`.

## Actual source state

| Area | Observed on 2026-11-02 | Evidence limit |
| --- | --- | --- |
| Old scanner | `Sources/ProcessScanner.swift` is deleted in the worktree | Historical prototype evidence no longer describes current source |
| Controller | Starts with `AggregateDecision(state: .idle, holdAssertion: false, reasons: [])`; no app caller invokes its decision update | The current source has no connected agent-to-power path |
| Power | `Sources/PowerAssertion.swift` implements `PowerPolicy` and an injectable IOKit boundary | Source and tests exist; no fresh native result recorded |
| App coordination | Startup recovery, activation, inbox reconciliation, owner validation, and decision delivery are not connected | R1 is incomplete |
| OMP | Extension, adapter, helper, and metadata fixtures exist | No real OMP delivery or first-version acceptance |
| Installer UI | Catalog exists; `IntegrationsStore` resolves the helper from `Bundle.main.bundleURL` and injects its path into Installer | Resolution source and helper-path tests exist; no fresh run or visual check |
| OpenCode and other targets | Existing code and resources remain; OpenCode has no scheduled caller | Deferred, not automatically enabled by the narrowed plan |

Do not describe the current checkout as a working keep-awake utility. An older generated or installed bundle may contain different code; its behavior was not inspected in this reset.

## Current evidence and blockers

The last recorded full run is the 2026-11-01 Stage 3 review result of 272 tests, zero failures. That is historical evidence, not verification of the current worktree.

Source inspection finds 294 XCTest method declarations. The additional suites declare 12 `PowerPolicyTests` and 10 `HelperPathTests` methods. No claim is made that these 294 methods were executed successfully. The count can be regenerated with `rg -n '^    func test' Tests/AwakeLiteCoreTests | wc -l`.

`PowerPolicyTests.testRealIOKitAssertionIsCreatedAndReleased` creates and reads back a real temporary assertion, and may skip if acquisition is refused. The current suite is not entirely fixture-only. `Package.swift` includes `PowerAssertion.swift` in the library; the controller and app UI still compile only through `build.sh`.

Blockers to a working OMP version:

1. App-owned startup and event reconciliation do not supply the aggregate power decision.
2. No real OMP task has established event completeness, especially main-run `session_stop`, retry, background work, or approval events.
3. Runtime recovery and owner validation are unverified. OMP's supplied owner token has no measured start time.
4. The inbox file cap is detected at reconcile, not enforced before producer bursts while the app is stopped. This remains a first-version reliability requirement.
5. The helper path now comes from the app bundle in the catalog path, but shell-context escaping for unusual paths remains unverified. Do not carry forward the former fixed-path claim as current UI behavior.

## Current plan

R0 documentation reset is complete. R1, R2, R3, and R4 have not started under the new plan. See [ROADMAP.md](ROADMAP.md) for each unit's exit check. R1 must produce isolated real assertion behavior before R2 checks OMP delivery. R3 closes reliability and acceptance; R4 removes unused parts after the OMP path is proven.

## Earlier implementation and evidence

The sections below preserve former Stages 1–3, the dated review, compatibility matrix, and unresolved limits. Stage numbers refer to the earlier plan, not the next task. Former Stage 5 app wiring maps to R1; native and live checks map to R2 and R3; storage-cap and owner-probe work maps to R3. Other-family implementation is deferred.

The Stage 3 review recorded 19 findings on 2026-11-01: 15 fixed, M3 and M5 deferred, L3 documented-only, and L2 withdrawn. Those dispositions describe that review date. Current source observations above do not claim new passing tests or live acceptance.

### Stage 2 integration catalog, installer, and activation (implemented, fixtures only)

- `Sources/Integrations/Manifest.swift`: strict schema-1 reader. Refuses unknown top-level, target, asset, step, and owned-entry keys; unknown kind/format/mode/capability/verification values; a family that does not match its directory; target ids without the `"<family>."` prefix; duplicate target, asset, destination, or marker ids; absolute, escaping, empty-component, symlinked, or missing asset sources; escaping asset destinations; empty targets/steps/owned entries; invalid `configRoot` selectors; `keyPath` outside JSON; and unknown `{placeholder}` tokens in asset text. Every message names `<family>/manifest.json` and the field.
- `Sources/Integrations/Catalog.swift`: loads all seven bundled manifests, enforces catalog-wide marker and target-id uniqueness, and resolves target availability through `ProductDiscovery` — documented home-relative executables and application bundles resolved against an injected home root and injected application roots. Discovery never launches a product, never runs a subprocess, and never raises a verification level.
- `Sources/Integrations/ConfigEditor.swift`: atomic writes that preserve an existing file's mode and sweep abandoned `.awake-lite-*.tmp` files; symlink refusal from the injected root down; structural JSON mutation at one key path; marker-delimited blocks for TOML/YAML/text; placeholder rendering (`{helperPath}`, `{family}`, `{target}`, `{generation}`, `{marker}`) as a single left-to-right pass that never re-substitutes an inserted value.
- `Sources/Integrations/InstallPlan.swift` and `Installer.swift`: `preview`, `apply`, `remove`, `recoverPending`; schema-1 receipt and operation journal; app-owned `packages/<family>/`, `receipts/`, `journal/`; installation stages `prepared`, `applying`, `committed`, `recoveryRequired`; hash-checked rollback with idempotent app-owned undo instructions; stale-preview refusal.
- `Sources/Integrations/Activation.swift` (unit 2.4): `ActivationHandoff(appSupportRoot:)` reads committed receipts and journals and produces `ActivationState` (`active` with family and generation, `inactive`, `unresolved`). `apply(to:)` is the startup handoff: it activates each committed family at its generation and deactivates every family in the model without one; `revoke(family:in:)` is the removal handoff and refuses while a committed receipt remains. `readState()` and both apply functions only read receipts and journals and call the model's `activate`/`deactivate`: no observer, timer, subprocess, event write, or power decision.
- `Package.swift` compiles `Sources/Core`, `Sources/Integrations`, `Sources/Adapters`, and `Sources/HookNormalizer.swift` in the single `AwakeLiteCore` target (the app-only sources stay excluded), plus the `AwakeLiteHelper` executable target over `Helper/`. `build.sh` compiles the integration and adapter sources, builds the helper into the bundle's `Contents/MacOS/`, signs it, and copies `Resources/Integrations/` into `AwakeLite.app/Contents/Resources/Integrations/`.

The activation handoff is not yet called by the app: startup wiring belongs to Stage 5.

### Stage 3 helper, adapters, and installed harness support (implemented, fixtures only)

No live harness session was performed for any of these units. Every statement below is source inspection or a fixture run; the per-target matrix in the Evidence section records what that leaves unverified.

**Unit 3.1, helper ingestion (`Helper/main.swift`, `Sources/Adapters/HelperRunner.swift`, `Sources/HookNormalizer.swift`)**

- The helper is a short-lived process shell: `Helper/main.swift` is `exit(HelperEntryPoint.main(arguments: Array(CommandLine.arguments.dropFirst())))` and every behavior lives in the library, so XCTest drives the production path with injected arguments, stdin bytes, root, clock, and owner.
- Command line: `AwakeLiteHelper --family <f> --target <t> --generation <n> --event <e> [--app-support <dir>] [--owner-instance <canonical token ≤64> --owner-pid <pid>]`. A missing, duplicated, empty, or unknown flag, a non-canonical family, a `--target` without the `<family>.` prefix, a non-positive generation, an event token outside `[A-Za-z0-9_-]` or longer than 128 characters, and a relative `--app-support` are all refused as exit 2. The same exit covers one owner flag without the other, a non-canonical or oversize `--owner-instance`, and a `--owner-pid` that is not an integer above 1. `--app-support` defaults to `~/Library/Application Support/AwakeLite`.
- stdin is bounded at 64 KiB (one byte past the bound is read to distinguish "at" from "over"), may be empty, and otherwise must be exactly one JSON object. stdout is always empty; failures print exactly one diagnostic line to stderr naming a flag, field, or path, never a payload byte.
- Exit codes: 0 = exactly one event file written; 2 = invalid input, usage, unknown family or event, or malformed/oversize payload; 3 = the family is inactive, the generation is stale, or the install state could not be read; 4 = the storage write failed.
- `HookNormalizer.ingest` fixes the order: registered family and documented event name → activation decided from committed receipts and unresolved journals with an unreadable state failing closed → bounded payload parse → adapter mapping → invariant re-stamp (schema, family, generation, target, owner, session instance, timestamp, `snapshotComplete = false`, fresh event id) → canonical-identifier validation → `LocalEventStore.enqueue`. Activation is checked before any payload byte is parsed and before storage is touched, so an inactive family cannot create a directory, lock, or file. An unreadable receipts/journal tree is reported as `activationUnavailable(path:)` — the install state, not a receipt the family does not own — and still exits 3 without writing.
- `HookPayload` is an allowlist view: an adapter asks for named fields only, and unknown keys are never enumerated, copied, logged, or persisted. A vendor parser error is replaced by `malformedPayload("payload")` because vendor text could quote the body.
- `HookAdapterRegistry.all = [PiAdapter(), OMPAdapter(), CodexAdapter()]`; OpenCode is not registered because its connector is app-side, not a hook family. One entry per install family: Codex serves both targets from one adapter and reads `--target`.
- `Sources/Adapters/OwnerIdentity.swift` names the *observed agent instance*, not the helper. The helper's parent is usually a throwaway `sh` created for one hook command, so the probe starts at `getppid()` and walks up with `proc_pidinfo(PROC_PIDTBSDINFO)` for at most 64 hops, skipping documented transient wrappers (`sh`, `bash`, `zsh`, `dash`, `ksh`, `tcsh`, `csh`, `fish`, `env`, `sudo`, `script`, `xargs`, `timeout`, `nohup`, `launchctl`) by basename with a login-shell hyphen removed. The owner is the first non-transient ancestor; it stops at PID 1, a cycle, an undescribable process, or the hop bound, and keeps the immediate parent if every ancestor is a wrapper.
- Owner instance: `p<pid>-u<uid>-t<startMicros>-b<bootSec>-<bootUsec>` with the boot token from `sysctl kern.boottime`. An undescribable process yields the deliberately unjoinable fallback `x-p<pid>-u<uid>-n<nonce>` with `startTimeMicros == 0`, so such emissions can hold sleep but never close another process's work. A re-parented helper (`getppid() <= 1`) takes the fallback instead of naming launchd.
- Supplied owner (owner flags): when `--owner-instance` and `--owner-pid` are both present, the ancestry walk is skipped and the owner is `(helper boot token, helper uid, supplied pid, supplied instance, startTimeMicros 0)`. The helper supplies only what it can see; the caller supplies the two values it measured before spawning it. The Pi and OMP assets mint one token per harness process (`p<pid>-<8 hex>`) at module load and pass it on every emission, so teardown matches even when the detached helper outlives its parent or is orphaned before it could probe one. The token is per process and does not repeat, so a later process that receives the same pid mints a different token and owner equality keeps the two apart. The narrower limitation is that, with `startTimeMicros == 0`, a liveness probe cannot verify that a live pid still names the owner recorded in an event, so such a probe must stay conservative and verified owner death remains the Stage 5 probe.
- Documented limits of the heuristic: an unknown wrapper between the helper and the agent still changes the owner (the failure direction holds the assertion rather than claiming idle), a measured owner separates PID reuse only by start time, while a supplied owner is separated by its per-process token but carries no start time for a liveness probe to confirm; hook delivery order is not causal order.

**Unit 3.2, Pi and OMP in-process extensions (`Resources/Integrations/{pi,omp}/assets/*.js`, `Sources/Adapters/{Pi,OMP}Adapter.swift`)**

- Both assets are real ES-module extensions (`export default function (pi) { pi.on(...) }`) installed as `~/.pi/agent/extensions/awake-lite/index.js` and `~/.omp/agent/extensions/awake-lite/index.js`. Each mapped event spawns the helper detached with allowlisted metadata only, writes stdin once and closes it, discards stdout and stderr, ignores every exit code, and starts no timer. A failure is never raised into the harness.
- Pi: each emission carries the module-level owner token (see unit 3.1). `session_start` is an incomplete session snapshot and creates no work (A04); `agent_start` mints the next run generation as `max(Date.now(), previous + 1)` and, when a previous run generation is still recorded, first emits the AwakeLite-internal `run_superseded` for it (mapped to `.cancelled`) so a superseded run can never hold sleep forever; `turn_start` keeps the run working; `turn_end` is `completed → heartbeat`, `error → failed`, `aborted → cancelled` with `sequence` taken from `turnIndex` only when it is a number; `ui_prompt_start`/`ui_prompt_end` are `humanWait`/`resumed`; `agent_settled` completes or cancels the run; `session_shutdown` with an observed run generation cancels that run, `reason: "quit"` terminates the owner, and the other documented reasons emit a conservative incomplete snapshot. Pi exposes no subagent lifecycle event, so child work is never reported, and human wait is observable only for extension UI prompts.
- OMP: each emission carries the module-level owner token. `session_start` is a snapshot; `agent_start` mints the next strictly increasing run generation, emits `run_superseded` (`.cancelled`) for a still-recorded previous generation, and starts a main run or a subagent child (`childStarted` plus parent work); `turn_start` keeps the run working; `agent_end` is a `heartbeat` for the main run (notification-only, not terminal) or `childFinished` for a subagent; `session_stop` completes the main run and is documented to defer until agent-owned background jobs are idle; `auto_retry_start` is a heartbeat and `auto_retry_end` is a heartbeat on success or `failed` on failure; `tool_approval_requested`/`tool_approval_resolved` are `humanWait`/`resumed`; `session_shutdown` cancels the observed run and otherwise leaves a conservative snapshot.
- Identifier handling in both adapters: a `session` or `parentWork` value is used as-is and refused — skipping that one event — when its canonical form differs from the raw value or when it is longer than 64 characters. Canonicalizing or truncating would silently merge two vendor ids into one session or work record. The documented trade-off is that such an event is skipped rather than merged into another session or work.
- OMP limits: `session_switch` documents no old-session identifier, so a switch cannot retire the old session authoritatively; `agent_end` carries no run outcome; `session_stop` carries no sequence because its `turn_id` is a different counter from `turnIndex`; no documented event closes a main-session run in a mode that never emits `session_stop`; and approval events are documented as emitted only when an approval handler is registered, which this subscription may not satisfy — so the OMP human-wait mapping is itself unverified.

**Unit 3.3, OpenCode read-only connector (`Sources/Adapters/OpenCodeAdapter.swift`, `Resources/Integrations/opencode/`)**

- The connector is library code with an injectable transport; tests use a fixture transport, so no check performs a network request. Production uses `URLSessionOpenCodeTransport` with a 5 s request timeout and only loopback hosts (`127.0.0.1`, `::1`). The production transport counts response bytes while streaming and stops reading past the 4 MiB budget instead of buffering the whole body. Authorization is supplied by the caller per request and never enters an event, file, error, or description.
- Four read-only GETs: `/api/session/active`, `/api/session/{id}`, `/api/session/{id}/permission`, `/api/session/{id}/form`. Session identifiers must start with `ses`, be at most 128 characters, and use a bounded character set before they can reach a path or an event.
- One successful listing is treated as the whole page (the published specification has no pagination). Membership alone is not work. The fan-out is bounded: `maxSessionsPerObservation = 128`; a larger listing is refused as `.oversize` before any per-session request, so one pass is at most 385 reads, and the caller records a `capacityExceeded` gap rather than presenting a truncated page as complete.
- Row interpretation is strict. Only a documented `running` row can hold; an active-row `type` this connector does not document is unreadable and becomes a problem, never work and never a completion. A `running` row that also carries a terminal `outcome` is a contradiction — the detail may describe an older execution — so it is a problem and the work keeps its hold; completion is never inferred from `outcome`. A documented `idle` row proves the session has no running execution and is stated as a session-scoped complete snapshot with no entries, so a proved-inactive session ends even when another read in the same pass fails.
- The event is an instance-scoped `.snapshot`; `snapshotComplete` is true only when every read in the pass succeeded. A session whose inactivity the pass does not prove — because the listing or its own reads failed, or because the row still claims `running` — keeps its hold until a later complete pass reconciles it; a permanently failing read keeps that hold as visible uncertainty until a complete pass or package removal clears it. A failed read also produces a per-session `.observationLost` gap and an oversize result a `capacityExceeded` gap, so the aggregate reports uncertainty rather than idle. Event ids are `<prefix>-<micros>-<uuid>` with a per-emission nonce, so two observations at the same instant stay distinct and cannot be dropped as duplicates. There is no timer, polling loop, thread, or retry inside the adapter (asserted by a test) — scheduling belongs to Stage 5 and must be gated on activation.
- The installed asset is an inert marker/generation record (`export const awakeLite = {...}`), not the connector. Install writes it to `~/.config/opencode/plugin/awake-lite/awake-lite.opencode.js`.

**Unit 3.4, Codex CLI and desktop (`Resources/Integrations/codex/assets/codex-hooks.toml`, `Sources/Adapters/CodexAdapter.swift`)**

- The asset is a real inline hook table for `~/.codex/config.toml`: one `[[hooks.<Event>]]` group with a `[[hooks.<Event>.hooks]]` `type = "command"` handler per event, `async = true`, `timeout = 10` and `3` for `Interrupt`. The handler invokes the helper with `--family codex --target {target} --generation {generation} --event <Event>` and writes no stdout, so its output and exit status are inert.
- Seven events: `UserPromptSubmit → started`, `PermissionRequest → humanWait`, `PostToolUse → resumed`, `Stop → completed`, `Interrupt → cancelled`, `SubagentStart/SubagentStop → child work`. All seven handlers are `async = true`. Work is one record per turn named from `turn_id`, so a continuation after `Stop` starts a new record. `SessionStart` is deliberately not registered: a session opening is not work (A04).
- `SessionEnd` is deliberately absent, from the adapter vocabulary and the asset. A session end reports that one conversation ended, not that the owner process died, and `ownerTerminated` retires the whole owner instance — so one conversation ending would release every other conversation hosted by that process. Owner death is verified only by the Stage 5 app-side probe. Consequence: an orphaned Codex turn that never reaches `Stop` or `Interrupt` keeps its hold rather than being assumed idle.
- Both install steps share the one asset and write into the same file with different markers and `--target` values, so one family install writes two blocks and Codex runs each event twice; the model keeps one turn record, so state converges at the cost of two short-lived helper runs per event.
- Codex skips untrusted non-managed hooks: after installing, the user must open `/hooks` once and trust the seven entries, and a later edit to the block changes each handler hash and requires a new review. AwakeLite does not bypass or pre-approve that step.
- Codex limits: a `Stop` that another hook turns into a continuation is not final and the model is briefly idle until the next `UserPromptSubmit` (and `turn_id` reuse for a continuation is unverified); no event reports approval decision, so a long gated command stays `waitingForUser` until `PostToolUse`; concurrent subagents of one turn share one child record because the distinguishing identifier is outside the allowlist; no hook path proves owner death, so a session that ends without `Stop`, `Interrupt`, or a later Stage 5 probe leaves its last turn's hold in place; a turn that began before installation has no record and its later events leave a session-scoped gap that only removal or reinstall clears; and the vendor contract excludes local command hooks from cloud orchestration, so cloud work is neither observed nor invented.

**Unit 3.5, per-target acceptance matrix** — recorded in the Evidence section below.

`verificationLevel` is declared data and was set to `fixture` for exactly `pi.cli`, `omp.cli`, `opencode.tui`, and `codex.cli`; the other six targets, including `codex.desktop`, stay `unverified`. Discovery, installation, and product presence never change it. A target with a fixture is still not live-accepted.

### Stage 1 core (implemented, not wired)

- `Sources/Core/Activity.swift`: pure reducer covering owner, session, and work identity, transitions, snapshots, observation gaps, activation generations, deduplication, and the aggregate sleep decision.
- `Sources/Core/LocalEventStore.swift`: immutable event inbox, atomic checkpoint, bounded retention, and crash-safe reconcile. A link write treats an existing event name holding byte-identical content as an idempotent replay (success, no new file) and refuses different content under the same name as `writeFailed`.
- `Package.swift`: SwiftPM library `AwakeLiteCore` plus an XCTest target.
- `Tests/AwakeLiteCoreTests/`: synthetic-event fixtures and checks for the Stage 1 core, plus Stage 2 catalog, installer, activation, and privacy fixtures.
- `build.sh` compiles `Sources/Core/*.swift` alongside the app sources.

The core is not connected to the menu app's power decisions. Stage 3 added event producers; the later partial power boundary exists, but the activation handoff and observer remain disconnected.

History: codex was added to the watched names after a local macOS inspection found a process at `.../CodexCLI.app/Contents/MacOS/codex`; the bundle was rebuilt and ad-hoc signed, and the scanner detected a real codex process alongside a deliberately absent control name. This does not prove assertion behavior or future integration functionality.

## Prepared documents

- [SPEC.md](SPEC.md): requirements, boundaries, and acceptance criteria A01–A17.
- [ARCHITECTURE.md](ARCHITECTURE.md): the implemented Stage 1–3 contracts (core, catalog and installer, helper and adapters) and the remaining proposed Stage 5 modules, with data model, event order, and storage.
- [ROADMAP.md](ROADMAP.md): implementation stages and exit criteria.
- [AGENTS.md](AGENTS.md): project navigation, current and planned ownership, working procedure, and approval boundary.
- [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md): dated documentation and source survey, including products outside the narrowed scope.
- [README.md](README.md): project entry point and the current build instructions and historical evidence.

Two independent candidate architectures were compared by a separate reviewer. The selected base uses app-owned state and file events without an extra daemon. Further documentation review clarified periodic inbox reconciliation, package activation generations, and the scope of recovery after event loss.

## Stage 1 decisions

- Bounds: at most 2048 inbox event files, 64 KiB per event file, 512 events applied per reconcile pass, 2048 remembered event IDs for deduplication, 1024 tracked works, 512 retained terminal works, 1024 recorded gaps, and 64 retained rejected files.
- Checkpoint order: apply events, then atomically save the checkpoint (fsync plus rename), then delete the processed files and quarantine rejected files. Replaying events after a crash is idempotent.
- Gaps from overflow or rejection are instance-scoped; gaps from observer loss are session-scoped. Gap storage has an absolute bound. A gap is cleared only by an authoritative snapshot covering that scope or by removal of the owning package.
- Events from an inactive family or a stale activation generation are rejected. Events more than 300 s in the future are rejected at ingest.
- `session.family` must equal `source`; a mismatch is rejected.
- A terminal update from a different owner identity is rejected, so PID reuse cannot close another instance's work.
- Snapshots marked complete are authoritative: omitted active work for a covered session is marked `ended`. Incomplete, stale, oversize, or owner-conflicted snapshots mark omitted work `.uncertain` instead.

## Evidence

- Stage 1: `swift test` on 2026-11-01 when Stage 1 landed: 66 tests, 0 failures (32 ActivityModelTests, 34 LocalEventStoreTests). The current split after the Stage 3 review is 33 ActivityModelTests and 36 LocalEventStoreTests. Swift 6.4.2 on arm64 macOS 27.2.0.
- Stage 2: `swift test` on 2026-11-01: 153 tests, 0 failures at that time — the 66 Stage 1 tests plus 87 Stage 2 tests: 46 `CatalogTests`, 27 `InstallerTests`, 10 `ActivationTests`, and 4 `PrivacyTests`. `CatalogTests` later grew to 47.
- Stage 3 (units 3.1–3.5): `swift test` on 2026-11-01: 250 tests, 0 failures at that time — the 66 Stage 1 tests, 88 Stage 2 tests (`CatalogTests` 47 after the verification-level table was added, `InstallerTests` 27, `ActivationTests` 10, `PrivacyTests` 4), and the Stage 3 suites `HelperIngestTests` 26, `PiOMPAdapterTests` 33, `CodexAdapterTests` 15, and `OpenCodeAdapterTests` 22.
- Stage 3 review and hardening: `swift test` on 2026-11-01 after the fixes: **272 tests, 0 failures** — 69 Stage 1 (`ActivityModelTests` 33, `LocalEventStoreTests` 36), 88 Stage 2 (`CatalogTests` 47, `InstallerTests` 27, `ActivationTests` 10, `PrivacyTests` 4), and 115 Stage 3 (`HelperIngestTests` 31, `PiOMPAdapterTests` 38, `CodexAdapterTests` 15, `OpenCodeAdapterTests` 31). The review round added 22 tests: +1 ActivityModel, +2 LocalEventStore, +5 HelperIngest, +5 PiOMPAdapter, +9 OpenCodeAdapter. Swift 6.4.2 on arm64 macOS 27.2.0.
- `./build.sh` on 2026-11-01 after the fixes: exit 0 with no compiler warnings, `AwakeLite.app` rebuilt with both `Contents/MacOS/AwakeLite` and `Contents/MacOS/AwakeLiteHelper`, helper and bundle ad-hoc signed, `codesign --verify --strict AwakeLite.app` passed, and the seven manifests plus assets are present under `AwakeLite.app/Contents/Resources/Integrations/`. The app was not launched.
- Stage 3 shipped-binary smoke (run by unit 3.1–3.4, not repeated here): the built helper returned exit 0 and wrote exactly one inbox file that the model applied for pi, omp, and codex with a committed receipt; a stale generation returned exit 3 and wrote no file; no seeded payload string appeared in stored bytes or on stderr.
- `./build.sh` exited 0 for Stage 2 as well; `AwakeLite.app` was rebuilt and ad-hoc signed, and the seven manifests plus assets are present under `AwakeLite.app/Contents/Resources/Integrations/`. The app was not launched.

Stage 2 fixture coverage, all against temporary home, application, and app-support roots:

- all seven manifests decode; the ten compatibility targets, their modes, and their declared verification levels are asserted from one table in `CatalogTests`; discovery shows availability appearing for a planted CLI binary and app bundle while each status keeps exactly the level its manifest declares (a `fixture` target stays `fixture`, an `unverified` target stays `unverified`);
- every loader rejection rule above is exercised with the manifest path and field in the message, plus symlinked asset file and symlinked asset directory cases and a cross-manifest duplicate marker;
- fresh install for each of the seven families; repeated install is idempotent, issues generation 2, records `previousGeneration`, and leaves exactly one entry per marker; a foreign key inside the owned container survives install, reinstall, and removal;
- foreign hooks, foreign keys, and a foreign plugin file survive install and removal; removal restores the foreign TOML bytes exactly and deletes only app-created files and directories;
- unsupported format, a foreign value at a marker, malformed JSON, and a duplicated block all fail without changing the file; symlinked config directory and symlinked config file are refused; a stale preview is refused before any mutation;
- interruption injected at journal creation, before and after each step, before the receipt, and after the receipt: recovery reaches `forwardCommitted` or `rolledBack` on the next start, clears the journal, and a retry installs consistently; an operation interrupted after a user edit stays `recoveryRequired`, is never overwritten, and blocks a new operation;
- a copy-step reinstall is idempotent, replaces the file with the new generation, leaves no second file, and remains removable;
- receipts and journals carry no seeded prompt/response/tool/credential strings (byte scan of every file under the app-support root after install, reinstall, removal, and a `recoveryRequired` conflict, including an in-flight journal, because shared configuration files are never copied into app storage);
- every receipt and journal decodes to within the documented key allowlists (including entry, step, and undo keys), and `InstallerError`/`RecoveryReport` text names paths and markers only, never seeded content;
- storage stays owner-only (0700 directories, 0600 files), and no path outside the injected roots is created.

Activation fixtures cover: a committed receipt activates its generation and other generations are rejected as `staleActivation`; removal deactivates, drops the family's work, and rejects its old-generation event as `inactiveSource`; `revoke` refuses while a receipt exists and drops work after removal; a reinstall issues generation 2, drops generation-1 work, rejects a late generation-1 event, and still applies generation-2 events; a family with no committed receipt is deactivated even if a stale checkpoint activated it, and its events are rejected with no work, gap, or dedup entry recorded; journals in `prepared`, `applying`, and `recoveryRequired` never activate (with an older committed receipt present), are reported with their operation id and stage, do not affect other families, and activation resumes at the surviving generation once recovery finishes; the handoff itself writes nothing.

- Unit 2.3: a throwaway store-level harness compiled `Sources/Core/*.swift` + `Sources/Integrations/*.swift` + `Sources/IntegrationsView.swift` + a temporary main (`AwakeLiteApp.swift` excluded) and drove `IntegrationsStore` against temporary home and app-support roots: 219 checks passed, 0 failed, exit code 0. The catalog was ready with 7 cards; per-family beginInstall → preview → apply left the receipt on disk with generation 1; show-changes left state unchanged; removal of codex dropped its receipt and package directory and restored the seeded foreign TOML byte-for-byte; a second store read the same generations from disk; check-connection never claimed a confirmed connection. The harness and its temporary roots were deleted afterward, the real `~/Library/Application Support/AwakeLite` was never created, and SwiftUI layout and sheet visuals remain unverified.
- This is fixture-level evidence only. It covers A01–A03 and A15 at installer level, the generation half of A11 and item 12 of the stage test matrix at handoff level, and A09–A13 and A16 at model level. It does not prove live harness behavior, SwiftUI layout, or real IOKit behavior.

Stage 3 fixture coverage, all against temporary roots and fixture transports:

- helper ingress: exit 0 with exactly one store-valid event file carrying the expected fields for each registered family; two emissions produce two distinct files and unique canonical ids; `--app-support` selects the root; an unknown event, an unregistered family, a bad target, and missing/duplicate/unknown arguments exit 2 with one diagnostic line; a malformed body and a 64 KiB-plus body exit 2 without writing; an inactive family exits 3 and creates no directory; a stale generation exits 3 without writing; a non-committed journal blocks an otherwise committed family; unreadable install state exits 3 naming the state path rather than a family receipt; activation is proven to be checked before the payload; an unwritable root exits 4; the maximum payload completes quickly and leaves no lock or temporary file; seeded prompt/response/tool/credential strings never reach stored bytes or diagnostics;
- owner identity: the instance is canonical, stable for the same process, different for another process, and boot-scoped; a non-transient process is not skipped; a real transient shell chain resolves to the spawning test process; two separate shell invocations agree on one owner; a supplied owner token is identical across emissions instead of the probed parent, and a detached helper keeps it after its parent exits; malformed owner flags exit 2 naming the flag; an undescribable process falls back to an unjoinable identity;
- Pi: session start creates no work; agent start and turn start keep one run working; human wait allows sleep and resume holds again; turn outcomes map to heartbeat/failed/cancelled; agent settled completes or cancels; reload ends the old run and starts a new generation; a superseded run generation is cancelled before the retry starts; session switch retires only the old session; shutdown without an observed run retires owner work; reload shutdown without a generation does not retire a newer run; reload shutdown cancels only its observed generation; non-quit shutdown reasons are conservative snapshots; late owner termination does not end a newer run; missing documented fields name the field only; an identifier whose canonical form differs from the raw value is refused rather than merged, as is one longer than 64 characters; an empty session id is refused; the asset is a helper-only source with no timer, network, transcript, or exit-code observation;
- OMP: session start creates no work; agent start plus session stop close the run; turn start and shutdown retire observation; agent end with a continuation is not completion; an auto-retry sequence never reports idle before the stop; a continuation after stop starts new work; an exhausted retry fails the run; approval wait and resume; a subagent is separate work with parent identity, and a subagent without a parent is refused;
- both families: inactive, stale, and journal-blocked emissions write nothing, and a reinstalled generation rejects old events in the model;
- Codex: only the documented vocabulary is declared; every documented event maps to the intended transition and work name; CLI and desktop targets stay distinct through the event; payload keys outside the allowlist are dropped; seeded content never reaches event bytes or diagnostics; inactive, stale, and unhealthy installs write nothing; exit 0 writes one store-valid file the model applies; an event for untracked work never claims working; start, wait, resume, complete, cancel, and restart leave the intended state; subagent work is a child of the turn and never replaces it; `SessionEnd` is not declared and an orphaned turn keeps its hold; a continuation after `Stop` reacquires with a new turn and documents the `turn_id` reuse gap; the installed asset renders only allowed placeholders and carries no shell logic;
- OpenCode: a complete snapshot with a running execution holds sleep; an empty listing confirms absence of work; an open but idle session is no data; a row without the running type is not work; a pending permission or form is human wait; a waiting session does not cancel a working one; an unknown execution outcome is uncertain; a finished row left in the active list releases the hold; an incomplete listing leaves omitted work uncertain end to end; an incomplete snapshot still records a proven working session; an unusable session identifier never reaches events; an older snapshot cannot end newer work; an oversize entry count or encoded size is an error that records a capacity gap; a listing above 128 rows is refused before any per-session read; an undocumented active-row type is unreadable; a running row with a terminal outcome is a problem, not completion; a proved-inactive session ends when another read fails; two observations at the same instant stay distinct; a response body above the 4 MiB budget stops at the limit; a transport failure yields uncertainty and never idle; an inactive family and a stale generation are rejected by the model; secrets never appear in events or problem text; the adapter source has no scheduling construct; endpoints outside loopback and unsafe configuration are refused.

### Unit 3.5: per-target acceptance matrix (2026-11-01)

Scope of this artifact: it records the evidence that exists for each of the ten compatibility targets for A04–A13. **No live harness session was run in this unit, no user product was driven, and no paid or remote request was issued.** Product versions are the installed versions recorded in [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md) on 2026-10-31; they were not re-checked here, and every target whose version is not recorded says so. Fixture evidence is dated 2026-11-01 and was re-run after the review fixes (`swift test`: 272 tests, 0 failures). No cell is `live`.

Legend: **F** = fixture demonstrates the criterion's observable behavior at model level for this target. **F\*** = fixture covers part of the criterion and the gap is named below. **U** = unverified, with the reason below. A cell is never raised because a fixture exists for a neighbouring criterion, and never because a product is installed.

| Target | A04 | A05 | A06 | A07 | A08 | A09 | A10 | A11 | A12 | A13 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `claude-code.cli` | U | U | U | U | U | U | U | U | U | U |
| `claude-code.desktop` | U | U | U | U | U | U | U | U | U | U |
| `codex.cli` | F | U | U | F | F\* | F\* | F\* | F | U | F\* |
| `codex.desktop` | U | U | U | U | U | U | U | U | U | U |
| `cursor.desktop` | U | U | U | U | U | U | U | U | U | U |
| `antigravity.cli` | U | U | U | U | U | U | U | U | U | U |
| `antigravity.desktop` | U | U | U | U | U | U | U | U | U | U |
| `pi.cli` | F | U | U | F | F\* | U | F\* | F | F\* | F\* |
| `omp.cli` | F | U | U | F | F\* | F | F | F | F\* | F\* |
| `opencode.tui` | F | U | U | F | F | F\* | F\* | F | U | F |

Per-target metadata (the level is the manifest's `verificationLevel`, which is declared data):

| Target | Mode | Product and version (research-dated, 2026-10-31) | Level | Fixture date | Live check |
| --- | --- | --- | --- | --- | --- |
| `claude-code.cli` | CLI | Claude Code; version not recorded | `unverified` | — (no adapter or fixture) | none |
| `claude-code.desktop` | desktop (Claude Code tab) | Claude desktop app; version not recorded | `unverified` | — (no adapter or fixture) | none |
| `codex.cli` | CLI | Codex CLI 0.160.0 (installed at research time) | `fixture` | 2026-11-01 | none |
| `codex.desktop` | desktop | Codex desktop app, package 0.166.0-alpha.5.1 (installed at research time) | `unverified` | — (the shared adapter only carries the target value) | none |
| `cursor.desktop` | desktop | Cursor; version not recorded | `unverified` | — (no adapter or fixture) | none |
| `antigravity.cli` | CLI | Antigravity; version not recorded | `unverified` | — (no adapter or fixture) | none |
| `antigravity.desktop` | desktop | Antigravity; desktop variant and version not recorded | `unverified` | — (no adapter or fixture) | none |
| `pi.cli` | CLI | Pi; version not recorded | `fixture` | 2026-11-01 | none |
| `omp.cli` | CLI | OMP 18.14.0 (installed at research time) | `fixture` | 2026-11-01 | none |
| `opencode.tui` | local TUI | OpenCode 2.2.5 (installed at research time) | `fixture` | 2026-11-01 | none |

Cells were re-evaluated after the Stage 3 review and hardening. Changes and their grounds:

- `codex.cli` A12: `F*` → `U`. The old cell rested on a `SessionEnd` teardown mapping. H5 removed that event from the vocabulary and the asset, so the family now has no teardown event at all; owner death is the Stage 5 probe, and Codex restart is otherwise unobserved at hook level.
- `pi.cli` and `omp.cli` A12: still `F*`, with a revised reason. B2 made teardown match even when the detached helper is orphaned (the supplied owner token), so the restart/shutdown half is stronger; owner death and PID reuse remain Stage 5, and a supplied owner carries no start time, so a liveness probe cannot confirm that a live pid still names the recorded owner.
- `opencode.tui` A13: still `F`, now also covering the bounded 128-row fan-out with a `capacityExceeded` gap (H2) and per-emission nonce ids that cannot conflate two observations (H3).
- No other cell changed. H1, H4, M1, M4, M6, and M7 harden behavior that the affected cells already covered at fixture level; none of them justifies raising a cell, and none lowers one.

Unverified cells and reasons (every `U` above appears here):

| Cells | Reason |
| --- | --- |
| `claude-code.cli`, `claude-code.desktop`, `cursor.desktop`, `antigravity.cli`, `antigravity.desktop`: A04–A13 | No adapter and no fixture exists for these families; their bundled assets are still inert Stage 2 placeholder JSON, and completing them is Stage 4 work. No product was launched, so nothing is known about their event delivery. |
| `codex.desktop`: A04–A13 | No desktop run was performed. Local desktop event delivery is unproven; fixtures exercise the shared adapter with a `codex.desktop` target value only, which cannot establish that the app emits these hooks for an ordinary local chat. Cloud-orchestrated work is excluded by the vendor contract, so it would be unobserved even live. |
| All ten targets: A05, A06 | No IOKit path is wired to the model. The single assertion owner is Stage 5 unit 5.1, so no fixture or live check can observe an assertion, a low-CPU hold, or an acquisition result yet. |
| `pi.cli`: A09 | Pi documents no subagent or task lifecycle event, so child work cannot be reported at all. |
| `opencode.tui`: A12 | The connector takes the owner identity from its caller and has no restart, owner-death, or PID-reuse fixture; the app-side observer that would own that lifecycle does not exist yet (Stage 5). |
| `pi.cli`: A08 (F\*) | Human wait is observable only for extension UI prompts. Pi documents no event for a host-owned prompt or approval, so the common approval wait is unobserved. |
| `omp.cli`: A08 (F\*) | Approval events are documented as emitted only when a tool requires approval and an approval handler is registered. Whether this extension's subscription alone satisfies that condition is unverified. |
| `codex.cli`: A08 (F\*) | No event reports the approval decision. A long gated command, and a denial followed by more work, stay `waitingForUser` until `PostToolUse` arrives. |
| `codex.cli`: A09 (F\*) | The identifier that distinguishes concurrent subagents is outside the payload allowlist, so subagents of one turn share one child record; the parent turn keeps the aggregate correct. |
| `codex.cli`: A10 (F\*) | A `Stop` that another hook rejects to force a continuation is not final, and the model is briefly idle until the next `UserPromptSubmit`. Whether a Codex version reuses `turn_id` for a continuation is unverified; if it does, the continuation would stay idle. |
| `pi.cli`: A10 (F\*) | `agent_end` is not terminal and the settled event closes the run, but there is no retry or queued-message fixture. The between-run backoff window is reported as no active run. |
| `opencode.tui`: A09 (F\*) | Parallel sessions are fixture-covered (a waiting session does not cancel a working one); the connector exposes no subagent surface at all. |
| `opencode.tui`: A10 (F\*) | Automatic continuation and background work are not mapped. The connector's answer to incomplete observation is uncertainty, not a continuation signal. |
| `pi.cli`, `omp.cli`: A12 (F\*) | Restart and shutdown mappings are fixture-covered (`session_shutdown`, reload reasons), and the helper's owner token makes teardown match even when the detached helper is orphaned. Owner death is still the Stage 5 probe; a supplied owner's token is per process, so a reused pid is a different owner in the model, but `startTimeMicros 0` means a liveness probe cannot confirm that a live pid still names the recorded owner and must stay conservative. The app half of A12 (startup recovery) is Stage 5. |
| `codex.cli`: A12 | No teardown event exists: `SessionEnd` was removed because a session end is not owner death, and the family has no other hook that reports a process ending. A turn that ends without `Stop` or `Interrupt` keeps its hold by design, so restart and owner death are unobserved at hook level and deferred to the Stage 5 owner probe. |
| `pi.cli`: A13 (F\*) | Non-quit shutdown reasons emit a conservative incomplete snapshot, but no fixture covers a lost or undelivered hook event. |
| `omp.cli`: A13 (F\*) | `session_shutdown` cancels the observed run; lost events are uncovered, and hooks provide no authoritative snapshot to recover from. |
| `codex.cli`: A13 (F\*) | An event for untracked work records a session-scoped gap; hooks have no authoritative snapshot that could clear it, so only removal or reinstall resolves it. |

Cross-target conditions that remain unverified for every target, and are not part of the A04–A13 matrix:

- Desktop delivery for every desktop target, including `codex.desktop` and the unbuilt Stage 4 desktop modes.
- Codex hook trust: no `/hooks` review or trust step was performed, so trusted delivery is untested; the manifests keep `requiresHookTrust` true.
- The OpenCode live API shape and version: the four read paths are taken from the published V2 reference and exercised only through a fixture transport. No request reached a real service, and pagination of `/api/session/active` is untested.
- Live latency: the two-second target in SPEC §9 is unmeasured for every target, and the interval between a harness event and the hook invocation is separate and also unmeasured.
- Real hook ordering, reload races, and duplicate delivery under a real harness restart.
- App restart recovery, owner retirement across boots, and PID reuse at app level (Stage 5).
- CPU time and wakeups (A17), UI layout, and the IOKit result (A14).

## Stage 3 review and hardening (2026-11-01)

An independent adversarial review of Stage 3 and the fixes applied during that round recorded 19 findings: 2 blocker, 5 high, 7 medium, 5 low. Disposition: 15 fixed, 2 deferred with a documented limitation (M3, M5), 1 documented-only (L3), 1 withdrawn as no finding (L2). No finding rests on a live harness run; every "fixed" row is proven by a fixture and the source it exercises.

| ID | Severity | Defect | Disposition | Proven by |
| --- | --- | --- | --- | --- |
| B1 | blocker | A superseded Pi or OMP run generation was never closed, so its record held sleep permanently. | Fixed: `agent_start` mints a strictly increasing generation (`max(Date.now(), previous + 1)`), and the assets emit the AwakeLite-internal `run_superseded` for the previous generation immediately before it; the adapters map it to `.cancelled`. | `PiOMPAdapterTests`: `testPiSupersededRunIsClosedBeforeTheRetryStarts`, `testOmpSupersededRunIsClosedBeforeTheContinuationStarts`, `testSupersededGenerationWithNoObservedWorkRecordsUnknownWork` |
| B2 | blocker | A detached helper orphaned before its owner probe took the launchd or fallback identity, so teardown never matched and the hold was permanent. | Fixed: both owner flags (`--owner-instance`, `--owner-pid`) skip the walk and pin the owner to a token the harness process minted; the Pi and OMP assets pass one token per process on every emission. | `HelperIngestTests`: `testSuppliedOwnerIsIdenticalAcrossEmissionsAndNotTheProbedParent`, `testDetachedHelperKeepsTheSuppliedOwnerAfterItsParentExits` |
| H1 | high | A proved-finished OpenCode session stayed `working` when another read in the same pass failed. | Fixed within the pass: a documented `idle` row, or the session's absence in a complete pass, emits a session-scoped complete snapshot with no entries. A `running` row with a terminal `outcome` is a problem, not completion. A session whose inactivity the pass does not prove keeps its hold until a later complete pass; a permanently failing read keeps visible uncertainty until a complete pass or removal. | `OpenCodeAdapterTests`: `testProvenInactiveSessionEndsWhenAnotherReadFails`, `testRunningRowWithTerminalOutcomeIsAProblemNotCompletion`, `testCompletePassWithOnlyFinishedRowsLeavesNoActiveRecord` |
| H2 | high | OpenCode fan-out over the active listing was unbounded (three reads per row). | Fixed: `maxSessionsPerObservation = 128` refuses a larger listing as `.oversize` before any per-session request; the caller records a `capacityExceeded` gap. | `OpenCodeAdapterTests`: `testRowBoundRefusesFanOutBeforeAnySessionRead`, `testRowBoundFiresAtOnePastTheLimit`, `testRowBoundAtTheLimitProceeds` |
| H3 | high | OpenCode event ids without a per-emission nonce conflated two observations taken in the same microsecond, so one could be dropped as a duplicate and a wrong idle could follow. | Fixed: ids are `<prefix>-<micros>-<uuid>` with a fresh nonce per emission. | `OpenCodeAdapterTests.testTwoObservationsAtTheSameInstantKeepDistinctWork` |
| H4 | high | `ownerTerminated` had no freshness guard and ended work observed after the event. | Fixed: only records with `updatedAt <= event.timestamp` end, and `updatedAt` is never rewound. | `ActivityModelTests`: `testOwnerTerminatedDoesNotEndWorkObservedAfterTheEvent`, `testOwnerTerminatedEndsOnlyThatOwnersWork`; `PiOMPAdapterTests.testLateOwnerTerminationDoesNotEndANewerRun` |
| H5 | high | Codex `SessionEnd` retired every conversation hosted by one process. | Fixed: the event is removed from the adapter vocabulary and the asset; seven events remain and all are `async = true`. Owner death is deferred to the Stage 5 probe. | `CodexAdapterTests`: `testSessionEndIsNotRegisteredAndAnOrphanedTurnKeepsItsHold`, `testAdapterDeclaresOnlyTheDocumentedCodexVocabulary` |
| M1 | medium | Unreadable install state was reported as a missing receipt, naming the wrong artifact. | Fixed: `HookIngestError.activationUnavailable(path:)` names the install state; exit stays 3 and nothing is written. | `HelperIngestTests.testUnreadableInstallStateNamesTheStatePathNotTheFamilyReceipt` |
| M2 | medium | The Codex vocabulary mixed a synchronous `SessionEnd` with `async = true` handlers. | Resolved by H5: seven events, one asset, every handler `async = true`. | `CodexAdapterTests.testAdapterDeclaresOnlyTheDocumentedCodexVocabulary`; asset inspection |
| M3 | medium | The installed helper path is escaped for TOML, not for the shell, and is a fixed `/Applications/...` constant, so a bundle path containing quotes, `$`, or backticks is unsupported. | Deferred with a documented limitation. It is also the install-path assumption recorded below and in ARCHITECTURE. | ARCHITECTURE "Installed entry mechanics"; the Stage 3 limits below |
| M4 | medium | An undocumented active-row `type` and a `running` row carrying a stale terminal `outcome` were interpreted optimistically. | Fixed: an unknown `type` is unreadable and becomes a problem; a `running` row with a terminal `outcome` is a problem, not completion. | `OpenCodeAdapterTests`: `testUndocumentedActiveRowTypeIsUnreadable`, `testRunningRowWithTerminalOutcomeIsAProblemNotCompletion` |
| M5 | medium | `enqueue` does not enforce the 2048-file inbox cap, so a burst while the app is not running is detected only at reconcile, and the resulting `storageOverflow` gap clears only by removal or reinstall. | Deferred as a Stage 5 requirement: bounded drain cadence and/or an ingest-side refusal. Recorded in "Unverified conditions and open questions" and ROADMAP 5.4. | `LocalEventStoreTests.testInboxOverflowRecordsGapAndPreventsIdle` (current behavior); requirement text below |
| M6 | medium | The OpenCode response body was buffered before the 4 MiB check, so an oversized body was read into memory first. | Fixed: the production transport counts bytes while streaming and stops at the budget (limit + 1), releasing the stream. | `OpenCodeAdapterTests.testResponseBodyBudgetStopsAtTheLimit` |
| M7 | medium | Pi and OMP canonicalized or truncated vendor identifiers, which could alias two ids into one session or work record. | Fixed: a value whose canonical form differs from the raw value, or exceeds 64 characters, is refused and that event is skipped. Documented trade-off: the event is skipped rather than merged into another session or work. | `PiOMPAdapterTests.testVendorIdentifiersMustAlreadyBeCanonical` |
| L1 | low | The Pi adapter assumed `sequence` was present on turn events. | Fixed: `sequence` is optional and taken from `turnIndex` only when numeric. | `PiOMPAdapterTests.testPiTurnEventsMapWithoutATurnIndex` |
| L2 | low | `matcher` was treated as required. | No finding: the vendor contract makes `matcher` optional and an omitted matcher matches every occurrence. | ARCHITECTURE family table; asset inspection |
| L3 | low | The Pi/OMP extension discovery roots are taken from vendor documentation but carry no dated source in this repository. | Documented only: kept in the unverified list. | "Unverified conditions and open questions" |
| L4 | low | A Pi limitation note described a retry backoff sentence the events do not support. | Fixed: the note now says the between-run gap reports no active run. | `Sources/Adapters/PiAdapter.swift` header; unit 3.2 above |
| L5 | low | A stale `helperPath` comment, and template rendering that could re-substitute an inserted value. | Fixed: the comment matches the constant, and `Template.renderText` is a single left-to-right pass. | `HelperIngestTests.testTemplateRenderingIsSinglePassAndNeverResubstitutesAValue`; `CodexAdapterTests.testAssetRendersOnlyAllowedPlaceholdersAndCarriesNoShellLogic` |

## Review and hardening (2026-11-01)

An independent review of the Stage 1 core found 26 findings (4 blocker, 6 high, 11 medium, 5 low). Blockers and high findings are fixed. Three mutation-audit rounds followed; every mutation targeting a tested guard is now killed.

- Snapshot authority: a `snapshotComplete` flag separates complete from partial coverage. Incomplete snapshots mark omitted work `.uncertain`, never `.ended`. `.ended` revives on `started`/`resumed`. A snapshot older than a record or a covering gap cannot end work or clear that gap. Snapshots above `maxWorks` entries are rejected with a capacity gap.
- Ordering: updates older than the record are rejected (`staleTimestamp`); events more than 300 s ahead are rejected at ingest with a gap.
- Gaps: absolute `maxGaps` bound (collapse densest scope, then merge the two oldest). Gap `detectedAt` uses event time or inbox file time. Rejection and overflow gaps are instance-scoped; observer loss stays session-scoped.
- Storage: checkpoint envelope `{schema, model}` with strict required keys. Corrupt, oversize, symlink, or unsupported-schema checkpoints throw instead of loading idle. The writer holds `flock` on `root/.lock`; the checkpoint is saved with `F_FULLFSYNC` plus atomic rename; processed files are deleted and rejected files quarantined only after the save. `enqueue` requires canonical identifiers and bounded size with `link`-based exclusive creation; quarantine never overwrites; stale temp files are swept; deletion failures are reported without aborting.
- Model: dedup key `source|instance|id`, and only applied events are remembered. New transitions `heartbeat` (work-scoped observer liveness only) and `ownerTerminated`. `retireForeignBoots(currentBootID:)` retires dead-boot owners. Owner instance must equal session instance; a snapshot owner conflict marks the record uncertain.
- `target` is still not read by the model.

## Unverified conditions and open questions

- No live harness acceptance exists for any target. Every target is either fixture-level or unverified; the per-cell reasons are in the unit 3.5 matrix above.
- Complete event delivery from ordinary Codex desktop chats on the installed version, and Codex hook trust after a `/hooks` review.
- Hook causality, delivery order, auto-retry, subagents, and background work in each real harness. Adapter fixtures encode the documented shapes, not observed delivery.
- The live OpenCode V2 API shape and version, including whether `/api/session/active` is ever paginated, and whether the running service's finished rows stay in that list.
- Owner identity on a real hook launch chain: the ancestry walk and its wrapper list were exercised against local test processes, not against a harness that spawns hooks through its own shell. The supplied-owner path was exercised against a real detached helper whose parent had exited, but never against a harness process.
- A supplied owner carries `startTimeMicros 0`, so a Stage 5 liveness probe cannot verify that a live pid still names the owner recorded in an event. The token itself is distinct per process, so a reused pid is a different owner in the model; the unverified part is how the probe must act on pid liveness alone — it must stay conservative and never release supplied-owner work on that basis. This behavior is unmeasured.
- Pi/OMP extension discovery roots (`~/.pi/agent/extensions/<name>/index.js`, `~/.omp/agent/extensions/<name>/index.js`) come from the vendor extension documentation (`extensions.md`, `extension-loading.md`), but no dated source for them is recorded in this repository (finding L3). They stay unverified.
- Helper path escaping (M3): the catalog now resolves the helper from the current bundle. The default Installer path remains a compatibility fallback. Shell-context escaping for paths containing quotes, `$`, or backticks remains unverified.
- Inbox cap enforcement (finding M5): `enqueue` does not enforce the 2048-file cap, so a burst while the app is not running is detected only at reconcile, and the `storageOverflow` gap it leaves can only be cleared by removal or reinstall. R3 requirement: enforce the bound before the burst accumulates, including while the app is stopped; drain cadence alone cannot satisfy this.
- OpenCode completeness proof: a session that finishes during an incomplete pass whose reads partly failed keeps its hold until a later complete pass reconciles it; a permanently failing read keeps that hold as visible uncertainty until a complete pass or removal. This is deliberate, not a resolved gap.
- OMP approval-event emission without a registered approval handler; Pi approvals and host-owned prompts, which emit no event at all.
- The exact Antigravity desktop variant and the live behavior of every missing product.
- Real IOKit acquisition and release, pause, quit, launch at login, and startup recovery (Stage 5).
- Actual CPU use, wakeups, and battery cost; the two-second latency target; UI layout.
- Native acceptance on other processor architectures.

Some products are absent. Full live acceptance of all ten targets cannot be promised without later user participation. This limits verification; it does not authorize downloading those products.

Remaining known limits of the hardened core:
- Capacity rejection is conservative: one dropped start can mark active instance work uncertain.
- `enqueue` does not enforce the inbox file cap; the app records an overflow gap during the pass. Enforcing the cap before production overflows is an R3 requirement (M5).
- The pass size is not validated against the dedup ring (documented invariant: 512 ≤ 2048).
- A replayed start after ring eviction plus terminal pruning is not test-covered; impossible while a pass is 512 files.
- No gap acknowledgement or manual clear.
- `heartbeat` is work-scoped only, not session liveness.
- Corrupt or future-schema checkpoints throw, with no quarantine or rebuild path.
- `target` is unused by the model; adapters and the catalog carry it, but no transition depends on it.

## Next action

Start ROADMAP R1 when development resumes. OMP CLI is the selected target. Preserve existing work, verify the implementation baseline, and connect the isolated OMP path. Do not start the former Claude Code unit 4.1. Publication, commits, pushes, release uploads, and system installs require explicit authorization.

Historical Stage 3 clarifications, with live gaps still open:

- **Stable owner identity: decided and documented.** `Sources/Adapters/OwnerIdentity.swift` names the nearest non-transient ancestor of the helper, skips a documented wrapper list, bounds the walk at 64 hops, and uses the `(pid, uid, start time, boot)` tuple as the instance. An undescribable process gets an unjoinable fallback that can hold work but never close it. Unit 3.1 exercised this against real local processes, including a transient shell chain and two separate shell invocations agreeing on one owner. A caller may instead supply the token it minted before spawning the helper, which is what the Pi and OMP extensions do, so a detached helper that outlives or is orphaned from its parent still produces one owner per harness process. A real harness launch chain remains unverified.
- **Session-level liveness: still Stage 5 owner-probe work.** `heartbeat` is work-scoped, and no adapter claims session-level liveness. The periodic owner probe that would retire a dead owner belongs to the Stage 5 startup and recovery ordering.
- **Checkpoint recovery: unchanged and fail-closed.** Corrupt, oversize, symlink, or unsupported-schema checkpoints throw rather than loading idle; the documenting gap (no quarantine or rebuild path) stays listed above.

Stage 2 limits recorded here rather than hidden:

- The installer has no cross-process lock; it assumes one app instance drives operations. Journal-based recovery covers interruption, not two concurrent writers.
- The activation handoff is not called by the app yet (Stage 5 startup order: `recoverPending()` first, then `ActivationHandoff.apply(to:)`, then inbox reconciliation). Event rejection itself is the model's, proven at fixture level only.
- A family with no committed receipt but a *completed* removal journal is reported inactive; there is no long-lived "removed families" record beyond the absence of a receipt.
- JSON files are rewritten structurally (sorted keys, two-space indentation), not byte-preserved. Foreign values survive; original key order and whitespace do not.
- A separator newline added before a block in a file that did not end with one is left behind by removal, because bytes outside the block are never rewritten.
- `format: directory` is implemented (the asset lands inside the app-owned directory) but no bundled manifest uses it.
- Removal refuses entries whose content no longer matches the receipt and leaves the receipt in place; there is no user-facing resolution flow yet.
- Target discovery only knows the documented default locations; a product installed elsewhere stays reported as absent.

Stage 3 limits recorded here rather than hidden:

- The original fixed-helper-path limitation was partly addressed in the worktree: the catalog store resolves the helper from its actual bundle and refuses setup on resolution failure; Installer still has the old default for other callers. Helper-path fixtures exist but were not run in this reset. Shell-context escaping remains an M3 verification gap. Installed extensions still ignore helper exit codes, so real event arrival must be checked.
- An installed Codex package writes two markers into one `config.toml`, so every Codex event runs the helper twice. State converges because both events carry the same turn id, but the cost is double process spawns.
- Codex hooks that fire for a turn that began before installation leave a session-scoped gap that only removal or reinstall clears; `Check connection` cannot resolve it.
- Codex has no teardown event. A session that ends without reaching `Stop` or `Interrupt` keeps its last turn's hold until the Stage 5 owner probe or removal; this is deliberate and is never reported as idle.
- The OpenCode connector has no caller. Nothing schedules a snapshot pass, and the installed marker file does not start anything, until the Stage 5 activation-gated scheduler exists. A session whose inactivity a pass does not prove (a failed listing or read, or a row still claiming `running`) keeps its hold until a complete pass or removal; a permanently failing read is visible uncertainty, not idle.
- The Pi and OMP extensions ignore helper exit codes by contract, so an inactive family, a stale generation, or a failed write is invisible to the harness; only the app's missing events reveal it.
- `session_shutdown` retires a whole owner instance (Pi and OMP). That is correct for one conversation per process and lossy for a process that hosts several; Codex no longer has an equivalent event.
- A supplied owner token is minted once per harness process (`p<pid>-<8 hex>`), so a different process on a reused pid is a different owner. It carries no start time, however, so a Stage 5 liveness probe cannot confirm that a live pid still names the recorded owner and must treat supplied-owner work conservatively instead of releasing it on pid liveness alone.
- `enqueue` does not enforce the 2048-file inbox cap, so a burst while the app is not running is detected only at reconcile and its `storageOverflow` gap clears only by removal or reinstall (M5, deferred to Stage 5).
- No adapter maps `session_switch` to an authoritative retirement (OMP), and no adapter can observe an approval decision (Codex, OMP, Pi).
