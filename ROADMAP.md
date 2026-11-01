# AwakeLite roadmap

Status: Stage 1 approved and implemented; Stages 2–6 proposed. Requirements: [SPEC.md](SPEC.md). Actual progress: [STATE.md](STATE.md).

## Stage 0. Approval

Deliverable: agreement on scope, architecture, limitations of unverified products, and work order. Do not change product code before explicit user authorization.

## Stage 1. Verifiable core

Deliverable: independent work model, normalized transitions, bounded event storage, and crash-safe recovery. Start with synthetic events without editing real agent settings.

Exit criteria: model and storage checks for A09–A13 and A16. Prove no fact loss across checkpoints and concurrent writes. If the file queue cannot remain a small understandable module, revisit storage before adding adapters.

## Stage 2. Local catalog and installer

Deliverable: seven cards, selected-only installation, previews, receipts, removal, and recovery after failure. Inactive packages observe nothing.

Exit criteria: A01–A03 and privacy criterion A15 in isolated configurations. Preserve unrelated settings. Do not install the harnesses themselves.

### Units

#### 2.1 Catalog model, manifest loader, and fixtures

Deliverable: schema-1 manifest decoding and a `Catalog` that loads the seven bundled manifests, exposes each family with its compatibility targets, modes, capabilities, and verification level, and resolves target availability from local product discovery without raising a verification level.

Files/areas: `Sources/Integrations.swift`, `Resources/Integrations/<family>/manifest.json`, decode and discovery fixtures in the test target.

Dependencies: none beyond the Stage 1 identifier and storage types; the installer does not exist yet.

Exit check: fixtures decode all seven families; unknown schema, unknown or missing required keys, unknown `kind` or `format`, duplicate markers, and absolute or escaping asset paths are rejected with a usable message. A discovered harness still reports `unverified`. Establishes the catalog half of A02 and the manifest-field half of A15.

#### 2.2 Installer core: preview, journal, receipt, rollback, recovery

Deliverable: `Installer.preview(family:configRoot:)`, `apply(preview:)`, `remove(family:)`, and `recoverPending()` over declarative steps only, with operation journal, install receipt, hash-checked rollback, and refusal of unsupported formats, symlinks, conflicts, and stale previews.

Files/areas: `Sources/Integrations.swift`, `journal/`, `receipts/`, `packages/` under the app support root, isolated-root tests in the test target.

Dependencies: 2.1 for manifest and catalog types.

Exit check: the isolated-root test matrix in ARCHITECTURE passes for fresh install per family, idempotent reinstall, foreign hooks and plugins present, unsupported or conflicting format, symlink target, stale preview, interruption after each journal step, rollback over a user-edited file, removal preserving foreign entries, and journal replay at startup. No real settings are touched. Covers A01–A03 and A15.

#### 2.3 Catalog window with cards and actions

Deliverable: the integration window listing seven cards with name, targets, product availability, installation status, verification level, and required actions, plus **Install support**, **Remove support**, **Check connection**, and **Show changes** with a preview and explicit confirmation.

Files/areas: `Sources/IntegrationsView.swift`, the app entry point for opening the window.

Dependencies: 2.1 for catalog state and 2.2 for preview, apply, and removal.

Exit check: source inspection and a manual pass against an isolated root show that every action routes to the installer API, the preview restates the exact paths and owned entries before confirmation, and no view code parses vendor payloads. The window must not acquire power assertions or write activity events; A02 and A03 evidence still comes from 2.2.

#### 2.4 Privacy and activation-generation checks

Deliverable: written and fixture-checked guarantees that receipts, journals, and error text carry lifecycle metadata only, that every install and reinstall issues a new activation generation, and that removal or reinstall rejects events from earlier generations.

Files/areas: `Sources/Integrations.swift`, the `activate(family:generation:)` handoff into the Stage 1 model, receipt and journal fixtures.

Dependencies: 2.2 for receipts and 2.3 for the removal path that must deactivate.

Exit check: fixtures show no prompts, responses, tool arguments, payloads, or credentials in receipt or journal bytes; an old-generation event is rejected after removal and after reinstall; no observer runs for an inactive package. Covers A15, A01, and the generation half of A11.

