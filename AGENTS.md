# Agent guide for AwakeLite

## Current authorization

Implementation is approved. Stage 1 "Verifiable core" is implemented and fixture-verified; the next unit is Stage 2 "Local catalog and installer" per ROADMAP.

Documentation-only restriction no longer applies within the approved scope. Do not ask again for permission already granted. Publication, commits, pushes, release uploads, and system installs still need explicit authorization for those actions. Architecture approval never implies publication authority.

## Start here

1. Read the current user request. It takes precedence over historical plans and this file.
2. Run `git status --short`. Preserve existing changes and distinguish them from your work.
3. Read [STATE.md](STATE.md) for actual progress, authorization, and unresolved checks.
4. Read the relevant requirements in [SPEC.md](SPEC.md), then the owning section in [ARCHITECTURE.md](ARCHITECTURE.md).
5. For approved implementation, select the next incomplete unit from [ROADMAP.md](ROADMAP.md). Do not restart completed research.

Read proportionally. Open source research only when a vendor contract, version, path, or missing evidence affects the task.

## Documentation map

| File | Use it for |
| --- | --- |
| [README.md](README.md) | Project entry point, current prototype, existing build, historical checks |
| [STATE.md](STATE.md) | Actual implementation and verification status; next authorized action |
| [SPEC.md](SPEC.md) | Agreed seven packages, ten targets, product behavior, acceptance IDs A01–A17 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Module ownership, data model, event order, storage, installation contracts |
| [ROADMAP.md](ROADMAP.md) | Implementation sequence and exit criteria after approval |
| [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md) | Dated source survey; broader than current scope and not runtime evidence |
| `AGENTS.md` | Working instructions and navigation; do not duplicate the full specification here |

The specification owns requirements. The architecture owns design decisions. STATE records what exists. Research may contain earlier alternatives or additional products; it does not expand the agreed scope. If these sources conflict materially, resolve the conflict before implementing the affected behavior.

## Existing repository

These files exist now:
| Path | Current responsibility |
| --- | --- |
| `Sources/AwakeLiteApp.swift` | SwiftUI entry point and MenuBarExtra |
| `Sources/AwakeController.swift` | Five-second process polling, pause, current IOKit assertion lifecycle, quit |
| `Sources/ProcessScanner.swift` | Exact-name and command-line pgrep matching |
| `Sources/LoginItem.swift` | Launch-at-login binding through SMAppService |
| `Sources/Core/Activity.swift` | Pure reducer: identities, transitions, gaps, aggregate decision, dedup |
| `Sources/Core/LocalEventStore.swift` | Inbox of immutable event files, atomic checkpoint, crash-safe reconcile |
| `Resources/Info.plist` | App identity, minimum macOS version, menu-bar-only configuration |
| `Package.swift` | SwiftPM library `AwakeLiteCore` plus XCTest target |
| `Tests/AwakeLiteCoreTests/` | Synthetic-event fixtures and checks for the Stage 1 core |
| `build.sh` | Builds with swiftc, including `Sources/Core/*.swift`, and applies an ad-hoc signature |
| `AwakeLite.app/` | Ignored generated app bundle, not authoritative source |

The current prototype treats process presence as activity. The menu-bar app, IOKit controller, and process scanner are unchanged; the new core is not wired to the app or to any harness yet. No adapters, installer, or helper executable exist. Do not invent test results or describe proposed files as existing.

## Planned ownership map

The following are proposed destinations, not files to create during documentation work. Keep small source groups; separate frameworks and one-file-per-type scaffolding are unnecessary.

| Responsibility | Proposed location | Boundary |
| --- | --- | --- |
| App lifecycle and menu | Existing app and controller files | Present state and apply user actions; no vendor parsing |
| Activity model and reducer | `Sources/Core/Activity.swift` | Pure state transitions, work identity, uncertainty, aggregate decision |
| Local event storage | `Sources/Core/LocalEventStore.swift` | Safe inbox, bounded retention, checkpoint, replay |
| Hook normalization | `Sources/HookNormalizer.swift` | Parse only allowed metadata; no raw payload persistence |
| Integration catalog and installation | `Sources/Integrations.swift` | One package list, previews, owned edits, receipts, recovery |
| Catalog UI | `Sources/IntegrationsView.swift` | Package cards, connection status, user actions |
| Vendor-specific observation | A compact adapter source group; `Sources/OpenCodeAdapter.swift` for native API reads | Keep vendor contracts out of the shared reducer |
| Power assertions | `Sources/PowerAssertion.swift`, or a small boundary in the existing controller | Exactly one assertion owner; report real IOKit results |
| Native helper executable | `Helper/main.swift` | Short-lived ingestion only; no UI or persistent daemon |
| Optional package assets | `Resources/Integrations/<family>/` | Bundled manifests, hook templates, Pi and OMP extensions |
| Behavioral fixtures and checks | `Tests/` and a documented verification command | Created with approved implementation; assert observable behavior |

