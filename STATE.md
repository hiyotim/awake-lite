# AwakeLite state

Updated: 2026-11-01.

## Current task and authorization

Implementation is approved. Stage 1 "Verifiable core" and Stage 2 "Local catalog and installer" (units 2.1 catalog/manifest loader/discovery, 2.2 installer core, 2.3 catalog window, 2.4 activation handoff and privacy) are implemented and fixture-verified.

The documentation-only restriction no longer applies within the approved scope. Commits, publication, release uploads, and system installs still need explicit authorization for those actions. Architecture approval never implies publication authority.

## User-confirmed scope

- Families: Claude Code, Codex, Cursor, Antigravity, Pi, OMP, and OpenCode.
- CLI and desktop targets for Claude Code, Codex, and Antigravity.
- Install only selected support from a local catalog of small bundled packages.
- Do not download missing harnesses.
- An open session with no work must allow the Mac to sleep.

## Actual program behavior

The runtime menu-bar behavior is not reverified in this unit. The last recorded behavior is the Stage 1 prototype: five-second pgrep polling for opencode, omp, and codex, one IOKit assertion, manual pause, quit, and launch at login, with no distinction between work and waiting for input. The catalog window (unit 2.3) is implemented: an AppKit-hosted window created on demand from the Integrations… menu item (no window exists at launch), driven by `IntegrationsStore`, which routes install, removal, and recovery through the Installer API only. The window layout was not visually exercised; the store-level pass substitutes for the manual GUI pass. No view code parses vendor payloads, acquires power assertions, or writes activity events.

### Stage 2 integration catalog, installer, and activation (implemented, fixtures only)

- `Sources/Integrations/Manifest.swift`: strict schema-1 reader. Refuses unknown top-level, target, asset, step, and owned-entry keys; unknown kind/format/mode/capability/verification values; a family that does not match its directory; target ids without the `"<family>."` prefix; duplicate target, asset, destination, or marker ids; absolute, escaping, empty-component, symlinked, or missing asset sources; escaping asset destinations; empty targets/steps/owned entries; invalid `configRoot` selectors; `keyPath` outside JSON; and unknown `{placeholder}` tokens in asset text. Every message names `<family>/manifest.json` and the field.
- `Sources/Integrations/Catalog.swift`: loads all seven bundled manifests, enforces catalog-wide marker and target-id uniqueness, and resolves target availability through `ProductDiscovery` — documented home-relative executables and application bundles resolved against an injected home root and injected application roots. Discovery never launches a product, never runs a subprocess, and never raises a verification level.
- `Sources/Integrations/ConfigEditor.swift`: atomic writes that preserve an existing file's mode and sweep abandoned `.awake-lite-*.tmp` files; symlink refusal from the injected root down; structural JSON mutation at one key path; marker-delimited blocks for TOML/YAML/text; placeholder rendering (`{helperPath}`, `{family}`, `{target}`, `{generation}`, `{marker}`).
- `Sources/Integrations/InstallPlan.swift` and `Installer.swift`: `preview`, `apply`, `remove`, `recoverPending`; schema-1 receipt and operation journal; app-owned `packages/<family>/`, `receipts/`, `journal/`; installation stages `prepared`, `applying`, `committed`, `recoveryRequired`; hash-checked rollback with idempotent app-owned undo instructions; stale-preview refusal.
- `Sources/Integrations/Activation.swift` (unit 2.4): `ActivationHandoff(appSupportRoot:)` reads committed receipts and journals and produces `ActivationState` (`active` with family and generation, `inactive`, `unresolved`). `apply(to:)` is the startup handoff: it activates each committed family at its generation and deactivates every family in the model without one; `revoke(family:in:)` is the removal handoff and refuses while a committed receipt remains. `readState()` and both apply functions only read receipts and journals and call the model's `activate`/`deactivate`: no observer, timer, subprocess, event write, or power decision.
- `Package.swift` now compiles `Sources/Core` and `Sources/Integrations` in the single `AwakeLiteCore` target (the app-only sources stay excluded), and `build.sh` compiles the integration sources and copies `Resources/Integrations/` into `AwakeLite.app/Contents/Resources/Integrations/`.

