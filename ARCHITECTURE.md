# AwakeLite architecture

Updated: 2026-11-04. The active first-version target is OMP CLI. [SPEC.md](SPEC.md) owns behavior; [ROADMAP.md](ROADMAP.md) owns work order; [STATE.md](STATE.md) owns evidence. The shipped surface was cut to OMP on 2026-11-04; the pre-cut multi-family implementation is commit `d6f1721` on branch `omp-only-minimal`.

## First-version path

Reuse the existing OMP extension, helper, normalizer, local event store, activity model, and power boundary. The app owns startup, reconciliation, owner validation, and decision delivery. It is the only checkpoint writer and assertion owner.

```mermaid
flowchart LR
    OMP[OMP CLI extension] --> Helper[Native helper and normalizer]
    Helper --> Inbox[Immutable event inbox]
    Inbox --> Model[App-owned activity model]
    Model --> Menu[Menu and diagnostics]
    Model --> Power[One IOKit assertion]
    Setup[Existing OMP setup and receipt] --> OMP
    Setup --> Activation[Activation generation]
    Activation --> Model
```

The app now connects this path. `AppCoordinator` owns startup and observation; `AwakeController` owns pause, quit, and the single assertion. The old process scanner is deleted. The menu-bar pause/quit actions were not exercised by GUI automation, but their `PowerPolicy` path is test-covered.

Use the existing installer and receipt path for the OMP proof. The app ships one family, so a setup path cannot receive events from another family. A later manual setup design must explain valid activation and removal; it cannot bypass the helper's generation checks.

Startup recovers pending installation operations, loads the persisted model, validates activation and owners, reconciles the inbox, and delivers the aggregate decision. Unreadable state never becomes confirmed idle. The coordinator adds only the code needed to connect existing boundaries.

R1b proved synthetic OMP metadata through the production helper and app to real IOKit. R2 immediately checks a real OMP session. R3 closes recovery and storage gaps. A new event transport, generic observer framework, or installer rewrite is not needed to begin this proof.

## App startup and observation

`AppCoordinator` is the only app-side owner of the model lifecycle. `start()` runs on the main thread and orders: prepare and load the checkpoint, retire owners from foreign boots, recover pending install operations, apply committed activation generations, start or stop inbox observation, and reconcile. A corrupt or unsupported checkpoint is reported and never replaced with an empty model; activation, save, and reconcile are skipped in that state. Unreadable install state deactivates observation and delivers an `.unknown` decision rather than confirmed idle.

The inbox watcher is a directory `DispatchSource`; a 30 s recovery timer exists only while the shipped family is active. Both sources are cancelled when activation is absent, unresolved, or unreadable. The catalog posts `.awakeLiteActivationChanged` after install, removal, or recovery; the coordinator then re-reads receipts and journals, saves the model, reconciles, and re-evaluates observation. No UI state is trusted as install state.

`AWAKE_LITE_APP_SUPPORT` overrides the app support root for isolated smoke checks. The default remains `~/Library/Application Support/AwakeLite`. The coordinator writes the checkpoint; the helper only writes immutable inbox events.



## Preserved broader contracts

The rest of this document describes the shared code retained for the OMP version: the activity model, event store, installer, activation handoff, helper, normalizer, and OMP adapter. Removed families exist only in git history and test-only installer fixtures. Retained code must still obey privacy, generation, ownership, and recovery contracts.

## Alternatives considered

Two independent candidate architectures were compared and reviewed before implementation.

| Option | Benefits | Costs | Decision |
| --- | --- | --- | --- |
| Independent event files and an app-owned model | Events survive app downtime; the helper needs no running receiver; no extra daemon | Requires queue bounds, crash-safe checkpoints, and gap handling | Selected base |
| Unix socket with one helper service | Centralized writes and acknowledgments | Adds service lifecycle, reconnect, and storage during outages | Excluded from the first version |
| One mutable JSON file for all helpers | Few files | Concurrent writes can lose updates and require shared synchronization | Rejected |
| Process presence or CPU usage | Easy connection | Cannot distinguish work from an open conversation | Rejected as automatic activity evidence |

Keep short helper operations and an explicit message format from the socket candidate. Arrival order in a socket or file does not prove causal order inside a harness.

## Module ownership

The following groups define ownership. Activity and the local event store are implemented in `Sources/Core/`; the catalog, installer, and activation handoff in `Sources/Integrations/`; the hook normalizer in `Sources/HookNormalizer.swift`; the OMP adapter in `Sources/Adapters/`; the helper process shell in `Helper/main.swift`; startup and inbox observation in `Sources/AppCoordinator.swift`. `Sources/PowerAssertion.swift` owns the power boundary.

