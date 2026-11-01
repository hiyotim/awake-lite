# AwakeLite

A small native macOS menu-bar app. The existing prototype keeps the Mac awake while an opencode, omp, or codex process exists. It releases its idle-sleep assertion after three empty checks, roughly 10–15 seconds after the last matching process exits. It uses Swift, SwiftUI, public Apple APIs, and no external dependencies. Requires macOS 13 or later.

The proposed event-based version is approved for implementation. The active unit is the Stage 1 core: independent work model, bounded event storage, and crash-safe recovery using synthetic events. The menu-bar app is unchanged and the core is not yet connected to it.

## Project documents

| Document | Purpose |
| --- | --- |
| [SPEC.md](SPEC.md) | Proposed requirements, agreed scope, and acceptance criteria |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Proposed module boundaries, data flow, and recovery |
| [ROADMAP.md](ROADMAP.md) | Work order and exit criteria after approval |
| [STATE.md](STATE.md) | Actual progress, evidence, and remaining questions |
| [AGENTS.md](AGENTS.md) | Agent navigation, ownership map, and working instructions |
| [HARNESS_RESEARCH.md](HARNESS_RESEARCH.md) | Dated source survey, broader than the current scope |

## Current prototype behavior

The prototype answers one question: does a matching process exist? It does not read agent output, logs, or sockets, and does not distinguish work from waiting for input. An open idle agent also keeps the Mac awake. Use **Pause** to release the hold manually.

The interface has not been translated as part of the documentation work. UI action names in this README are English descriptions of the current controls.

## Historical process-name investigation

The original checks ran on 2026-10-31 on a Linux VPS running Ubuntu 24.04. This subsection establishes no macOS behavior. Later local macOS checks are listed under Verification.

| Check | Result on the VPS |
| --- | --- |
| `pgrep -lx opencode` | Empty, exit 1 |
| `pgrep -x opencode` | Empty, exit 1 |
| `pgrep -x opencode.exe` | Finds PIDs |
| `pgrep -f 'opencode'` | Finds agents and the shell running the command |
| `pgrep -f '(^\|/)opencode(\.exe)?( \|$)'` | Finds only agents in that check |
| omp | Not running; its process name was not confirmed |

The real process on that VPS was named opencode.exe:

```
/home/hiyori/.local/lib/node_modules/@opencode/cli/bin/opencode.exe serve --service
/home/hiyori/.local/lib/node_modules/@opencode/cli/bin/opencode.exe run --format json ...
```

These observations led to the current scanner:

1. Exact `pgrep -x <name>` alone misses opencode on that VPS because the process is named opencode.exe. The scanner first tries an exact name, then an anchored command-line match.
2. The anchored `(^|/)NAME(\.exe)?( |$)` pattern accepts a path before the name and an optional .exe suffix. It rejects the checked `vim opencode.swift` case.
3. Command-line matching can still match an unrelated process whose arguments contain a path component with that name, such as `bash -c 'cd ~/opencode && ...'`. This is a documented limitation of the current -f fallback.

The watched array contains bare names: `["opencode", "omp", "codex"]`.

- opencode is the agent name from the original brief. The scanner adds the optional .exe form instead of requiring another array entry.
- omp is also from the original brief. Neither its exact process name nor command line was confirmed on the VPS. If macOS uses a different name such as omp-cli, verify it before changing the array.
- codex was added after a local macOS inspection on 2026-10-31 found a process at `.../CodexCLI.app/Contents/MacOS/codex`. Presence keeps the current prototype awake even without an active task. Chat activity is not inspected.
- node and bun were not added. Watching every Node process would keep the Mac awake for unrelated programs.

The opencode and omp process names on macOS were not confirmed by these prototype checks. The array retains the names from the brief, and the scanner tries two matching forms.

## Build the current prototype

Requires macOS 13 or later and Command Line Tools (`xcode-select --install`). The bundle is built directly with swiftc; there is no Xcode project.

