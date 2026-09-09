// Real timers preserve the root AsyncLocalStorage that the wake queue must carry.
import path from "node:path";
import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { createDeferred, withTestTimeout } from "../../test/helpers/promise.js";
import { useAutoCleanupTempDirTracker } from "../../test/helpers/temp-dir.js";
import type { OpenClawConfig } from "../config/types.openclaw.js";
import {
  getActiveGatewayRootWorkCount,
  getGatewaySuspendAdmissionPhase,
  markGatewayRestartDraining,
  resetGatewayWorkAdmission,
  runOutsideGatewayRootWorkAdmission,
  runWithRetainedGatewayRootWork,
  tryBeginGatewayRootWorkAdmission,
  tryBeginGatewaySuspendAdmission,
} from "../process/gateway-work-admission.js";
import { resolveGlobalSingleton } from "../shared/global-singleton.js";
import { resolveHeartbeatPreflight, resolveHeartbeatRunPrompt } from "./heartbeat-runner-prompt.js";
import type { HeartbeatRunResult, HeartbeatWakeRequest } from "./heartbeat-wake-contracts.js";
import {
  requestSessionEventWake,
  requestSessionEventWakeAndWait,
  setSessionEventWakeHandler,
} from "./session-event-wake.js";
import {
  runWithSystemEventWakeReceipt,
  selectAgentSystemEvents,
  withSystemEventOwner,
} from "./system-event-ownership.js";
import {
  consumeSelectedSystemEventEntries,
  enqueueSystemEventEntry,
  enqueueSystemEventWithReceipt,
  peekSystemEventEntries,
  resetSystemEventsForTest,
} from "./system-events.js";

const tempDirs = useAutoCleanupTempDirTracker(afterEach);
const sessionKey = "agent:main:main";
const ran = { status: "ran", durationMs: 1 } as const;
let disposeHandler: (() => void) | undefined;

beforeEach(() => {
  resetGatewayWorkAdmission();
});

afterEach(async () => {
  resetGatewayWorkAdmission();
  disposeHandler?.();
  const disposeDrain = setSessionEventWakeHandler(async () => ({
    status: "skipped",
    reason: "disabled",
  }));
  // A global immediate wake joins all remaining ready targets before teardown.
  await requestSessionEventWakeAndWait({
    source: "manual",
    intent: "immediate",
    reason: "manual",
    coalesceMs: 0,
  });
  disposeDrain();
  resetSystemEventsForTest();
  vi.unstubAllEnvs();
});

function taskWake(jobId: string): HeartbeatWakeRequest & { coalesceMs: number } {
  return {
    source: "interval",
    intent: "task",
    reason: `heartbeat-task:${jobId}`,
    agentId: "main",
    sessionKey,
    coalesceMs: 10,
    tasks: [{ jobId, name: jobId, prompt: jobId }],
  };
}

it("drains an admitted retry while same-target independent work stays parked", async () => {
  const root = tryBeginGatewayRootWorkAdmission("test:cron-admission");
  if (!root) {
    throw new Error("expected root admission");
  }
  const firstAttempt = createDeferred();
  const observed: string[][] = [];
  let first = true;
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    observed.push((request.tasks ?? []).map((task) => task.jobId));
    if (first) {
      first = false;
      firstAttempt.resolve();
      return { status: "skipped", reason: "cron-in-progress", retryAtMs: Date.now() + 30 };
    }
    return ran;
  });
  const pending = root.run(() =>
    runWithRetainedGatewayRootWork(() => requestSessionEventWakeAndWait(taskWake("admitted"))),
  );
  root.release();
  await firstAttempt.promise;
  const suspension = tryBeginGatewaySuspendAdmission(() => {});
  expect(suspension?.drain()).toBe(true);
  const independent = requestSessionEventWakeAndWait(taskWake("independent"));
  try {
    await expect(pending).resolves.toMatchObject({ status: "ran" });
    expect(observed).toEqual([["admitted"], ["admitted"]]);
    expect(getActiveGatewayRootWorkCount()).toBe(0);
    expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
    expect(suspension?.release()).toBe(true);
    await independent;
    expect(observed).toEqual([["admitted"], ["admitted"], ["independent"]]);
  } finally {
    suspension?.release();
    await Promise.allSettled([pending, independent]);
  }
});

