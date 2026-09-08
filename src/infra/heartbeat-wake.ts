// Tracks heartbeat wake requests, busy skips, and retry timing.
import { normalizeOptionalString } from "@openclaw/normalization-core/string-coerce";
import { createSubsystemLogger } from "../logging/subsystem.js";
import { resolveTimerTimeoutMs } from "../shared/number-coercion.js";
import { normalizeHeartbeatWakeReason } from "./heartbeat-reason.js";

export type HeartbeatRunResult =
  | { status: "ran"; durationMs: number }
  | { status: "skipped"; reason: string; retryAfterMs?: number }
  | { status: "failed"; reason: string };

export const HEARTBEAT_SKIP_REQUESTS_IN_FLIGHT = "requests-in-flight";
export const HEARTBEAT_SKIP_CRON_IN_PROGRESS = "cron-in-progress";
export const HEARTBEAT_SKIP_LANES_BUSY = "lanes-busy";
export type RetryableHeartbeatBusySkipReason =
  | typeof HEARTBEAT_SKIP_REQUESTS_IN_FLIGHT
  | typeof HEARTBEAT_SKIP_CRON_IN_PROGRESS
  | typeof HEARTBEAT_SKIP_LANES_BUSY;

const RETRYABLE_BUSY_SKIP_REASONS = new Set([
  HEARTBEAT_SKIP_REQUESTS_IN_FLIGHT,
  HEARTBEAT_SKIP_CRON_IN_PROGRESS,
  HEARTBEAT_SKIP_LANES_BUSY,
]);

export function isRetryableHeartbeatBusySkipReason(reason: string): boolean {
  return RETRYABLE_BUSY_SKIP_REASONS.has(reason);
}

export type HeartbeatWakeIntent = "scheduled" | "event" | "immediate" | "manual";

export type HeartbeatWakeSource =
  | "interval"
  | "manual"
  | "exec-event"
  | "notifications-event"
  | "cron"
  | "hook"
  | "background-task"
  | "background-task-blocked"
  | "acp-spawn"
  | "cli-watchdog"
  | "restart-sentinel"
  | "retry"
  | "other";

export type HeartbeatWakeOverride = {
  target?: string;
  to?: string | undefined;
  accountId?: string | undefined;
};

type HeartbeatWakeCompletion = {
  executionId: string;
  onResult: (result: HeartbeatRunResult) => void;
};

export type HeartbeatWakeRequest = {
  source: HeartbeatWakeSource;
  intent: HeartbeatWakeIntent;
  reason?: string;
  agentId?: string;
  sessionKey?: string;
  heartbeat?: HeartbeatWakeOverride;
  /** Local completion bookkeeping, never part of the model request. */
  completion?: HeartbeatWakeCompletion;
};

export type HeartbeatWakeHandler = (
  opts: Omit<HeartbeatWakeRequest, "completion">,
) => Promise<HeartbeatRunResult>;

let heartbeatsEnabled = true;

export function setHeartbeatsEnabled(enabled: boolean) {
  heartbeatsEnabled = enabled;
}

export function areHeartbeatsEnabled(): boolean {
  return heartbeatsEnabled;
}

type WakeTimerKind = "normal" | "retry";
type PendingWakeReason = {
  source: HeartbeatWakeSource;
  intent: HeartbeatWakeIntent;
  reason: string;
  priority: number;
  requestedAt: number;
  notBefore: number;
  completions: Set<HeartbeatWakeCompletion>;
  agentId?: string;
  sessionKey?: string;
  heartbeat?: HeartbeatWakeOverride;
};

let handler: HeartbeatWakeHandler | null = null;
let handlerGeneration = 0;
const pendingWakes = new Map<string, PendingWakeReason>();
const inFlightWakes = new Set<PendingWakeReason>();
let scheduled = false;
let running = false;
let timer: NodeJS.Timeout | null = null;
let timerDueAt: number | null = null;
let timerKind: WakeTimerKind | null = null;

const DEFAULT_COALESCE_MS = 250;
const DEFAULT_RETRY_MS = 1_000;
const REASON_PRIORITY = {
  RETRY: 0,
  INTERVAL: 1,
  DEFAULT: 2,
  ACTION: 3,
} as const;

function resolveWakePriority(params: {
  source: HeartbeatWakeSource;
  intent: HeartbeatWakeIntent;
  reason: string;
}): number {
  if (params.intent === "manual" || params.intent === "immediate") {
    return REASON_PRIORITY.ACTION;
  }
  if (params.source === "retry" || params.reason === "retry") {
    return REASON_PRIORITY.RETRY;
  }
  if (
    params.intent === "scheduled" ||
    params.source === "interval" ||
    params.reason === "interval"
  ) {
    return REASON_PRIORITY.INTERVAL;
  }
  return REASON_PRIORITY.DEFAULT;
}

function normalizeWakeReason(reason?: string): string {
  return normalizeHeartbeatWakeReason(reason);
}

function normalizeWakeTarget(value?: string): string | undefined {
  const trimmed = normalizeOptionalString(value) ?? "";
  return trimmed || undefined;
}

