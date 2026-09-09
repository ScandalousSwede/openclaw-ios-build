import { AsyncLocalStorage } from "node:async_hooks";
import { resolveTimerTimeoutMs } from "@openclaw/normalization-core/number-coercion";
import { normalizeOptionalString } from "@openclaw/normalization-core/string-coerce";
import { runWithoutOwnedSessionTranscriptWrites } from "../config/sessions/transcript-write-context.js";
import {
  captureGatewayRootWorkAdmissionContinuationScope,
  getGatewayRestartDrainSignal,
  isGatewayRestartDraining,
  isGatewayWorkAdmissionClosed,
  onGatewaySuspendAdmissionChange,
  tryBeginGatewayIndependentRootWorkAdmission,
  waitForGatewayRestartFenceSettlement,
} from "../process/gateway-work-admission.js";
import { parseAgentSessionKey } from "../routing/session-key.js";
import { resolveGlobalSingleton } from "../shared/global-singleton.js";
import { normalizeHeartbeatWakeReason } from "./heartbeat-reason.js";
import type { HeartbeatRunResult, HeartbeatWakeRequest } from "./heartbeat-wake-contracts.js";
import {
  contributionWake,
  merge,
  mergeForDispatch,
  withoutRetiredContributions,
  type PendingWake,
  type SessionEventWakeWaitOptions,
  type Settlement,
  type WakePayload,
} from "./session-event-wake-coalescing.js";
import {
  bindSystemEventWakeAdmission,
  runWithAdmittedSystemEventSelection,
} from "./system-event-ownership.js";

export type { SessionEventWakeWaitOptions } from "./session-event-wake-coalescing.js";

type SessionEventWakeResult = HeartbeatRunResult;
type SessionEventWakeRequest = HeartbeatWakeRequest;
type WakeHandler = (
  request: SessionEventWakeRequest,
  signal: AbortSignal,
) => Promise<SessionEventWakeResult>;
type WakeGroup = {
  task?: PendingWake;
  scheduled?: PendingWake;
  event?: PendingWake;
  admittedTask?: PendingWake;
  admittedScheduled?: PendingWake;
  admittedEvent?: PendingWake;
  blockedUntil: number;
};
type ActiveWake = { generation: number; controller: AbortController };
type RequestOptions = Omit<SessionEventWakeRequest, "retainedWork"> & { coalesceMs?: number };

const SLOTS = [
  "task",
  "scheduled",
  "event",
  "admittedTask",
  "admittedScheduled",
  "admittedEvent",
] as const;
const COALESCE_MS = 250;
const RETRY_MS = 1_000;
export const SESSION_EVENT_IDLE_RETRY_MS = 60_000;
const MAX_ACTIVE_TARGETS = 4;
const GLOBAL_TARGET = "::";
const RETRY_REASONS = new Set([
  "active-run",
  "requests-in-flight",
  "cron-in-progress",
  "preempted",
  "channel-not-ready",
]);
const GUARD_REASONS = new Set(["not-due", "min-spacing", "flood"]);

export function isRetryableSessionEventWakeReason(reason: string): boolean {
  return RETRY_REASONS.has(reason);
}

function canAdmit(wake: PendingWake): boolean {
  if (isGatewayRestartDraining()) {
    // One-way restart settles admitted waiters without invoking the handler.
    // A reversible signal fence parks all work until its owner decides.
    return getGatewayRestartDrainSignal().aborted && wake.admissions.length > 0;
  }
  return wake.admissions.length > 0 || !isGatewayWorkAdmissionClosed();
}

function immediateGlobalEvent(group: WakeGroup | undefined): PendingWake | undefined {
  return [group?.event, group?.admittedEvent]
    .filter((wake): wake is PendingWake =>
      Boolean(wake && wake.intent === "immediate" && canAdmit(wake)),
    )
    .toSorted(
      (left, right) => (left.barrierSequence ?? Infinity) - (right.barrierSequence ?? Infinity),
    )[0];
}