it("coalesces admitted and independent work normally while admission is open", async () => {
  const root = tryBeginGatewayRootWorkAdmission("test:coalesced-admission");
  if (!root) {
    throw new Error("expected root admission");
  }
  const observed: string[][] = [];
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    observed.push((request.tasks ?? []).map((task) => task.jobId));
    return ran;
  });
  const pending = root.run(() => requestSessionEventWakeAndWait(taskWake("admitted")));
  const independent = requestSessionEventWakeAndWait(taskWake("independent"));
  try {
    await Promise.all([pending, independent]);
    expect(observed).toEqual([["admitted", "independent"]]);
  } finally {
    root.release();
  }
  expect(getActiveGatewayRootWorkCount()).toBe(0);
});

it("retains queued work when a live origin's waiter detaches on retry", async () => {
  const root = tryBeginGatewayRootWorkAdmission("test:detached-waiter");
  if (!root) {
    throw new Error("expected root admission");
  }
  const terminal = createDeferred();
  let attempts = 0;
  disposeHandler = setSessionEventWakeHandler(async () => {
    attempts += 1;
    if (attempts === 1) {
      return { status: "skipped", reason: "cron-in-progress", retryAtMs: Date.now() + 20 };
    }
    terminal.resolve();
    return ran;
  });
  try {
    const pending = root.run(() =>
      requestSessionEventWakeAndWait(taskWake("detached"), { stopWaitingOnRetry: () => true }),
    );
    await expect(pending).resolves.toMatchObject({ status: "skipped", reason: "cron-in-progress" });
    await terminal.promise;
    expect(attempts).toBe(2);
  } finally {
    root.release();
  }
});

it.each(["detach", "abort"] as const)(
  "keeps %s work queued after its parent ends, then admits it only after suspension reopens",
  async (mode) => {
    const root = tryBeginGatewayRootWorkAdmission("test:ended-detached-origin");
    const probeRoot = tryBeginGatewayRootWorkAdmission("test:draining-probe");
    if (!root || !probeRoot) {
      throw new Error("expected root admissions");
    }
    const firstAttempt = createDeferred();
    const terminal = createDeferred();
    const controller = new AbortController();
    const observed: string[][] = [];
    let first = true;
    disposeHandler = setSessionEventWakeHandler(async (request) => {
      const tasks = (request.tasks ?? []).map((task) => task.jobId);
      observed.push(tasks);
      if (first) {
        first = false;
        firstAttempt.resolve();
        return { status: "skipped", reason: "cron-in-progress", retryAtMs: Date.now() + 20 };
      }
      if (tasks.includes("detached")) {
        terminal.resolve();
      }
      return ran;
    });
    const pending = root.run(() =>
      requestSessionEventWakeAndWait(taskWake("detached"), {
        abortSignal: controller.signal,
        stopWaitingOnRetry: () => mode === "detach",
      }),
    );
    await firstAttempt.promise;
    if (mode === "abort") {
      controller.abort();
    }
    await expect(pending).resolves.toMatchObject(
      mode === "detach"
        ? { status: "skipped", reason: "cron-in-progress" }
        : { status: "failed", reason: "heartbeat wake cancelled" },
    );
    root.release();
    const suspension = tryBeginGatewaySuspendAdmission(() => {});
    expect(suspension?.drain()).toBe(true);
    // This later admitted turn proves the detached retry deadline has elapsed
    // while independent work is still parked behind the closed fence.
    const probe = probeRoot.run(() =>
      requestSessionEventWakeAndWait({ ...taskWake("probe"), coalesceMs: 50 }),
    );
    try {
      await probe;
      probeRoot.release();
      expect(observed).toEqual([["detached"], ["probe"]]);
      expect(getActiveGatewayRootWorkCount()).toBe(0);
      expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
      expect(suspension?.release()).toBe(true);
      await withTestTimeout(terminal.promise, 1500, "detached queued work did not resume");
      expect(observed).toEqual([["detached"], ["probe"], ["detached"]]);
    } finally {
      root.release();
      probeRoot.release();
      suspension?.release();
      await Promise.allSettled([pending, probe]);
    }
  },
);