function getWakeTargetKey(params: { agentId?: string; sessionKey?: string }) {
  const agentId = normalizeWakeTarget(params.agentId);
  const sessionKey = normalizeWakeTarget(params.sessionKey);
  return `${agentId ?? ""}::${sessionKey ?? ""}`;
}

function queuePendingWakeReason(params: {
  source: HeartbeatWakeSource;
  intent: HeartbeatWakeIntent;
  reason?: string;
  requestedAt?: number;
  notBefore?: number;
  completions?: Iterable<HeartbeatWakeCompletion>;
  agentId?: string;
  sessionKey?: string;
  heartbeat?: HeartbeatWakeOverride;
}) {
  const requestedAt = params.requestedAt ?? Date.now();
  const normalizedReason = normalizeWakeReason(params.reason);
  const normalizedAgentId = normalizeWakeTarget(params.agentId);
  const normalizedSessionKey = normalizeWakeTarget(params.sessionKey);
  const wakeTargetKey = getWakeTargetKey({
    agentId: normalizedAgentId,
    sessionKey: normalizedSessionKey,
  });
  const next: PendingWakeReason = {
    source: params.source,
    intent: params.intent,
    reason: normalizedReason,
    priority: resolveWakePriority({
      source: params.source,
      intent: params.intent,
      reason: normalizedReason,
    }),
    requestedAt,
    notBefore: params.notBefore ?? Date.now(),
    completions: new Set(params.completions),
    agentId: normalizedAgentId,
    sessionKey: normalizedSessionKey,
    heartbeat: params.heartbeat,
  };
  const previous = pendingWakes.get(wakeTargetKey);
  if (!previous) {
    pendingWakes.set(wakeTargetKey, next);
    return;
  }
  // Priority selects the wake, not the owners awaiting that session outcome.
  for (const observer of next.completions) {
    previous.completions.add(observer);
  }
  next.completions = previous.completions;
  const merged =
    (next.heartbeat ?? previous.heartbeat)
      ? { ...next, heartbeat: next.heartbeat ?? previous.heartbeat }
      : next;
  if (next.priority > previous.priority) {
    pendingWakes.set(wakeTargetKey, merged);
    return;
  }
  if (next.priority === previous.priority && next.requestedAt >= previous.requestedAt) {
    pendingWakes.set(wakeTargetKey, merged);
  }
}

function schedule(coalesceMs: number, kind: WakeTimerKind = "normal") {
  const delay = resolveTimerTimeoutMs(coalesceMs, DEFAULT_COALESCE_MS, 0);
  const dueAt = Date.now() + delay;
  if (timer) {
    // Keep retry cooldown as a hard minimum delay. This prevents the
    // finally-path reschedule (often delay=0) from collapsing backoff.
    if (timerKind === "retry") {
      return;
    }
    // If existing timer fires sooner or at the same time, keep it.
    if (typeof timerDueAt === "number" && timerDueAt <= dueAt) {
      return;
    }
    // New request needs to fire sooner — preempt the existing timer.
    clearTimeout(timer);
    timer = null;
    timerDueAt = null;
    timerKind = null;
  }
  timerDueAt = dueAt;
  timerKind = kind;
  timer = setTimeout(() => {
    void (async () => {
      timer = null;
      timerDueAt = null;
      timerKind = null;
      scheduled = false;
      const active = handler;
      if (!active) {
        return;
      }
      if (running) {
        scheduled = true;
        schedule(delay, kind);
        return;
      }

      // A deferred session keeps its own due time. It must not delay ready
      // work for other sessions or agents behind one global cooldown timer.
      const pendingBatch: PendingWakeReason[] = [];
      for (const [key, pendingWake] of pendingWakes) {
        if (pendingWake.notBefore <= Date.now()) {
          pendingBatch.push(pendingWake);
          pendingWakes.delete(key);
        }
      }
      for (const wake of pendingBatch) {
        inFlightWakes.add(wake);
      }
      running = true;
      let processedCount = 0;
      try {
        for (const pendingWake of pendingBatch) {
          const wakeOpts = {
            source: pendingWake.source,
            intent: pendingWake.intent,
            reason: pendingWake.reason ?? undefined,
            ...(pendingWake.agentId ? { agentId: pendingWake.agentId } : {}),
            ...(pendingWake.sessionKey ? { sessionKey: pendingWake.sessionKey } : {}),
            ...(pendingWake.heartbeat ? { heartbeat: pendingWake.heartbeat } : {}),
          };
          const res = await active(wakeOpts);
          const cooldownDelay =
            res.status === "skipped" &&
            Number.isFinite(res.retryAfterMs) &&
            (res.retryAfterMs ?? 0) > 0
              ? resolveTimerTimeoutMs(res.retryAfterMs, DEFAULT_RETRY_MS, 1)
              : undefined;
          const busy = res.status === "skipped" && isRetryableHeartbeatBusySkipReason(res.reason);
          if (busy || cooldownDelay !== undefined) {
            // Preserve arrival order so a retry cannot replace newer pending
            // work for the same target. Busy retries retain their existing floor.
            queuePendingWakeReason({
              source: pendingWake.source,
              intent: pendingWake.intent,
              reason: pendingWake.reason ?? "retry",
              agentId: pendingWake.agentId,
              sessionKey: pendingWake.sessionKey,
              heartbeat: pendingWake.heartbeat,
              completions: pendingWake.completions,
              requestedAt: pendingWake.requestedAt,
              notBefore: Date.now() + (cooldownDelay ?? DEFAULT_RETRY_MS),
            });
            if (busy) {
              schedule(DEFAULT_RETRY_MS, "retry");
            }
          } else {
            for (const completion of pendingWake.completions) {
              try {
                completion.onResult(res);
              } catch {
                // A failed observer must never replay already executed work.
                createSubsystemLogger("heartbeat").error("wake result observer failed");
              }
            }
          }
          processedCount += 1;
        }
      } catch {
        // Error is already logged by the heartbeat runner; schedule a retry.
        for (const pendingWake of pendingBatch.slice(processedCount)) {
          queuePendingWakeReason({
            source: pendingWake.source,
            intent: pendingWake.intent,
            reason: pendingWake.reason ?? "retry",
            agentId: pendingWake.agentId,
            sessionKey: pendingWake.sessionKey,
            heartbeat: pendingWake.heartbeat,
            completions: pendingWake.completions,
            requestedAt: pendingWake.requestedAt,
          });
        }
        schedule(DEFAULT_RETRY_MS, "retry");
      } finally {
        for (const wake of pendingBatch) {
          inFlightWakes.delete(wake);
        }
        running = false;
        if (pendingWakes.size > 0 || scheduled) {
          const nextDelay =
            pendingWakes.size > 0
              ? Math.max(
                  0,
                  Math.min(...Array.from(pendingWakes.values(), (wake) => wake.notBefore)) -
                    Date.now(),
                )
              : delay;
          schedule(nextDelay, "normal");
        }
      }
    })();
  }, delay);
  timer.unref?.();
}

