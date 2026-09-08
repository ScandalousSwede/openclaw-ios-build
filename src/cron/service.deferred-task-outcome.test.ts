// Exercises the real cron -> wake queue -> SQLite task lifecycle with synthetic state.
import { describe, expect, it, vi } from "vitest";
import {
  requestHeartbeat,
  resetHeartbeatWakeStateForTests,
  setHeartbeatWakeHandler,
  type HeartbeatRunResult,
} from "../infra/heartbeat-wake.js";
import {
  enqueueSystemEventEntry,
  peekSystemEventEntries,
  consumeSelectedSystemEventEntries,
  resetSystemEventsForTest,
} from "../infra/system-events.js";
import { resetDetachedTaskLifecycleRuntimeForTests } from "../tasks/detached-task-runtime.js";
import { resetTaskFlowRegistryForTests } from "../tasks/task-flow-registry.js";
import { listTaskRecords } from "../tasks/task-registry.js";
import { findTaskByRunId, resetTaskRegistryForTests } from "../tasks/task-registry.js";
import {
  configureTaskRegistryMaintenance,
  reconcileInspectableTasks,
  getInspectableActiveTaskRestartBlockers,
  resetTaskRegistryMaintenanceRuntimeForTests,
} from "../tasks/task-registry.maintenance.js";
import { withStateDirEnv } from "../test-helpers/state-dir-env.js";
import { createCronExecutionId } from "./run-id.js";
import { CronService } from "./service.js";
import {
  createCronStoreHarness,
  createNoopLogger,
  installCronTestHooks,
} from "./service.test-harness.js";
import { saveCronStore } from "./store.js";
import type { CronJob } from "./types.js";

const log = createNoopLogger();
installCronTestHooks({ logger: log });
const { makeStorePath } = createCronStoreHarness({ prefix: "openclaw-cron-deferred-task-" });