it.each(["detach", "abort"] as const)(
  "separates a %s contribution from a coalesced live waiter before draining suspension",
  async (mode) => {
    const liveRoot = tryBeginGatewayRootWorkAdmission("test:mixed-live-origin");
    const detachedRoot = tryBeginGatewayRootWorkAdmission("test:mixed-detached-origin");
    if (!liveRoot || !detachedRoot) {
      throw new Error("expected root admissions");
    }
    const firstAttempt = createDeferred();
    const terminal = createDeferred();
    const controller = new AbortController();
    const observed: string[][] = [];
    let first = true;
    disposeHandler = setSessionEventWakeHandler(async (request) => {
      const tasks = (request.tasks ?? []).map((task) => task.jobId);
      observed.push(tasks);
      if (first) {
        first = false;
        firstAttempt.resolve();
        return { status: "skipped", reason: "cron-in-progress", retryAtMs: Date.now() + 20 };
      }
      if (tasks.includes("detached")) {
        terminal.resolve();
      }
      return ran;
    });
    const live = liveRoot.run(() => requestSessionEventWakeAndWait(taskWake("admitted")));
    const detached = detachedRoot.run(() =>
      requestSessionEventWakeAndWait(taskWake("detached"), {
        abortSignal: controller.signal,
        stopWaitingOnRetry: () => mode === "detach",
      }),
    );
    await firstAttempt.promise;
    if (mode === "abort") {
      controller.abort();
    }
    await detached;
    detachedRoot.release();
    const suspension = tryBeginGatewaySuspendAdmission(() => {});
    expect(suspension?.drain()).toBe(true);
    try {
      await expect(live).resolves.toMatchObject({ status: "ran" });
      liveRoot.release();
      expect(observed).toEqual([["admitted", "detached"], ["admitted"]]);
      expect(getActiveGatewayRootWorkCount()).toBe(0);
      expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
      expect(suspension?.release()).toBe(true);
      await withTestTimeout(terminal.promise, 1500, "mixed detached contribution did not resume");
      expect(observed).toEqual([["admitted", "detached"], ["admitted"], ["detached"]]);
    } finally {
      liveRoot.release();
      detachedRoot.release();
      suspension?.release();
      await Promise.allSettled([live, detached]);
    }
  },
);

it("preserves the owner-string contract with an older module sharing the process queue", () => {
  // This is the established native/source module ABI, not admission metadata.
  const legacyOwners = resolveGlobalSingleton(
    Symbol.for("openclaw.systemEvents.ownership"),
    () => new WeakMap<object, string>(),
  );
  const legacyOptions = { sessionKey, contextKey: "legacy:alpha" };
  legacyOwners.set(legacyOptions, "alpha");
  enqueueSystemEventEntry("legacy alpha event", legacyOptions);
  enqueueSystemEventEntry(
    "current beta event",
    withSystemEventOwner({ sessionKey, contextKey: "current:beta" }, "beta"),
  );
  const snapshot = peekSystemEventEntries(sessionKey);
  expect(snapshot.map((event) => legacyOwners.get(event))).toEqual(["alpha", "beta"]);
  expect(selectAgentSystemEvents(snapshot, "alpha").map((event) => event.text)).toEqual([
    "legacy alpha event",
  ]);
  expect(selectAgentSystemEvents(snapshot, "beta").map((event) => event.text)).toEqual([
    "current beta event",
  ]);
});

it("keeps the latest task content when open admission coalesces both cohorts", async () => {
  const root = tryBeginGatewayRootWorkAdmission("test:coalesced-correction");
  if (!root) {
    throw new Error("expected root admission");
  }
  const prompts: string[] = [];
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    prompts.push(...(request.tasks ?? []).map((task) => task.prompt));
    return ran;
  });
  const pending = root.run(() => requestSessionEventWakeAndWait(taskWake("same-job")));
  const independent = requestSessionEventWakeAndWait({
    ...taskWake("same-job"),
    tasks: [{ jobId: "same-job", name: "same-job", prompt: "corrected independent payload" }],
  });
  try {
    await Promise.all([pending, independent]);
    expect(prompts).toEqual(["corrected independent payload"]);
  } finally {
    root.release();
  }
});