| Module | Owns | Must not own |
| --- | --- | --- |
| App and views (`Sources/*.swift`) | MenuBarExtra, the one-card integration window, error presentation | Vendor payload parsing or causal-order decisions |
| Activity (`Sources/Core/Activity.swift`) | Work identity, transitions, deduplication, snapshots, aggregate decision | IOKit calls or harness configuration changes |
| Local event store (`Sources/Core/LocalEventStore.swift`) | Inbox, checkpoints, recovery, limits, safe file access | Declaring work complete because a file is old |
| Hook normalizer (`Sources/HookNormalizer.swift`) | Payload allowlist, adapter registry, activation check, invariant re-stamp, one event write | Reading undocumented fields, persisting payload bytes, or deciding power |
| Native helper (`Helper/main.swift`, `Sources/Adapters/HelperRunner.swift`) | Argument and stdin bounds, exit codes, one event write per emission | Raw payload persistence, GUI startup, timers, network, or inference |
| Owner identity (`Sources/Adapters/OwnerIdentity.swift`) | Ancestry walk, wrapper skipping, instance token, unmeasured fallback | Deciding activity or retiring work by itself |
| Integrations (`Sources/Integrations/`) | Catalog, the shipped target, previews, install and removal, activation handoff | Declaring a mode verified because its executable exists |
| OMP adapter (`Sources/Adapters/OMPAdapter.swift`) | OMP event names, documented payload shapes, and its declared limitations | Guessing missing data, storing state, or writing directly to IOKit |
| Startup and observation (`Sources/AppCoordinator.swift`) | Pending-operation recovery, checkpoint load/save, activation handoff, inbox watcher, bounded recovery pass, decision delivery | Vendor payload parsing, IOKit calls, or UI state |
| Power (`Sources/PowerAssertion.swift`) | One assertion and actual acquisition/release results | Process polling, pmset changes, or lid control |

Retain the existing app entry point, controller, and login-item code where appropriate. Activity and the event store stay in `Sources/Core/`; Integrations and Adapters are compact source groups and the helper is a separate entry point compiled into its own binary. [AGENTS.md](AGENTS.md) maps actual files. These groups are responsibilities, not a requirement for separate frameworks or one file per type.

`ProcessScanner.swift` is deleted in the current worktree. Process presence must not return as activity evidence. Owner-identity checks remain separate from activity detection.

## Data model

| Entity | Main fields | Invariant |
| --- | --- | --- |
| Integration package | Family, package version, assets, install steps, compatibility targets | One catalog drives the UI, installer, and fixtures |
| Compatibility target | CLI or desktop, harness version, observation capabilities, verification level | Verification of one target does not transfer to another |
| Owner identity | PID, start time, UID, OS boot identity, instance identity | A PID alone is insufficient |
| Session identity | Family, instance, opaque session ID | Identical strings from different sources do not merge sessions |
| Work identity | Session, generation, child or background-work ID | Old completion cannot close new work |
| Activity event | Schema version, event ID, source, activation generation, target, work, transition, available causal data | Fields without a reliable source remain unknown |
| Session state | Observed work, waits, terminal facts, observation completeness | Waiting in one work item does not cancel another |
| Install receipt | Package, activation generation, owned entries, hashes, operation stage | Removal is limited to app-owned changes |

Owner identity names the observed agent instance, not the short-lived hook helper process; adapters must derive a stable identity for that instance and change it on restart or PID reuse. A caller-supplied owner (the OMP extension) mints its instance token once per harness process, so a different process on a reused pid is a different owner; it carries `startTimeMicros 0` by contract, so a liveness probe cannot confirm that a live pid still names the recorded owner. That is deliberate, because a measurable identity would be lost when the detached helper is orphaned.

Normalized transitions cover start, human wait, resume, completion, error, cancellation, child-work start and end, snapshot, observation loss, work-scoped heartbeat, and owner termination. A heartbeat confirms observer liveness for one work item. It does not establish work state and provides no session-level liveness. Owner termination retires only that owner's work after identity verification, and only records whose `updatedAt` is not newer than the event, so a late termination cannot end work observed after it; it never rewinds a record's `updatedAt`.

Derive the sleep decision from the model instead of storing a second independent decision flag. User pause suppresses the system effect without changing observed work.

## Event order and uncertainty

Stale updates lose: an event older than the stored record for that work is rejected. Ownership is positional: the owner instance must equal the session instance, and a conflicting snapshot owner marks the record uncertain rather than transferring it. Events dated more than 300 s in the future are rejected at ingest with a gap, using event time or inbox file time as the gap timestamp.

Snapshots carry a completeness flag. Only a complete snapshot is authoritative for its scope: omitted active work ends. An incomplete snapshot marks omitted work uncertain. A snapshot older than a record or a covering gap neither ends work nor clears that gap. Oversize snapshots that exceed the work bound are rejected with a capacity gap, which conservatively marks affected work uncertain.

## Storage without an unbounded journal

A private user directory contains installed package resources and receipts, independent event files, a model checkpoint, and a short installation-operation journal. Restrict access to the current user. Never use unchecked identifiers as path components.

