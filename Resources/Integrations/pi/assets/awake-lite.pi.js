// AwakeLite Pi lifecycle extension.
// Marker "{marker}" / family "{family}" / target "{target}" / generation: "{generation}".
// Helper "{helperPath}".
//
// Reports lifecycle metadata only, and only through the helper contract:
// one short-lived helper process per mapped vendor event, started detached,
// with stdin written once and closed, stdout and stderr discarded, and every
// exit code ignored. The factory starts no timer and no process, no handler
// waits on the helper, and no failure is ever raised into Pi.
//
// No conversation content is read or sent: the payload carries the session id,
// the AwakeLite run discriminator, the documented turn index, and the
// documented lifecycle flags only.

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const HELPER = "{helperPath}";
const FAMILY = "{family}";
const TARGET = "{target}";
const GENERATION = Number("{generation}");
const MARKER = "{marker}";

// One owner per harness process, minted at module load. The helper is spawned
// detached, so it can be orphaned before it probes a parent; passing this
// identity keeps every event of one Pi process under the same owner even after
// the process exits. The helper builds the rest of the identity itself and
// records startTimeMicros 0 by contract, so owner liveness stays conservative.
const OWNER_PID = process.pid;
const OWNER_INSTANCE = "p" + OWNER_PID + "-" + randomUUID().replace(/-/g, "").slice(0, 8);

// Inspectable provenance for the installed file; the helper contract uses the
// constants above.
export const awakeLite = { marker: MARKER, family: FAMILY, target: TARGET, generation: GENERATION };

let runGeneration = 0;

function currentSession(ctx) {
  try {
    const manager = ctx ? ctx.sessionManager : undefined;
    if (manager && typeof manager.getSessionId === "function") {
      const id = manager.getSessionId();
      if (typeof id === "string" && id.length > 0) return id;
    }
  } catch (error) {
    return "";
  }
  return "";
}

function report(eventName, fields) {
  try {
    const args = [
      "--family", FAMILY,
      "--target", TARGET,
      "--generation", String(GENERATION),
      "--event", eventName,
      "--owner-instance", OWNER_INSTANCE,
      "--owner-pid", String(OWNER_PID)
    ];
    const child = spawn(HELPER, args, { stdio: ["pipe", "ignore", "ignore"], detached: true });
    child.on("error", function () {});
    if (child.stdin) {
      child.stdin.on("error", function () {});
      child.stdin.end(JSON.stringify(fields));
    }
    child.unref();
  } catch (error) {
    // A failed emission is silent by contract.
  }
}

function runFields(ctx) {
  const fields = { session: currentSession(ctx), workGeneration: runGeneration };
  return fields;
}

function turnFields(ctx, event) {
  const fields = runFields(ctx);
  if (event && typeof event.turnIndex === "number") fields.sequence = event.turnIndex;
  return fields;
}

export default function awakeLitePi(pi) {
  pi.on("session_start", function (event, ctx) {
    runGeneration = 0;
    const reason = event && typeof event.reason === "string" ? event.reason : "";
    report("session_start", { session: currentSession(ctx), reason: reason });
  });

  pi.on("session_shutdown", function (event, ctx) {
    const reason = event && typeof event.reason === "string" ? event.reason : "";
    const fields = { session: currentSession(ctx), reason: reason };
    if (runGeneration > 0) fields.workGeneration = runGeneration;
    report("session_shutdown", fields);
    runGeneration = 0;
  });

  pi.on("agent_start", function (event, ctx) {
    // A new low-level run needs a discriminator no earlier run in this session
    // can reuse, including after a reload restarts this module. The generation
    // it replaces is closed first: Pi emits no event that ends a superseded
    // run, and the model would otherwise hold its work until shutdown.
    const previous = runGeneration;
    runGeneration = Math.max(Date.now(), previous + 1);
    if (previous > 0) {
      report("run_superseded", { session: currentSession(ctx), workGeneration: previous });
    }
    report("agent_start", runFields(ctx));
  });

  pi.on("turn_start", function (event, ctx) {
    if (runGeneration === 0) return;
    report("turn_start", turnFields(ctx, event));
  });

  pi.on("turn_end", function (event, ctx) {
    if (runGeneration === 0) return;
    const fields = turnFields(ctx, event);
    fields.outcome = event && typeof event.outcome === "string" ? event.outcome : "";
    report("turn_end", fields);
  });

  pi.on("ui_prompt_start", function (event, ctx) {
    if (runGeneration === 0) return;
    report("ui_prompt_start", runFields(ctx));
  });

  pi.on("ui_prompt_end", function (event, ctx) {
    if (runGeneration === 0) return;
    report("ui_prompt_end", runFields(ctx));
  });

  pi.on("agent_settled", function (event, ctx) {
    if (runGeneration === 0) return;
    const fields = runFields(ctx);
    fields.aborted = Boolean(event && event.aborted);
    report("agent_settled", fields);
    runGeneration = 0;
  });
}