it.each(["release", "reset"] as const)(
  "rejects a %s-retired origin before invoking the handler",
  async (retirement) => {
    const root = tryBeginGatewayRootWorkAdmission("test:retired-admission");
    if (!root) {
      throw new Error("expected root admission");
    }
    const handler = vi.fn(async () => ran);
    disposeHandler = setSessionEventWakeHandler(handler);
    const pending = root.run(() => requestSessionEventWakeAndWait(taskWake("retired")));
    if (retirement === "reset") {
      resetGatewayWorkAdmission();
    } else {
      root.release();
    }
    try {
      await expect(pending).resolves.toEqual({
        status: "failed",
        reason: "heartbeat wake admission is no longer active",
      });
      expect(handler).not.toHaveBeenCalled();
    } finally {
      root.release();
    }
  },
);

it.each(["open", "suspended"] as const)(
  "preserves a coalesced live sibling when another origin retires with admission %s",
  async (admission) => {
    const retiredRoot = tryBeginGatewayRootWorkAdmission("test:retired-coalesced-origin");
    const liveRoot = tryBeginGatewayRootWorkAdmission("test:live-coalesced-origin");
    if (!retiredRoot || !liveRoot) {
      throw new Error("expected root admissions");
    }
    const observed: string[][] = [];
    disposeHandler = setSessionEventWakeHandler(async (request) => {
      observed.push((request.tasks ?? []).map((task) => task.jobId));
      return ran;
    });
    const retired = retiredRoot.run(() => requestSessionEventWakeAndWait(taskWake("retired")));
    const live = liveRoot.run(() => requestSessionEventWakeAndWait(taskWake("live")));
    retiredRoot.release();
    const suspension = admission === "suspended" ? tryBeginGatewaySuspendAdmission(() => {}) : null;
    if (admission === "suspended") {
      expect(suspension?.drain()).toBe(true);
    }
    try {
      await expect(retired).resolves.toEqual({
        status: "failed",
        reason: "heartbeat wake admission is no longer active",
      });
      await expect(live).resolves.toEqual(ran);
      expect(observed).toEqual([["live"]]);
      liveRoot.release();
      expect(getActiveGatewayRootWorkCount()).toBe(0);
      expect(getGatewaySuspendAdmissionPhase()).toBe(
        admission === "suspended" ? "draining" : "accepting",
      );
    } finally {
      retiredRoot.release();
      liveRoot.release();
      suspension?.release();
      await Promise.allSettled([retired, live]);
    }
  },
);

it.each(["older", "newer"] as const)(
  "uses surviving task content when the %s coalesced correction loses its origin",
  async (retirement) => {
    const olderRoot = tryBeginGatewayRootWorkAdmission("test:older-correction-origin");
    const newerRoot = tryBeginGatewayRootWorkAdmission("test:newer-correction-origin");
    if (!olderRoot || !newerRoot) {
      throw new Error("expected root admissions");
    }
    const prompts: string[] = [];
    disposeHandler = setSessionEventWakeHandler(async (request) => {
      prompts.push(...(request.tasks ?? []).map((task) => task.prompt));
      return ran;
    });
    const older = olderRoot.run(() =>
      requestSessionEventWakeAndWait({
        ...taskWake("same-job"),
        tasks: [{ jobId: "same-job", name: "same-job", prompt: "older payload" }],
      }),
    );
    const newer = newerRoot.run(() =>
      requestSessionEventWakeAndWait({
        ...taskWake("same-job"),
        tasks: [{ jobId: "same-job", name: "same-job", prompt: "newer payload" }],
      }),
    );
    (retirement === "older" ? olderRoot : newerRoot).release();
    try {
      await expect(retirement === "older" ? older : newer).resolves.toEqual({
        status: "failed",
        reason: "heartbeat wake admission is no longer active",
      });
      await expect(retirement === "older" ? newer : older).resolves.toEqual(ran);
      expect(prompts).toEqual([retirement === "older" ? "newer payload" : "older payload"]);
    } finally {
      olderRoot.release();
      newerRoot.release();
      await Promise.allSettled([older, newer]);
    }
    expect(getActiveGatewayRootWorkCount()).toBe(0);
  },
);