## Stage 3. Installed harnesses

Connect one at a time: Pi, OMP, OpenCode, then Codex CLI and desktop. This sequence first tests in-process events, then snapshot APIs, then hook trust and desktop orchestration. New evidence may justify a different order; explain the change briefly in STATE.

For each target, verify the normal lifecycle, human waits, cancellation, failure, retry, parallel work, and restart. Use test sessions without interrupting existing user work. Do not issue paid requests in an unbounded automatic loop.

Exit criteria: a per-target matrix for A04–A13. Keep unverified scenarios explicitly marked. Product installation is not evidence of acceptance.

### Units

#### 3.1 Helper ingestion and adapter fixtures

Deliverable: the short-lived helper executable and allowlist normalizer, converting documented hook payload shapes into one immutable event file per emission, with no assertion, no daemon behavior, and no raw payload persistence.

Files/areas: `Helper/main.swift`, `Sources/HookNormalizer.swift`, `Resources/Integrations/<family>/` hook templates, normalized-event fixtures in the test target.

Dependencies: 2.2 for the storage root and 2.4 for activation generations.

Exit check: fixtures for every family's documented payload shape produce the expected `ActivityEvent` fields; unknown fields are dropped rather than persisted; a payload for an inactive family or stale generation exits with a documented non-zero code and writes no event; the helper exits promptly and holds no lock after writing. Covers the normalization half of A15 and the ingest half of A11.

#### 3.2 Pi and OMP in-process extensions

Deliverable: Pi and OMP extensions that emit start, human wait, resume, completion, error, cancellation, child work, and generation identity through the helper contract, plus adapter sources that keep vendor event names out of the shared core.

Files/areas: `Resources/Integrations/pi/`, `Resources/Integrations/omp/`, adapter sources, per-family fixtures.

Dependencies: 3.1.

Exit check: Pi fixtures cover reload and session switch; OMP fixtures cover auto-retry, continuation queues, and background work; both reject a stale generation. Covers A07, A09, A10, A11 at fixture level for these two targets.

#### 3.3 OpenCode read-only connector

Deliverable: a client of the existing local OpenCode service that reads execution details and human waits, treats membership in the active-session list as insufficient, uses authorization only against the verified local endpoint, and never restarts the service.

Files/areas: `Sources/OpenCodeAdapter.swift`, `Resources/Integrations/opencode/`, snapshot fixtures including complete, incomplete, stale, oversize, and finished-row cases.

Dependencies: 3.1 for the event write path and the Stage 1 snapshot rules.

Exit check: fixtures show an open-but-idle session as no data or waiting, an incomplete snapshot leaving omitted work uncertain, and a completed session releasing its hold; no polling loop starts when the package is inactive. Covers A04, A08, A10, A12, A13 at fixture level.

#### 3.4 Codex CLI and desktop

Deliverable: Codex user-level hooks with the required trust step, plus an app-server snapshot path only if an accessible one supplies authoritative state; CLI and desktop modes are tracked as separate compatibility targets.

Files/areas: `Resources/Integrations/codex/`, Codex adapter sources, per-mode fixtures.

Dependencies: 3.1 for ingestion.

Exit check: CLI fixtures cover start, wait, completion, cancellation, retry, and restart; the desktop target keeps ordinary local chats explicitly unverified until a live check proves event completeness, and local versus cloud orchestration is recorded separately. Covers A04, A08, A10, A12 at fixture level for CLI and only for demonstrated desktop paths.

#### 3.5 Per-target live acceptance matrix

Deliverable: the A04–A13 matrix as a repository artifact whose rows are the ten targets and whose cells hold product version, execution mode, verification level, and evidence date; each cell verified or explicitly unverified.

Files/areas: STATE evidence section, per-target fixtures added alongside each adapter.

Dependencies: 3.2–3.4 and the user's available products.

Exit check: every target and scenario cell is either live-checked or marked unverified with the reason. Sessions used for checks are separate test sessions; existing user sessions are not interrupted and no unbounded paid request loop is issued. Covers A04–A13 to the extent the available products allow.

## Stage 4. Remaining selected families

Deliverable: Claude Code, Cursor, and Antigravity packages based on official contracts and fixtures. Record CLI and desktop compatibility separately.

