/** Detached task-ledger integration for cron runs. */
import { normalizeOptionalLowercaseString } from "@openclaw/normalization-core/string-coerce";
import {
  DEFAULT_AGENT_ID,
  normalizeAgentId,
  resolveAgentIdFromSessionKey,
} from "../../routing/session-key.js";
import {
  completeTaskRunByRunId,
  createRunningTaskRun,
  createQueuedTaskRun,
  failTaskRunByRunId,
} from "../../tasks/detached-task-runtime.js";
import { resolveCronAgentSessionKey } from "../isolated-agent/session-key.js";
import { createCronExecutionId } from "../run-id.js";
import type { CronJob, CronRunStatus } from "../types.js";
import { normalizeCronRunErrorText, timeoutErrorMessage } from "./execution-errors.js";
import type { CronServiceState } from "./state.js";
import { CRON_HEARTBEAT_TASK_KIND, CRON_TASK_RUNNING_PROGRESS_SUMMARY } from "./task-ledger.js";

/** Converts cron ids into bounded session-key path segments with a fallback for empty input. */
export function normalizeCronLaneSegment(value: string | undefined, fallback: string): string {
  const normalized = normalizeOptionalLowercaseString(value)
    ?.replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64);
  return normalized || fallback;
}

/** Builds the main-session child key used to isolate one cron run's task transcript. */
export function resolveMainSessionCronRunSessionKey(job: CronJob, startedAt: number): string {
  const explicitAgentId = job.agentId?.trim();
  const agentId = normalizeAgentId(explicitAgentId || resolveAgentIdFromSessionKey(job.sessionKey));
  const jobSegment = normalizeCronLaneSegment(job.id, "job");
  const runSegment = normalizeCronLaneSegment(String(Math.max(0, Math.floor(startedAt))), "run");
  return `agent:${agentId}:cron:${jobSegment}:run:${runSegment}`;
}

function resolveCronTaskTarget(params: {
  state: CronServiceState;
  job: CronJob;
  startedAt: number;
}): { agentId?: string; sessionKey?: string } {
  const agentId = params.job.agentId;
  if (params.job.sessionTarget === "main") {
    const sessionKey = resolveMainSessionCronRunSessionKey(params.job, params.startedAt);
    // Share gateway resolution with execution. Global keys need an explicit
    // agent identity too, otherwise agent-filtered task readers hide the run.
    return (
      params.state.deps.resolveMainSessionTarget?.({ agentId, sessionKey }) ?? {
        agentId,
        sessionKey,
      }
    );
  }
  const explicitSessionKey = params.job.sessionKey?.trim();
  if (explicitSessionKey) {
    // Explicit isolated bindings must open the transcript the run actually used.
    return { agentId, sessionKey: explicitSessionKey };
  }
  if (params.job.sessionTarget !== "isolated") {
    return { agentId };
  }
  return {
    agentId,
    sessionKey: resolveCronAgentSessionKey({
      sessionKey: `cron:${params.job.id}`,
      agentId: agentId ?? params.state.deps.defaultAgentId ?? DEFAULT_AGENT_ID,
    }),
  };
}

/** Creates a best-effort detached task ledger row for a cron run. */
export function tryCreateCronTaskRun(params: {
  state: CronServiceState;
  job: CronJob;
  startedAt: number;
}): string | undefined {
  const runId = createCronExecutionId(params.job.id, params.startedAt);
  try {
    const target = resolveCronTaskTarget(params);
    const taskParams = {
      runtime: "cron" as const,
      taskKind: params.job.sessionTarget === "main" ? CRON_HEARTBEAT_TASK_KIND : undefined,
      sourceId: params.job.id,
      ownerKey: "",
      scopeKind: "system" as const,
      childSessionKey: target.sessionKey,
      agentId: target.agentId,
      runId,
      label: params.job.name,
      task: params.job.name || params.job.id,
      deliveryStatus: "not_applicable" as const,
      notifyPolicy: "silent" as const,
    };
    // Main work may be accepted by cron long before the child heartbeat runs.
    const task =
      params.job.sessionTarget === "main"
        ? createQueuedTaskRun(taskParams)
        : createRunningTaskRun({
            ...taskParams,
            startedAt: params.startedAt,
            lastEventAt: params.startedAt,
            progressSummary: CRON_TASK_RUNNING_PROGRESS_SUMMARY,
          });
    if (!task) {
      params.state.deps.log.warn(
        { jobId: params.job.id },
        "cron: task ledger record was not persisted",
      );
      return undefined;
    }
    return runId;
  } catch (error) {
    params.state.deps.log.warn(
      { jobId: params.job.id, error },
      "cron: failed to create task ledger record",
    );
    return undefined;
  }
}

/** Completes or fails the detached task ledger row for a cron run when one exists. */
export function tryFinishCronTaskRun(
  state: CronServiceState,
  result: {
    taskRunId?: string;
    executionDeferred?: boolean;
    status: CronRunStatus;
    error?: unknown;
    endedAt: number;
    summary?: string;
  },
): void {
  if (!result.taskRunId || result.executionDeferred) {
    return;
  }
  try {
    if (result.status === "ok" || result.status === "skipped") {
      completeTaskRunByRunId({
        runId: result.taskRunId,
        runtime: "cron",
        endedAt: result.endedAt,
        lastEventAt: result.endedAt,
        terminalSummary: result.summary ?? undefined,
      });
      return;
    }
    failTaskRunByRunId({
      runId: result.taskRunId,
      runtime: "cron",
      status:
        normalizeCronRunErrorText(result.error) === timeoutErrorMessage() ? "timed_out" : "failed",
      endedAt: result.endedAt,
      lastEventAt: result.endedAt,
      error: result.status === "error" ? normalizeCronRunErrorText(result.error) : undefined,
      terminalSummary: result.summary ?? undefined,
    });
  } catch (error) {
    state.deps.log.warn(
      { runId: result.taskRunId, jobStatus: result.status, error },
      "cron: failed to update task ledger record",
    );
  }
}