Bound the inbox, event size, work count, and retained terminal facts. On overflow, persist an observation-gap marker scoped to the affected source, instance, and known sessions; rejection and overflow gaps are instance-scoped, observer-loss gaps stay session-scoped. Gap storage has an absolute bound: collapse the densest scope first, then merge the two oldest. Do not claim confirmed idle until a complete authoritative snapshot covers that scope, or all affected work and owners are confirmed terminated. An unrelated new task cannot clear the uncertainty. Never delete old events merely because they appear unnecessary.

Checkpoint envelope: the checkpoint file stores a versioned `{schema, model}` envelope with strict required keys. Corrupt, oversize, symlink, or unsupported-schema checkpoints refuse to load rather than starting idle. One process serializes reconcile with an exclusive lock on `root/.lock`; the checkpoint is written with full fsync plus atomic rename.

Inbox writes use canonical identifiers and bounded payloads, with link-based exclusive file creation so concurrent writers cannot overwrite each other. An event name that already exists is compared byte-for-byte: identical content is the same normalized event arriving twice (a retry, or two producers of one fact), so it is an idempotent replay that succeeds and adds no file; different content under the same name would silently merge two facts, so it is refused as `writeFailed`. Rejected files quarantine without overwriting. Save before move: processed inbox files are deleted and rejected files quarantined only after the checkpoint is saved, so a crash replays rather than loses facts.

Limitation (recorded as review finding M5 and deferred): `enqueue` does not enforce the 2048-file inbox cap. A burst of events while the app is not running is therefore detected only when reconciliation next runs, and the `storageOverflow` gap it records clears only by removal or reinstall. R3 must enforce the bound before a burst accumulates, including while the app is stopped. Drain cadence alone cannot bound stopped-app production.

A directory watcher requests inbox reconciliation. The app also reads the inbox at startup and periodically reconciles the inbox and owners of enabled integrations. This periodic pass must find events even when every watcher notification is lost and the owner remains alive. With no integrations enabled, do not run periodic inbox polling. File notifications alone are insufficient.

## Packages and connections

One bundled manifest describes the shipped package inventory: OMP. Installation copies or registers resources only for that family. An uninstalled package creates no hooks, timers, or connections.

| Family | Preferred mechanism | Separate verification needed |
| --- | --- | --- |
| OMP | Separate in-process extension at `~/.omp/agent/extensions/awake-lite/index.js` | Auto-retry, continuation queues, background work, approval events |

Vendor event names and paths belong to a versioned adapter, not the shared core. Verify them against the owning source before implementation. The pre-cut multi-family manifest inventory is in the checkpoint branch and in test-only installer fixtures; it is not shipped.

## Installation and removal

Create a preview and read current configuration before a change. Structurally add only owned entries with a stable marker. Reject unsupported formats, symlinks, conflicts, and stale previews without losing unrelated data.

Installation stages are prepared, applying, committed, and recovery-required. A receipt records ownership and completed changes. Rollback checks expected hashes so it cannot overwrite later user edits.

A package can connect several compatibility targets without duplicating shared hooks. Each installation receives a new activation generation, recorded in its receipt and installed command or extension. An old observer cannot acquire the new generation by reading the current receipt when it emits an event. Removing support excludes the package from the model. Ignore old-hook events even after reinstall with a different generation.

Support non-default configuration roots, profiles, and XDG locations explicitly, or report the limitation. Do not silently write into an unused default profile.

Do not bypass a harness's extension trust or workspace policy. The hook helper must not change permission decisions, continue tasks, or add model context. Its output must be inert according to the specific harness contract.

## Catalog, manifests, and installer contracts

The retained installer provides one catalog, one install model, one recovery path, and one activation handoff in `Sources/Integrations/`, compiled by both `swift test` and `./build.sh`. The catalog window is separate UI code and adds no file editing. Vendor paths and vendor event names stay in the adapter source, never in these shared types. Nothing here parses a vendor payload, holds power policy, touches IOKit, or runs a subprocess.

The install machinery supports a JSON value under an app-owned key, a comment-delimited block, and an app-owned copied file, all rendered from bundled assets. The shipped OMP package uses the copied-file step. The other formats remain implemented and fixture-tested until R4 replaces the generic installer with an OMP-specific one.

### App-owned storage layout

Everything the app owns lives under one injected root (production default `~/Library/Application Support/AwakeLite/`):

```
<app-support-root>/
├── inbox/                                  # Stage 1: immutable normalized event files
├── rejected/                               # Stage 1: quarantined event files
├── checkpoint.json                         # Stage 1: model checkpoint envelope
├── .lock                                   # Stage 1: single-writer lock
├── packages/<family>/                      # immutable copy of the bundled family directory
├── receipts/<family>.json                  # one receipt per installed package
└── journal/<operation-id>.json             # one in-flight or unresolved operation
    └── backups/<operation-id>/<index>      # app-owned package directory only
```

