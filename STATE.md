# AwakeLite state

Updated: 2026-11-01.

## Current task and authorization

Implementation is approved. The active unit is ROADMAP Stage 1 "Verifiable core" (work model, bounded event storage, crash-safe recovery, synthetic events only).

The documentation-only restriction no longer applies within the approved scope. Commits, publication, release uploads, and system installs still need explicit authorization for those actions. Architecture approval never implies publication authority.

## User-confirmed scope

- Families: Claude Code, Codex, Cursor, Antigravity, Pi, OMP, and OpenCode.
- CLI and desktop targets for Claude Code, Codex, and Antigravity.
- Install only selected support from a local catalog of small bundled packages.
- Do not download missing harnesses.
- An open session with no work must allow the Mac to sleep.

## Actual program behavior

The menu-bar prototype is unchanged: five-second pgrep polling for opencode, omp, and codex, one IOKit assertion, manual pause, quit, and launch at login. It does not distinguish work from waiting for input.

### Stage 1 core (implemented, not wired)

- `Sources/Core/Activity.swift`: pure reducer covering owner, session, and work identity, transitions, snapshots, observation gaps, activation generations, deduplication, and the aggregate sleep decision.
- `Sources/Core/LocalEventStore.swift`: immutable event inbox, atomic checkpoint, bounded retention, and crash-safe reconcile.
- `Package.swift`: SwiftPM library `AwakeLiteCore` plus an XCTest target.
- `Tests/AwakeLiteCoreTests/`: synthetic-event fixtures and checks for the Stage 1 core.
- `build.sh` now compiles `Sources/Core/*.swift` alongside the app sources.

The core is not connected to the menu app, IOKit, any harness, helper, installer, or UI. No adapters, installer, or helper executable exist.

History: codex was added to the watched names after a local macOS inspection found a process at `.../CodexCLI.app/Contents/MacOS/codex`; the bundle was rebuilt and ad-hoc signed, and the scanner detected a real codex process alongside a deliberately absent control name. This does not prove assertion behavior or future integration functionality.

## Prepared documents

- [SPEC.md](SPEC.md): requirements, boundaries, and acceptance criteria A01–A17.
- [ARCHITECTURE.md](ARCHITECTURE.md): the approved Stage 1 base and remaining proposed modules, data model, event order, storage, and installation contracts.
- [ROADMAP.md](ROADMAP.md): implementation stages and exit criteria.
- [AGENTS.md](AGENTS.md): project navigation, current and planned ownership, working procedure, and approval boundary.
- [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md): dated documentation and source survey, including products outside the narrowed scope.
- [README.md](README.md): project entry point and the current prototype's historical checks.

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

- `swift test` on 2026-11-01: 66 tests, 0 failures (32 ActivityModelTests, 34 LocalEventStoreTests). Swift 6.4.2 on arm64 macOS 27.2.0.
- `./build.sh` exited 0; `AwakeLite.app` was rebuilt and ad-hoc signed. The app was not launched.

This is fixture-level evidence only. It covers A09–A13 and A16 at model and storage level and does not prove live harness behavior.

## Review and hardening (2026-11-01)

An independent review of the Stage 1 core found 26 findings (4 blocker, 6 high, 11 medium, 5 low). Blockers and high findings are fixed. Three mutation-audit rounds followed; every mutation targeting a tested guard is now killed.

- Snapshot authority: a `snapshotComplete` flag separates complete from partial coverage. Incomplete snapshots mark omitted work `.uncertain`, never `.ended`. `.ended` revives on `started`/`resumed`. A snapshot older than a record or a covering gap cannot end work or clear that gap. Snapshots above `maxWorks` entries are rejected with a capacity gap.
- Ordering: updates older than the record are rejected (`staleTimestamp`); events more than 300 s ahead are rejected at ingest with a gap.
- Gaps: absolute `maxGaps` bound (collapse densest scope, then merge the two oldest). Gap `detectedAt` uses event time or inbox file time. Rejection and overflow gaps are instance-scoped; observer loss stays session-scoped.
- Storage: checkpoint envelope `{schema, model}` with strict required keys. Corrupt, oversize, symlink, or unsupported-schema checkpoints throw instead of loading idle. The writer holds `flock` on `root/.lock`; the checkpoint is saved with `F_FULLFSYNC` plus atomic rename; processed files are deleted and rejected files quarantined only after the save. `enqueue` requires canonical identifiers and bounded size with `link`-based exclusive creation; quarantine never overwrites; stale temp files are swept; deletion failures are reported without aborting.
- Model: dedup key `source|instance|id`, and only applied events are remembered. New transitions `heartbeat` (work-scoped observer liveness only) and `ownerTerminated`. `retireForeignBoots(currentBootID:)` retires dead-boot owners. Owner instance must equal session instance; a snapshot owner conflict marks the record uncertain.
- `target` is still not read by the model.

## Unverified conditions and open questions

- Complete event delivery from ordinary Codex desktop chats on the installed version.
- Hook causality, auto-retry, subagents, and background work in each adapter.
- Completeness of the existing OpenCode service's snapshots, including finished rows in the active list.
- Real-hook event completeness and the stable-owner-identity contract for each adapter remain unproven.
- The exact Antigravity desktop variant and live behavior of missing products.
- Future architecture's actual CPU use, wakeups, and battery cost.
- Native acceptance of the UI, IOKit, login item, and other target processor architectures.

Some products are absent. Full live acceptance of all ten targets cannot be promised without later user participation. This limits verification; it does not authorize downloading those products.

Remaining known limits of the hardened core:
- Capacity rejection is conservative: one dropped start can mark active instance work uncertain.
- `enqueue` does not enforce the inbox file cap; the app records an overflow gap during the pass.
- The pass size is not validated against the dedup ring (documented invariant: 512 ≤ 2048).
- A replayed start after ring eviction plus terminal pruning is not test-covered; impossible while a pass is 512 files.
- No gap acknowledgement or manual clear.
- `heartbeat` is work-scoped only, not session liveness.
- Corrupt or future-schema checkpoints throw, with no quarantine or rebuild path.
- `target` is unused.

## Next action

Review this result, then Stage 2 (catalog and installer) per [ROADMAP.md](ROADMAP.md). Before Stage 3, settle stable owner identity, session-level liveness, and checkpoint recovery policy.