it("settles an admitted wake without crossing a committed restart fence", async () => {
  const root = tryBeginGatewayRootWorkAdmission("test:restart-admission");
  if (!root) {
    throw new Error("expected root admission");
  }
  const handler = vi.fn(async () => ran);
  disposeHandler = setSessionEventWakeHandler(handler);
  const pending = root.run(() => requestSessionEventWakeAndWait(taskWake("restarting")));
  markGatewayRestartDraining();
  try {
    await expect(pending).resolves.toEqual({
      status: "failed",
      reason: "heartbeat wake interrupted by gateway restart",
    });
    expect(handler).not.toHaveBeenCalled();
  } finally {
    root.release();
  }
});

it("uses one admitted occurrence snapshot for the real heartbeat prompt and consumption during suspension", async () => {
  const directory = tempDirs.make("heartbeat-admission-events-");
  vi.stubEnv("OPENCLAW_STATE_DIR", directory);
  const cfg: OpenClawConfig = {
    session: { store: path.join(directory, "sessions.json") },
    agents: { defaults: { workspace: directory } },
  };
  const root = tryBeginGatewayRootWorkAdmission("test:event-admission");
  if (!root) {
    throw new Error("expected root admission");
  }
  const admittedReceipt = await root.run(async () =>
    enqueueSystemEventWithReceipt("Reminder: admitted result", {
      sessionKey,
      contextKey: "cron:admitted",
    }),
  );
  const admitted = peekSystemEventEntries(sessionKey)[0];
  const independentEvent = enqueueSystemEventEntry("Reminder: independent result", {
    sessionKey,
    contextKey: "cron:independent",
  });
  const unbound = await root.run(async () =>
    enqueueSystemEventEntry("Reminder: unbound live-parent result", {
      sessionKey,
      contextKey: "cron:unbound",
    }),
  );
  const observed: Array<{ ids: Array<string | undefined>; prompt: string }> = [];
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    const preflight = await resolveHeartbeatPreflight({
      cfg,
      agentId: "main",
      sessionKey,
      source: request.source,
      reason: request.reason,
    });
    const prepared = resolveHeartbeatRunPrompt({
      cfg,
      preflight,
      canRelayToUser: false,
      startedAt: Date.now(),
      scheduledTasks: [],
      useHeartbeatResponseTool: false,
    });
    observed.push({
      ids: preflight.pendingEventEntries.map((event) => event.id),
      prompt: prepared.prompt,
    });
    consumeSelectedSystemEventEntries(sessionKey, [
      ...prepared.genericEvents,
      ...prepared.inspectedSystemEventsToConsume,
    ]);
    return ran;
  });
  const suspension = tryBeginGatewaySuspendAdmission(() => {});
  expect(suspension?.drain()).toBe(true);
  const pending = root.run(() =>
    runWithSystemEventWakeReceipt(admittedReceipt, () =>
      requestSessionEventWakeAndWait({
        source: "cron",
        intent: "immediate",
        reason: "cron:admitted",
        agentId: "main",
        sessionKey,
        coalesceMs: 0,
      }),
    ),
  );
  const independent = requestSessionEventWakeAndWait({
    source: "cron",
    intent: "immediate",
    reason: "cron:independent",
    agentId: "main",
    sessionKey,
    coalesceMs: 0,
  });
  try {
    await pending;
    expect(observed).toHaveLength(1);
    expect(observed[0]?.ids).toEqual([admitted?.id]);
    expect(observed[0]?.prompt).toContain("admitted result");
    expect(observed[0]?.prompt).not.toContain("independent result");
    expect(observed[0]?.prompt).not.toContain("unbound live-parent result");
    expect(peekSystemEventEntries(sessionKey).map((event) => event.id)).toEqual([
      independentEvent?.id,
      unbound?.id,
    ]);
    root.release();
    expect(getActiveGatewayRootWorkCount()).toBe(0);
    expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
    expect(suspension?.release()).toBe(true);
    await independent;
    expect(observed[1]?.ids).toEqual([independentEvent?.id, unbound?.id]);
    expect(peekSystemEventEntries(sessionKey)).toEqual([]);
  } finally {
    root.release();
    suspension?.release();
    await Promise.allSettled([pending, independent]);
  }
});