```sh
chmod +x build.sh
./build.sh
open AwakeLite.app
```

build.sh recreates AwakeLite.app, copies Resources/Info.plist, and applies an ad-hoc signature. LSUIElement hides the Dock icon. Do not rebuild or launch the app unless the current task authorizes it.

### Core model checks

The Stage 1 core (`Sources/Core/`, the `AwakeLiteCore` library, and `Tests/AwakeLiteCoreTests/`) is checked with `swift test` (XCTest, no app launch): 66 checks, 0 failures as of 2026-11-01. The core is not yet connected to the menu app or any harness.

## Verification

### Local macOS checks on 2026-10-31

After adding codex to the watched names:

- The bundle was compiled with swiftc using a separate temporary module cache and signed ad hoc. `codesign --verify --strict AwakeLite.app` succeeded.
- The existing ProcessScanner detected a real codex process and did not detect a deliberately absent control name.
- The app was not launched for those checks. Sleep assertions, menu behavior, launch at login, and battery use were not verified.

Architecture and documentation translation have not changed product sources or repeated runtime verification.

### Original Linux VPS checks on 2026-10-31

These were reported for Ubuntu 24.04, not macOS:

- `swiftc -parse` on all Sources/*.swift with Swift 6.0 exited 0. Parsing is not type checking or a build.
- ProcessScanner, which uses only Foundation, was compiled and run on Linux. It found the real opencode.exe despite an empty `pgrep -x opencode`; did not find the absent omp; found a launched omp.exe; and rejected `vim editorproc.swift`. It also reproduced the documented false-positive case involving a shell command line containing a matching path.
- Resources/Info.plist parsed and contained LSUIElement = true and LSMinimumSystemVersion = 13.0.
- `bash -n build.sh` passed.
- The prototype contained 176 Swift lines across four files, with 157 nonempty lines.

The original Linux checks did not verify:

- macOS compilation or type checking against SwiftUI, IOKit, and ServiceManagement.
- Live MenuBarExtra, menu icon, or LSUIElement behavior.
- IOPM assertion acquisition and release, or entries in `pmset -g assertions`.
- SMAppService launch at login, which needs an app bundle and macOS settings approval.
- The original seven acceptance scenarios below.
- macOS process names for opencode and omp.

## Original manual Mac checks, not performed

These apply to the current process-based prototype, not to the proposed event-based specification's A01–A17:

```sh
./build.sh
open AwakeLite.app
```

1. With no agents, the icon is moon.zzz and pmset lists no AwakeLite assertion.
2. Start opencode. Within five seconds, the icon becomes cup.and.saucer.fill and an assertion appears.
3. Close opencode. The assertion disappears within roughly fifteen seconds.
4. Run opencode and omp. Closing one preserves the assertion; closing the last releases it.
5. Enable Pause while an agent runs. The assertion disappears. Disable Pause and it returns.
6. Quit with a hold active. The assertion disappears.
7. Check Activity Monitor for background CPU use.

If `pgrep -lx omp` on macOS reports another name, verify it before updating AwakeController.watched.

## Items excluded from the original prototype

The original prototype excluded work-versus-input detection, editable process lists, custom patterns, PID verification through `ps -o comm=`, notifications, history, statistics, closed-lid control, Developer ID distribution, notarization, App Store distribution, macOS CI, and localization.

Some of these, especially activity detection, now belong to the proposed next version. Follow SPEC and ROADMAP for the current plan rather than treating this historical list as a permanent exclusion.

## Current limitations

- kIOPMAssertionTypePreventUserIdleSystemSleep prevents idle system sleep and permits display sleep.
- Closed-lid behavior is outside the app's scope; the prototype does not override macOS clamshell policy.
- The prototype is not App Sandbox enabled. It was designed for personal use; store distribution was not validated.
- The assertion belongs to the process. If SIGKILL terminates it, macOS removes its assertion, although the normal IOPMAssertionRelease path does not run.