describe("deferred main cron task outcome", () => {
  it("binds later startup catch-up work to its execution time rather than reservation time", async () => {
    await withStateDirEnv("openclaw-startup-task-proof-", async () => {
      resetDetachedTaskLifecycleRuntimeForTests();
      resetTaskRegistryForTests({ persist: false });
      resetTaskFlowRegistryForTests({ persist: false });
      resetHeartbeatWakeStateForTests();
      const { storePath } = await makeStorePath();
      const reservedAt = Date.now();
      const jobs: CronJob[] = ["first", "second"].map((id) => ({
        id,
        name: id,
        enabled: true,
        createdAtMs: reservedAt - 60000,
        updatedAtMs: reservedAt - 60000,
        schedule: { kind: "every", everyMs: 86400000 },
        sessionTarget: "main",
        wakeMode: "next-heartbeat",
        payload: { kind: "systemEvent", text: "Synthetic startup work" },
        state: { nextRunAtMs: reservedAt - 1000 },
      }));
      await saveCronStore(storePath, { version: 1, jobs });
      const wakes: Parameters<typeof requestHeartbeat>[0][] = [];
      setHeartbeatWakeHandler(async () => ({ status: "ran", durationMs: 1 }));
      const cron = new CronService({
        storePath,
        cronEnabled: true,
        log,
        enqueueSystemEvent: vi.fn(),
        requestHeartbeat: (opts) => {
          wakes.push(opts);
          requestHeartbeat(opts);
          vi.setSystemTime(Date.now() + 1000);
        },
        runIsolatedAgentJob: async () => ({ status: "ok" }),
      });
      try {
        await cron.start();
        expect(wakes).toHaveLength(2);
        const tasks = listTaskRecords();
        expect(tasks).toHaveLength(2);
        expect(tasks.find((task) => task.sourceId === "second")?.runId).toBe(
          createCronExecutionId("second", reservedAt + 1000),
        );
        for (const task of tasks) {
          expect(wakes.find((wake) => wake.reason === `cron:${task.sourceId}`)?.sessionKey).toBe(
            task.childSessionKey,
          );
        }
        await vi.advanceTimersByTimeAsync(250);
        expect(listTaskRecords().map((task) => task.status)).toEqual(["succeeded", "succeeded"]);
      } finally {
        cron.stop();
        resetHeartbeatWakeStateForTests();
        resetTaskRegistryForTests({ persist: false });
        resetTaskFlowRegistryForTests({ persist: false });
        resetDetachedTaskLifecycleRuntimeForTests();
      }
    });
  });

  it.each([
    { result: { status: "ran", durationMs: 10 } as HeartbeatRunResult, expected: "succeeded" },
    {
      result: { status: "failed", reason: "synthetic execution failure" } as HeartbeatRunResult,
      expected: "failed",
    },
    {
      result: { status: "skipped", reason: "quiet-hours" } as HeartbeatRunResult,
      expected: "failed",
    },
  ])(
    "keeps the task awaiting execution, then records $expected for $result.status",
    async ({ result, expected }) => {
      await withStateDirEnv("openclaw-cron-task-proof-", async () => {
        resetDetachedTaskLifecycleRuntimeForTests();
        resetTaskRegistryForTests({ persist: false });
        resetTaskFlowRegistryForTests({ persist: false });
        resetHeartbeatWakeStateForTests();
        resetSystemEventsForTest();
        const { storePath } = await makeStorePath();
        configureTaskRegistryMaintenance({ cronStorePath: storePath, runtimeAuthoritative: true });
        const handler = vi
          .fn()
          .mockResolvedValueOnce({ status: "skipped", reason: "min-spacing", retryAfterMs: 500 })
          .mockResolvedValue(result);
        setHeartbeatWakeHandler(handler);
        const cron = new CronService({
          storePath,
          cronEnabled: true,
          log,
          enqueueSystemEvent: (text, opts) => {
            const sessionKey = opts!.sessionKey!;
            const event = enqueueSystemEventEntry(text, { sessionKey });
            return event
              ? {
                  accepted: true,
                  remove: () => consumeSelectedSystemEventEntries(sessionKey, [event]).length > 0,
                }
              : { accepted: false };
          },
          requestHeartbeat,
          runHeartbeatOnce: async () => ({ status: "skipped", reason: "cron-in-progress" }),
          runIsolatedAgentJob: async () => ({ status: "ok" }),
        });
        try {
          await cron.start();
          const job = await cron.add({
            name: "Synthetic deferred technical work",
            enabled: true,
            schedule: { kind: "every", everyMs: 86400000 },
            sessionTarget: "main",
            wakeMode: "now",
            payload: { kind: "systemEvent", text: "Summarize the synthetic fixture artifact." },
          });
          const startedAt = Date.now();
          const runId = createCronExecutionId(job.id, startedAt);
          await cron.run(job.id, "force");
          expect(findTaskByRunId(runId)?.status).toBe("queued");
          expect(reconcileInspectableTasks().find((task) => task.runId === runId)?.status).toBe(
            "queued",
          );
          expect(
            getInspectableActiveTaskRestartBlockers().some((task) => task.runId === runId),
          ).toBe(true);
          await vi.advanceTimersByTimeAsync(250);
          expect(handler).toHaveBeenCalledTimes(1);
          expect(findTaskByRunId(runId)?.status).toBe("queued");
          expect(reconcileInspectableTasks().find((task) => task.runId === runId)?.status).toBe(
            "queued",
          );
          expect(
            getInspectableActiveTaskRestartBlockers().some((task) => task.runId === runId),
          ).toBe(true);
          await vi.advanceTimersByTimeAsync(500);
          expect(handler).toHaveBeenCalledTimes(2);
          expect(handler.mock.calls[1][0].sessionKey).toBe(findTaskByRunId(runId)?.childSessionKey);
          expect(findTaskByRunId(runId)?.status).toBe(expected);
          expect(findTaskByRunId(runId)?.deliveryStatus).toBe("not_applicable");
          if (result.status !== "ran") {
            expect(peekSystemEventEntries(findTaskByRunId(runId)!.childSessionKey!)).toEqual([]);
            expect(findTaskByRunId(runId)?.error).toContain(result.reason);
          }
        } finally {
          cron.stop();
          resetTaskRegistryMaintenanceRuntimeForTests();
          resetHeartbeatWakeStateForTests();
          resetSystemEventsForTest();
          resetTaskRegistryForTests({ persist: false });
          resetTaskFlowRegistryForTests({ persist: false });
          resetDetachedTaskLifecycleRuntimeForTests();
        }
      });
    },
  );
});