it.each(["detach", "abort"] as const)(
  "keeps %s event custody isolated from another admitted prompt while the parent stays live",
  async (mode) => {
    const directory = tempDirs.make("heartbeat-detached-event-");
    vi.stubEnv("OPENCLAW_STATE_DIR", directory);
    const cfg: OpenClawConfig = {
      session: { store: path.join(directory, "sessions.json") },
      agents: { defaults: { workspace: directory } },
    };
    const parent = tryBeginGatewayRootWorkAdmission("test:live-detached-event-parent");
    const siblingRoot = tryBeginGatewayRootWorkAdmission("test:bound-event-sibling");
    if (!parent || !siblingRoot) {
      throw new Error("expected root admissions");
    }
    const receipt = await parent.run(async () =>
      enqueueSystemEventWithReceipt("Reminder: detached event", {
        sessionKey,
        contextKey: "cron:detached",
      }),
    );
    const detachedEvent = peekSystemEventEntries(sessionKey)[0];
    const firstAttempt = createDeferred();
    const terminal = createDeferred();
    const controller = new AbortController();
    const observed: Array<{ ids: Array<string | undefined>; prompt: string }> = [];
    let first = true;
    disposeHandler = setSessionEventWakeHandler(async (request) => {
      if (first) {
        first = false;
        firstAttempt.resolve();
        return { status: "skipped", reason: "cron-in-progress", retryAtMs: Date.now() + 100 };
      }
      const preflight = await resolveHeartbeatPreflight({
        cfg,
        agentId: "main",
        sessionKey,
        source: request.source,
        reason: request.reason,
      });
      const prepared = resolveHeartbeatRunPrompt({
        cfg,
        preflight,
        canRelayToUser: false,
        startedAt: Date.now(),
        scheduledTasks: [],
        useHeartbeatResponseTool: false,
      });
      observed.push({
        ids: preflight.pendingEventEntries.map((event) => event.id),
        prompt: prepared.prompt,
      });
      consumeSelectedSystemEventEntries(sessionKey, [
        ...prepared.genericEvents,
        ...prepared.inspectedSystemEventsToConsume,
      ]);
      if (preflight.pendingEventEntries.some((event) => event.id === detachedEvent?.id)) {
        terminal.resolve();
      }
      return ran;
    });
    const wake = {
      source: "cron" as const,
      intent: "immediate" as const,
      reason: "cron:detached",
      agentId: "main",
      sessionKey,
      coalesceMs: 0,
    };
    const pending = parent.run(() =>
      runWithSystemEventWakeReceipt(receipt, () =>
        requestSessionEventWakeAndWait(wake, {
          abortSignal: controller.signal,
          stopWaitingOnRetry: () => mode === "detach",
        }),
      ),
    );
    await firstAttempt.promise;
    if (mode === "abort") {
      controller.abort();
    }
    await pending;
    const siblingReceipt = await siblingRoot.run(async () =>
      enqueueSystemEventWithReceipt("Reminder: admitted sibling event", {
        sessionKey,
        contextKey: "cron:sibling",
      }),
    );
    const siblingEvent = peekSystemEventEntries(sessionKey).find(
      (event) => event.contextKey === "cron:sibling",
    );
    const suspension = tryBeginGatewaySuspendAdmission(() => {});
    expect(suspension?.drain()).toBe(true);
    const sibling = siblingRoot.run(() =>
      runWithSystemEventWakeReceipt(siblingReceipt, () =>
        requestSessionEventWakeAndWait({ ...wake, reason: "cron:sibling" }),
      ),
    );
    try {
      await expect(sibling).resolves.toEqual(ran);
      siblingRoot.release();
      expect(getActiveGatewayRootWorkCount()).toBe(1);
      expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
      expect(observed).toHaveLength(1);
      expect(observed[0]?.ids).toEqual([siblingEvent?.id]);
      expect(observed[0]?.prompt).toContain("admitted sibling event");
      expect(observed[0]?.prompt).not.toContain("detached event");
      expect(peekSystemEventEntries(sessionKey).map((event) => event.id)).toEqual([
        detachedEvent?.id,
      ]);
      suspension?.release();
      await withTestTimeout(
        terminal.promise,
        1500,
        "detached event was not consumed after independent admission reopened",
      );
      expect(observed[1]?.ids).toEqual([detachedEvent?.id]);
      expect(peekSystemEventEntries(sessionKey)).toEqual([]);
    } finally {
      parent.release();
      siblingRoot.release();
      suspension?.release();
      await Promise.allSettled([pending, sibling]);
    }
  },
);

