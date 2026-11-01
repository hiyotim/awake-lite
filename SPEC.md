# AwakeLite specification

Status: proposed, awaiting approval. Implementation of the new version requires explicit user approval. Date: 2026-10-31.

## 1. Purpose

AwakeLite is a small native macOS menu-bar app. It prevents automatic system sleep while a connected coding agent performs local work. It allows sleep when that work ends or the agent waits for a person. A session left open for weeks must not, by itself, keep the Mac awake.

Target platform: macOS 13 or later, on Apple silicon and Intel. Verify each processor architecture separately.

## 2. Agreed scope

The user selected a local package catalog. Small integration resources ship with the `.app`, and users install support only for selected harnesses. The catalog does not download or install the harnesses themselves. A server, online marketplace, and remote package downloads are outside the first version.

The catalog contains exactly seven families. A family with CLI and desktop targets has one card and one installation of shared resources. Compatibility status remains separate for each target.

| Package | Compatibility targets |
| --- | --- |
| Claude Code | CLI; local Claude Code in the Claude desktop app's Code tab |
| Codex | CLI; local tasks in the Codex desktop app |
| Cursor | Agent in the desktop IDE |
| Antigravity | CLI; desktop with local execution |
| Pi | CLI |
| OMP | CLI |
| OpenCode | Local TUI with its existing local service |

There are ten compatibility targets. Cursor CLI, ordinary Claude chat, remote SSH sessions, fully cloud-hosted work, and other harnesses are outside this scope. Record the exact Antigravity desktop product and version during acceptance. Hooks in one variant do not establish compatibility with another.

The user has Codex, Pi, OMP, and OpenCode installed. Use documentation, source code, and event fixtures for the other products. Do not download missing harnesses or claim their behavior is verified. Having a product installed does not mean it has passed acceptance.

## 3. Main user flows

1. The user opens AwakeLite, then **Integrations**. All packages are disabled by default.
2. The user selects a package, reviews its purpose, modes, limitations, and configuration changes, then installs support.
3. The app shows whether the integration is configured, needs a harness restart or hook trust, and has received events.
4. The user starts a task. AwakeLite keeps the Mac awake during model requests, command execution, and observed background work.
5. The agent finishes and stays open at its conversation. AwakeLite releases its sleep assertion.
6. The agent waits for a person. AwakeLite releases its assertion if no other work remains active.
7. The user removes an integration package. Only AwakeLite-owned connections are removed. Other settings remain intact.

## 4. Activity states

| State | Meaning | Sleep effect |
| --- | --- | --- |
| Working | Confirmed unfinished work exists | Hold the sleep assertion |
| Waiting for user | Progress requires human input or approval | Allow sleep if no other work is active |
| Idle | Absence of work has been confirmed | Allow sleep if no other work is active |
| Unknown | Observation is incomplete, stale, or lost | Apply the uncertainty rules below; do not substitute Idle |

Waiting for a server response, low CPU usage, no new tokens, and task duration are not evidence of idle state. Process presence helps verify the owner of a state record. It is not evidence that the owner is working.

Track separate instances, sessions, and work generations. If one session ends while another works, keep the assertion. A waiting parent session does not cancel work by a child agent or background command.

Completion of one model invocation does not mean the whole task has ended. A `Stop` event that another hook rejects to force continuation is not final evidence of idle state either.

## 5. Uncertainty and recovery

- If observation of previously confirmed work is lost, retain its hold until reliable completion, state recovery, or confirmed termination of that work. Show the reason for uncertainty and provide manual pause.
- Discovering an open but unobserved harness does not create a hold. Show **No data** or **Waiting for a new request**.
- On restart, restore persisted facts and verify their owners. Distinguish loss of the observer from termination of the agent.
- Do not reconstruct a missing completion event from an arbitrary silence timeout. Re-read an authoritative snapshot API where available. Otherwise, expose the integration's limitation.
- An incomplete event chain, data loss, or queue overflow prevents a claim of confirmed idle state.
- If a source cannot safely distinguish old work from new work, or cannot observe continuation correctly, keep that target experimental or unavailable for automatic sleep control.

The normal case of a completed task with its conversation open overnight must allow sleep. Lost events are a separate, visible failure condition. The app does not promise infallible observation.

## 6. Integration catalog

