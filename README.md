# AwakeLite

AwakeLite is a native macOS menu-bar utility intended to prevent automatic system sleep while a coding agent works. The first working version now targets OMP CLI only. It must permit sleep when work ends or waits for a person, even if the conversation stays open.

## Current state

The app is wired: `AppCoordinator` recovers pending install operations, loads the model checkpoint, applies committed activation, watches the inbox, reconciles events, and feeds the aggregate decision into `AwakeController` and the single IOKit assertion. An app restart re-acquires persisted working state; disabled or unreadable OMP activation starts no observer.

A real OMP `18.16.0` print-mode session has now exercised the whole path: work start held a real assertion, completion released it, and an idle session held nothing. Retry, background jobs, parallel sessions, approval denial, owner death, and full acceptance remain unverified. The test extension is installed at `~/.omp/agent/extensions/awake-lite/index.js` at activation generation 2 and points at this repository's `AwakeLite.app`; moving the repository breaks that installed path until reinstall.

OMP is the only shipped integration family and `omp.cli` the only shipped target. Pi, Codex, OpenCode, Claude Code, Cursor, and Antigravity adapters and resources were removed from the shipped surface on 2026-11-04. Their manifests survive only as test-only installer fixtures; no adapter, catalog entry, or app code loads them. The checkpoint branch `omp-only-minimal` preserves the pre-cut work.

## Continue development

Read these documents in order:

| Document | Question it answers |
| --- | --- |
| [STATE.md](STATE.md) | What exists, what is broken, and what was actually checked? |
| [SPEC.md](SPEC.md) | What must the OMP version do? |
| [ROADMAP.md](ROADMAP.md) | What is the next bounded task and its exit check? |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Which existing component owns the behavior? |
| [AGENTS.md](AGENTS.md) | How must a coding agent work in this repository? |

Start with ROADMAP R2: check real OMP delivery. The OMP-only cut and app wiring are done. Preserve current uncommitted work before resets, deletion, or branch changes.

## Build and checks

Requires macOS 13 or later and Apple Command Line Tools. The project uses SwiftPM for the library and helper tests, and `swiftc` for the app. There is no Xcode project.

For an implementation task, the check commands are:

```sh
swift test
./build.sh
codesign --verify --strict AwakeLite.app
```

`swift test` includes `PowerAssertion.swift`, the core, integrations, the OMP adapter, the normalizer, and the helper target. The app entry point, controller, login item, and catalog UI compile through `build.sh`. The suite contains a real IOKit assertion test and is not entirely fixture-only. A skipped IOKit test does not establish native behavior.

`build.sh` recreates the local generated `AwakeLite.app`, builds the helper into `Contents/MacOS/AwakeLiteHelper`, copies the OMP integration package, and signs the helper before the app. A successful build does not establish OMP event delivery or correct sleep behavior. Documentation-only changes require no build or app launch.

For an authorized runtime check, launch the local bundle with `open AwakeLite.app`. Building and launching do not install it into `/Applications` or configure OMP. Prepare OMP setup separately through the existing preview and receipt path. The catalog store resolves the helper from the current app bundle and refuses setup when resolution fails; path escaping still needs verification for the chosen location.

## Evidence and limits

On 2026-11-04 the cut, app wiring, and a real OMP print-mode run were verified: `swift build` and `swift test` (243 tests, 0 failures, including the real IOKit acquisition test), `./build.sh`, and `codesign --verify --strict AwakeLite.app`; the bundle contains only `Resources/Integrations/omp`. With OMP `18.16.0`, a real task acquired `PreventUserIdleSystemSleep` and released it on completion; an idle TUI session held nothing; approval checks emitted human-wait/resume; an offline run was reconciled after restart. Historical multi-family evidence remains in git (`omp-only-minimal` checkpoint) and is summarized in STATE.

The original process-based version had 176 Swift lines and watched opencode, omp, and codex. It treated an open process as activity and could not distinguish work from waiting. Historical scanner checks do not validate the current event-based app.

The intended assertion prevents idle system sleep and permits display sleep. Closed-lid control, `pmset` changes, lock-screen bypass, analytics, and privileged services are outside scope. Automatic activity detection must not read or persist conversation content.
