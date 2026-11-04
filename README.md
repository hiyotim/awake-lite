# AwakeLite

AwakeLite is a native macOS menu-bar utility intended to prevent automatic system sleep while a coding agent works. The first working version now targets OMP CLI only. It must permit sleep when work ends or waits for a person, even if the conversation stays open.

## Current state

The source is an incomplete migration, not a verified keep-awake app. The old process scanner has been removed in the worktree. The new controller starts idle, and no app caller feeds agent activity into it. `PowerPolicy` exists, but the app does not connect event ingestion, model reconciliation, and power decisions.

OMP's extension, helper, activity model, event store, installer, and power boundary already exist. The next development task is to connect those components, prove the path in isolated roots, and then check real OMP delivery. No target has live acceptance. Current source inspection does not establish the behavior of an older generated or installed bundle.

The repository still contains seven integration families and ten manifest targets from the earlier plan. Their presence is not a compatibility promise. Other families and catalog expansion are deferred; documentation cleanup has not removed their code or changed installed support.

## Continue development

Read these documents in order:

| Document | Question it answers |
| --- | --- |
| [STATE.md](STATE.md) | What exists, what is broken, and what was actually checked? |
| [SPEC.md](SPEC.md) | What must the OMP version do? |
| [ROADMAP.md](ROADMAP.md) | What is the next bounded task and its exit check? |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Which existing component owns the behavior? |
| [AGENTS.md](AGENTS.md) | How must a coding agent work in this repository? |
| [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md) | What did the earlier source survey report? |

Start with ROADMAP R1. Get one OMP path working before adding integrations or replacing infrastructure. Preserve current uncommitted work before resets, deletion, or branch changes.

## Build and checks

Requires macOS 13 or later and Apple Command Line Tools. The project uses SwiftPM for the library and helper tests, and `swiftc` for the app. There is no Xcode project.

For an implementation task, the check commands are:

```sh
swift test
./build.sh
codesign --verify --strict AwakeLite.app
```

`swift test` includes `PowerAssertion.swift`, the core, integrations, adapters, normalizer, and the helper target. The app entry point, controller, login item, and catalog UI compile through `build.sh`. The full test suite contains a real IOKit assertion test and is not entirely fixture-only. A skipped IOKit test does not establish native behavior.

`build.sh` recreates the local generated `AwakeLite.app`, builds the helper into `Contents/MacOS/AwakeLiteHelper`, copies bundled integration resources, and signs the helper before the app. A successful build does not establish OMP event delivery or correct sleep behavior. Documentation-only changes require no build or app launch.

For an authorized runtime check, launch the local bundle with `open AwakeLite.app`. Building and launching do not install it into `/Applications` or configure OMP. Prepare OMP setup separately through the existing preview and receipt path. The catalog store resolves the helper from the current app bundle and refuses setup when resolution fails; path escaping still needs verification for the chosen location.

## Evidence and limits

The last recorded full run on 2026-11-01 had 272 tests passing. The current source declares 294 test methods, including 12 power-policy and 10 helper-path methods added afterward. This is a source count, not a new passing run. Historical build, fixture, helper-smoke, and compatibility evidence is in STATE.

The original process-based version had 176 Swift lines and watched opencode, omp, and codex. It treated an open process as activity and could not distinguish work from waiting. Historical scanner checks do not validate the current event-based app.

The intended assertion prevents idle system sleep and permits display sleep. Closed-lid control, `pmset` changes, lock-screen bypass, analytics, and privileged services are outside scope. Automatic activity detection must not read or persist conversation content.