Directories are created with mode 0700 and files with 0600. An existing file keeps its permission bits when the installer rewrites it, so editing a user's configuration is never a silent permission change. `<family>` matches a single canonical path component (`[A-Za-z0-9._-]`, no separators). `<operation-id>` is `<20-digit unix micros>-<16 hex>`, so the journal file name is both chronological and unpredictable, and it must equal the `operationId` inside the file.

The package directory holds a copy of `<bundle>/Resources/Integrations/<family>/` (manifest plus assets), so an app update cannot change installed support underneath a running harness. Removal deletes it because the install created it. No user configuration file is ever copied into app storage: rollback uses app-owned template content only (see "Operation journal").

### Package manifest (bundled, trusted, schema 1)

`Resources/Integrations/<family>/manifest.json` is trusted input shipped inside the app. It is declarative: no key can express a shell command, network address, executable, or code. Unknown keys anywhere in the document are refused, which is what keeps such a field out.

| Field | Meaning |
| --- | --- |
| `schema` | Exactly `1`. Other values are refused. |
| `family` | Canonical family identifier; must equal the containing directory name. |
| `displayName` | Card title; non-empty. |
| `packageVersion` | Version of this bundled resource set; non-empty. |
| `targets[]` | `id`, `mode` (`cli`, `desktop`), `capabilities` (subset of `lifecycleHooks`, `snapshotAPI`, `inProcessExtension`, `readOnlyConnector`), `verificationLevel` (`unverified`, `fixture`, `live`). |
| `assets[]` | `id`, `source` (relative path inside the family directory), `destination` (relative to the installed package root). |
| `steps[]` | Declarative steps, described below. |
| `requiresRestart` | Whether the harness must restart before support can take effect. |
| `requiresHookTrust` | Whether the harness requires a user trust action. |
| `notes` | Limitations shown before confirmation. |

Validation performed by `PackageManifestReader`, each failure naming `<family>/manifest.json` and the offending field:

- `schema` exactly 1; `family` equals the directory name; `displayName` and `packageVersion` non-empty; unknown top-level keys refused.
- `targets[]` non-empty, ids unique and equal to `"<family>.<suffix>"` with one safe suffix; `mode`, `capabilities`, and `verificationLevel` from their closed sets; unknown target keys refused. The shipped manifest declares exactly `omp.cli`; the test fixtures declare their own targets for format coverage.
- `assets[]` ids unique; `source` is a safe relative path inside the family directory, resolves to an existing regular file, and no component from the family directory down is a symlink; `destination` is a safe relative path, unique across assets. Absolute paths, `..`, empty components, and escapes are refused. Asset text is scanned for placeholder tokens: an unknown `{token}` is a load error rather than something that ships verbatim.
- `steps[]` non-empty; `kind` in `hookConfig`, `pluginFile`, `extensionFile`, `commandWrapper`; `format` in `json`, `toml`, `yaml`, `text`, `directory`; `target` exists in `targets[]`; owned-entry markers non-empty, single-line, and unique across the whole catalog; each owned entry names an existing asset.
- `configRoot` must be exactly `${APPSUPPORT}`, or start with `~/` or `$HOME/` and name a safe relative subpath. `path` is a safe relative path below that root. `keyPath` is a non-empty array of non-empty strings and is permitted only for `format: json` (required for a JSON `hookConfig` step).

`verificationLevel` is data, never inference: discovering an executable, an app bundle, or a running process leaves it unchanged. Only a fixture or a recorded live check raises it.

### Installed entry mechanics

Every installed asset text is rendered once at apply time in a single left-to-right pass: a substituted value is never scanned again, so a `{marker}` inside a substituted value cannot expand into a second placeholder. Allowed placeholders are `{helperPath}`, `{family}`, `{target}`, `{generation}`, and `{marker}`. `helperPath` is an injected Installer value recorded in the preview and checked again at apply. The catalog store resolves it from the running bundle through `HelperResolver` and refuses setup if resolution fails. The default Installer initializer retains `/Applications/AwakeLite.app/Contents/MacOS/AwakeLiteHelper` for callers that do not inject a path. The build places the helper inside `Contents/MacOS/` and signs it before the bundle. Every installed asset ignores helper exit status, so runtime delivery still needs a separate check. Substituted values are escaped for the double-quoted context every bundled template uses, and JSON assets are rendered structurally so the result stays valid JSON. The repo's literal placeholder text must not appear in any installed file, which tests assert.

Limitation: placeholder values are escaped for a double-quoted string context (backslash, quote, newline, carriage return, tab), not for a shell. The OMP extension spawns the helper directly with `execFile`, so shell metacharacters do not apply; the chosen bundle path must still survive rendering as a JavaScript string literal. The default `/Applications` path is not a requirement.

