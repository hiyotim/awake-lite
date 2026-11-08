# AwakeLite state

Updated: 2026-11-04. This update records the OMP-only surface cut, the app-owned startup and observation path, and the first real OMP delivery run. The pre-cut implementation is commit `d6f1721` on branch `omp-only-minimal`; nothing was pushed.

## Current task and authorization

The user selected OMP CLI (`omp.cli`) as the only first-version target. R1a (surface cut), R1b (app wiring), and the R2 core live proof are complete. The next development unit is ROADMAP R3: reliability, owner probing, storage bounds, and the remaining live scenarios.

The checkpoint commit `d6f1721` was explicitly authorized. The cut, R1b, and the real OMP setup are not committed. Commits, pushes, publication, release uploads, and system installs remain separately authorized actions. The user authorized the OMP extension write for this test.

## Active scope

- Shipped family and target: `omp` / `omp.cli` only.
- Shipped resources: `Resources/Integrations/omp/` only.
- Helper registry: `OMPAdapter` only.
- Test-only fixtures: `Tests/AwakeLiteCoreTests/Fixtures/Integrations/` contains the six removed packages. They keep generic installer format coverage until R4. Nothing there is shipped or loaded by the app.
- Real setup: `~/.omp/agent/extensions/awake-lite/index.js` was installed at activation generation 2 for the live test, with receipt and package copy under `~/Library/Application Support/AwakeLite/`. The installed helper path points into this repository's `AwakeLite.app`; moving the repository breaks that path.
- No target is fully accepted.

## Actual source state

| Area | Observed 2026-11-04 | Evidence limit |
| --- | --- | --- |
| Startup and observation | `Sources/AppCoordinator.swift` recovers install state, loads the checkpoint, applies activation, watches the inbox, reconciles, and delivers the decision | Live print-mode OMP run; retry/background not exercised |
| Controller and power | `AwakeController.update(decision:)` reaches `PowerPolicy`; pause preserves the decision and releases the assertion | Menu-bar pause/quit clicks not exercised |
| Activity and persistence | App-owned reconcile and checkpoint; corrupt checkpoints fail closed | Fixture, native, and live print-mode checks |
| Installer and activation | Startup recovery and activation are connected; catalog operations post `.awakeLiteActivationChanged` | Live install at generation 2 |
| OMP extension and adapter | Extension asset, adapter, normalizer, helper runner, and owner probe exist | Live print-mode delivery; retry/background not exercised |
| Catalog UI | One shipped OMP card; helper resolved from the running bundle | No visual run in this update |
| Removed families | Adapters and shipped resources removed; manifests remain only as test fixtures | No adapter can ingest them |

## Evidence from this update

- `swift build`: success.
- `swift test`: **243 tests, 0 failures** in 7.8 s. Suites: `ActivityModelTests` 33, `LocalEventStoreTests` 36, `CatalogTests` 47, `InstallerTests` 28, `ActivationTests` 10, `PrivacyTests` 4, `HelperIngestTests` 31, `HelperPathTests` 10, `OMPAdapterTests` 23, `PowerPolicyTests` 12, `AppCoordinatorTests` 9.
- `PowerPolicyTests.testRealIOKitAssertionIsCreatedAndReleased` passed, and `AppCoordinatorTests.testRealAssertionFollowsCoordinatorDecisions` passed with a real assertion, including the pause path.
- `./build.sh`: exit 0; `codesign --verify --strict AwakeLite.app` passed; the bundle contains only `Resources/Integrations/omp`.
- Isolated app smoke on 2026-11-04: launched the built app with `AWAKE_LITE_APP_SUPPORT=<temp>` and a committed OMP receipt at generation 1. The production helper wrote `agent_start`; the app acquired `PreventUserIdleSystemSleep` named `AwakeLite: work in progress` under the app's pid. `session_stop` released it. After stopping the app with the work still active, relaunching it against the same root re-acquired the assertion from the persisted checkpoint. Exiting the app released it. A second launch with an empty root rejected the same helper emission with exit 3, wrote no inbox file, and held no assertion.
- `AppCoordinatorTests` additionally covers: disabled OMP (no observer), human wait/resume, removal, reinstall generation change, an unresolved journal stopping observation, and a corrupt checkpoint left untouched.
- Real support was created only for the authorized R2 test: the OMP extension at generation 2, its receipt, and the package copy. No Pi, Codex, OpenCode, or other family support was created.

### R2 live OMP evidence (2026-11-04)

Environment: OMP `18.16.0` initially, re-checked on `18.18.1`; print mode (`-p`, text), macOS 27.2.0, arm64. The extension was installed through the existing preview/receipt path at generation 1, then reinstalled at generation 2; the helper path pointed at this repository's `AwakeLite.app`.

