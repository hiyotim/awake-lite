# AwakeLite roadmap

Updated: 2026-11-02. The first working version targets OMP CLI (`omp.cli`) only. This sequence replaces the former Stage 4–6 expansion order. [SPEC.md](SPEC.md) owns requirements; [STATE.md](STATE.md) owns evidence.

The first objective is a real OMP task that acquires and releases the app's sleep assertion. Reuse existing components before removing or replacing them. Do not add another adapter while that path is unverified.

## R0. Reset scope and documentation

Status: documentation reset completed on 2026-11-02. No product source, tests, manifests, real settings, or Git history changed in this reset.

- Record OMP CLI as the only first-version target.
- Describe the disconnected app and existing power boundary accurately.
- Preserve earlier fixture evidence and unresolved contracts.
- Replace the expansion plan with R1–R4 and update agent instructions.

Exit: documents agree on scope, actual state, work order, and evidence limits. R0 does not establish a working app.

## R1. Connect one isolated OMP path

Status: next development unit. Covers the app-wiring parts of A01, A05, A07, A14, and A15.

1. Inspect Git status and preserve existing work before source edits. A checkpoint commit requires the user's authorization; do not reset or discard files.
2. Verify the current build and relevant tests once. Record new failures separately from the earlier 272-test result. The full suite includes a real IOKit test.
3. Reuse the OMP install and activation path in isolated configuration and app-support roots. Resolve the helper from the actual bundle. Keep other families inactive in the first-version runtime without editing their real configuration.
4. Add one app-owned startup and reconcile path. Recover installation operations, load persisted model state, validate activation and owners, reconcile events, then feed the aggregate decision into `AwakeController.update(decision:)`.
5. Observe the inbox with recovery for missed notifications. Run periodic recovery only while OMP support is enabled. Keep checkpoint writes in the app.
6. Exercise the production helper with synthetic OMP metadata in an isolated root. Verify start, finish, pause, and quit through the app and real IOKit readback.

Exit: the isolated production path creates exactly one assertion on start, removes it on finish, and shows actual errors. Disabled OMP produces no contribution or observer. This proves app wiring, not real OMP delivery.

Owning areas: `AwakeController.swift`, `AwakeLiteApp.swift`, `PowerAssertion.swift`, `Core/`, `Integrations/Activation.swift`, and the smallest necessary app-side coordination code. Avoid a new transport, daemon, framework, installer rewrite, or broad UI redesign.

Record evidence in STATE before moving to R2. If existing tests or the build fail, repair only blockers to this unit and reassess after at most two automatic repair rounds.

## R2. Check real OMP delivery immediately

Status: blocked on R1. Covers live OMP evidence for A04–A08 and A10, with selected A09 scenarios.

1. Record the installed OMP version, CLI mode, macOS version, and processor architecture. Verify the extension events and loading path against the installed version before setup.
2. Prepare a reviewable OMP-only setup preview using the existing installer. Apply to real settings only within authorization for that setup. System installation and publication remain separate actions.
3. Start a separate test session. Leave existing user tasks and sessions undisturbed.
4. Check an open idle session, work start, normal completion, cancellation, failure, human wait and resume, continuation, retry, and observed background work. Read the actual assertion through IOKit or `pmset -g assertions`.
5. Check pause and quit while a task is active. Inspect persisted metadata for privacy.

Exit: one real OMP task proves start and finish through the whole app path, and each remaining scenario has an explicit result or blocker. `agent_end` alone is not completion for the main OMP run. Verify `session_stop`, background-work ordering, and whether approval events fire in the selected mode.

If OMP cannot supply the required lifecycle, stop expansion and describe the missing event or guarantee. Keep affected criteria unverified. Revise only the OMP adapter or its declared limitation; do not infer completion from silence or lower the shared safety rules. A basic live proof alone does not close R3 or mark the target fully accepted.

## R3. Close OMP reliability and first-version acceptance

Status: blocked on the R2 live proof. Covers the remaining OMP criteria, especially A09–A13 and A16–A17.

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
2. Propose a bounded removal of unused UI and integration machinery. Preserve existing work before deletion. Do not remove receipt, generation, or recovery protections while retained code depends on them.
3. Simplify OMP setup only if the current setup causes an observed problem. Manual instructions must explain how valid activation is established; bypassing the helper's activation check is not a simplification.
4. Re-run the affected checks and the real OMP start/finish/pause scenario after removal.
5. Use the app on ordinary tasks and record concrete defects in STATE.

Exit: README describes the version that was actually exercised, retained code serves its declared behavior, and no new family has been added. Choose a second target only after OMP acceptance and use, through a new scope decision. There is no arbitrary line-count target or promised completion date.

## Preserved earlier work

Former Stages 1–3 produced the core, installer, catalog, helper, and Pi, OMP, Codex, and OpenCode adapters. Their historical evidence and review findings remain in STATE; detailed contracts remain in ARCHITECTURE. Partial former Stage 5.1 power code also exists in the worktree.

The old Stage 4 work on Claude Code, Cursor, and Antigravity, broad desktop qualification, and publication preparation are deferred. References to old stage numbers in historical evidence are not instructions to resume that plan.
