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

## Stage 3. Installed harnesses

Connect one at a time: Pi, OMP, OpenCode, then Codex CLI and desktop. This sequence first tests in-process events, then snapshot APIs, then hook trust and desktop orchestration. New evidence may justify a different order; explain the change briefly in STATE.

For each target, verify the normal lifecycle, human waits, cancellation, failure, retry, parallel work, and restart. Use test sessions without interrupting existing user work. Do not issue paid requests in an unbounded automatic loop.

Exit criteria: a per-target matrix for A04–A13. Keep unverified scenarios explicitly marked. Product installation is not evidence of acceptance.

## Stage 4. Remaining selected families

Deliverable: Claude Code, Cursor, and Antigravity packages based on official contracts and fixtures. Record CLI and desktop compatibility separately.

Exit criteria: verified installation, normalization, and scenario fixtures. Confirm live support only on a product later made available by the user. Do not download missing products to complete this stage.

## Stage 5. Native app acceptance

Deliverable: menu-bar UI, catalog window, real assertion behavior, pause, quit, launch at login, startup recovery, and diagnostics.

Exit criteria: A05, A14, A15, and A17 on the available Mac. Record processor architecture and macOS version. One Mac does not establish support for every target platform.

## Stage 6. Handoff readiness

Deliverable: documentation matches accepted targets. The UI identifies experimental and unavailable modes. App and integration removal are documented and checked.

Exit criteria: focused review of runtime, concurrency, and configuration operations, followed by fixes for confirmed defects. Limit automatic repair to two rounds per bounded unit, then reassess the approach.

Full acceptance of ten targets requires live checks of ten targets. Before that, a limited version can be delivered with an accurate compatibility matrix. Publication, release uploads, push, and system installation require authorization for those actions unless the user has already explicitly granted it in the same session.

## Effort estimate

The core, catalog, and first adapters should take several working days after approval. A broader version with verification is roughly one to two working weeks, or longer if desktop modes impose limits. This is an estimate, not a deadline. Missing products prevent a promised date for their live acceptance.
