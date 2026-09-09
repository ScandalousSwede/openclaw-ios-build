// Actual timer admission, terminal receipt, recovery, and suspension boundaries.
import { afterEach, describe, expect, it, vi } from "vitest";
import { createDeferred } from "../../../test/helpers/promise.js";
import { setupCronServiceSuite, writeCronStoreSnapshot } from "../../cron/service.test-harness.js";
import { onTimer } from "../../cron/service/timer.test-support.js";
import type { CronJob } from "../../cron/types.js";
import {
  requestHeartbeatAndWait,
  setHeartbeatWakeHandler,
  type HeartbeatWakeHandler,
} from "../../infra/heartbeat-wake.js";
import {
  enqueueSystemEventWithReceipt,
  drainSystemEventEntries,
  resetSystemEventsForTest,
} from "../../infra/system-events.js";
import { getQueueSize } from "../../process/command-queue.js";
import {
  getActiveGatewayRootWorkCount,
  getGatewaySuspendAdmissionPhase,
  resetGatewayWorkAdmission,
  tryBeginGatewaySuspendAdmission,
} from "../../process/gateway-work-admission.js";
import { CommandLane } from "../../process/lanes.js";
import { openOpenClawStateDatabase } from "../../state/openclaw-state-db.js";
import { listTaskRecordsUnsorted } from "../../tasks/task-registry.js";
import { resetTaskRegistryForTests } from "../../tasks/task-runtime.test-helpers.js";
import { cronStoreKey } from "../store/key.js";
import { inspectActiveCronRunReceipt } from "../store/run-receipt-store.js";
import { readCronTaskRunHistoryPage } from "../task-run-history.js";
import { getSuspensionVisibleCronTaskRunCount } from "./active-run-cancellation.js";
import { stop } from "./ops-lifecycle.js";
import { enqueueRun } from "./ops-run.js";
import {
  createTimerTestState,
  createDueMainJob,
  createDueIsolatedAgentJob,
} from "./timer.test-fixtures.js";

const { logger, makeStorePath } = setupCronServiceSuite({ prefix: "cron-service-timer-lifecycle" });

afterEach(() => {
  resetTaskRegistryForTests();
});