- **`hookConfig` + `json`.** The file is read and parsed. The installer walks `keyPath`, creates missing intermediate objects, and writes `container[marker] = assetValue`. Every foreign key and value is preserved. Malformed JSON, a non-object path segment, or a foreign value already at the marker is a conflict: the file is left byte-identical. The file is written atomically and structurally (sorted keys, two-space indentation), which is the most a structural JSON writer preserves.
- **`hookConfig` + `toml`/`yaml`/`text`.** A marker-delimited block is appended or replaced:
  `# >>> awake-lite BEGIN <marker> generation=<n>` … `# <<< awake-lite END <marker>`.
  Bytes outside the block are never rewritten. An identical block makes reinstall idempotent; two blocks for one marker, or a BEGIN without its END, is a conflict. When the existing file does not end with a newline, one is appended before the block; removal deletes exactly the block, including its final newline, and does not remove that separator.
- **`pluginFile`/`extensionFile`/`commandWrapper`, and `format: directory`.** The rendered asset is written to `configRoot/path` (for `directory`, the asset file name is appended to the app-owned directory). A destination that exists with foreign content is a conflict; the destination and its content marker are recorded in the receipt.
- **Refusals.** Unsupported kind/format combinations (for example `hookConfig` with `directory`), unknown kinds or formats, a symlink anywhere on the edited path, a conflicting existing entry, and malformed input all fail with an explanation naming the path. A whole foreign file is never replaced.
- **Removal.** Only receipt entries are undone, in reverse order of kind: the marker key (pruning containers it leaves empty), the marker block, or the app-owned file. A file the install created is deleted once it holds nothing else. Any entry whose current content no longer matches the receipt hash is reported as a conflict and left untouched; the receipt stays for a later retry.
- **Temporary files.** An atomic write first sweeps abandoned `.awake-lite-*.tmp` files older than an hour from the destination directory.

### Install receipt (schema 1)

`receipts/<family>.json` records ownership and lifecycle only:

| Field | Meaning |
| --- | --- |
| `schema` | Exactly `1`. |
| `family` | Family identifier; must match the file name. |
| `packageVersion` | Version that produced the installed entries. |
| `activationGeneration` | `UInt64`, new for every install and reinstall. |
| `installedAt` | Timestamp of the commit. |
| `stage` | `committed`. |
| `entries[]` | `target`, `path`, `format`, `kind`, `marker`, `expectedHash`, `keyPath`, `createdFile`. |
| `previousGeneration` | Optional; the generation this install replaced. |
| `createdDirectories` | Directories the install created; removal deletes only these, and only when empty. |

`entries[]` is the complete removal set: an entry not listed is never touched. `expectedHash` is the hash of the marker value (canonical JSON), the block body, or the copied file. `createdFile` is the only authority for deleting a file. A receipt contains no prompts, responses, tool arguments, payloads, or credentials.

### Operation journal (schema 1)

`journal/<operation-id>.json` exists only while an operation is in flight or unresolved:

| Field | Meaning |
| --- | --- |
| `schema` | Exactly `1`. |
| `operationId` | Must equal the file name stem. |
| `family`, `action` | Package and `install`/`remove`. |
| `stage` | `prepared`, `applying`, `committed`, `recoveryRequired`. |
| `startedAt` | Operation start. |
| `expectedMutations` | How many configuration mutations the operation intends to record. |
| `steps[]` | `operation` (`config`, `obsolete`, `package`), `target`, `path`, `beforeHash`, `afterHash`, `backupPath` (package directory only), `applied`, `created`, `undo`. |
| `createdPaths[]` | Directories the operation created and must delete on rollback. |
| `receipt` | The complete receipt to write when the mutation set finishes. |

`undo` is an app-owned instruction (`removeJSONEntries`, `restoreJSONEntries`, `removeBlocks`, `restoreBlocks`, `deleteFile`, `restoreFile`) whose payload is rendered template text or a removed marker value. A shared configuration file is never copied into the journal, so no user content enters app storage. Each step is registered before its mutation and completed after it, and undo instructions are idempotent, so an interruption at any point is reversible.

Recovery runs at app start and before any new operation. It completes the operation forward when every step is applied, every path still holds the recorded result, and the expected mutation count was recorded; otherwise it rolls back to `prepared` and removes created paths. Only the last step that touched a path is compared, because a later step in the same file supersedes an earlier one. Rollback refuses to overwrite a file whose current hash differs from the step's recorded result — a later user edit — sets the stage to `recoveryRequired`, and reports the conflict; a new operation is then refused until it is resolved.

### Module and API boundaries

