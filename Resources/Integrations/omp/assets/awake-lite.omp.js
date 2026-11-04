// AwakeLite OMP lifecycle extension.
// Marker "{marker}" / family "{family}" / target "{target}" / generation: "{generation}".
// Helper "{helperPath}".
//
// Reports lifecycle metadata only, and only through the helper contract:
// one short-lived helper process per mapped vendor event, started detached,
// with stdin written once and closed, stdout and stderr discarded, and every
// exit code ignored. The factory starts no timer and no process, no handler
// waits on the helper, and no failure is ever raised into OMP.
//
// No conversation content is read or sent: the payload carries the session id,
// the agent identity kind and parent id, the AwakeLite run discriminator, the
// documented turn id, and the documented lifecycle flags only.
//
// OMP rebinds extension factories to every subagent session, so the same
// handlers also report child work: the child session is a separate identity,
// and its parent id is the documented spawning agent registry id.

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";

const HELPER = "{helperPath}";
const FAMILY = "{family}";
const TARGET = "{target}";
const GENERATION = Number("{generation}");
const MARKER = "{marker}";

// One owner per harness process, minted at module load. The helper is spawned
// detached, so it can be orphaned before it probes a parent; passing this
// identity keeps every event of one OMP process under the same owner even after
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

function agentKind(ctx) {
  try {
    const agent = ctx ? ctx.agent : undefined;
    if (agent && agent.kind === "sub") return "sub";
    if (agent && agent.kind === "main") return "main";
  } catch (error) {
    return "main";
  }
  return "main";
}

function parentWork(ctx) {
  try {
    const agent = ctx ? ctx.agent : undefined;
    if (agent && typeof agent.parentId === "string") return agent.parentId;
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
  const fields = {
    session: currentSession(ctx),
    workGeneration: runGeneration,
    agentKind: agentKind(ctx)
  };
  const parent = parentWork(ctx);
  if (parent.length > 0) fields.parentWork = parent;
  return fields;
}

export default function awakeLiteOmp(pi) {
  pi.on("session_start", function (event, ctx) {
    runGeneration = 0;
    report("session_start", { session: currentSession(ctx) });
  });

  pi.on("session_shutdown", function (event, ctx) {
    const fields = { session: currentSession(ctx) };
    if (runGeneration > 0) fields.workGeneration = runGeneration;
    report("session_shutdown", fields);
    runGeneration = 0;
  });

  pi.on("agent_start", function (event, ctx) {
    // A new agent loop needs a discriminator no earlier loop in this session
    // can reuse, including after a reload restarts this module. The generation
    // it replaces is closed first: a continuation, retry, or reloaded runtime
    // emits no event that ends the superseded run.
    const previous = runGeneration;
    runGeneration = Math.max(Date.now(), previous + 1);
    if (previous > 0) {
      report("run_superseded", { session: currentSession(ctx), workGeneration: previous });
    }
    report("agent_start", runFields(ctx));
  });

  pi.on("turn_start", function (event, ctx) {
    if (runGeneration === 0) return;
    const fields = runFields(ctx);
    if (event && typeof event.turnIndex === "number") fields.sequence = event.turnIndex;
    report("turn_start", fields);
  });

  pi.on("agent_end", function (event, ctx) {
    if (runGeneration === 0) return;
    const fields = runFields(ctx);
    // Documented terminal-settle flags. When either is set this loop end is not
    // a final idle signal: an automatic continuation or background work follows.
    fields.willContinue = Boolean(event && event.willContinue);
    fields.awaitingAsyncWork = Boolean(event && event.awaitingAsyncWork);
    report("agent_end", fields);
  });

  pi.on("session_stop", function (event, ctx) {
    if (runGeneration === 0) return;
    if (agentKind(ctx) !== "main") return;
    report("session_stop", runFields(ctx));
    runGeneration = 0;
  });

  pi.on("auto_retry_start", function (event, ctx) {
    if (runGeneration === 0) return;
    report("auto_retry_start", runFields(ctx));
  });

  pi.on("auto_retry_end", function (event, ctx) {
    if (runGeneration === 0) return;
    const fields = runFields(ctx);
    fields.success = Boolean(event && event.success);
    report("auto_retry_end", fields);
  });

  pi.on("tool_approval_requested", function (event, ctx) {
    if (runGeneration === 0) return;
    report("tool_approval_requested", runFields(ctx));
  });

  pi.on("tool_approval_resolved", function (event, ctx) {
    if (runGeneration === 0) return;
    report("tool_approval_resolved", runFields(ctx));
  });
}