Exact file boundaries remain adjustable during implementation. Update this map when actual ownership changes. Keep the existing build correct when introducing a helper or nested source directories. Do not create empty modules merely to match this table.

## Product invariants

- Scope is Claude Code CLI and local desktop Code; Codex CLI and local desktop; Cursor desktop Agent; Antigravity CLI and local desktop; Pi CLI; OMP CLI; OpenCode local TUI and service.
- Install only selected integration support. Do not download harnesses. Do not infer desktop compatibility from CLI behavior.
- An open process, low CPU, silence, or elapsed time does not establish work or idle state.
- Preserve previously confirmed unfinished work when observation becomes unknown. Do not invent completion from a timeout.
- Track independent work and generations. Waiting parents, live children, duplicate events, late completion, and PID reuse must not corrupt another task.
- One app-owned model determines one IOKit assertion. The helper and adapters never own power policy.
- No mandatory extra runtime, persistent helper daemon, privileged service, analytics, lid control, pmset modification, or lock-screen bypass.
- Persist lifecycle metadata only. Do not read transcripts or store prompts, responses, tool arguments, raw hook payloads, or credentials to detect activity.

Detailed transition and acceptance rules belong in SPEC and ARCHITECTURE.

## Implementation procedure after approval

1. Confirm the approved unit and acceptance IDs. Update STATE to record implementation authorization and the active unit.
2. Inspect the smallest relevant source boundary and the current vendor contract before changing it.
3. Prove the core on isolated fixtures before connecting real harnesses. The first unresolved design check is bounded event storage and crash-safe recovery.
4. Verify installation and removal in an isolated home or configuration root before touching real settings.
5. Integrate one target at a time. Do not restart the shared OpenCode service, terminate user processes, or disturb existing sessions to attach an observer.
6. Run checks appropriate to the unit, inspect the diff, and record evidence and limitations in STATE.

Only the app writes model checkpoints. Independent hook writers publish separate immutable events. Checkpoint and event cleanup must survive crashes without losing facts. Bound storage and report gaps rather than silently discarding required history.

Accept events only from enabled packages with the correct activation generation. Removal and reinstall must reject events from old in-flight hooks. Preserve causal scope; a new unrelated task cannot clear an older observation gap.

The installer changes only owned configuration entries. Preserve foreign settings, check preview freshness, use receipts, and avoid rollback over later user edits. Do not execute commands from untrusted manifests. Respect hook trust and workspace policies.

## Verification and completion

For documentation-only changes, inspect the diff, local links, terminology, scope counts, and acceptance IDs. Do not build or launch the app to validate prose.

The documented core check for the Stage 1 unit is `swift test` (XCTest), currently 66 checks. The SwiftPM test target covers `Sources/Core/` only; the `Sources/*.swift` app sources are compiled solely by `./build.sh`, not by the test target. The app build command remains `./build.sh`; it recreates the generated app bundle. Do not claim results without running them.

Runtime, concurrency, and configuration changes need focused review and behavioral checks. Keep these evidence levels separate: source inspection, fixtures, compilation, real IOKit behavior, and live per-target acceptance. Record the tested product version and execution mode. Missing products remain unverified; do not download them to close a gate.

Use at most two automatic repair rounds per bounded unit, then reassess unresolved failures. Prefer targeted follow-up checks over repeated broad reviews.

Update STATE when actual progress or evidence changes. Update ROADMAP only when the plan changes. Update README when user-facing behavior or build steps change. Do not create duplicate progress logs or handoff files.

Work directly by default. Delegate only bounded independent work when it improves the result, and explicitly select an available suitable model. Do not route work automatically to OpenCode, Pi, or OMP.

Do not commit, push, publish, upload releases, or install into system locations without authorization for that action. Before finishing, report changes, evidence, remaining work, and blockers. Never present unverified functionality as complete.