| File | Public surface | Boundary |
| --- | --- | --- |
| `Sources/Integrations/Manifest.swift` | `JSONValue`, `Digests`, `PathRules`, `ConfigRootSpec`, manifest types, `PackageManifestReader`, `ManifestError` | Strict schema-1 decoding and path rules only. |
| `Sources/Integrations/Catalog.swift` | `Catalog`, `CatalogError`, `TargetStatus`, `ProductDiscovery` | Loads the shipped manifests, enforces cross-manifest marker and target uniqueness, resolves local availability. |
| `Sources/Integrations/ConfigEditor.swift` | `FileState`, `ConfigEditor`, `JSONMutation`, `MarkerBlock`, `Template`, `IntegrationPaths` | Atomic writes, symlink refusal, structural JSON edits, marker blocks. No vendor knowledge. |
| `Sources/Integrations/InstallPlan.swift` | `InstallStage`, `InstalledEntry`, `InstallReceipt`, `JournalStep`, `JournalUndo`, `OperationJournal`, `InstallPlan`, `InstallPreview`, `InstallPlanner` | Declarative plan and preview construction; reads only. |
| `Sources/Integrations/Installer.swift` | `Installer` with `preview(family:configRoot:appSupportRoot:discovery:)`, `apply(_:now:)`, `remove(family:appSupportRoot:now:)`, `recoverPending(appSupportRoot:)`; `InstallerStorage`; `InstallerError` | Owns previews, edits, receipts, journal, rollback, recovery. |
| `Sources/Integrations/Activation.swift` | `ActivationHandoff` with `readState()`, `apply(to:)`, `revoke(family:in:)`; `ActivationState`, `ActiveFamily`, `UnresolvedOperation` | Reads committed receipts and journals and activates or deactivates the Stage 1 model. No observer, timer, event write, or power policy. |
| `Sources/IntegrationsView.swift` | `IntegrationsStore`, `IntegrationsWindowController`, `IntegrationsView`, preview/removal sheets | One shipped card, Installer-only actions, preview restating exact paths and owned entries; no vendor parsing, no power policy, no event writes. |

`preview` returns the family, display name, package version, generation it would create, previous generation, the injected roots, resolved target ids, declared target status (mode, capabilities, verification level, availability), preview entries with an action (`create`, `update`, `unchanged`, `conflict`), exact paths, notes, warnings, conflicts, and a digest of every input. It writes nothing. `apply` refuses a preview whose input files, receipt generation, or plan digest changed, and refuses any preview that carries a conflict.

`Catalog` resolves target availability from local files only: a documented candidate table of home-relative executables and application bundles, resolved against an injected home root and injected application roots. Discovery never launches a product, never runs a subprocess, and never changes a verification level.

### Activation-generation handoff

`Sources/Integrations/Activation.swift` is the only place where install state meets the model. It reads `receipts/*.json` and `journal/*.json` under an injected app-support root and produces:

```
struct ActivationState {
    var active: [ActiveFamily]        // family + activated generation
    var inactive: [String]            // known families that must not be observed
    var unresolved: [UnresolvedOperation]  // family + operation id + stage
}
```

- `active` holds one entry per committed receipt whose family has no unfinished operation.
- `inactive` holds families storage knows about that must not be observed, including every family with a `prepared`, `applying`, or `recoveryRequired` journal.
- `unresolved` reports each journal that has not reached `committed`, with its stage.

API:

| Call | Meaning |
| --- | --- |
| `ActivationHandoff(appSupportRoot:)` | Injected root; production passes `~/Library/Application Support/AwakeLite`. |
| `readState() throws -> ActivationState` | Reads receipts and journals only. |
| `apply(to: &model) throws -> ActivationState` | Startup handoff. Deactivates every family that is active in the model without a committed receipt, then calls `activate(family:generation:)` for each active family. |
| `revoke(family:in: &model) throws -> ActivationState` | Removal handoff. Refuses while a committed receipt still exists, then calls `deactivate(family:)`, dropping that family's work and gaps. |

A reinstall issues `previousGeneration + 1` (1 for a fresh install), recorded in the receipt and rendered into the installed template. Because `ActivityModel.activate` deactivates on a generation change, a reinstall drops work from the old installation, and an event carrying any other generation is rejected as `staleActivation` — including a late event from a hook that was running during removal or an earlier reinstall. A family with no committed receipt is inactive: its events are rejected as `inactiveSource` and it registers no work, gap, or dedup entry.

An unresolved operation never activates its family, so a half-installed package cannot receive events and `recoveryRequired` cannot activate while its conflict stands. `recoveryRequired` must be resolved first; after recovery the next handoff activates the surviving committed generation.

The handoff is read-only: no observer, timer, subprocess, event file, power decision, or receipt write. `AppCoordinator` calls recovery first, then activation, then inbox reconciliation, and delivers the aggregate decision to `AwakeController`.

### Config-root rules

