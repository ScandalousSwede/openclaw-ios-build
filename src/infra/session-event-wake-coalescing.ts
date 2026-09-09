// Pure wake contribution coalescing; the runtime retains all queue and lifecycle ownership.
import type { GatewayRootWorkAdmissionContinuationScope } from "../process/gateway-work-admission.js";
import type { HeartbeatRunResult, HeartbeatWakeRequest } from "./heartbeat-wake-contracts.js";

type SessionEventWakeResult = HeartbeatRunResult;
type SessionEventWakeRequest = HeartbeatWakeRequest;

export type SessionEventWakeWaitOptions = {
  abortSignal?: AbortSignal;
  /** Detach this waiter while the queue retains the wake at its retry deadline. */
  stopWaitingOnRetry?: (
    result: Extract<SessionEventWakeResult, { status: "skipped" }>,
    retryAtMs: number,
  ) => boolean;
};
export type Settlement = {
  admission?: GatewayRootWorkAdmissionContinuationScope;
  /** Original contribution, needed only while a borrowed waiter can detach. */
  wake?: WakePayload;
  active: boolean;
  settle: (result: SessionEventWakeResult) => void;
  stopWaitingOnRetry?: SessionEventWakeWaitOptions["stopWaitingOnRetry"];
};
export type WakePayload = SessionEventWakeRequest & {
  sequence: number;
  barrierSequence?: number;
  requestedAt: number;
  readyAt: number;
  notBefore: number;
  taskSequences: Map<string, number>;
};
export type PendingWake = WakePayload & {
  settlements: Settlement[];
  admissions: Settlement[];
  /** Only a selected dispatch can combine cohorts; retries return each to its owned slot. */
  parts?: PendingWake[];
};
function priority(wake: SessionEventWakeRequest): number {
  return wake.intent === "manual" || wake.intent === "immediate"
    ? 3
    : wake.source === "retry" || wake.reason === "retry"
      ? 0
      : wake.intent === "scheduled" || wake.source === "interval" || wake.reason === "interval"
        ? 1
        : 2;
}

export function merge(previous: PendingWake, next: PendingWake): PendingWake {
  const preferred =
    (previous.intent === "task") !== (next.intent === "task")
      ? previous.intent === "task"
        ? previous
        : next
      : priority(next) > priority(previous) ||
          (priority(next) === priority(previous) && next.requestedAt >= previous.requestedAt)
        ? next
        : previous;
  const other = preferred === previous ? next : previous;
  const tasks = new Map((previous.tasks ?? []).map((task) => [task.jobId, task]));
  const taskSequences = new Map(previous.taskSequences);
  for (const task of next.tasks ?? []) {
    const sequence = next.taskSequences.get(task.jobId) ?? next.sequence;
    if (sequence >= (taskSequences.get(task.jobId) ?? -Infinity)) {
      tasks.set(task.jobId, task);
      taskSequences.set(task.jobId, sequence);
    }
  }
  const bypass =
    (preferred.intent === "manual" || preferred.intent === "immediate") && !preferred.retainedWork;
  return {
    ...preferred,
    // A scheduled reason must not discard the event's guard-retry semantics.
    intent: preferred.intent === "scheduled" ? other.intent : preferred.intent,
    sequence: Math.min(previous.sequence, next.sequence),
    barrierSequence:
      previous.barrierSequence === undefined
        ? next.barrierSequence
        : Math.min(previous.barrierSequence, next.barrierSequence ?? Infinity),
    requestedAt:
      !bypass && (previous.notBefore || next.notBefore)
        ? Math.min(previous.requestedAt, next.requestedAt)
        : preferred.requestedAt,
    readyAt: Math.min(previous.readyAt, next.readyAt),
    notBefore: bypass ? 0 : Math.max(previous.notBefore, next.notBefore),
    heartbeat: preferred.heartbeat ?? other.heartbeat,
    scheduledEveryMs: preferred.scheduledEveryMs ?? other.scheduledEveryMs,
    tasks: tasks.size
      ? [...tasks.values()].toSorted((left, right) => left.jobId.localeCompare(right.jobId))
      : undefined,
    retainedWork: !bypass && (previous.retainedWork || next.retainedWork),
    settlements: [...previous.settlements, ...next.settlements].filter((entry) => entry.active),
    admissions: [...previous.admissions, ...next.admissions],
    taskSequences,
    parts: undefined,
  };
}

export function mergeForDispatch(previous: PendingWake, next: PendingWake): PendingWake {
  return {
    ...merge(previous, next),
    parts: [...(previous.parts ?? [previous]), ...(next.parts ?? [next])],
  };
}

export function contributionWake(wake: PendingWake, entry: Settlement): PendingWake {
  if (!entry.wake) {
    throw new Error("admitted heartbeat wake has no original contribution");
  }
  return {
    ...entry.wake,
    readyAt: wake.readyAt,
    notBefore: wake.notBefore,
    retainedWork: wake.retainedWork,
    settlements: entry.active ? [entry] : [],
    admissions: entry.active ? [entry] : [],
  };
}

export function withoutRetiredContributions(
  wake: PendingWake,
  retired: ReadonlySet<Settlement>,
): PendingWake | undefined {
  let remaining: PendingWake | undefined;
  for (const part of wake.parts ?? [wake]) {
    let retained = part;
    if (part.admissions.some((entry) => retired.has(entry))) {
      const entries = part.admissions.filter((entry) => !retired.has(entry));
      if (entries.length === 0) {
        continue;
      }
      retained = entries.map((entry) => contributionWake(part, entry)).reduce(merge);
    }
    // Rebuild within each original slot first: dispatch parts stay bounded by
    // the six existing cohorts, regardless of the number of merged waiters.
    remaining = remaining ? mergeForDispatch(remaining, retained) : retained;
  }
  return remaining;
}