it("resumes a parked independent wake after committed restart reset without another enqueue", async () => {
  const handler = vi.fn(async () => ran);
  disposeHandler = setSessionEventWakeHandler(handler);
  const pending = requestSessionEventWakeAndWait({ ...taskWake("restart-parked"), coalesceMs: 10 });
  markGatewayRestartDraining();
  // Let the actual queue timer fire and park behind the committed restart.
  await new Promise<void>((resolve) => {
    setTimeout(resolve, 30);
  });
  expect(handler).not.toHaveBeenCalled();
  resetGatewayWorkAdmission();
  await expect(
    withTestTimeout(pending, 1500, "restart reset did not rearm the parked wake"),
  ).resolves.toEqual(ran);
  expect(handler).toHaveBeenCalledOnce();
  expect(getActiveGatewayRootWorkCount()).toBe(0);
});

it("clears a finished borrowed selection when its nested timer reopens independent work", async () => {
  const directory = tempDirs.make("heartbeat-nested-admission-");
  vi.stubEnv("OPENCLAW_STATE_DIR", directory);
  const cfg: OpenClawConfig = {
    session: { store: path.join(directory, "sessions.json") },
    agents: { defaults: { workspace: directory } },
  };
  const parent = tryBeginGatewayRootWorkAdmission("test:nested-selection-parent");
  if (!parent) {
    throw new Error("expected parent admission");
  }
  const receipt = await parent.run(async () =>
    enqueueSystemEventWithReceipt("Reminder: parent event", {
      sessionKey,
      contextKey: "cron:parent",
    }),
  );
  const parentEvent = peekSystemEventEntries(sessionKey)[0];
  const suspension = tryBeginGatewaySuspendAdmission(() => {});
  expect(suspension?.drain()).toBe(true);
  const nestedFinished = createDeferred();
  const observed: Array<{ ids: Array<string | undefined>; prompt: string }> = [];
  let nestedEventId: string | undefined;
  let nestedTimer: ReturnType<typeof setTimeout> | undefined;
  const wake = {
    source: "cron" as const,
    intent: "immediate" as const,
    reason: "cron:parent",
    agentId: "main",
    sessionKey,
    coalesceMs: 0,
  };
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    const preflight = await resolveHeartbeatPreflight({
      cfg,
      agentId: "main",
      sessionKey,
      source: request.source,
      reason: request.reason,
    });
    const prepared = resolveHeartbeatRunPrompt({
      cfg,
      preflight,
      canRelayToUser: false,
      startedAt: Date.now(),
      scheduledTasks: [],
      useHeartbeatResponseTool: false,
    });
    observed.push({
      ids: preflight.pendingEventEntries.map((event) => event.id),
      prompt: prepared.prompt,
    });
    consumeSelectedSystemEventEntries(sessionKey, [
      ...prepared.genericEvents,
      ...prepared.inspectedSystemEventsToConsume,
    ]);
    if (request.reason === "cron:parent") {
      // This real timer inherits the borrowed selection, then runs after that
      // selection closes. Reopening here makes the queue timer inherit it too.
      nestedTimer = setTimeout(
        () =>
          runOutsideGatewayRootWorkAdmission(() => {
            nestedEventId = enqueueSystemEventEntry("Reminder: nested independent event", {
              sessionKey,
              contextKey: "cron:nested",
            })?.id;
            const nested = requestSessionEventWakeAndWait({ ...wake, reason: "cron:nested" });
            suspension?.release();
            void nested.then(() => nestedFinished.resolve(), nestedFinished.reject);
          }),
        20,
      );
    }
    return ran;
  });
  const pending = parent.run(() =>
    runWithSystemEventWakeReceipt(receipt, () => requestSessionEventWakeAndWait(wake)),
  );
  try {
    await expect(pending).resolves.toEqual(ran);
    parent.release();
    await withTestTimeout(nestedFinished.promise, 1500, "nested independent wake did not finish");
    expect(observed.map((entry) => entry.ids)).toEqual([[parentEvent?.id], [nestedEventId]]);
    expect(observed[1]?.prompt).toContain("nested independent event");
    expect(peekSystemEventEntries(sessionKey)).toEqual([]);
    expect(getActiveGatewayRootWorkCount()).toBe(0);
  } finally {
    clearTimeout(nestedTimer);
    parent.release();
    suspension?.release();
    await Promise.allSettled([pending]);
  }
});