- `configRoot` passed to `preview` is the injected home root (a temporary directory in tests); `~` and `$HOME` selectors resolve against it, and `${APPSUPPORT}` resolves to the injected app support root.
- A step never guesses among several candidate roots. If the intended root is not explicitly identified, the installer reports the limitation instead of writing to an unused default profile and implying success.
- Every path the installer writes lies inside an injected root. Anything else fails validation.
- Read current content, structurally add or remove only owned entries, and preserve foreign settings, hooks, plugins, credentials, and formatting intent.
- Unsupported formats, symlink targets, and conflicting existing entries fail with an explanation rather than replacing a file.

### Stage 2 test matrix

All checks run against a temporary home, configuration, and app-support root; no real user settings are read or written.

1. Fresh install for every fixture package, plus the shipped OMP manifest.
2. Repeated install is idempotent and creates no duplicate entry.
3. Install beside foreign hooks and plugins preserves them.
4. Unsupported format or a conflicting entry fails without replacing the file.
5. A symlink target is refused.
6. A stale preview is refused.
7. Interruption after each journal step; recovery reaches committed or prepared on the next start.
8. Rollback over a user-edited file is refused and reported as recoverable.
9. Removal preserves foreign entries.
10. Removal or reinstall rejects old-generation events.
11. Receipts and journals contain no conversation data (A15).
12. No observer runs for an inactive package (A01).

Items 1–9 and 11 are implemented in `Tests/AwakeLiteCoreTests/InstallerTests.swift`; item 11 additionally covers the key allowlists and error text in `PrivacyTests.swift`. Item 10 (old-generation rejection after removal and after reinstall, including a late event) and item 12 (a family with no committed receipt observes nothing, and unresolved journals never activate) are implemented in `ActivationTests.swift` against the model. The helper's own activation check is covered in `HelperIngestTests.swift`. Scheduling a live observer for an active package remains R1b.

## Stage 3 helper and adapter contracts

The retained helper and adapter sources are compiled by both `swift test` and `./build.sh`: the normalizer (`Sources/HookNormalizer.swift`), the OMP adapter (`Sources/Adapters/OMPAdapter.swift`), and the helper's argument/stdin shell (`Sources/Adapters/HelperRunner.swift` with `Helper/main.swift`). The contracts and limits below are normative; the OMP evidence is in [STATE.md](STATE.md).

### Helper invocation and exit codes

```
AwakeLiteHelper --family <family> --target <family>.<mode> --generation <uint64> --event <vendor-event> [--app-support <dir>] [--owner-instance <token> --owner-pid <pid>]
```

- `--app-support` defaults to `~/Library/Application Support/AwakeLite` and must be absolute. A missing, duplicated, empty, or unknown flag; a non-canonical family; a target without the `<family>.` prefix; a zero generation; an event token outside `[A-Za-z0-9_-]` or longer than 128 characters; or a relative root is exit 2.
- The two owner flags are all-or-nothing: one without the other, a non-canonical or over-64-character instance, or a pid that is not an integer above 1 is exit 2. With both, the ancestry walk is skipped (see "Owner identity"); without either, the walk is unchanged.
- stdin is optional, bounded at 64 KiB, and otherwise must be exactly one JSON object. stdout is always empty; one diagnostic line may be written to stderr, naming a flag, field, or path and never a payload byte.
- Exit codes: `0` one event file written; `2` invalid input, usage, unknown family or event, or malformed/oversize payload; `3` inactive family, stale generation, or unreadable install state; `4` storage failure.
- The helper holds no lock after writing, starts no timer or network connection, acquires no assertion, and exits after one emission.

`HookNormalizer.ingest` fixes the order: adapter family → documented event name → activation from committed receipts and unresolved journals (unreadable state fails closed) → bounded payload parse → adapter mapping → invariant re-stamp (schema, family, generation, target, owner, session instance, timestamp, `snapshotComplete = false`, fresh event id) → canonical identifier validation → `LocalEventStore.enqueue`. Activation is decided before a payload byte is parsed and before storage is touched. An unreadable tree is `activationUnavailable(path:)` — the install state, not the family's receipt — and still exits 3 without creating anything. `HookPayload` exposes named fields only; unknown keys are never enumerated, copied, logged, or persisted.

`HookAdapterRegistry.all` holds the shipped adapter: `OMPAdapter`. A new family requires an explicit scope decision and one registry entry.

### Owner identity

The helper's immediate parent is usually a throwaway `sh`, so the owner is the *observed agent instance*, not the helper: the probe starts at `getppid()`, walks up with `proc_pidinfo(PROC_PIDTBSDINFO)` for at most 64 hops, and skips documented transient wrappers (`sh`, `bash`, `zsh`, `dash`, `ksh`, `tcsh`, `csh`, `fish`, `env`, `sudo`, `script`, `xargs`, `timeout`, `nohup`, `launchctl`) by basename with a leading login-shell hyphen removed. The first non-transient ancestor is the owner; the walk stops at PID 1, a cycle, an undescribable process, or the hop bound, and keeps the immediate parent if every ancestor is a wrapper.

