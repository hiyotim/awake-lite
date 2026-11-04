# Agent guide for AwakeLite

## Current task and scope

The user selected OMP CLI (`omp.cli`) for the first working version on 2026-11-02. Follow the recovery units R0–R4 in [ROADMAP.md](ROADMAP.md). The former Stage 4 expansion is deferred. Existing adapters and bundled packages do not expand the active scope.

The current assignment is documentation cleanup and a development plan. Do not treat this assignment as a request to implement or launch the app. Implementation was previously approved; when asked to continue development, start with R1 without repeating that approval request. Commits, pushes, publication, release uploads, and system installs require explicit authorization for those actions.

## Read in this order

1. Read the current user request and run `git status --short`. Preserve existing work, including untracked files.
2. Read [STATE.md](STATE.md) for the actual code state and evidence.
3. Read [SPEC.md](SPEC.md) for first-version behavior and acceptance criteria.
4. Select the next incomplete recovery unit in [ROADMAP.md](ROADMAP.md).
5. Read only the owning contracts in [ARCHITECTURE.md](ARCHITECTURE.md) and the relevant source files.

README is the entry point. SPEC owns requirements. ARCHITECTURE owns contracts. ROADMAP owns work order. STATE owns progress and evidence. [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md) is a dated source survey, not live acceptance or a task list.

## Actual implementation

The current source is an incomplete migration. `Sources/ProcessScanner.swift` is deleted in the worktree. `AwakeController` starts with an idle aggregate decision; no app caller supplies new decisions. `Sources/PowerAssertion.swift` exists, but agent events do not reach its policy through the app. Do not describe this checkout as a working keep-awake utility.

| Responsibility | Owning files | State |
| --- | --- | --- |
| Menu, pause, quit, login item | `Sources/AwakeLiteApp.swift`, `AwakeController.swift`, `LoginItem.swift` | Exists; model input is disconnected |
| Power assertion | `Sources/PowerAssertion.swift` | Exists; current native behavior is unverified |
| Activity and persistence | `Sources/Core/Activity.swift`, `LocalEventStore.swift` | Exists; earlier fixture evidence is in STATE |
| OMP extension and mapping | `Resources/Integrations/omp/`, `Sources/Adapters/OMPAdapter.swift` | Exists; no live OMP acceptance |
| Helper and normalization | `Helper/main.swift`, `Sources/Adapters/HelperRunner.swift`, `OwnerIdentity.swift`, `Sources/HookNormalizer.swift` | Exists; emits lifecycle metadata |
| Installation and activation | `Sources/Integrations/` | Exists; startup handoff is not connected |
| Catalog UI | `Sources/IntegrationsView.swift` | Exists; broad catalog work is deferred |
| Other adapters | `Sources/Adapters/PiAdapter.swift`, `CodexAdapter.swift`, `OpenCodeAdapter.swift` | Preserved; outside the first version |
| Behavioral checks | `Tests/AwakeLiteCoreTests/` | Includes fixtures and a real IOKit test |

The observer scheduler and the app-owned startup/reconcile path are missing. Do not create empty modules to match an ownership table.

## Keep development bounded

- Work on one recovery unit at a time. End it with the observable result and evidence defined in ROADMAP.
- Reuse the existing OMP extension, helper, model, and power boundary. Establish a working path before replacing infrastructure.
- Do not add adapters, desktop support, a new installer, a daemon, a second event transport, or a generic plugin framework before OMP live acceptance.
- Keep other families inactive in the first-version runtime. Preserve their files and installed configuration until a separately scoped change addresses them.
- Do not restore process presence or a silence timeout as activity evidence.
- Stop at a missing OMP lifecycle contract. Report the exact limitation instead of compensating with speculative infrastructure.
- After OMP acceptance, inspect dependencies and remove unused parts in a bounded change. A smaller line count alone is not an acceptance criterion.

## Preserve contracts

One app-owned model determines one IOKit assertion. The helper and adapters never own power policy. Pause suppresses the assertion while preserving observed state.

An open process, low CPU, silence, or elapsed time establishes neither work nor completion. Keep previously confirmed unfinished work uncertain when observation is lost. Preserve independent work, generations, duplicate rejection, and PID-reuse protection. Do not let one task clear another task's uncertainty.

Only the app writes model checkpoints. Hook writers publish separate immutable events. Save the checkpoint before event cleanup. Bound storage and surface loss instead of silently dropping required facts.

Accept events only from enabled packages with the correct activation generation. Removal and reinstall must reject old in-flight hooks. A manual setup must not bypass activation checks.

Use the existing installer for the OMP proof. Preserve foreign settings, preview freshness, receipts, journal recovery, and hash-checked rollback. Test configuration edits in isolated roots first. Do not run commands from untrusted manifests or bypass agent trust policies.

Persist lifecycle metadata only. Do not read transcripts or store prompts, responses, tool arguments, raw hook bodies, or credentials. Use public macOS APIs without a privileged service, persistent helper daemon, additional mandatory runtime, analytics, lid control, `pmset` changes, or lock-screen bypass.

## Verify and report

For documentation changes, inspect the diff, local links, scope, and acceptance references. Do not build, run tests, launch the app, or change real settings just to validate prose.

For implementation, run checks relevant to the unit and inspect the final diff. `swift test` compiles the library and helper target. The library includes `Sources/PowerAssertion.swift`; the app entry point, controller, login item, and catalog UI compile through `./build.sh`. The build script recreates the generated `AwakeLite.app` and signs the helper before the bundle. `codesign --verify --strict AwakeLite.app` verifies the result.

The full test suite contains `PowerPolicyTests.testRealIOKitAssertionIsCreatedAndReleased`, which creates a real temporary sleep assertion and may skip if acquisition is refused. Do not call every test fixture-only or treat a skipped native test as a pass.

Keep source inspection, fixtures, compilation, real IOKit behavior, and live OMP acceptance separate. Record versions, execution mode, failures, and skipped checks in STATE. Earlier passing runs do not prove the current worktree.

Runtime, concurrency, permissions, and configuration changes require focused deeper review and behavioral checks. Use at most two automatic repair rounds for one bounded unit before reassessing. Do not repeat broad checks without new evidence.

Work directly by default. Use optional subagents only for bounded independent tasks that improve the result, with an explicitly selected suitable model. Do not route work to OMP or OpenCode automatically.

Update STATE when evidence changes, ROADMAP when the plan changes, and README when user-facing behavior or build instructions change. Do not create duplicate progress logs. Report changes, verification, remaining work, and blockers without claiming unverified behavior is complete.
