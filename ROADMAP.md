# AwakeLite roadmap

Updated: 2026-11-04. The first working version targets OMP CLI (`omp.cli`) only. This sequence replaces the former multi-family expansion order. [SPEC.md](SPEC.md) owns requirements; [STATE.md](STATE.md) owns evidence.

The first objective is a real OMP task that acquires and releases the app's sleep assertion. Reuse existing components before removing or replacing them. Do not add another adapter while that path is unverified.

## R0. Reset scope and documentation

Status: complete 2026-11-02. No product source changed in that reset.

- Record OMP CLI as the only first-version target.
- Describe the disconnected app and existing power boundary accurately.
- Replace the expansion plan with a bounded sequence.

Exit: documents agree on scope. R0 did not establish a working app.

## R1a. Cut the shipped surface to OMP

Status: complete 2026-11-04 in the worktree. The pre-cut state is commit `d6f1721` on branch `omp-only-minimal`.

- Deleted the Pi, Codex, and OpenCode adapters; `HookAdapterRegistry` now contains OMP only.
- Moved the six non-OMP integration packages out of `Resources/Integrations` into test-only fixtures; the app bundle ships `omp` only.
- Deleted the removed adapters' test suites, reduced the catalog tests to one shipped family and target, and retargeted generic installer tests to fixture packages.
- Added a shipped-OMP install/remove test and excluded fixture data from SwiftPM target resources.

Evidence: `swift test` 232 tests, 0 failures (including the real IOKit assertion test); `./build.sh`; `codesign --verify --strict AwakeLite.app`; the bundle contains only `Resources/Integrations/omp`.

Exit: shipped code and resources contain only OMP; the generic installer keeps fixture-level format coverage until R4.

## R1b. Connect one isolated OMP path

Status: complete 2026-11-04 in the worktree. Covers the app-wiring parts of A01, A05, A07, A14, and A15.

Implemented:

- `Sources/AppCoordinator.swift` owns startup order: recover pending operations, load the checkpoint, retire foreign-boot owners, apply committed activation, reconcile the inbox, and deliver the aggregate decision to `AwakeController`.
- The inbox is watched with a directory `DispatchSource`; a 30 s recovery pass runs only while OMP is active. Both stop when activation is absent or unreadable.
- The catalog posts `.awakeLiteActivationChanged` after install, removal, or recovery; the coordinator re-reads receipts and journals instead of trusting UI state.
- An unreadable checkpoint is never replaced with an empty model. An unreadable or unresolved install state fails closed, stops observation, and surfaces a diagnostic.
- The app support root can be overridden with `AWAKE_LITE_APP_SUPPORT` for isolated smoke checks; the default remains `~/Library/Application Support/AwakeLite`.

Exit evidence: with the app running against an isolated root and a committed OMP receipt at generation 1, the production helper wrote `agent_start` and `session_stop` events. The app held a real `PreventUserIdleSystemSleep` assertion named `AwakeLite: work in progress` on start, released it on finish, re-acquired the persisted working state after an app restart, and released it when the process exited. With an empty root the helper exited 3, wrote nothing, and no assertion appeared. `AppCoordinatorTests` covers disabled OMP (no observer), start/finish, human wait/resume, removal, reinstall generations, an unresolved journal, a corrupt checkpoint, and the real IOKit path including pause. The menu-bar pause/quit clicks were not exercised by GUI automation; their `PowerPolicy` path is test-covered.

Owning areas: `AwakeController.swift`, `AwakeLiteApp.swift`, `PowerAssertion.swift`, `Core/`, `Integrations/Activation.swift`, and the smallest necessary app-side coordination code. Avoid a new transport, daemon, framework, installer rewrite, or broad UI redesign.

Record evidence in STATE before moving to R2. If existing tests or the build fail, repair only blockers to this unit and reassess after at most two automatic repair rounds.

## R2. Check real OMP delivery immediately

Status: core live proof complete 2026-11-04 with OMP `18.16.0` in print mode on macOS 27.2.0 arm64; re-checked on `18.18.1` on 2026-11-08, including the Esc interrupt path. Retry, background work, parallel sessions, approval denial, and owner death remain unverified and move to R3.

Observed:

- `agent_start`/`turn_start` created exactly one real assertion, held for the run, and `session_stop` released it.
- An offline run wrote five events (session start, two starts, completion, shutdown); restarting the app reconciled them to a completed work record with no gap.
- An open idle TUI session created no work and no assertion.
- `--approval-mode always-ask` emitted `humanWait` and `resumed`.
- Reinstall moved activation to generation 2 and dropped old-generation work; a further real run held and released the assertion.
- No tested prompt text appeared in app storage.

Still unverified: automatic retry, background jobs, parallel sessions/subagents, approval denial, OMP process death mid-run, and the two-second latency target. A killed OMP probe left a working record until reinstall changed the generation, because no owner-death probe exists yet.

If OMP cannot supply a required event or guarantee in a tested mode, describe the missing event rather than inferring completion from silence. Keep affected criteria unverified.

## R3. Close OMP reliability and first-version acceptance

Status: next development unit. Covers the remaining OMP criteria, especially A06, A09–A13, and A16–A17, plus the scenarios not exercised in R2.

- Check parallel OMP work, waiting parents with active children, duplicates, late completion, and generation changes.
- Check app restart during work, missed notifications, helper failure, corrupt checkpoints, owner termination, and PID reuse. A supplied owner token has no measured start time; PID presence alone cannot validate its identity.
- Enforce the inbox cap before a producer burst accumulates, including while the app is stopped. The existing reconcile-time overflow detection does not satisfy A16 by itself.
- Exercise OMP removal and reinstall in isolated roots, including foreign settings, interrupted writes, and old-generation events.
- Measure event latency, CPU use, and wakeups with OMP disabled, idle, and active. Report measured conditions instead of claiming battery savings.
- Perform focused review of changed runtime, concurrency, storage, and configuration behavior. Fix reproduced defects within this unit.

Exit: the OMP acceptance table in STATE records evidence for every applicable A01–A17 criterion, with no unacknowledged gap. Any unsupported required scenario keeps the version experimental. Record native-test skips and distinguish fixture, IOKit, and live evidence.

## R4. Reduce the accepted version and use it

Status: blocked on OMP acceptance.

1. Inspect the dependency path used by the accepted OMP version.
2. Replace the generic installer stack (`Manifest`, `Catalog`, `ConfigEditor`, `InstallPlan`, `Installer`, about 4.2k lines) and the catalog UI (about 1k lines) with an OMP-specific installer and a small menu setup, expected around 500 lines. Preserve receipt, generation, atomic-write, removal, and privacy behavior while retained code depends on them.
3. Re-run the affected checks and the real OMP start/finish/pause scenario after replacement.
4. Use the app on ordinary tasks and record concrete defects in STATE.

Exit: README describes the version that was actually exercised, retained code serves its declared behavior, and no new family has been added. Choose a second target only after OMP acceptance and use, through a new scope decision. There is no arbitrary line-count target or promised completion date.

## Preserved earlier work

The pre-cut implementation is commit `d6f1721` on branch `omp-only-minimal`. It contains the seven-family catalog, installer, helper, and the Pi, OMP, Codex, and OpenCode adapters. Test-only manifests under `Tests/AwakeLiteCoreTests/Fixtures/Integrations/` keep the generic installer's JSON, TOML, and copy coverage until R4 replaces it.

References to former stages in the checkpoint's history are not instructions to resume that plan.