- Real print session: `omp -p "Write one short sentence about the ocean." --no-session --mode text`. The app held `PreventUserIdleSystemSleep` named `AwakeLite: work in progress` from 0.6 s until the run ended; the assertion was released afterwards. Exit 0.
- Offline delivery: with the app stopped, the same kind of run wrote five immutable events: `session_start` snapshot, two `started` transitions (agent and turn), `completed`, and a final `session_shutdown` snapshot. The completion arrived before shutdown. On app restart the five events were reconciled, the work ended as `completed`, no gap was recorded, and no assertion was left.
- Open idle TUI session: no work and no assertion while running.
- Approval: with `--approval-mode always-ask` and a prompt that needed a shell command, the extension emitted `humanWait` and `resumed` transitions; no prompt content was stored.
- Reinstall: generation became 2, the old generation's work was dropped on activation, and a further real print run acquired and released the assertion again.
- Privacy scan: the tested prompt strings did not appear anywhere under `~/Library/Application Support/AwakeLite`.
- The app is running and idle after the final run; no assertion is held.

### 2026-11-08 interrupt fix

OMP was upgraded to `18.18.1`. A user test showed that pressing Esc in an interactive turn left the work `working`: OMP emits `agent_end` with no `willContinue`/`awaitingAsyncWork`, and the adapter mapped that terminal settle to a heartbeat. The adapter now completes the main run on that event; `session_stop` after it is a duplicate terminal update and is ignored by the model.

A controlled TUI reproduction (prompt, then Esc) wrote `snapshot`, `started`, `started`, `completed`; the app reconciled the run as completed with no false hold. `OMPAdapterTests` grew to 23 with the terminal-end case and the duplicate-stop case; the full suite is 243 tests, 0 failures. The extension was reinstalled at generation 2 and the app restarted.

## What changed since the cut

- Added `Sources/AppCoordinator.swift`: startup order, checkpoint ownership, activation refresh, inbox watcher, 30 s recovery pass gated on OMP activation, diagnostics, and decision delivery.
- Wired `AwakeLiteApp` to create the coordinator and feed `AwakeController`.
- Added a diagnostic line to the controller/menu for startup and reconcile errors.
- The catalog posts `.awakeLiteActivationChanged` after recovery, apply, or removal; the coordinator re-reads install state.
- Added `AWAKE_LITE_APP_SUPPORT` as an isolated-root override for the app support directory.
- `ActivationHandoff` treats a root with no installer-owned directories as fresh, while a missing journal beside an existing receipt still fails closed. This fixed a fresh-start false error.
- Updated README, SPEC, ROADMAP, ARCHITECTURE, AGENTS, and STATE for R1b.

## Blockers to a working OMP version

1. Remaining live scenarios were not exercised: auto-retry, background work, parallel sessions/subagents, approval denial, and OMP process death mid-run. A killed approval probe left a working record until reinstall changed the generation; no owner-death probe exists yet.
2. Runtime owner validation is conservative but incomplete: OMP's supplied owner token has no measured start time, and no owner probe retires dead work yet.
3. The inbox file cap is detected at reconcile, not enforced before producer bursts while the app is stopped.
4. The installed helper path points into this repository. A live install from a non-default bundle path worked, but moving the app bundle breaks the installed extension until reinstall.
5. Menu-bar pause/quit was not clicked in the live test; the underlying `PowerPolicy` pause and release paths are tested, and process exit releases the assertion.
6. CPU use, wakeups, and the two-second processing target are not measured (A17).

## Current plan

- R1a surface cut: complete and verified.
- R1b app path: complete and verified with synthetic OMP metadata.
- R2 core live proof: complete. Real start/finish, idle, approval wait/resume, offline delivery, and reinstall were exercised with OMP 18.16.0.
- R3: close reliability and acceptance gaps: retry/background/parallel scenarios, owner probing and death, pre-burst inbox bounds, restart/PID reuse, latency, CPU, and wakeups.
- R4: replace the generic installer stack and catalog UI with an OMP-specific installer after acceptance.

## Remaining known limits

- Removal and reinstall protections (receipts, journals, generation checks, hash-checked rollback) are retained and fixture-tested, and now driven at startup.
- A supplied owner is separated by its per-process token but carries `startTimeMicros 0`; a liveness probe cannot confirm that a live pid still names the recorded owner and must stay conservative.
- The extension ignores helper exit codes by contract, so inactive, stale, or failed emissions are invisible to OMP; only missing events reveal them.
- `session_switch` cannot retire an old OMP session authoritatively because it names no old-session identifier.
- `agent_end` carries no outcome; a terminal `agent_end` or `session_stop` completes the run. Failures and aborts also settle as completed.
- Process presence, silence, and low CPU remain invalid activity evidence.