describe("cron service timer seam coverage", () => {
  it.each(["now", "next-heartbeat"] as const)(
    "keeps %s retained heartbeat work nonterminal while a sibling finishes",
    async (wakeMode) => {
      const { storePath } = await makeStorePath();
      const now = Date.now();
      const sessionKey = "agent:main:main";
      const job = createDueMainJob({ now, wakeMode });
      const sibling = createDueIsolatedAgentJob({ now });
      const release = createDeferred<{ status: "ran"; durationMs: number }>();
      const handler = vi
        .fn<HeartbeatWakeHandler>()
        .mockResolvedValueOnce({ status: "skipped", reason: "cron-in-progress" })
        .mockImplementation(async () => {
          drainSystemEventEntries(sessionKey);
          return await release.promise;
        });
      setHeartbeatWakeHandler(handler);
      await writeCronStoreSnapshot({ storePath, jobs: [job, sibling] });
      const state = createTimerTestState({
        storePath,
        cronEnabled: true,
        log: logger,
        nowMs: () => Date.now(),
        enqueueSystemEvent: (text, opts) => {
          const remove = enqueueSystemEventWithReceipt(text, {
            sessionKey,
            contextKey: opts?.contextKey,
          });
          return remove ? { accepted: true, remove } : { accepted: false };
        },
        requestHeartbeat: vi.fn(),
        requestHeartbeatAndWait: (wake, lifecycle) =>
          requestHeartbeatAndWait({ ...wake, sessionKey, coalesceMs: 0 }, lifecycle),
        runIsolatedAgentJob: async () => ({ status: "ok", delivered: true }),
      });
      const batch = onTimer(state);
      try {
        await vi.waitFor(() => {
          expect(handler).toHaveBeenCalledTimes(1);
          expect(
            listTaskRecordsUnsorted().find((task) => task.sourceId === sibling.id)?.status,
          ).toBe("succeeded");
        });
        // Join scheduler admission/finalization before checking: an intermediate task snapshot can be falsely green.
        await batch;
        const task = listTaskRecordsUnsorted().find((row) => row.sourceId === job.id);
        expect(task).toBeDefined();
        expect(task?.endedAt).toBeUndefined();
        expect(task?.status).toBe("running");
        expect(inspectActiveCronRunReceipt({ storePath, jobId: job.id })?.receiptId).toBeDefined();
        expect(
          readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
        ).toEqual([]);
        release.resolve({ status: "ran", durationMs: 1 });
        await vi.advanceTimersByTimeAsync(1_000);
        await batch;
        expect(handler).toHaveBeenCalledTimes(2);
        await vi.waitFor(() => {
          expect(listTaskRecordsUnsorted().find((row) => row.taskId === task?.taskId)?.status).toBe(
            "succeeded",
          );
        });
        expect(
          readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
        ).toHaveLength(1);
        expect(state.deps.requestHeartbeat).not.toHaveBeenCalled();
      } finally {
        release.resolve({ status: "ran", durationMs: 1 });
        await vi.advanceTimersByTimeAsync(1_000);
        await batch;
        stop(state);
        setHeartbeatWakeHandler(null);
        resetSystemEventsForTest();
      }
    },
  );

  it("finishes an admitted cron heartbeat while suspension remains closed", async () => {
    // Fake timers lose originating ALS; exercise the actual timer's admitted root.
    vi.useRealTimers();
    resetGatewayWorkAdmission();
    const { storePath } = await makeStorePath();
    const now = Date.now();
    const sessionKey = "agent:main:main";
    const job = createDueMainJob({ now, wakeMode: "now" });
    const firstAttempt = createDeferred();
    const handler = vi.fn<HeartbeatWakeHandler>().mockImplementation(async () => {
      if (handler.mock.calls.length === 1) {
        firstAttempt.resolve();
        return { status: "skipped", reason: "cron-in-progress" };
      }
      drainSystemEventEntries(sessionKey);
      return { status: "ran", durationMs: 1 };
    });
    setHeartbeatWakeHandler(handler);
    await writeCronStoreSnapshot({ storePath, jobs: [job] });
    const state = createTimerTestState({
      storePath,
      cronEnabled: true,
      log: logger,
      nowMs: () => Date.now(),
      enqueueSystemEvent: (text, opts) => {
        const remove = enqueueSystemEventWithReceipt(text, {
          sessionKey,
          contextKey: opts?.contextKey,
        });
        return remove ? { accepted: true, remove } : { accepted: false };
      },
      requestHeartbeat: vi.fn(),
      requestHeartbeatAndWait: (wake, lifecycle) =>
        requestHeartbeatAndWait({ ...wake, sessionKey, coalesceMs: 0 }, lifecycle),
      runIsolatedAgentJob: async () => ({ status: "ok", delivered: true }),
    });
    const batch = onTimer(state);
    let suspension: ReturnType<typeof tryBeginGatewaySuspendAdmission> = null;
    try {
      await firstAttempt.promise;
      await batch;
      const task = listTaskRecordsUnsorted().find((row) => row.sourceId === job.id);
      expect(task?.status).toBe("running");
      expect(getActiveGatewayRootWorkCount()).toBeGreaterThan(0);
      suspension = tryBeginGatewaySuspendAdmission(() => {});
      expect(suspension?.drain()).toBe(true);
      await vi.waitFor(
        () => {
          expect(listTaskRecordsUnsorted().find((row) => row.taskId === task?.taskId)?.status).toBe(
            "succeeded",
          );
          expect(getActiveGatewayRootWorkCount()).toBe(0);
          expect(getSuspensionVisibleCronTaskRunCount()).toBe(0);
        },
        { timeout: 3_000, interval: 10 },
      );
      expect(getGatewaySuspendAdmissionPhase()).toBe("draining");
      expect(handler).toHaveBeenCalledTimes(2);
      expect(inspectActiveCronRunReceipt({ storePath, jobId: job.id })).toBeUndefined();
      expect(
        readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
      ).toEqual([expect.objectContaining({ status: "ok" })]);
    } finally {
      suspension?.release();
      await batch;
      await vi.waitFor(() => expect(getSuspensionVisibleCronTaskRunCount()).toBe(0), {
        timeout: 3_000,
      });
      stop(state);
      setHeartbeatWakeHandler(null);
      resetSystemEventsForTest();
      resetGatewayWorkAdmission();
    }
  });

  it("recovers a deferred heartbeat terminal write without replaying its work", async () => {
    const { storePath } = await makeStorePath();
    const now = Date.now();
    const job = createDueMainJob({ now, wakeMode: "next-heartbeat" });
    job.schedule = { kind: "every", everyMs: 3_600_000, anchorMs: now };
    const release = createDeferred<{ status: "ran"; durationMs: number }>();
    const handler = vi.fn<HeartbeatWakeHandler>().mockImplementation(async () => release.promise);
    setHeartbeatWakeHandler(handler);
    await writeCronStoreSnapshot({ storePath, jobs: [job] });
    const enqueueSystemEvent = vi.fn();
    const state = createTimerTestState({
      storePath,
      cronEnabled: true,
      log: logger,
      nowMs: () => Date.now(),
      enqueueSystemEvent,
      requestHeartbeat: vi.fn(),
      requestHeartbeatAndWait: (wake, lifecycle) =>
        requestHeartbeatAndWait({ ...wake, coalesceMs: 0 }, lifecycle),
      runIsolatedAgentJob: async () => ({ status: "ok", delivered: true }),
    });
    const database = openOpenClawStateDatabase().db;
    let rejectedTerminalWrite = false;
    database.function("reject_deferred_terminal", (jobId, stateJson) => {
      if (jobId === job.id && typeof stateJson === "string") {
        const persisted = JSON.parse(stateJson) as CronJob["state"];
        if (!rejectedTerminalWrite && persisted.lastRunStatus === "ok") {
          rejectedTerminalWrite = true;
          throw new Error("deferred terminal write failed");
        }
      }
      return 0;
    });
    database.exec(`
      CREATE TEMP TRIGGER reject_deferred_terminal
      AFTER UPDATE ON cron_jobs
      BEGIN
        SELECT reject_deferred_terminal(NEW.job_id, NEW.state_json);
      END;
    `);
    const batch = onTimer(state);
    try {
      await vi.waitFor(() => expect(handler).toHaveBeenCalledOnce());
      await batch;
      const task = listTaskRecordsUnsorted().find((row) => row.sourceId === job.id);
      expect(task?.status).toBe("running");
      release.resolve({ status: "ran", durationMs: 1 });
      await vi.waitFor(() => {
        expect(logger.error).toHaveBeenCalledWith(
          expect.objectContaining({ jobId: job.id, error: "deferred terminal write failed" }),
          "cron: deferred heartbeat finalization failed",
        );
      });
      expect(rejectedTerminalWrite).toBe(true);
      expect(inspectActiveCronRunReceipt({ storePath, jobId: job.id })).toBeDefined();
      database.exec("DROP TRIGGER reject_deferred_terminal");
      // Exercise the already-armed production timer and canonical receipt recovery.
      await vi.advanceTimersByTimeAsync(60_000);
      await vi.waitFor(() => {
        expect(inspectActiveCronRunReceipt({ storePath, jobId: job.id })).toBeUndefined();
      });
      expect(handler).toHaveBeenCalledOnce();
      expect(enqueueSystemEvent).toHaveBeenCalledOnce();
      expect(listTaskRecordsUnsorted().filter((row) => row.sourceId === job.id)).toEqual([
        expect.objectContaining({ taskId: task?.taskId, status: "succeeded" }),
      ]);
      expect(
        readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
      ).toEqual([expect.objectContaining({ status: "ok" })]);
    } finally {
      release.resolve({ status: "ran", durationMs: 1 });
      database.exec("DROP TRIGGER IF EXISTS reject_deferred_terminal");
      await batch;
      stop(state);
      setHeartbeatWakeHandler(null);
      resetSystemEventsForTest();
    }
  });

  it("releases a queued manual cron lane while its original heartbeat retains terminal ownership", async () => {
    const { storePath } = await makeStorePath();
    const now = Date.now();
    const sessionKey = "agent:main:main";
    const job = createDueMainJob({ now, wakeMode: "now" });
    const sibling = createDueIsolatedAgentJob({ now });
    job.state.nextRunAtMs = now + 60_000;
    sibling.state.nextRunAtMs = now + 60_000;
    const release = createDeferred<{ status: "ran"; durationMs: number }>();
    const observedDepths: number[] = [];
    const handler = vi.fn<HeartbeatWakeHandler>().mockImplementation(async () => {
      const depth = getQueueSize(CommandLane.Cron);
      observedDepths.push(depth);
      // The runner's existing busy contract preserves unrelated queued Cron work.
      if (depth > 1) {
        return { status: "skipped", reason: "cron-in-progress" };
      }
      drainSystemEventEntries(sessionKey);
      return await release.promise;
    });
    setHeartbeatWakeHandler(handler);
    await writeCronStoreSnapshot({ storePath, jobs: [job, sibling] });
    const state = createTimerTestState({
      storePath,
      cronEnabled: true,
      log: logger,
      nowMs: () => Date.now(),
      enqueueSystemEvent: (text, opts) => {
        const remove = enqueueSystemEventWithReceipt(text, {
          sessionKey,
          contextKey: opts?.contextKey,
        });
        return remove ? { accepted: true, remove } : { accepted: false };
      },
      requestHeartbeat: vi.fn(),
      requestHeartbeatAndWait: (wake, lifecycle) =>
        requestHeartbeatAndWait({ ...wake, sessionKey, coalesceMs: 0 }, lifecycle),
      runIsolatedAgentJob: async () => ({ status: "ok", delivered: true }),
    });
    try {
      await enqueueRun(state, job.id, "force");
      await enqueueRun(state, sibling.id, "force");
      await vi.waitFor(() => {
        expect(listTaskRecordsUnsorted().find((task) => task.sourceId === sibling.id)?.status).toBe(
          "succeeded",
        );
        expect(getQueueSize(CommandLane.Cron)).toBe(0);
      });
      expect(observedDepths[0]).toBe(2);
      const task = listTaskRecordsUnsorted().find((row) => row.sourceId === job.id);
      expect(task?.status).toBe("running");
      expect(task?.endedAt).toBeUndefined();
      const receipt = inspectActiveCronRunReceipt({ storePath, jobId: job.id });
      expect(receipt?.receiptId).toBeDefined();
      expect(task?.runId).toContain(receipt?.receiptId);
      expect(
        readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
      ).toEqual([]);
      release.resolve({ status: "ran", durationMs: 1 });
      await vi.advanceTimersByTimeAsync(1_000);
      await vi.waitFor(() => {
        expect(listTaskRecordsUnsorted().find((row) => row.taskId === task?.taskId)?.status).toBe(
          "succeeded",
        );
      });
      expect(handler).toHaveBeenCalledTimes(2);
      expect(
        readCronTaskRunHistoryPage({ storeKey: cronStoreKey(storePath), jobId: job.id }).entries,
      ).toHaveLength(1);
      expect(inspectActiveCronRunReceipt({ storePath, jobId: job.id })).toBeUndefined();
    } finally {
      release.resolve({ status: "ran", durationMs: 1 });
      await vi.advanceTimersByTimeAsync(1_000);
      await vi.waitFor(() => expect(getSuspensionVisibleCronTaskRunCount()).toBe(0));
      stop(state);
      setHeartbeatWakeHandler(null);
      resetSystemEventsForTest();
    }
  });
});