Each card shows the name, supported targets, product availability, installation status, verification level, and required actions. Detecting an installed program does not mean support is configured or compatibility is verified.

User actions are **Install support**, **Remove support**, **Check connection**, and **Show changes**. Installed integrations provide short restart or hook-trust instructions when the harness requires them.

Installation is idempotent: repeating it does not duplicate hooks. Removal preserves unrelated hooks, plugins, extensions, credentials, and settings. A late event from a hook already running when support was removed must not restore its contribution, including after a later reinstall. On conflicts or unsupported configuration formats, fail with a useful explanation instead of replacing the whole file.

Changes spanning several files require an operation journal and safe rollback. If the user edits a file after installation begins, rollback must not overwrite those edits with an older copy.

First-version packages are trusted resources shipped with the app. Arbitrary internet packages, a user marketplace, and execution of commands from third-party manifests are not supported.

## 7. Interface

The main menu contains aggregate status, a short list of work affecting sleep, pause, the integration window, launch at login, and quit. Installation details and diagnostics belong in one separate window.

The visible sleep-assertion status reflects the IOKit result, not just the intent to acquire it. Do not report success when assertion acquisition or release fails.

**Pause** immediately releases the app's assertion while preserving observation and task state. Unpausing recomputes the decision. **Quit** releases the app's assertion and stops observation.

## 8. Resource use, privacy, and system boundaries

Use Swift, SwiftUI, Foundation, and public macOS APIs. Only the menu-bar app runs continuously. A short-lived native CLI helper ships inside the same `.app`. Pi and OMP extensions use their harness's existing runtime.

Do not add Electron, a separate Node or Python runtime, a privileged service, a persistent helper daemon, analytics, or mandatory networking for the catalog.

Store only instance, session, and work identity, state, and lifecycle metadata. Do not persist raw hook payloads, prompts, model responses, tool arguments, or transcript contents. Local API authentication secrets must not enter persisted state, error messages, or logs.

Prevent automatic idle system sleep. The display may turn off. Closed-lid control, `SleepDisabled`, `pmset` changes, disabling the lock screen, and bypassing macOS policies are outside the task.

Disabled packages do not start observers. Use events for enabled integrations. Poll only where needed to verify or recover state. Measure polling cost and resource use; do not claim battery savings in advance.

## 9. Acceptance

Record version and verification level separately for every compatibility target. Fixtures and successful compilation do not replace live product acceptance.

| ID | Observable behavior |
| --- | --- |
| A01 | With no integrations enabled, process presence alone does not keep the Mac awake |
| A02 | Only the selected package is installed; repeated installation does not create duplicates |
| A03 | Removal preserves unrelated settings; a conflict or failure leaves a recoverable state |
| A04 | An open idle conversation does not keep the Mac awake |
| A05 | Starting work creates a real IOKit assertion |
| A06 | Long model requests and commands retain the assertion despite low CPU usage |
| A07 | Completion, failure, and cancellation release the corresponding work's hold |
| A08 | Waiting for input or approval allows sleep when no other work remains active |
| A09 | Parallel sessions and subagents are tracked independently |
| A10 | Automatic continuation, retry, and background work do not produce false idle state |
| A11 | Duplicate and late events from old work do not corrupt newer work |
| A12 | App restart, owner death, and PID reuse are handled correctly |
| A13 | Lost events, API disconnection, and storage overflow appear as uncertainty |
| A14 | Pause and quit release the assertion; IOKit errors are reported accurately |
| A15 | Persisted data contains no conversation content, tool contents, or credentials |
| A16 | Weeks of observation do not create an unbounded queue or event history |
| A17 | Background resource use and CPU wakeups are measured with no integrations, idle integrations, and active work |

Target latency after receiving a reliable event is at most two seconds. For a polling adapter, allow its polling interval plus at most two seconds of processing. These are proposed criteria, not current measurements. Verify latency between the harness event and hook invocation separately.

## 10. Completion conditions

The catalog, core, and scenarios verified on available products must pass their acceptance checks. Identify unverified desktop modes and missing products in the app and documentation. Claim full support for all ten targets only after separate live checks of each.

[ROADMAP.md](ROADMAP.md) defines implementation order and checkpoints. [ARCHITECTURE.md](ARCHITECTURE.md) defines module boundaries. Until this specification is approved, work is limited to documentation and architectural design.