/**
 * Register (or clear) the heartbeat wake handler.
 * Returns a disposer function that clears this specific registration.
 * Stale disposers (from previous registrations) are no-ops, preventing
 * a race where an old runner's cleanup clears a newer runner's handler.
 */
export function setHeartbeatWakeHandler(next: HeartbeatWakeHandler | null): () => void {
  handlerGeneration += 1;
  const generation = handlerGeneration;
  handler = next;
  if (next) {
    // New lifecycle starting (e.g. after SIGUSR1 in-process restart).
    // Clear any timer metadata from the previous lifecycle so stale retry
    // cooldowns do not delay a fresh handler.
    if (timer) {
      clearTimeout(timer);
    }
    timer = null;
    timerDueAt = null;
    timerKind = null;
    // Reset module-level execution state that may be stale from interrupted
    // runs in the previous lifecycle. Without this, `running === true` from
    // an interrupted heartbeat blocks all future schedule() attempts, and
    // `scheduled === true` can cause spurious immediate re-runs.
    running = false;
    scheduled = false;
    // A replaced handler no longer owns its abandoned execution bookkeeping.
    // Do not replay it: the old provider attempt may already have executed.
    inFlightWakes.clear();
  }
  if (handler && pendingWakes.size > 0) {
    schedule(DEFAULT_COALESCE_MS, "normal");
  }
  return () => {
    if (handlerGeneration !== generation) {
      return;
    }
    if (handler !== next) {
      return;
    }
    handlerGeneration += 1;
    handler = null;
  };
}

export function requestHeartbeat(opts: HeartbeatWakeRequest & { coalesceMs?: number }) {
  queuePendingWakeReason({
    source: opts.source,
    intent: opts.intent,
    reason: opts.reason,
    agentId: opts.agentId,
    sessionKey: opts.sessionKey,
    heartbeat: opts.heartbeat,
    completions: opts.completion ? [opts.completion] : undefined,
  });
  schedule(opts.coalesceMs ?? DEFAULT_COALESCE_MS, "normal");
}

export function hasHeartbeatWakeHandler() {
  return handler !== null;
}

/** Execution custody survives routing aliases and coalescing into a shared session. */
export function hasHeartbeatWakeForExecution(executionId: string | undefined): boolean {
  if (!executionId) {
    return false;
  }
  return [...pendingWakes.values(), ...inFlightWakes].some((wake) =>
    [...wake.completions].some((completion) => completion.executionId === executionId),
  );
}

export function hasPendingHeartbeatWake() {
  return pendingWakes.size > 0 || Boolean(timer) || scheduled;
}

export function resetHeartbeatWakeStateForTests() {
  if (timer) {
    clearTimeout(timer);
  }
  timer = null;
  timerDueAt = null;
  timerKind = null;
  pendingWakes.clear();
  inFlightWakes.clear();
  scheduled = false;
  running = false;
  handlerGeneration += 1;
  handler = null;
}