it("does not bind an independent handler's emitted waiter to its timer creator's unclaimed receipt", async () => {
  const directory = tempDirs.make("heartbeat-independent-receipt-");
  vi.stubEnv("OPENCLAW_STATE_DIR", directory);
  const cfg: OpenClawConfig = {
    session: { store: path.join(directory, "sessions.json") },
    agents: { defaults: { workspace: directory } },
  };
  const parent = tryBeginGatewayRootWorkAdmission("test:unclaimed-receipt-parent");
  if (!parent) {
    throw new Error("expected parent admission");
  }
  const receipt = await parent.run(async () =>
    enqueueSystemEventWithReceipt("Reminder: unrelated parent event", {
      sessionKey,
      contextKey: "cron:unclaimed",
    }),
  );
  const parentEvent = peekSystemEventEntries(sessionKey)[0];
  const childCreated = createDeferred();
  const childState: {
    promise?: Promise<HeartbeatRunResult>;
    suspension: ReturnType<typeof tryBeginGatewaySuspendAdmission>;
  } = { suspension: null };
  const observed: Array<{ ids: Array<string | undefined>; prompt: string }> = [];
  const wake = {
    source: "cron" as const,
    intent: "immediate" as const,
    reason: "cron:first",
    agentId: "main",
    sessionKey,
    coalesceMs: 0,
  };
  disposeHandler = setSessionEventWakeHandler(async (request) => {
    if (request.reason === "cron:first") {
      childState.suspension = tryBeginGatewaySuspendAdmission(() => {});
      childState.suspension?.drain();
      childState.promise = runWithRetainedGatewayRootWork(() =>
        requestSessionEventWakeAndWait({ ...wake, reason: "cron:child" }),
      );
      childCreated.resolve();
      return ran;
    }
    const preflight = await resolveHeartbeatPreflight({
      cfg,
      agentId: "main",
      sessionKey,
      source: request.source,
      reason: request.reason,
    });
    const prepared = resolveHeartbeatRunPrompt({
      cfg,
      preflight,
      canRelayToUser: false,
      startedAt: Date.now(),
      scheduledTasks: [],
      useHeartbeatResponseTool: false,
    });
    observed.push({
      ids: preflight.pendingEventEntries.map((event) => event.id),
      prompt: prepared.prompt,
    });
    consumeSelectedSystemEventEntries(sessionKey, [
      ...prepared.genericEvents,
      ...prepared.inspectedSystemEventsToConsume,
    ]);
    return ran;
  });
  // Fire-and-forget creates no waiter binding for this unrelated receipt.
  runWithSystemEventWakeReceipt(receipt, () =>
    runOutsideGatewayRootWorkAdmission(() => requestSessionEventWake(wake)),
  );
  try {
    await withTestTimeout(childCreated.promise, 1500, "independent handler did not emit its child");
    await expect(childState.promise).resolves.toEqual(ran);
    expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
    expect(getActiveGatewayRootWorkCount()).toBe(1);
    expect(observed).toHaveLength(1);
    expect(observed[0]?.ids).toEqual([]);
    expect(observed[0]?.prompt).not.toContain("unrelated parent event");
    expect(peekSystemEventEntries(sessionKey).map((event) => event.id)).toEqual([parentEvent?.id]);
  } finally {
    parent.release();
    childState.suspension?.release();
    await Promise.allSettled(childState.promise ? [childState.promise] : []);
  }
});