Exit criteria: verified installation, normalization, and scenario fixtures. Confirm live support only on a product later made available by the user. Do not download missing products to complete this stage.

### Units

#### 4.1 Claude Code CLI and desktop Code adapter

Deliverable: user-level lifecycle hooks for the CLI and, separately, for local Claude Code in the Claude desktop app's Code tab, with a `Stop` rejected by another hook treated as non-final and human waits mapped to waiting rather than idle.

Files/areas: `Resources/Integrations/claude-code/`, Claude adapter sources, per-mode fixtures.

Dependencies: 3.1 for helper ingestion and 2.2 for installation of the two modes from one family package.

Exit check: fixtures cover normal lifecycle, approval wait, error, cancellation, restart, and a `Stop` rejected by another hook; desktop Code stays explicitly unverified until a live check exists. Installation writes only owned hook entries and preserves unrelated settings. Covers A02, A03, A07, A08, A10 at fixture level and records A04–A13 gaps per mode.

#### 4.2 Cursor Agent adapter

Deliverable: a Cursor desktop adapter over the documented native Agent hook contract, covering cancellation, automatic continuation, and background subagents.

Files/areas: `Resources/Integrations/cursor/`, Cursor adapter sources, fixtures.

Dependencies: 3.1.

Exit check: fixtures cover start, completion, cancellation, automatic continuation, and background subagent work; the target remains marked unverified while the product is absent, and installation is verified in an isolated root. Covers A02, A03, A07, A10 for the fixture level.

#### 4.3 Antigravity CLI and desktop adapter

Deliverable: hooks that account for `fullyIdle` and that record the exact desktop product and version; CLI and desktop are separate compatibility targets with separate evidence.

Files/areas: `Resources/Integrations/antigravity/`, Antigravity adapter sources, fixtures.

Dependencies: 3.1.

Exit check: fixtures cover background work, human waits, and cancellation for both modes; the exact desktop variant and version are recorded during acceptance, and an unconfirmed variant stays unverified. Covers A02, A03, A08, A10 at fixture level.

#### 4.4 Install and removal verification for the three remaining families

Deliverable: isolated-root installation and removal checks for Claude Code, Cursor, and Antigravity, including foreign hooks, unsupported formats, interruption, and old-generation rejection.

Files/areas: installer test matrix in the test target, `Resources/Integrations/<family>/`.

Dependencies: 4.1–4.3 and 2.2 for the installer semantics.

Exit check: each family installs, reinstalls idempotently, and removes without disturbing foreign entries; conflicts fail without replacement; events from a removed or reinstalled generation are rejected. Covers A02, A03, A11, A15 for these families.

## Stage 5. Native app acceptance

Deliverable: menu-bar UI, catalog window, real assertion behavior, pause, quit, launch at login, startup recovery, and diagnostics.

Exit criteria: A05, A14, A15, and A17 on the available Mac. Record processor architecture and macOS version. One Mac does not establish support for every target platform.

### Units

#### 5.1 Model-to-power boundary

Deliverable: exactly one assertion owner derived from the Stage 1 aggregate decision, reporting the real IOKit acquisition and release result, with `ProcessScanner` removed from sleep policy and no second decision flag.

Files/areas: `Sources/PowerAssertion.swift` or the small boundary in `Sources/AwakeController.swift`, `Sources/ProcessScanner.swift` for removal of its policy role.

Dependencies: 2.4 for activation and generation handoff.

Exit check: with no integrations enabled, process presence acquires nothing; a confirmed working state acquires one assertion; a long model request or command with low CPU keeps that hold; a failed acquire or release surfaces as a visible error rather than success. Covers A01, A05, A06, and the error-reporting half of A14.

#### 5.2 Menu UI, pause, and quit

Deliverable: the menu contents from SPEC §7 — aggregate status, the short list of work affecting sleep, pause, integrations window, launch at login, and quit — plus the catalog window reachable from it.

Files/areas: `Sources/AwakeLiteApp.swift`, `Sources/AwakeController.swift`, `Sources/IntegrationsView.swift`.

Dependencies: 5.1 and 2.3.