Instance token: `p<pid>-u<uid>-t<startMicros>-b<bootSec>-<bootUsec>`, boot from `sysctl kern.boottime`. An undescribable process yields the unjoinable fallback `x-p<pid>-u<uid>-n<nonce>` with `startTimeMicros == 0`, which can hold work but never close another process's work; a re-parented helper (`getppid() <= 1`) takes the fallback rather than naming launchd.

Supplied identity: a caller that can measure the harness process before spawning the helper passes `--owner-instance` and `--owner-pid` together. The owner is then `(helper boot token, helper uid, supplied pid, supplied instance, startTimeMicros 0)` and no ancestry walk runs. The boot token and uid stay the helper's own because they are the values it can see; `startTimeMicros` is 0 because the caller supplies no measurement of the owner's start time. This exists because a detached helper can be orphaned before it probes its parent: the measured owner would be launchd or a dead wrapper, so emissions of one harness process would disagree and teardown could never match. The OMP asset mints `p<pid>-<8 random hex>` once per process at module load and send it with every emission, so teardown is orphan-proof, and a later process that receives the same pid mints a different token, which owner equality keeps apart. The narrower limitation is that `startTimeMicros` is 0, so a liveness probe cannot verify that a live pid still names the owner recorded in an event; such a probe must treat supplied-owner work conservatively — never releasing it on pid liveness alone — and owner death therefore remains the Stage 5 probe's job rather than a hook's claim.

Limits: an unknown wrapper between the helper and the agent changes the owner (the model then rejects the terminal transition, so the direction is conservative); a measured owner separates PID reuse only by start time, while a supplied owner is separated by its per-process token but offers no start time for a liveness probe to confirm; arrival order is not causal order.

### OMP mapping and documented limits

The extension is installed at `~/.omp/agent/extensions/awake-lite/index.js` as an in-process extension.

| Event | Mapping |
| --- | --- |
| `session_start` | Incomplete session snapshot; creates no work. |
| `agent_start` | Next strictly increasing run generation, preceded by `run_superseded` (`.cancelled`) for a still-recorded previous generation; then a main run `started` or a subagent `childStarted` plus parent work. |
| `turn_start` | Started (keeps the run working). |
| `agent_end` | With `willContinue` or `awaitingAsyncWork`, a heartbeat; otherwise completes the main run. A subagent ends as `childFinished`. |
| `session_stop` | Completed; documented to defer until agent-owned background jobs are idle. |
| `auto_retry_start` / `auto_retry_end` | Heartbeat; `auto_retry_end` with `success: false` is `failed`. |
| `tool_approval_requested` / `tool_approval_resolved` | Human wait / resumed. |
| `session_shutdown` | Cancels the observed run generation; without one, a conservative snapshot. |

Documented limits: `session_switch` names no old-session identifier, so a switch cannot retire the old session; `agent_end` carries no run outcome, so failures and aborts settle as completed; `session_stop` carries no `sequence` because its `turn_id` is a different counter; a mode that emits neither a terminal `agent_end` nor `session_stop` leaves the run working until shutdown; approval events are documented as emitted only when an approval handler is registered, so the human-wait mapping is unverified; delivery order is unverified.

The extension asset spawns the helper detached with allowlisted metadata only, writes stdin once, discards stdout and stderr, ignores every exit code, and starts no timer. A failed emission is therefore invisible to the harness.



### Activation check on the event path

Every emission is checked against install state before anything is parsed or written: an unreadable receipts/journal tree, a family with no committed receipt, or an unresolved operation means exit 3 and no event file, and a generation that differs from the committed one is `staleGeneration` (also exit 3). An unreadable tree is reported as `activationUnavailable(path:)` so it is never mistaken for a missing receipt. The check reads committed receipts and journals only, so a removed or reinstalled package cannot be resurrected by a hook that was already in flight.

## Adapter checks completed and still open

The fixture prerequisites exist: the core is proven for two parallel sessions, late completion, a waiting parent with a working child, an event gap, PID reuse, and restart; installation is verified in isolated roots with unrelated hooks, failures, non-default paths, and interruption; and the OMP adapter tests cover its documented event set, allowlist, activation, and storage path against fixture payloads.

Still open, and the reason `omp.cli` is not marked `live`: connecting a real OMP process and observing its delivery. Fixture success does not raise live compatibility status, and the product's installed presence is not evidence of acceptance. [STATE.md](STATE.md) records what is proven and what is not.

## Historical decisions

Approved on 2026-11-01: native app-owned core, local packages, independent events, and uncertainty rules. On 2026-11-02 the user selected OMP CLI as the only first-version target. On 2026-11-04 the shipped surface was cut to OMP; the pre-cut implementation is on branch `omp-only-minimal`.

OMP delivery is the R2 check; the existing checkpoint fixtures do not establish app-level recovery. If OMP lacks a required guarantee, revise its adapter or declared status rather than weaken the shared model. Commits, publications, release uploads, and system installs require separate authorization.