Installed entries are inert marker-bearing templates. Nothing is wired to a harness, no helper executable exists yet (`/Applications/AwakeLite.app/Contents/MacOS/AwakeLiteHelper` is the documented constant), and every bundled target still reports `unverified`. The activation handoff is not yet called by the app: startup wiring belongs to Stage 5.

### Stage 1 core (implemented, not wired)

- `Sources/Core/Activity.swift`: pure reducer covering owner, session, and work identity, transitions, snapshots, observation gaps, activation generations, deduplication, and the aggregate sleep decision.
- `Sources/Core/LocalEventStore.swift`: immutable event inbox, atomic checkpoint, bounded retention, and crash-safe reconcile.
- `Package.swift`: SwiftPM library `AwakeLiteCore` plus an XCTest target.
- `Tests/AwakeLiteCoreTests/`: synthetic-event fixtures and checks for the Stage 1 core, plus Stage 2 catalog, installer, activation, and privacy fixtures.
- `build.sh` compiles `Sources/Core/*.swift` alongside the app sources.

The core is not connected to the menu app, IOKit, any harness, helper, or power policy. No adapters or helper executable exist.

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

- Stage 1: `swift test` on 2026-11-01: 66 tests, 0 failures (32 ActivityModelTests, 34 LocalEventStoreTests). Swift 6.4.2 on arm64 macOS 27.2.0.
- Stage 2: `swift test` on 2026-11-01: 153 tests, 0 failures — the same 66 Stage 1 tests plus 87 Stage 2 tests: 46 `CatalogTests`, 27 `InstallerTests`, 10 `ActivationTests`, and 4 `PrivacyTests`.
- `./build.sh` exited 0; `AwakeLite.app` was rebuilt and ad-hoc signed, and the seven manifests plus assets are present under `AwakeLite.app/Contents/Resources/Integrations/`. The app was not launched.

Stage 2 fixture coverage, all against temporary home, application, and app-support roots:

- all seven manifests decode; the ten compatibility targets and their modes are asserted; discovery shows availability appearing for a planted CLI binary and app bundle while every verification level stays `unverified`;
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

Stage 2 complete (units 2.1–2.4 implemented and fixture-verified). Next unit is ROADMAP 3.1 (helper ingestion and adapter fixtures) when the user asks to continue. Publication, commits, pushes, release uploads, and system installs remain unauthorized.

Stage 2 limits recorded here rather than hidden:

- The installer has no cross-process lock; it assumes one app instance drives operations. Journal-based recovery covers interruption, not two concurrent writers.
- The activation handoff is not called by the app yet (Stage 5 startup order: `recoverPending()` first, then `ActivationHandoff.apply(to:)`, then inbox reconciliation). Event rejection itself is the model's, proven at fixture level only.
- A family with no committed receipt but a *completed* removal journal is reported inactive; there is no long-lived "removed families" record beyond the absence of a receipt.
- JSON files are rewritten structurally (sorted keys, two-space indentation), not byte-preserved. Foreign values survive; original key order and whitespace do not.
- A separator newline added before a block in a file that did not end with one is left behind by removal, because bytes outside the block are never rewritten.
- `format: directory` is implemented (the asset lands inside the app-owned directory) but no bundled manifest uses it.
- The documented helper path does not exist on disk until Stage 3; installed templates point at it and are otherwise inert.
- Removal refuses entries whose content no longer matches the receipt and leaves the receipt in place; there is no user-facing resolution flow yet.
- Target discovery only knows the documented default locations; a product installed elsewhere stays reported as absent.

Before Stage 3, settle stable owner identity, session-level liveness, and checkpoint recovery policy.
