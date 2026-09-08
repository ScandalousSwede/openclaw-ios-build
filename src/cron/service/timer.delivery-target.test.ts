// Main cron route lookup must share the host's canonical session target.
import fs from "node:fs/promises";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { resetTaskRegistryForTests } from "../../tasks/task-registry.js";
import { setupCronServiceSuite } from "../service.test-harness.js";
import type { CronJob } from "../types.js";
import { createCronServiceState } from "./state.js";
import { executeJobCore } from "./timer.js";

const { logger, makeStorePath } = setupCronServiceSuite({ prefix: "cron-delivery-target" });
afterEach(() => resetTaskRegistryForTests());
const now = Date.parse("2026-09-08T14:00:00Z");
const route = {
  channel: "discord",
  to: "channel-owner",
  accountId: "default",
  threadId: "topic-7",
};

describe("main cron canonical delivery lookup", () => {
  it.each([
    { requested: "main", canonical: "agent:main:main", agentId: "main" },
    { requested: "main", canonical: "agent:work:custom", agentId: "work" },
    { requested: "agent:work:main", canonical: "agent:work:custom", agentId: "work" },
    { requested: "global", canonical: "global", agentId: "work" },
  ])(
    "uses the resolved $canonical metadata for $requested",
    async ({ requested, canonical, agentId }) => {
      const { storePath } = await makeStorePath();
      const sessionStore = path.join(path.dirname(path.dirname(storePath)), "route-sessions.json");
      await fs.writeFile(
        sessionStore,
        JSON.stringify({
          [canonical]: { sessionId: "route-session", updatedAt: now, deliveryContext: route },
          ...(requested !== canonical
            ? {
                [requested]: {
                  sessionId: "decoy",
                  updatedAt: now,
                  lastChannel: "discord",
                  lastTo: "wrong-route",
                },
              }
            : {}),
        }),
      );
      const resolveTarget = vi.fn(({ sessionKey }: { sessionKey: string }) => ({
        agentId,
        sessionKey: sessionKey === requested ? canonical : sessionKey,
      }));
      const resolveStore = vi.fn(() => sessionStore);
      const enqueueSystemEvent = vi.fn();
      const state = createCronServiceState({
        storePath,
        cronEnabled: true,
        log: logger,
        nowMs: () => now,
        resolveMainSessionTarget: resolveTarget,
        resolveSessionStorePath: resolveStore,
        enqueueSystemEvent,
        requestHeartbeat: vi.fn(),
        runIsolatedAgentJob: vi.fn(async () => ({ status: "ok" as const })),
      });
      const job: CronJob = {
        id: "route-check",
        name: "route check",
        enabled: true,
        createdAtMs: now,
        updatedAtMs: now,
        schedule: { kind: "every", everyMs: 60000 },
        sessionTarget: "main",
        sessionKey: requested,
        wakeMode: "next-heartbeat",
        payload: { kind: "systemEvent", text: "synthetic route check" },
        state: { runningAtMs: now },
      };
      const result = await executeJobCore(state, job);
      expect(result.status).toBe("ok");
      expect(resolveTarget).toHaveBeenCalledWith({ agentId: undefined, sessionKey: requested });
      expect(resolveStore).toHaveBeenCalledWith(agentId);
      expect(enqueueSystemEvent).toHaveBeenCalledWith(
        "synthetic route check",
        expect.objectContaining({ deliveryContext: route }),
      );
    },
  );

  it.each(["unresolved", "throws", "missing-route"] as const)(
    "does not fall back to raw or owner routing when %s",
    async (mode) => {
      const { storePath } = await makeStorePath();
      const sessionStore = path.join(path.dirname(path.dirname(storePath)), "route-sessions.json");
      await fs.writeFile(
        sessionStore,
        JSON.stringify({
          main: { sessionId: "raw-decoy", updatedAt: now, deliveryContext: route },
        }),
      );
      const enqueueSystemEvent = vi.fn();
      const state = createCronServiceState({
        storePath,
        cronEnabled: true,
        log: logger,
        nowMs: () => now,
        resolveMainSessionTarget: ({ sessionKey }) => {
          if (sessionKey !== "main") {
            return { agentId: "main", sessionKey };
          }
          if (mode === "throws") {
            throw new Error("synthetic target failure");
          }
          return mode === "unresolved"
            ? undefined
            : { agentId: "main", sessionKey: "agent:main:absent" };
        },
        resolveSessionStorePath: () => sessionStore,
        enqueueSystemEvent,
        requestHeartbeat: vi.fn(),
        runIsolatedAgentJob: vi.fn(async () => ({ status: "ok" as const })),
      });
      const job: CronJob = {
        id: "route-missing",
        name: "route missing",
        enabled: true,
        createdAtMs: now,
        updatedAtMs: now,
        schedule: { kind: "every", everyMs: 60000 },
        sessionTarget: "main",
        sessionKey: "main",
        wakeMode: "next-heartbeat",
        owner: { agentId: "main", sessionKey: "main" },
        payload: { kind: "systemEvent", text: "synthetic missing route" },
        state: { runningAtMs: now },
      };
      if (mode === "throws") {
        // Execution already fails closed when the authoritative host rejects its target.
        await expect(executeJobCore(state, job)).rejects.toThrow("synthetic target failure");
        expect(enqueueSystemEvent).not.toHaveBeenCalled();
        return;
      }
      expect((await executeJobCore(state, job)).status).toBe("ok");
      expect(enqueueSystemEvent).toHaveBeenCalledOnce();
      expect(enqueueSystemEvent.mock.calls[0]?.[1]).not.toHaveProperty("deliveryContext");
    },
  );
});