Exit check: pause immediately releases the assertion while observation and task state are preserved, and unpausing recomputes the decision; quit releases the assertion and stops observation; status text reflects the IOKit result. Covers A14.

#### 5.3 Startup recovery and activation from receipts

Deliverable: startup ordering that runs `recoverPending()` before any new operation, activates only families with a committed receipt at the recorded generation, and deactivates on removal, while distinguishing observer loss from owner termination.

Files/areas: app startup path in `Sources/AwakeLiteApp.swift`, `Sources/Integrations.swift`, `Sources/Core/Activity.swift` call sites.

Dependencies: 2.2, 2.4, and 5.1.

Exit check: an interrupted installation replays to committed or rolls back to prepared on the next start; a stale checkpoint or refused recovery reports uncertainty rather than idle; a dead owner retires only its own work and PID reuse cannot close another instance's work. Covers A12 and A13 at app level.

#### 5.4 Native acceptance and resource measurement

Deliverable: measured evidence for the native criteria on the available Mac, separating source inspection, fixtures, compilation, real IOKit behavior, and live per-target acceptance.

Files/areas: STATE evidence section, the verification command documented for the build.

Dependencies: 5.2 and 5.3.

Exit check: A05 is confirmed by IOKit readback rather than intent; A14 covers pause, quit, and a deliberately failed acquisition; A15 covers persisted app-support content, logs, and error text; A17 records CPU time and wakeups with no integrations, idle integrations, and active work, with macOS version and processor architecture. Unmeasured claims stay unmeasured.

## Stage 6. Handoff readiness

Deliverable: documentation matches accepted targets. The UI identifies experimental and unavailable modes. App and integration removal are documented and checked.

Exit criteria: focused review of runtime, concurrency, and configuration operations, followed by fixes for confirmed defects. Limit automatic repair to two rounds per bounded unit, then reassess the approach.

### Units

#### 6.1 Compatibility matrix and status labeling

Deliverable: one compatibility matrix, in documentation and in the catalog UI, giving each of the ten targets its product version, execution mode, verification level, and unverified reason.

Files/areas: README, `Sources/IntegrationsView.swift`, STATE evidence section.

Dependencies: 3.5, 4.4, and 5.4.

Exit check: no target claims support without a live check; experimental and unavailable modes are labeled in the UI and in documentation from the same source of truth.

#### 6.2 Removal documentation and checks

Deliverable: documented and exercised removal of a single integration, of all integrations, and of the app, covering installed resources, receipts, journals, activation state, and the launch-at-login registration.

Files/areas: README removal section, installer removal path, isolated-root checks.

Dependencies: 2.2 and 4.4.

Exit check: removing one family leaves other families installed and their foreign settings intact; removing the app leaves no owned hook, plugin, or extension behind, and any residue is documented. Covers A03.

#### 6.3 Focused review of runtime, concurrency, and configuration

Deliverable: an independent review of the menu runtime, assertion lifetime, startup recovery, concurrent hook writes, and configuration operations, with confirmed defects fixed and the two-round repair limit respected.

Files/areas: changed native sources, installer and store tests.

Dependencies: 5.4 and 6.2.

Exit check: findings are recorded with severity and disposition; every blocker and high finding is fixed or explicitly carries a documented limitation; no claimed result rests on an unrun check.

#### 6.4 Release readiness

Deliverable: a release checklist covering build, signature, bundle contents, the seven bundled manifests, privacy review of persisted data and logs, and the authorization boundary for publication.

Files/areas: `build.sh`, `Resources/`, README, STATE.

Dependencies: 6.1–6.3.

Exit check: the checklist is complete except for actions that still require explicit authorization; publication, push, release upload, and system installation remain separately authorized and are not performed by this stage.

Full acceptance of ten targets requires live checks of ten targets. Before that, a limited version can be delivered with an accurate compatibility matrix. Publication, release uploads, push, and system installation require authorization for those actions unless the user has already explicitly granted it in the same session.

## Effort estimate

The core, catalog, and first adapters should take several working days after approval. A broader version with verification is roughly one to two working weeks, or longer if desktop modes impose limits. This is an estimate, not a deadline. Missing products prevent a promised date for their live acceptance.