function targetKey(request: SessionEventWakeRequest): string {
  if (!request.sessionKey || (request.sessionKey === "global" && !request.agentId)) {
    return `${request.agentId ?? ""}::`;
  }
  // Namespaced sessions carry their owner; shared keys need the agent store too.
  return parseAgentSessionKey(request.sessionKey)
    ? `::${request.sessionKey}`
    : `${request.agentId ?? ""}::${request.sessionKey}`;
}

function shouldRetain(
  wake: PendingWake,
  result: Extract<SessionEventWakeResult, { status: "skipped" }>,
): boolean {
  return (
    RETRY_REASONS.has(result.reason) ||
    (GUARD_REASONS.has(result.reason) &&
      Boolean(
        wake.tasks?.length ||
        wake.intent === "task" ||
        wake.intent === "event" ||
        wake.intent === "immediate",
      ))
  );
}

function createSessionEventWakeRuntime() {
  const pending = new Map<string, WakeGroup>();
  const active = new Map<string, ActiveWake>();
  const abortSignals = new AsyncLocalStorage<AbortSignal>();
  let handler: WakeHandler | null = null;
  let generation = 0;
  let sequence = 0;
  let timer: NodeJS.Timeout | undefined;
  let timerDueAt = 0;
  let enabled = true;
  let waitingForRestartFence = false;

  function enqueue(wake: PendingWake, blockedUntil = 0): void {
    if (wake.parts) {
      for (const part of wake.parts) {
        enqueue(
          {
            ...part,
            readyAt: wake.readyAt,
            notBefore: wake.notBefore,
            retainedWork: wake.retainedWork,
          },
          blockedUntil,
        );
      }
      return;
    }
    if (wake.admissions.some((entry) => !entry.active)) {
      // A detached waiter leaves work queued, but cannot lend its old root to
      // another live contribution. Rebuild the bounded cohorts from the exact
      // normalized contributions before their payloads can coalesce again.
      for (const entry of wake.admissions) {
        if (!entry.active) {
          entry.admission?.release();
        }
        enqueue(contributionWake(wake, entry), blockedUntil);
      }
      return;
    }
    const key = targetKey(wake);
    const group = pending.get(key) ?? { blockedUntil: 0 };
    const slot =
      wake.admissions.length > 0
        ? wake.intent === "task"
          ? "admittedTask"
          : wake.intent === "scheduled"
            ? "admittedScheduled"
            : "admittedEvent"
        : wake.intent === "task"
          ? "task"
          : wake.intent === "scheduled"
            ? "scheduled"
            : "event";
    group[slot] = group[slot] ? merge(group[slot], wake) : wake;
    group.blockedUntil = Math.max(group.blockedUntil, blockedUntil);
    pending.set(key, group);
  }

  function partitionDetachedContributions(): void {
    for (const group of pending.values()) {
      for (const slot of SLOTS) {
        const wake = group[slot];
        if (wake?.admissions.some((entry) => !entry.active)) {
          delete group[slot];
          enqueue(wake, group.blockedUntil);
        }
      }
    }
  }

  function isReady(group: WakeGroup | undefined, now: number): boolean {
    return Boolean(
      group &&
      group.blockedUntil <= now &&
      SLOTS.some((slot) => {
        const wake = group[slot];
        return wake && canAdmit(wake) && Math.max(wake.readyAt, wake.notBefore) <= now;
      }),
    );
  }

  function afterBarrier(key: string, wake: PendingWake, global: WakeGroup | undefined): boolean {
    const barrier = immediateGlobalEvent(global)?.barrierSequence;
    return key !== GLOBAL_TARGET && barrier !== undefined && wake.sequence >= barrier;
  }

  function takeReady(): Array<{ key: string; wakes: PendingWake[] }> {
    partitionDetachedContributions();
    if (active.has(GLOBAL_TARGET)) {
      return [];
    }
    const now = performance.now();
    const global = pending.get(GLOBAL_TARGET);
    const globalReady = isReady(global, now);
    if (globalReady && active.size) {
      return [];
    }
    const event = immediateGlobalEvent(global);
    const flush =
      globalReady &&
      event?.intent === "immediate" &&
      Math.max(event.readyAt, event.notBefore) <= now;
    const candidates =
      globalReady && global
        ? flush
          ? [...pending].filter(([key]) => key !== GLOBAL_TARGET).concat([[GLOBAL_TARGET, global]])
          : [[GLOBAL_TARGET, global] as const]
        : pending;
    const ready: Array<{ key: string; wakes: PendingWake[] }> = [];
    for (const [key, group] of candidates) {
      if (ready.length + active.size >= MAX_ACTIVE_TARGETS) {
        break;
      }
      if (
        active.has(key) ||
        group.blockedUntil > now ||
        (key === GLOBAL_TARGET && (active.size || ready.length))
      ) {
        continue;
      }
      const picked: Partial<Record<(typeof SLOTS)[number], PendingWake>> = {};
      for (const slot of SLOTS) {
        const wake = group[slot];
        if (
          wake &&
          canAdmit(wake) &&
          !afterBarrier(key, wake, global) &&
          wake.notBefore <= now &&
          (flush || wake.readyAt <= now)
        ) {
          picked[slot] = wake;
          delete group[slot];
        }
      }
      if (!SLOTS.some((slot) => group[slot])) {
        pending.delete(key);
      }
      // Cohorts remain separate while parked. Once independent admission is
      // available, the same task/monitor/event coalescing rules apply to both.
      const combine = (left?: PendingWake, right?: PendingWake) =>
        left && right ? mergeForDispatch(left, right) : (left ?? right);
      const taskWake = combine(picked.task, picked.admittedTask);
      const scheduledWake = combine(picked.scheduled, picked.admittedScheduled);
      const eventWake = combine(picked.event, picked.admittedEvent);
      let wakes: PendingWake[];
      if (taskWake) {
        const task = scheduledWake ? mergeForDispatch(scheduledWake, taskWake) : taskWake;
        wakes = eventWake
          ? [task, eventWake].toSorted(
              (left, right) =>
                Number(Boolean(right.retainedWork)) - Number(Boolean(left.retainedWork)) ||
                left.requestedAt - right.requestedAt,
            )
          : [task];
      } else if (eventWake) {
        wakes = [scheduledWake ? mergeForDispatch(scheduledWake, eventWake) : eventWake];
      } else {
        wakes = scheduledWake ? [scheduledWake] : [];
      }
      if (wakes.length) {
        ready.push({ key, wakes });
      }
    }
    return ready;
  }

  function settle(wake: PendingWake, result: SessionEventWakeResult): void {
    for (const entry of wake.settlements) {
      entry.settle(result);
    }
    // Detaching/cancelling a waiter does not cancel the queued wake. Borrowed
    // scopes retire with that wake; they never extend the origin root lifetime.
    for (const entry of wake.admissions) {
      entry.admission?.release();
    }
  }

  function retry(
    wake: PendingWake,
    result?: Extract<SessionEventWakeResult, { status: "skipped" }>,
  ): void {
    const idleGrace =
      result &&
      (result.reason === "preempted" ||
        result.reason === "channel-not-ready" ||
        ((result.reason === "requests-in-flight" || result.reason === "active-run") &&
          (wake.intent === "scheduled" || wake.intent === "task")));
    const guard = idleGrace || (result && GUARD_REASONS.has(result.reason));
    const delay =
      result?.retryAtMs !== undefined
        ? Math.max(0, result.retryAtMs - Date.now())
        : idleGrace
          ? SESSION_EVENT_IDLE_RETRY_MS
          : RETRY_MS;
    const deadline = performance.now() + delay;
    if (result) {
      const retryAtMs = Date.now() + delay;
      for (const entry of wake.settlements) {
        if (entry.active && entry.stopWaitingOnRetry?.(result, retryAtMs)) {
          entry.settle(result);
        }
      }
    }
    enqueue(
      {
        ...wake,
        readyAt: performance.now(),
        notBefore: guard ? deadline : 0,
        retainedWork: guard ? true : wake.retainedWork,
      },
      guard ? 0 : deadline,
    );
  }

  function handOff(wakes: PendingWake[], start: number): void {
    for (const wake of wakes.slice(start)) {
      enqueue(wake);
    }
  }

  async function dispatch(
    key: string,
    wakes: PendingWake[],
    owner: ActiveWake,
    run: WakeHandler,
  ): Promise<void> {
    const signal = owner.controller.signal;
    try {
      for (const [index, selectedWake] of wakes.entries()) {
        let wake = selectedWake;
        // Busy backoff also owns wakes selected before the current attempt began.
        const blockedUntil = pending.get(key)?.blockedUntil ?? 0;
        if (
          owner.generation !== generation ||
          blockedUntil > performance.now() ||
          wake.admissions.some((entry) => !entry.active)
        ) {
          handOff(wakes, index);
          return;
        }
        const independent = tryBeginGatewayIndependentRootWorkAdmission("heartbeat:wake");
        if (
          !independent &&
          (!canAdmit(wake) || wake.parts?.some((part) => part.admissions.length === 0))
        ) {
          // A fence can close after selection. Return each cohort before waiting
          // so independent work cannot monopolize this target's active slot.
          handOff(wakes, index);
          return;
        }
        if (!independent && getGatewayRestartDrainSignal().aborted) {
          settle(wake, {
            status: "failed",
            reason: "heartbeat wake interrupted by gateway restart",
          });
          continue;
        }
        let result: SessionEventWakeResult | undefined;
        let onAbort: (() => void) | undefined;
        try {
          const invoke = async (): Promise<SessionEventWakeResult> => {
            signal.throwIfAborted();
            if (isGatewayRestartDraining()) {
              return getGatewayRestartDrainSignal().aborted
                ? { status: "failed", reason: "heartbeat wake interrupted by gateway restart" }
                : { status: "skipped", reason: "preempted", retryAtMs: Date.now() };
            }
            // Subscribe before calling the handler: it can synchronously replace its owner.
            const aborted = new Promise<never>((_resolve, reject) => {
              onAbort = () =>
                reject(
                  signal.reason instanceof Error
                    ? signal.reason
                    : new Error("Heartbeat handler was replaced"),
                );
              signal.addEventListener("abort", onAbort, { once: true });
            });
            const request: SessionEventWakeRequest = {
              source: wake.source,
              intent: wake.intent,
              reason: wake.reason,
              ...(wake.agentId ? { agentId: wake.agentId } : {}),
              ...(wake.sessionKey ? { sessionKey: wake.sessionKey } : {}),
              ...(wake.heartbeat ? { heartbeat: wake.heartbeat } : {}),
              ...(wake.scheduledEveryMs !== undefined
                ? { scheduledEveryMs: wake.scheduledEveryMs }
                : {}),
              ...(wake.tasks ? { tasks: wake.tasks } : {}),
              ...(wake.retainedWork ? { retainedWork: true } : {}),
            };
            // A synchronous handler throw must not leave the abort promise unobserved.
            const running = abortSignals.run(signal, async () => run(request, signal));
            return Promise.race([running, aborted]);
          };
          const retired = new Set<Settlement>();
          const runOwned = (
            admissionIndex: number,
          ): Promise<SessionEventWakeResult | undefined> => {
            const entry = wake.admissions[admissionIndex];
            const scope = entry?.admission;
            if (entry && scope) {
              let entered = false;
              return scope
                .run(() => {
                  entered = true;
                  return runOwned(admissionIndex + 1);
                })
                .catch((error: unknown) => {
                  if (entered) {
                    throw error;
                  }
                  // Only this original contribution lost admission. A same-slot
                  // sibling still owns its result and must reach the handler.
                  retired.add(entry);
                  entry.settle({
                    status: "failed",
                    reason: "heartbeat wake admission is no longer active",
                  });
                  scope.release();
                  return runOwned(admissionIndex + 1);
                });
            }
            if (retired.size > 0) {
              const remaining = withoutRetiredContributions(wake, retired);
              if (!remaining) {
                return Promise.resolve(undefined);
              }
              wake = remaining;
            }
            return independent
              ? independent.run(() => runWithAdmittedSystemEventSelection(undefined, invoke))
              : runWithAdmittedSystemEventSelection(wake.admissions, invoke);
          };
          result = await runOwned(0);
        } catch {
          if (owner.generation === generation) {
            retry(wake);
          } else {
            enqueue(wake);
          }
          continue;
        } finally {
          independent?.release();
          if (onAbort) {
            signal.removeEventListener("abort", onAbort);
          }
        }
        if (!result) {
          continue;
        }
        if (result.status === "skipped" && shouldRetain(wake, result)) {
          if (owner.generation === generation) {
            retry(wake, result);
          } else {
            enqueue(wake);
          }
        } else {
          settle(wake, result);
        }
      }
    } finally {
      if (active.get(key) === owner) {
        active.delete(key);
      }
      schedulePending();
    }
  }

  function scheduleAt(dueAt: number): void {
    if (!handler || (timer && timerDueAt <= dueAt)) {
      return;
    }
    clearTimeout(timer);
    timerDueAt = dueAt;
    timer = setTimeout(
      () => {
        timer = undefined;
        const run = handler;
        if (!run) {
          return;
        }
        // Register the whole batch first so replacement retires unstarted work too.
        const ready = takeReady().map(({ key, wakes }) => {
          const owner = { generation, controller: new AbortController() };
          active.set(key, owner);
          return { key, wakes, owner };
        });
        for (const { key, wakes, owner } of ready) {
          void dispatch(key, wakes, owner, run);
        }
        schedulePending();
      },
      resolveTimerTimeoutMs(Math.max(0, dueAt - performance.now()), COALESCE_MS, 0),
    );
    timer.unref?.();
  }

  function schedulePending(readyDelayMs = 0): void {
    partitionDetachedContributions();
    if (
      isGatewayRestartDraining() &&
      !getGatewayRestartDrainSignal().aborted &&
      !waitingForRestartFence
    ) {
      waitingForRestartFence = true;
      void waitForGatewayRestartFenceSettlement().finally(() => {
        waitingForRestartFence = false;
        schedulePending(COALESCE_MS);
      });
    }
    if (active.size >= MAX_ACTIVE_TARGETS || active.has(GLOBAL_TARGET)) {
      return;
    }
    const now = performance.now();
    const global = pending.get(GLOBAL_TARGET);
    if (active.size && isReady(global, now)) {
      return;
    }
    let earliest = Infinity;
    for (const [key, group] of pending) {
      if (active.has(key)) {
        continue;
      }
      for (const slot of SLOTS) {
        const wake = group[slot];
        if (wake && canAdmit(wake) && !afterBarrier(key, wake, global)) {
          earliest = Math.min(earliest, Math.max(wake.readyAt, wake.notBefore, group.blockedUntil));
        }
      }
    }
    if (Number.isFinite(earliest)) {
      scheduleAt(earliest <= now ? now + readyDelayMs : earliest);
    }
  }

  function setSessionEventWakeHandler(next: WakeHandler | null): () => void {
    const previousGeneration = generation;
    generation += 1;
    const ownedGeneration = generation;
    handler = next;
    clearTimeout(timer);
    timer = undefined;
    if (next) {
      for (const group of pending.values()) {
        group.blockedUntil = 0;
        for (const slot of SLOTS) {
          const wake = group[slot];
          if (wake) {
            wake.notBefore = 0;
            wake.retainedWork = false;
          }
        }
      }
    }
    // Abort listeners can register another handler; retire only the replaced generation.
    for (const owner of active.values()) {
      if (owner.generation === previousGeneration) {
        owner.controller.abort();
      }
    }
    schedulePending(COALESCE_MS);
    return () => {
      if (generation === ownedGeneration) {
        setSessionEventWakeHandler(null);
      }
    };
  }

  function enqueueRequest(options: RequestOptions, settlement?: Settlement): void {
    const now = performance.now();
    const { coalesceMs, ...wake } = options;
    const normalized = {
      ...wake,
      agentId: normalizeOptionalString(wake.agentId),
      sessionKey: normalizeOptionalString(wake.sessionKey),
      reason: normalizeHeartbeatWakeReason(wake.reason),
    };
    const nextSequence = ++sequence;
    runWithoutOwnedSessionTranscriptWrites(() => {
      const payload: WakePayload = {
        ...normalized,
        sequence: nextSequence,
        barrierSequence:
          targetKey(normalized) === GLOBAL_TARGET && wake.intent === "immediate"
            ? nextSequence
            : undefined,
        requestedAt: now,
        readyAt: now + resolveTimerTimeoutMs(coalesceMs, COALESCE_MS, 0),
        notBefore: 0,
        taskSequences: new Map((wake.tasks ?? []).map((task) => [task.jobId, nextSequence])),
      };
      if (settlement?.admission) {
        settlement.wake = payload;
      }
      const pendingWake: PendingWake = {
        ...payload,
        settlements: settlement ? [settlement] : [],
        admissions: settlement?.admission ? [settlement] : [],
      };
      enqueue(pendingWake);
      schedulePending();
    });
  }

  function requestSessionEventWake(options: RequestOptions): void {
    enqueueRequest(options);
  }
  function requestSessionEventWakeAndWait(
    options: RequestOptions,
    lifecycle?: SessionEventWakeWaitOptions,
  ): Promise<SessionEventWakeResult> {
    return new Promise((resolve) => {
      const signal = lifecycle?.abortSignal;
      const settlement: Settlement = {
        admission: captureGatewayRootWorkAdmissionContinuationScope() ?? undefined,
        active: true,
        stopWaitingOnRetry: lifecycle?.stopWaitingOnRetry,
        settle: (result) => {
          if (settlement.active) {
            settlement.active = false;
            signal?.removeEventListener("abort", onAbort);
            resolve(result);
          }
        },
      };
      bindSystemEventWakeAdmission(settlement);
      const onAbort = () => {
        settlement.settle({ status: "failed", reason: "heartbeat wake cancelled" });
        schedulePending();
      };
      if (signal?.aborted) {
        onAbort();
        settlement.admission?.release();
      } else {
        signal?.addEventListener("abort", onAbort, { once: true });
        enqueueRequest(options, settlement);
      }
    });
  }

  // Parked independent work owns no active target and resumes from this same queue.
  onGatewaySuspendAdmissionChange(() => schedulePending());

  return {
    setSessionEventWakeHandler,
    requestSessionEventWake,
    requestSessionEventWakeAndWait,
    getSessionEventWakeAbortSignal: () => abortSignals.getStore(),
    areSessionEventWakesEnabled: () => enabled,
    setSessionEventWakesEnabled: (value: boolean) => {
      enabled = value;
    },
  };
}

// Gateway and source-transformed plugins share the entire owner, including timer and disposal.
export const {
  setSessionEventWakeHandler,
  requestSessionEventWake,
  requestSessionEventWakeAndWait,
  getSessionEventWakeAbortSignal,
  areSessionEventWakesEnabled,
  setSessionEventWakesEnabled,
} = resolveGlobalSingleton(Symbol.for("openclaw.sessionEventWake"), createSessionEventWakeRuntime);
