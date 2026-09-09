import type { CronJob } from "../types.js";
import { createCronServiceState as createCronServiceStateBase } from "./state.js";

export function createTimerTestState(
  params: Parameters<typeof createCronServiceStateBase>[0],
): ReturnType<typeof createCronServiceStateBase> {
  return createCronServiceStateBase({ defaultAgentId: "main", ...params });
}

export function createDueMainJob(params: { now: number; wakeMode: CronJob["wakeMode"] }): CronJob {
  return {
    id: "main-heartbeat-job",
    name: "main heartbeat job",
    enabled: true,
    createdAtMs: params.now - 60_000,
    updatedAtMs: params.now - 60_000,
    schedule: { kind: "every", everyMs: 60_000, anchorMs: params.now - 60_000 },
    sessionTarget: "main",
    wakeMode: params.wakeMode,
    payload: { kind: "systemEvent", text: "heartbeat seam tick" },
    sessionKey: "agent:main:main",
    state: { nextRunAtMs: params.now - 1 },
  };
}

export function createDueIsolatedAgentJob(params: { now: number }): CronJob {
  return {
    id: "isolated-agent-job",
    agentId: "finn",
    name: "isolated agent job",
    enabled: true,
    createdAtMs: params.now - 60_000,
    updatedAtMs: params.now - 60_000,
    schedule: { kind: "every", everyMs: 60_000, anchorMs: params.now - 60_000 },
    sessionTarget: "isolated",
    wakeMode: "now",
    payload: { kind: "agentTurn", message: "run isolated cron" },
    state: { nextRunAtMs: params.now - 1 },
  };
}
